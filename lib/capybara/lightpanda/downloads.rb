# frozen_string_literal: true

require "fileutils"

module Capybara
  module Lightpanda
    # File-download tracker built on `Browser.setDownloadBehavior` (upstream PR
    # #2722, build >= 7545, guaranteed by MINIMUM_NIGHTLY_BUILD). When a
    # navigation response carries `Content-Disposition: attachment`, Lightpanda
    # streams the body to disk under `downloadPath` and — with
    # `eventsEnabled: true` — emits `Browser.downloadWillBegin` /
    # `Browser.downloadProgress`. We mirror those into a completed-files list +
    # a blocking `wait`, the way ferrum's Downloads does.
    #
    # Navigation downloads require Content-Disposition: attachment, not just a
    # MIME type. The floor also honors an anchor's download attribute (upstream
    # #4124, 11097); Node#click lets that native activation finish.
    # Capybara's MIME-only :download shared spec still stays in capybara_skip.
    #
    # Structure deliberately mirrors Network (same browser ref, same mutex +
    # subscribe/unsubscribe lifecycle, same reset-after-disposeBrowserContext
    # contract) so the two trackers behave identically under create_page/reset.
    class Downloads # rubocop:disable Metrics/ClassLength
      attr_reader :browser, :path

      # How long #wait gives a download to BEGIN (the downloadWillBegin frame
      # can arrive a beat after the click that triggers it, once the click's
      # own wait_for_idle has already returned). Once a download has begun we
      # wait the full `timeout` for it to finish.
      DOWNLOAD_BEGIN_GRACE = 1.0

      def initialize(browser)
        @browser = browser
        @path = nil
        @enabled = false
        @destination_unknown = false
        @mutex = Mutex.new
        @configuration_mutex = Mutex.new
        @pending = {}  # guid => absolute path when the download began
        @files = []    # absolute paths of completed downloads, in order
        @started = 0   # monotonic count of downloads begun this session
        @will_handler = nil
        @progress_handler = nil
      end

      # Opt into downloads, writing completed files under `save_path`. No-op
      # when `save_path` is blank — downloads then stay at Lightpanda's `deny`
      # default. Connection-scoped (browser.command) like Network.enable;
      # Browser#create_page calls this after the context is loaded (the CDP
      # method is a no-op without one). Subscribe BEFORE the wire toggle so no
      # event can slip past, and roll the handlers back if the command fails.
      def enable(save_path)
        @configuration_mutex.synchronize do
          allow_downloads(save_path) unless @enabled || save_path.to_s.empty?
        end
      end

      # Ferrum's `downloads.set_behavior(save_path:, behavior: :allow)`, which
      # Cuprite suites call in setup to pick the download directory. `:allow`
      # (re)points downloads at `save_path`; `:deny` and `:default` turn them
      # off. Files already recorded stay listed. Lasts until the next
      # `reset!`, which goes back to the configured `save_path`, so call it
      # per test as those suites do.
      BEHAVIORS = { allow: "allow", deny: "deny", default: "default" }.freeze

      def set_behavior(save_path:, behavior: :allow)
        wire = BEHAVIORS.fetch(behavior.to_sym) do
          raise ArgumentError, "unknown download behavior #{behavior.inspect} (use :allow, :deny or :default)"
        end
        @configuration_mutex.synchronize do
          return allow_downloads(save_path) if wire == "allow" && !save_path.to_s.empty?

          disable_downloads(wire == "allow" ? "deny" : wire)
        end
      end

      # Chromium accepts the directory when configuring the page. Lightpanda
      # creates it on the browser host when the first attachment arrives.
      def download_path=(destination)
        @configuration_mutex.synchronize { allow_downloads(destination, prepare_directory: false) }
      end

      # Absolute paths of downloads completed this session (newest last).
      def files
        @mutex.synchronize do
          check_destination!
          @files.dup
        end
      end

      # Monotonic count of downloads that have begun this session. Used by
      # #wait to detect "a download started since I was called" even after the
      # event queue has drained and @pending is empty again.
      def started_count
        @mutex.synchronize do
          check_destination!
          @started
        end
      end

      def in_progress?
        @mutex.synchronize do
          check_destination!
          @pending.any?
        end
      end

      # Block until in-flight downloads finish, then return the completed-file
      # list. Non-raising, matching Network#wait_for_idle.
      #
      # The triggering click returns (its wait_for_idle settles on the
      # navigation's network response) slightly BEFORE the downloadWillBegin
      # frame is processed, so a naive `wait until !in_progress?` would see an
      # empty queue and return before the download even registered. Instead:
      # give a download up to DOWNLOAD_BEGIN_GRACE to begin (tracked by the
      # monotonic @started counter, immune to the queue already having drained),
      # then wait up to `timeout` for every in-flight download to finish.
      # With a trigger block the caller expects a new download: record the
      # baseline before yielding and allow the full timeout for it to start.
      def wait(seconds = 5, timeout: seconds)
        baseline = started_count
        yield if block_given?

        deadline = Utils::Wait.deadline(timeout)
        begin_deadline = block_given? ? deadline : Utils::Wait.deadline([timeout, DOWNLOAD_BEGIN_GRACE].min)
        loop do
          now = Utils::Wait.monotonic_time
          @mutex.synchronize do
            check_destination!
            began = @started > baseline
            return @files.dup if now >= deadline || (@pending.empty? && (began || now >= begin_deadline))
          end
          sleep 0.02
        end
      end

      def clear
        @mutex.synchronize do
          @files.clear
          @pending.clear
          @started = 0
        end
      end

      # Wipe local state after Target.disposeBrowserContext, which drops both
      # the subscriptions and the per-connection download config — leaving
      # @enabled true would no-op the next #enable. Mirrors Network#reset.
      def reset
        @configuration_mutex.synchronize do
          unsubscribe
          clear
          @enabled = false
          @mutex.synchronize do
            @path = nil
            @destination_unknown = false
          end
        end
      end

      private

      def disable_downloads(behavior)
        result = browser.command("Browser.setDownloadBehavior", behavior: behavior, eventsEnabled: false)
        unsubscribe
        @enabled = false
        @mutex.synchronize do
          @path = nil
          @destination_unknown = false
          @pending.clear
        end
        result
      rescue TimeoutError
        invalidate_destination
        raise
      end

      def allow_downloads(save_path, prepare_directory: true)
        destination = File.expand_path(save_path.to_s)
        FileUtils.mkdir_p(destination) if prepare_directory
        subscribe unless @enabled
        begin
          params = { behavior: "allow", downloadPath: destination, eventsEnabled: true }
          browser.client.command("Browser.setDownloadBehavior", params,
                                 on_success: -> { @mutex.synchronize { @path = destination } })
        rescue TimeoutError
          invalidate_destination
          raise
        rescue StandardError
          unsubscribe unless @enabled
          raise
        end
        @mutex.synchronize { @destination_unknown = false }
        @enabled = true
      end

      def invalidate_destination
        # The browser may already have applied a command whose reply timed out.
        unsubscribe
        @enabled = false
        @mutex.synchronize do
          @destination_unknown = true
          @path = nil
          @pending.clear
        end
      end

      def check_destination!
        return unless @destination_unknown

        raise Error, "Download destination is unknown after a timeout. Set the destination again or reset the session."
      end

      def subscribe
        @will_handler = build_will_handler
        @progress_handler = build_progress_handler
        browser.on("Browser.downloadWillBegin", &@will_handler)
        browser.on("Browser.downloadProgress", &@progress_handler)
      end

      # downloadWillBegin carries {guid, url, suggestedFilename}. behavior
      # "allow" writes the file under the (path-stripped) suggested name, so
      # record the directory here in case the next download uses another one.
      def build_will_handler
        lambda do |params|
          guid = params["guid"]
          name = File.basename(params["suggestedFilename"].to_s)
          next if guid.nil? || name.empty?

          @mutex.synchronize do
            next unless @path

            @pending[guid] = File.join(@path, name)
            @started += 1
          end
        end
      end

      # downloadProgress carries {guid, state}. On "completed" the file is on
      # disk at downloadPath/basename; "canceled" just drops the pending entry.
      def build_progress_handler
        lambda do |params|
          guid = params["guid"]
          case params["state"]
          when "completed"
            @mutex.synchronize do
              path = @pending.delete(guid)
              @files << path if path
            end
          when "canceled"
            @mutex.synchronize { @pending.delete(guid) }
          end
        end
      end

      def unsubscribe
        browser.off("Browser.downloadWillBegin", @will_handler) if @will_handler
        browser.off("Browser.downloadProgress", @progress_handler) if @progress_handler
        @will_handler = nil
        @progress_handler = nil
      end
    end
  end
end
