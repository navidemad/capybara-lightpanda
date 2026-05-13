# frozen_string_literal: true

require "open3"

module Capybara
  module Lightpanda
    class Process
      READY_PATTERN = /server running.*address\s*=\s*(\d+\.\d+\.\d+\.\d+:\d+)/m
      ADDRESS_IN_USE_PATTERN = /err=AddressInUse/

      # Floor for the cookie/navigation/redirect/modal/keyboard/css/forms/dispatch/
      # xpath/history/iframe-context/dialog fixes the gem now relies on:
      # PR #2255 (Network.clearBrowserCookies empty params + Network.getAllCookies),
      # PR #2257 (window.location.pathname/.search assignment triggers navigation),
      # PR #2265 (URL fragment inherited across fragment-less redirect),
      # PR #2261 (LP.handleJavaScriptDialog pre-arm), PR #2283 (Referer on
      # cross-page nav), PR #2292 (KeyboardEvent.keyCode/charCode), PR #2294
      # (UA stylesheet display:none for HEAD/SCRIPT/STYLE/NOSCRIPT/TEMPLATE/
      # TITLE/[type=hidden]), PR #2308 (textarea LF→CRLF), PR #2312 (<input
      # type=image> click submits form), PR #2315 (:disabled honors fieldset/
      # optgroup ancestors), PR #2322 (LP dialog defaultText fallback when
      # promptText is null), PR #2324 (<label> click runs activation behavior
      # on labeled control), PR #2286 (HTML constraint validation API:
      # el.validity, validationMessage, checkValidity, reportValidity),
      # PR #2342 (<summary> click toggles parent <details>.open),
      # PR #2352 (HTMLInputElement.pattern + patternMismatch via V8 RegExp),
      # PR #2368 (events: report listener exceptions instead of halting
      # dispatch — lets us drop the polyfills.js patchDispatch IIFE),
      # PR #2289 (Page.getNavigationHistory + Page.navigateToHistoryEntry —
      # lets us drop the history.back()/history.forward() JS workaround in
      # Browser#back / #forward), PR #2305 (XPath 1.0: Document.evaluate,
      # XPathResult, XPathEvaluator, XPathExpression — lets us drop the
      # ~700 LOC XPath polyfill in javascripts/index.js),
      # PR #2431 (cdp: remove duplicate Page.frameNavigated emission + reuse
      # child frame's V8 context — fixes issue #2400 iframe contextId churn,
      # lets us drop Browser#find_in_frame's refresh_frame_stack! rescue),
      # PR #2445 (cdp: reset browser context arena on Target.disposeBrowserContext
      # — restores per-spec state hygiene during Driver#reset!, cures the
      # batch-mode pollution that PR #2431 alone exposed),
      # PR #2435 (dom: implement HTMLDialogElement.{show, showModal, close}
      # natively — lets us drop the polyfills.js HTMLDialogElement block).
      # Build 6199 = first nightly carrying all three 2026-05-13 merges
      # (#2431, #2445, #2435); nightly 6198 was published before the merges.
      MINIMUM_NIGHTLY_BUILD = Gem::Version.new("6199")

      attr_reader :pid, :ws_url, :version, :nightly_build

      def initialize(options)
        @options = options
        @pid = nil
        @ws_url = nil
        @version = nil
        @nightly_build = nil
        @stdout_r = nil
        @stdout_w = nil
        @stderr_r = nil
        @stderr_w = nil
        @finalizer_registered = false
      end

      def start
        binary_path = @options.browser_path || Binary.find_or_download

        raise BinaryNotFoundError, "Lightpanda binary not found" unless binary_path

        check_minimum_version(binary_path)
        attempt_start(binary_path)
      rescue ProcessTimeoutError => e
        raise unless e.message.include?("already in use")

        kill_process_on_port(@options.port)
        attempt_start(binary_path)
      end

      def stop
        return unless @pid

        begin
          ::Process.kill("TERM", -@pid) # Kill process group
        rescue Errno::ESRCH, Errno::EPERM
          # Process group already dead, try direct
          begin
            ::Process.kill("TERM", @pid)
          rescue Errno::ESRCH
            # Process already dead
          end
        end

        begin
          ::Process.wait(@pid)
        rescue Errno::ECHILD
          # Already reaped
        end

        cleanup_pipes
        @pid = nil
      end

      def alive?
        return false unless @pid

        ::Process.kill(0, @pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      private

      def check_minimum_version(binary_path)
        stdout, = Open3.capture3(binary_path, "version")
        @version = stdout.strip
        # Accept either `nightly.NNNN` (publicly distributed builds) or
        # `dev.NNNN` (locally compiled trees) — the build number is the same
        # `git rev-list --count HEAD` counter, just labelled differently.
        build = @version[/(?:nightly|dev)\.(\d+)/, 1]
        @nightly_build = Gem::Version.new(build) if build

        return if @nightly_build && @nightly_build >= MINIMUM_NIGHTLY_BUILD

        raise BinaryError,
              "Lightpanda #{@version} is too old. " \
              "This gem requires build >= #{MINIMUM_NIGHTLY_BUILD}. " \
              "Update: curl -sL https://github.com/lightpanda-io/browser/releases/download/nightly/" \
              "#{Binary.platform_binary} -o #{binary_path} && chmod +x #{binary_path}"
      rescue Errno::ENOENT
        # Binary not runnable — let attempt_start handle it
      end

      def attempt_start(binary_path)
        @stdout_r, @stdout_w = IO.pipe
        @stderr_r, @stderr_w = IO.pipe

        @pid = spawn_process(binary_path)
        register_finalizer(@pid)

        @stdout_w.close
        @stderr_w.close

        wait_for_ready

        # Drain stderr/stdout to prevent pipe buffer from filling up
        # and blocking the Lightpanda process
        start_drain_thread
      end

      def start_drain_thread
        @drain_thread = Thread.new do
          ios = [@stdout_r, @stderr_r].compact
          loop do
            ready = IO.select(ios, nil, nil, 0.5)
            next unless ready

            ready[0].each do |io|
              io.read_nonblock(4096)
            rescue IO::WaitReadable
              # No data
            rescue EOFError
              ios.delete(io)
            end

            break if ios.empty?
          rescue IOError
            break
          end
        end
      end

      def spawn_process(binary_path)
        args = build_args

        ::Process.spawn(
          { "LIGHTPANDA_DISABLE_TELEMETRY" => "true" },
          binary_path, *args,
          out: @stdout_w,
          err: @stderr_w,
          pgroup: true
        )
      end

      def build_args
        [
          "serve",
          "--host",
          @options.host.to_s,
          "--port",
          @options.port.to_s,
          "--log_level",
          "info",
        ]
      end

      def wait_for_ready
        started_at = Time.now
        output = +""

        catch(:ready) do
          while Time.now - started_at < @options.process_timeout
            ready = IO.select([@stdout_r, @stderr_r], nil, nil, 0.1)

            next unless ready

            ready[0].each do |io|
              chunk = io.read_nonblock(1024)
              output << chunk

              if (match = output.match(READY_PATTERN))
                @ws_url = "ws://#{match[1]}/"
                throw(:ready)
              end

              if output.match?(ADDRESS_IN_USE_PATTERN)
                cleanup_failed_process
                raise ProcessTimeoutError,
                      "Lightpanda failed to start: port #{@options.port} is already in use"
              end
            rescue IO::WaitReadable
              # No data available yet
            rescue EOFError
              # Pipe closed
            end
          end

          stop

          raise ProcessTimeoutError,
                "Lightpanda failed to start within #{@options.process_timeout} seconds.\nOutput: #{output}"
        end
      end

      def cleanup_failed_process
        return unless @pid

        begin
          ::Process.wait(@pid, ::Process::WNOHANG)
        rescue Errno::ECHILD
          nil
        end

        cleanup_pipes
        @pid = nil
      end

      # Auto-recover when a previous Lightpanda is still bound to our port.
      # Best-effort: relies on `lsof` to map port → pid (macOS / most Linux
      # distros). Where `lsof` isn't on PATH, we surface a clear error rather
      # than silently failing the retry — the user can free the port manually.
      def kill_process_on_port(port)
        port = port.to_i
        return if port <= 0

        pids = pids_listening_on(port)
        if pids.nil?
          raise BinaryError,
                "Port #{port} is in use and `lsof` is unavailable to identify the holder. " \
                "Free the port manually or install lsof to enable automatic recovery."
        end

        pids.each do |pid|
          ::Process.kill("TERM", pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end

        sleep 0.5
      end

      # Returns an array of PIDs holding the TCP port, [] if none, or nil if
      # `lsof` itself isn't available / usable on this system.
      #
      # `lsof -ti` exits 1 with empty stdout/stderr when nothing matches the
      # filter — that's the common "port not held" case, so we treat
      # (exit != 0, empty stdout, empty stderr) as []. A non-zero exit with
      # stderr content is a real lsof failure (broken install, permission
      # error, etc.); surface that as `nil` so the caller raises a clear
      # BinaryError instead of silently retrying the start.
      def pids_listening_on(port)
        stdout, stderr, status = Open3.capture3("lsof", "-ti", "tcp:#{port}")
        return parse_lsof_pids(stdout) if status.success?
        return [] if stdout.strip.empty? && stderr.strip.empty?

        nil
      rescue Errno::ENOENT
        nil
      end

      def parse_lsof_pids(stdout)
        stdout.split("\n").filter_map do |line|
          pid = line.strip.to_i
          pid.positive? ? pid : nil
        end
      end

      # Class method so the finalizer proc doesn't capture `self` (which
      # would prevent GC from ever running the finalizer).
      class << self
        private

        def weak_kill(pid)
          proc do
            ::Process.kill("TERM", -pid)
            ::Process.wait(pid)
          rescue Errno::ESRCH, Errno::ECHILD, Errno::EPERM
            nil
          end
        end
      end

      # `start` may be called more than once on the same Process instance
      # (Browser#restart_process_if_dead runs `stop` then `start` after a
      # crash). Each `attempt_start` calls `register_finalizer`, and
      # ObjectSpace allows multiple finalizers per object — so without
      # this guard the second start would queue a redundant TERM-on-GC
      # whose first invocation no-ops on ESRCH but is still pure noise.
      # We register exactly once; the captured `pid` is overwritten by
      # `undefine_finalizer + define_finalizer` so the finalizer always
      # references the most recently started process.
      def register_finalizer(pid)
        ObjectSpace.undefine_finalizer(self) if @finalizer_registered
        ObjectSpace.define_finalizer(self, self.class.send(:weak_kill, pid))
        @finalizer_registered = true
      end

      def cleanup_pipes
        [@stdout_r, @stdout_w, @stderr_r, @stderr_w].each do |pipe|
          pipe&.close unless pipe&.closed?
        end
      end
    end
  end
end
