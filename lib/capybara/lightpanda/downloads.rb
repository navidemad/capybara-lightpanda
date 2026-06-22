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
    # IMPORTANT: the trigger is `Content-Disposition: attachment`, NOT MIME
    # type. A `text/csv` (or any) response without that header is rendered as a
    # normal navigation, not downloaded — which is why Capybara's MIME-triggered
    # `:download` shared spec stays in capybara_skip.
    #
    # Structure deliberately mirrors Network (same browser ref, same mutex +
    # subscribe/unsubscribe lifecycle, same reset-after-disposeBrowserContext
    # contract) so the two trackers behave identically under create_page/reset.
    class Downloads
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
        @mutex = Mutex.new
        @pending = {}  # guid => on-disk basename (from suggestedFilename)
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
        return if @enabled || save_path.to_s.empty?

        @path = File.expand_path(save_path.to_s)
        FileUtils.mkdir_p(@path)
        subscribe
        begin
          browser.command("Browser.setDownloadBehavior",
                          behavior: "allow", downloadPath: @path, eventsEnabled: true)
        rescue StandardError
          unsubscribe
          @path = nil
          raise
        end
        @enabled = true
      end

      # Absolute paths of downloads completed this session (newest last).
      def files
        @mutex.synchronize { @files.dup }
      end

      # Monotonic count of downloads that have begun this session. Used by
      # #wait to detect "a download started since I was called" even after the
      # event queue has drained and @pending is empty again.
      def started_count
        @mutex.synchronize { @started }
      end

      def in_progress?
        @mutex.synchronize { @pending.any? }
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
      def wait(timeout: 5)
        baseline = started_count
        clock = -> { ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) }
        hard_deadline = clock.call + timeout
        begin_deadline = clock.call + [timeout, DOWNLOAD_BEGIN_GRACE].min

        loop do
          began = started_count > baseline
          done = (began ? !in_progress? : clock.call >= begin_deadline) || clock.call >= hard_deadline
          return files if done

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
        unsubscribe
        clear
        @enabled = false
        @path = nil
      end

      private

      def subscribe
        @will_handler = build_will_handler
        @progress_handler = build_progress_handler
        browser.on("Browser.downloadWillBegin", &@will_handler)
        browser.on("Browser.downloadProgress", &@progress_handler)
      end

      # downloadWillBegin carries {guid, url, suggestedFilename}. behavior
      # "allow" writes the file under the (path-stripped) suggested name, so
      # remember guid => basename to resolve the absolute path on completion.
      def build_will_handler
        lambda do |params|
          guid = params["guid"]
          name = File.basename(params["suggestedFilename"].to_s)
          next if guid.nil? || name.empty?

          @mutex.synchronize do
            @pending[guid] = name
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
              name = @pending.delete(guid)
              @files << File.join(@path, name) if name && @path
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
