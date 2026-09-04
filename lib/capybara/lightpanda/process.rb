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
      # Build 7571 = the #2795 merge (48ed689c).
      # PR #2719 (css: apply @layer block rules to the cascade, merged
      # 2026-07-17) makes StyleManager rank `@layer` rules correctly. Before it,
      # a rule inside an `@layer` block was dropped from the cascade entirely,
      # so an element hidden by an `@layer` `display: none` — the default shape
      # of Tailwind v4's generated CSS — reported `checkVisibility() === true`.
      # `_lightpanda.isVisible` (predicates.js) terminates in checkVisibility(),
      # so on builds < 8160 Capybara believes such elements are visible and acts
      # on them: clicks land on hidden nodes and `assert_no_selector` passes for
      # visible ones. That is a wrong-answer bug rather than an exception, which
      # is exactly the kind users can't diagnose, so the floor MUST include it.
      # Build 8160 = the #2719 merge (b19b5725).
      # PR #2983 (css: respect @layer priority, merged 2026-07-24) is the second
      # half of that same fix and the reason 8160 is NOT sufficient. #2719 only
      # made rules inside an `@layer` block *participate* in the cascade; it
      # ranked them by specificity + document order alone. #2983 widened
      # VisibilityRule.priority to carry a 12-bit layer rank, so layer order
      # finally beats specificity as the spec requires. On builds 8160–8280 a
      # page whose layers disagree about `display` resolves to the wrong rule —
      # Tailwind v4's `@layer utilities` losing to `@layer base` is the common
      # shape — and `_lightpanda.isVisible` (predicates.js) terminates in
      # checkVisibility(), so Capybara again believes hidden elements are
      # visible. Same undiagnosable wrong-answer class as #2719 itself, so the
      # floor MUST include it.
      # Build 8281 = the #2983 merge (76e2e7e6).
      # PR #3015 (cdp: sanitize non-UTF-8 values, merged 2026-07-24) fixes
      # issue #2992: a legacy-encoded Content-Disposition filename made
      # Browser.downloadWillBegin emit `suggestedFilename` as a JSON array of
      # bytes instead of a string. Downloads#build_will_handler does
      # File.basename(params["suggestedFilename"].to_s), so below this build it
      # records a "[130, 160, ...]" basename and Driver#downloads hands back a
      # path that does not exist.
      # Build 8283 = the #3015 merge (8fbcc7e5).
      # PR #3054 (forms: close the ancestor dialog on method=dialog submission,
      # merged 2026-07-25) makes `<form method="dialog">` close its nearest
      # ancestor <dialog>, set returnValue from the submitter's IDL value, fire
      # close, and perform no navigation. Below it the submission falls through
      # to a GET navigation and the dialog stays open forever — which is the
      # <dialog>+Turbo-confirm idiom Spree 5's admin uses for every destroy
      # confirmation. There is no gem-side workaround to guard this: the only
      # defense is the floor.
      # Build 8311 = the #3054 merge (c917cadc).
      # PR #3058 (forms: include optgroup children in a select's list of
      # options, merged 2026-07-26) makes `<option>`s inside an `<optgroup>`
      # reachable through HTMLSelectElement (options / value / selectedIndex /
      # submission). Below it Capybara's `select` cannot find a grouped option
      # at all and there is no gem-side workaround — a plain ElementNotFound on
      # any grouped <select>. Build 8328 = the #3058 merge (c7182354).
      # PR #3080 (webapi: increase max timer count, merged 2026-07-29) lifts the
      # one-shot setTimeout cap 512 → 2048 (Airbnb-class pages schedule 600+);
      # below it timers past the cap are silently dropped and page JS stalls in
      # ways that read as Capybara timeouts. Build 8412 = the #3080 merge.
      # PR #3081 + #3082/#3085 (script load/error events; dynamic scripts whose
      # `src` is set via setAttribute, merged 2026-07-30) — below them an
      # inline script fired no load event, a throwing script still fired
      # `load`, and a setAttribute('src') script never loaded, which breaks
      # loader idioms (importmap shims, lazy widget bootstraps) that gate the
      # UI Capybara waits for. Builds 8414/8419.
      # PR #3087 (fix: potential UAF when an option's value is programmatically
      # set, merged 2026-07-30) — a use-after-free in exactly the path
      # `Node#select_option`/`Node#set` on a <select> drives, i.e. a browser
      # crash surfacing as DeadBrowserError mid-spec.
      # Build 8448 = the #3087 merge (6d824c88) — the binding floor of the
      # 2026-07-30 bump.
      # Subsumed by 8448, recorded so they are not re-derived: build 8298 made
      # Network.enable idempotent (the gem never hit it — the Notification is
      # per-BrowserContext and Network#enable's @enabled guard means one enable
      # per context), and build 8305 (#3048) derives scrollWidth/scrollHeight
      # from element content (the gem keeps scroll as a no-op either way).
      # PR #2664 (Emulation.setDeviceMetricsOverride, build 7556) is subsumed:
      # Browser#set_viewport calls it on every create_page to honor the
      # `window_size` option. Note the override only reached
      # Page.getLayoutMetrics later (~build 8300); the gem does not depend on
      # that half, so it is NOT part of the floor.
      #
      # 2026-08-25 bump 8448 -> 8796: #3257 (HTMLElement.draggable IDL, build
      # 8793) and #3259 (MouseEvent coordinate getters floor to integers
      # Chrome-style, build 8796; PointerEvent stays fractional). The floor
      # guarantees native `.draggable`, so the drag scripts in node.rb read it
      # verbatim — the `_lightpanda.isDraggable` polyfill was retired with
      # this bump — and drag events carry integer clientX/Y (the shared spec
      # asserting that runs un-skipped). Build 8796 = the #3259 merge
      # (341a01570), which is also the 2026-08-25 nightly cut.
      #
      # 2026-08-26 bump 8796 -> 8875, four fixes the gem now asserts on:
      #   #3264 (8842) CDP Input.dispatchKeyEvent builds a *trusted*
      #     KeyboardEvent, so frame/user_input.zig fires `keypress` on
      #     printable/Enter keydowns and synthesizes a trusted PointerEvent
      #     click for Enter on <button>/<a href>/input[submit|button|reset|
      #     image] and Space-keyup on those plus checkbox/radio. That click is
      #     a real activation event (PointerEvent.Proto = MouseEvent), so
      #     Node#send_keys(:enter) submits/navigates and send_keys(:space)
      #     toggles a checkbox — both were no-ops below 8842. No gem code
      #     drives it; Keyboard never sends CDP `type: "char"`, so nothing
      #     double-fires. Pinned by test/features/keyboard_activation_test.rb.
      #   #3269 (8868) adds `dialog:not([open]) { display: none }` to the
      #     UA-stylesheet truth checkVisibility() and getComputedStyle().display
      #     share, so a closed <dialog> AND its subtree read as non-visible.
      #     Below 8868 Capybara matched text and controls inside a never-opened
      #     dialog. Pinned by test/features/upstream_bugs_test.rb (Bug #4).
      #   #3270 (8857) inline-style keyword matching in checkVisibility /
      #     getComputedStyle is case-insensitive for display / visibility /
      #     opacity / pointer-events, so `style="display: NONE"` hides.
      #     Feeds _lightpanda.isVisible. Pinned by visibility_keywords_test.rb.
      #   #3256 (8875) the CDP WS handshake accepts the exact lowercase
      #     `Host: localhost:<port>` form (bare `localhost`, `LOCALHOST:<port>`
      #     and `localhost.evil.com:<port>` still 403). Below 8875 only an IP
      #     literal passed, so a user-supplied `ws_url:` had to say 127.0.0.1.
      #     Pinned by test/features/ws_url_host_test.rb.
      # Build 8875 = the #3256 merge (f2169836e). NOTE: this floor leads the
      # nightly channel — the 2026-08-26 nightly is 8855 — so it lands with the
      # next nightly cut. #3267 (8880, Authorization stripped on cross-origin
      # redirects) arrives with the same floor but drives nothing gem-side.
      MINIMUM_NIGHTLY_BUILD = Gem::Version.new("8875")

      # Second, equivalent floor for the *release* channel.
      #
      # Tagged releases are built with `-Dversion=<tag>`, which resolves to a
      # plain semver with no pre-release tag — so `lightpanda version` prints a
      # bare "0.3.6" carrying no commit counter at all, and MINIMUM_NIGHTLY_BUILD
      # has nothing to compare against. Releases are cut from the same trunk, so
      # a release is acceptable exactly when its own commit count clears the
      # nightly floor. 0.4.0 (2026-08-31) is build 9058 — the first tagged
      # release past the 8875 floor (0.3.7 = 8671 predates every fix the floor
      # exists for). There was never a 0.3.8: upstream jumped the minor, and
      # the pin briefly named that nonexistent version while it waited.
      #
      # INVARIANT: every MINIMUM_NIGHTLY_BUILD bump must also move this to the
      # first release containing that build (`git rev-list --count <tag>` in the
      # browser repo tells you). Leaving it behind would let the release channel
      # silently accept a binary the nightly channel rejects.
      MINIMUM_RELEASE = Gem::Version.new("0.4.0")

      class << self
        # `lightpanda version` prints one of two shapes, and the gem supports
        # both so a suite can either track nightly or pin a reproducible
        # release:
        #
        #   "1.0.0-nightly.8285+de85a51d"  rolling nightly (also "dev.NNNN" for
        #                                  a locally compiled tree — same
        #                                  `git rev-list --count HEAD` counter,
        #                                  different label). Checked against
        #                                  MINIMUM_NIGHTLY_BUILD.
        #   "0.3.5"                        a tagged release: bare semver, no
        #                                  build metadata. Checked against
        #                                  MINIMUM_RELEASE.
        #
        # The release form is matched anchored — a bare semver and nothing else
        # — so a stray "1.2.3" inside some other string can never be mistaken
        # for a release. Anything that matches neither shape stays a hard
        # failure: a version we cannot identify is never assumed to be new
        # enough.
        #
        # Lives on the class, not the instance, because there are two ways to
        # learn a version and only one of them involves a Process: the spawn
        # path shells out to the binary, while an externally-managed browser
        # (`ws_url:`) is asked over CDP. `LP.version` returns the identical
        # string the CLI prints, so both channels share this one parser rather
        # than drifting apart — the drift being how `ws_url:` shipped with no
        # floor check at all.
        #
        # Returns [version, nightly_build, release]; exactly one of the latter
        # two is non-nil. The update hint is yielded rather than passed so the
        # caller's hint-building only runs on the failure path.
        def check_version!(raw)
          version = raw.to_s.strip

          if (build = version[/(?:nightly|dev)\.(\d+)/, 1])
            nightly_build = Gem::Version.new(build)
            return [version, nightly_build, nil] if nightly_build >= MINIMUM_NIGHTLY_BUILD
          elsif (tag = version[/\A\d+\.\d+\.\d+\z/])
            release = Gem::Version.new(tag)
            return [version, nil, release] if release >= MINIMUM_RELEASE
          end

          raise BinaryError,
                "Lightpanda #{version} is too old. " \
                "This gem requires nightly build >= #{MINIMUM_NIGHTLY_BUILD} " \
                "or release >= #{MINIMUM_RELEASE}. " \
                "Update: #{yield}"
        end
      end

      attr_reader :pid, :ws_url, :version, :nightly_build, :release

      def initialize(options)
        @options = options
        @pid = nil
        @ws_url = nil
        @version = nil
        @nightly_build = nil
        @release = nil
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

      # Shells the floor check out to the binary. The ws_url path can't — see
      # Browser#check_remote_version, which feeds the same parser from CDP.
      def check_minimum_version(binary_path)
        stdout, = Open3.capture3(binary_path, "version")
        @version, @nightly_build, @release =
          self.class.check_version!(stdout) { Binary.update_hint(binary_path) }
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
          # getComputedStyle; see .claude/rules/lightpanda-io.md limitation #5.
          "--enable-external-stylesheets",
          # Raise the inbound CDP WebSocket message cap from Lightpanda's 1 MiB
          # default (Config.zig `cdp_max_message_size`) to 100 MiB, matching
          # Chrome's inbound DevTools buffer. An inbound message over the cap is
          # dropped with WS close 1009 and NO JSON-RPC error — the whole CDP
          # connection dies (wishlist A44). The 1 MiB default already covers
          # axe-core (~553 KB), but larger injected bundles (jQuery + plugins,
          # instrumentation) via execute_script exceed it (Node#drop used to as
          # well, before files moved to DOM.setFileInputFiles). The reader
          # buffer grows lazily (16 KB at init),
          # so a high cap costs nothing until a big message actually arrives.
          # Flag added in PR #2760 (build 7441) — below the floor, so guaranteed.
          "--cdp-max-message-size",
          (100 * 1024 * 1024).to_s,
        ]
        # Opt-in image fetching (upstream #3230, build >= 8834). Deliberately
        # NOT always-on like --enable-external-stylesheets: images never feed
        # the DOM predicates, so the default spends no bandwidth on them. On
        # builds < 8834 the flag is a fatal UnknownOption at boot — see
        # Options#load_images.
        base.push("--load-resources", "image") if @options.load_images
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
