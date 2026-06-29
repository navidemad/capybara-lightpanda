# frozen_string_literal: true

require "open3"

module Capybara
  module Lightpanda
    class Process
      READY_PATTERN = /server running.*address\s*=\s*(\d+\.\d+\.\d+\.\d+:\d+)/m
      ADDRESS_IN_USE_PATTERN = /err=AddressInUse/

      # Seconds to wait for a graceful SIGTERM before escalating to SIGKILL in
      # `stop` / the GC finalizer. Lightpanda absorbs a *single* SIGTERM while a
      # CDP connection is still live (graceful shutdown blocks on the connection
      # worker — see .claude/rules/lightpanda-io.md limitation #7B). The PRIMARY
      # fix is gem-side: Browser closes the CDP WebSocket before SIGTERM at exit
      # (Browser.quit_all via at_exit), so SIGTERM lands after EOF and teardown is
      # instant. This escalation is the BACKSTOP for crash / GC-abandon paths the
      # at_exit can't reach — without it, a SIGTERM left to the finalizer (which
      # can't close the WS) blocked Process.wait forever (the 45-min
      # `rake test:all` hang). NOT the same as #2507/#2509 (telemetry curl-multi),
      # which the gem never hits because it disables telemetry.
      STOP_GRACE_SECONDS = 3

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
      # dispatch — load-bearing for the gem's JS bundle dispatch assumptions),
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
      # natively — load-bearing for the gem's HTMLDialogElement assumptions
      # after polyfills.js was deleted),
      # PR #2450 (forms: add enctype + 5 submitter form-* IDL accessors +
      # text/plain submission — lets us delete polyfills.js entirely; reads
      # of form.enctype / submitter.form{Action,Enctype,Method,NoValidate,
      # Target} now return spec-typed values natively),
      # PR #2478 (css: evaluate @media and matchMedia against viewport —
      # inline <style> @media blocks now apply declarations against the
      # hardcoded 1920×1080 viewport, and window.matchMedia(q).matches
      # returns spec-correct booleans. Lets _lightpanda.isVisible detect
      # inline-@media-gated hides via el.checkVisibility() without any
      # gem-side workaround),
      # PR #2487 (css: external <link rel="stylesheet"> fetch behind the
      # --enable-external-stylesheets flag — build_args now passes that flag
      # unconditionally, so the floor MUST include the build that introduced
      # it; the flag is a fatal UnknownOption on builds < 6353),
      # PR #2498 (StyleManager: author display rule beats UA [hidden] — fixes
      # the Stimulus/Alpine dropdown ElementNotFound),
      # PR #2635 (dom: DOM.setFileInputFiles backs input.files + fires change
      # for <input type=file>) AND PR #2654 (forms: encode file inputs as
      # multipart/form-data on submit — filename + Content-Type + bytes per
      # RFC 7578). Both halves are required for attach_file to upload end-to-end:
      # #2635 populates the FileList, #2654 makes form submission carry the
      # bytes. Node#fill_input's `when "file"` branch calls
      # Browser#set_file_input_files, so the floor MUST include the #2654 build;
      # on builds 6625–6671 the file attaches but the form submits empty.
      # NOTE: the gem's teardown hang is the live-CDP-connection SIGTERM hang
      # (limitation #7B) — telemetry-independent, present on 6353 AND on the #2509
      # fix build, handled by the at_exit WS-close plus the SIGKILL backstop
      # above. It is NOT #2507 (telemetry curl-multi, fixed by #2509): the gem
      # disables telemetry, so it never creates the curl multi #2507 needs. Keep
      # both teardown defenses even after #2511 (the variant-B fix, MERGED in
      # build 6371) lands in a nightly.
      # Build 6672 = the #2654 merge (22d1c5ec, 2026-06-08) — the first commit
      # carrying both file-upload halves.
      # PR #2671 (DataTransfer / DataTransferItem / DataTransferItemList +
      # DragEvent, merged 2026-06-10) provides the APIs Node#drop's DROP_JS
      # assembles its payload from; on builds without it the drop JS raises
      # "DataTransfer is not defined".
      # Build 6699 = the #2671 merge (d1f4c409, 2026-06-10) — the Node#drop
      # DataTransfer floor. (The prior 6672 file-upload floor — and 6353
      # before it — are subsumed.)
      # PR #2708 (document fires readystatechange on readiness changes,
      # merged 2026-06-12) made the index.js readystatechange re-dispatch
      # shim redundant, so it was removed — on builds without #2708 Turbo's
      # PageObserver never reaches pageLoaded() and turbo:load never fires.
      # Build 6736 carried the #2708 merge.
      # PR #2722 (Browser.setDownloadBehavior streams Content-Disposition:
      # attachment responses to disk under downloadPath + emits
      # Browser.downloadWillBegin / downloadProgress, merged 2026-06-19) backs
      # the Downloads tracker (downloads.rb) wired in Browser#create_page. On
      # builds < 7545 setDownloadBehavior is a bare success no-op — every
      # download would silently never be written to disk — so the floor MUST
      # include it. Note Lightpanda triggers downloads on Content-Disposition:
      # attachment, NOT by MIME type (a text/csv response without that header
      # is rendered as a normal navigation), which is why Capybara's
      # MIME-triggered :download shared spec stays in capybara_skip.
      # Build 7545 = the #2722 merge (a808386c).
      # PR #2785 (build 7550, improve innerText + outerText) AND PR #2795
      # (build 7571, innerText uses StyleManager visibility) make native
      # Element.innerText implement the HTML rendered-text collection steps —
      # block line breaks + skipping display:none descendants. The
      # _lightpanda.visibleText predicate (predicates.js) now delegates the
      # rendered-text collection to native innerText (keeping only a visibility
      # gate + ShadowRoot fragment walk), so the floor MUST include #2795; on
      # builds < 7571 innerText returns textContent verbatim (no block breaks,
      # leaks display:none text).
      # Build 7571 = the #2795 merge (48ed689c) — now the binding floor.
      MINIMUM_NIGHTLY_BUILD = Gem::Version.new("7571")

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
        binary_path = @options.browser_path || Binary.update

        raise BinaryNotFoundError, "Lightpanda binary not found" unless binary_path

        check_minimum_version(binary_path)
        attempt_start(binary_path)
      rescue PortInUseError
        kill_process_on_port(@options.port)
        attempt_start(binary_path)
      end

      def stop
        return unless @pid

        self.class.send(:terminate, @pid)
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
              "Update: #{Binary.update_hint(binary_path)}"
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
        base = [
          "serve",
          "--host",
          @options.host.to_s,
          "--port",
          @options.port.to_s,
          "--log_level",
          "info",
          # External stylesheet fetch (PR #2487, build >= 6353 — enforced by the
          # floor). Always on so linked CSS contributes to checkVisibility /
          # getComputedStyle; see .claude/rules/lightpanda-io.md limitation #6.
          "--enable-external-stylesheets",
          # Raise the inbound CDP WebSocket message cap from Lightpanda's 1 MiB
          # default (Config.zig `cdp_max_message_size`) to 100 MiB, matching
          # Chrome's inbound DevTools buffer. An inbound message over the cap is
          # dropped with WS close 1009 and NO JSON-RPC error — the whole CDP
          # connection dies (wishlist A44). The 1 MiB default already covers
          # axe-core (~553 KB), but larger injected bundles (jQuery + plugins,
          # instrumentation) via execute_script, and base64 drag-drop payloads in
          # Node#drop, exceed it. The reader buffer grows lazily (16 KB at init),
          # so a high cap costs nothing until a big message actually arrives.
          # Flag added in PR #2760 (build 7441) — below the floor, so guaranteed.
          "--cdp-max-message-size",
          (100 * 1024 * 1024).to_s,
        ]
        extra = ENV.fetch("LIGHTPANDA_EXTRA_ARGS", "").split
        base + extra
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
                stop
                raise PortInUseError,
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

      # Class methods so the finalizer proc doesn't capture `self` (which
      # would prevent GC from ever running the finalizer). `terminate` is shared
      # by the instance `#stop` and the finalizer so both escalate TERM -> KILL.
      class << self
        private

        def weak_kill(pid)
          proc { terminate(pid) }
        end

        # SIGTERM the process group, then SIGKILL if it hasn't exited within
        # `grace` seconds; reap the child. Safe on an already-dead pid. The
        # SIGKILL escalation is what keeps teardown from hanging on builds that
        # ignore SIGTERM after serving CDP (see STOP_GRACE_SECONDS).
        def terminate(pid, grace: STOP_GRACE_SECONDS)
          signal(pid, "TERM")
          return if reap_within(pid, grace)

          signal(pid, "KILL")
          begin
            ::Process.wait(pid)
          rescue Errno::ECHILD
            nil
          end
        end

        # Signal the process group (-pid), falling back to the bare pid if the
        # group send is rejected (ESRCH/EPERM).
        def signal(pid, name)
          ::Process.kill(name, -pid)
        rescue Errno::ESRCH, Errno::EPERM
          begin
            ::Process.kill(name, pid)
          rescue Errno::ESRCH
            nil
          end
        end

        # True once `pid` is reaped (or already gone); false if still alive
        # after `seconds`.
        def reap_within(pid, seconds)
          deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + seconds
          loop do
            begin
              return true if ::Process.wait(pid, ::Process::WNOHANG)
            rescue Errno::ECHILD
              return true
            end
            return false if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) >= deadline

            sleep 0.05
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
