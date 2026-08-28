# frozen_string_literal: true

require "forwardable"

require_relative "browser/runtime"
require_relative "browser/finder"
require_relative "browser/navigation"
require_relative "browser/modals"
require_relative "browser/console"
require_relative "browser/selenium_compat"

module Capybara
  module Lightpanda
    class Browser
      extend Forwardable

      include Runtime
      include Finder
      include Navigation
      include Modals
      include Console
      include SeleniumCompat

      attr_reader :options, :process, :client, :target_id, :session_id, :browser_context_id, :frame_stack

      delegate %i[on off] => :client

      # Sentinel key marking a serialized DOM node in JS-result payloads.
      # Produced by #unwrap_call_result / #serialize_remote_array, consumed by
      # Driver#unwrap_script_result, which wraps the objectId in a Node.
      NODE_MARKER = "__lightpanda_node__"

      # --- Live-browser registry: clean teardown at process exit --------------
      # Capybara's per-test reset (Driver#reset!) disposes only the
      # BrowserContext and keeps the process + CDP connection alive, so a
      # browser outlives the suite. With nothing calling #quit at exit, teardown
      # would fall to the Process GC finalizer, which SIGTERMs the binary WITHOUT
      # first closing the CDP WebSocket. Lightpanda swallows a *single* SIGTERM
      # while a CDP connection is live (graceful shutdown blocks on the
      # connection worker; it takes three signals to force-exit), so that SIGTERM
      # is absorbed and only the STOP_GRACE_SECONDS SIGKILL escalation reaps it —
      # 3s per process, and a hard hang before that escalation existed. #quit
      # closes the WS first, so we track live browsers and #quit them from a
      # single at_exit, guaranteeing the socket is closed before any SIGTERM.
      @live = []
      @live_mutex = Mutex.new
      @at_exit_installed = false

      class << self
        def track(browser)
          @live_mutex.synchronize do
            @live << browser unless @live.include?(browser)
            next if @at_exit_installed

            @at_exit_installed = true
            at_exit { quit_all }
          end
        end

        def untrack(browser)
          @live_mutex.synchronize { @live.delete(browser) }
        end

        # at_exit handler: close every live browser's CDP WebSocket (via #quit)
        # before its Process finalizer can SIGTERM the binary. Per-browser rescue
        # so one wedged browser can't strand the rest.
        def quit_all
          @live_mutex.synchronize { @live.dup }.each do |browser|
            browser.quit
          rescue StandardError
            nil
          end
        end
      end

      # Lightpanda version string (e.g. "1.0.0-nightly.8925+a7bda0ea5") and its
      # parsed build number. Learned from `lightpanda version` at Process
      # startup on the spawn path, and from the CDP `LP.version` command when
      # connecting to an externally-managed browser via ws_url — so these are
      # populated either way, and a caller inspecting them does not have to
      # know which path built the session.
      def version
        @process&.version || @remote_version
      end

      # Set on the nightly/dev channel only; nil for a tagged release, which
      # carries no build counter. `release` is its mirror image — exactly one of
      # the two is non-nil once the session is up.
      def nightly_build
        @process&.nightly_build || @remote_nightly_build
      end

      def release
        @process&.release || @remote_release
      end

      def initialize(options = {})
        @options = Options.new(options)
        @process = nil
        @client = nil
        @remote_version = nil
        @remote_nightly_build = nil
        @remote_release = nil
        @target_id = nil
        @session_id = nil
        @browser_context_id = nil
        @started = false
        @page_events_enabled = false
        @modal_messages = []
        @modal_messages_mutex = Mutex.new
        @modal_handler_installed = false
        @modal_armed = false
        @unhandled_modal = nil
        @console_logs = []
        @console_logs_mutex = Mutex.new
        @page_errors = []
        @page_errors_mutex = Mutex.new
        @frame_stack = []
        @turbo_event = Utils::Event.new
        @turbo_event.set

        start
      end

      def start
        return if @started

        if @options.ws_url?
          @client = Client.new(@options.ws_url, @options)
          check_remote_version
        else
          @process = Process.new(@options)
          @process.start
          @client = Client.new(@process.ws_url, @options)
        end

        create_browser_context
        create_page

        @started = true
        self.class.track(self)
      end

      # Per-session BrowserContext (Chrome's incognito-profile primitive).
      # Cookies, storage, and targets created within the context are wiped
      # when it's disposed — so `reset` is one CDP call instead of an
      # explicit cookies.clear / storage.clear / close-target dance.
      # Mirrors ferrum's Contexts model.
      def create_browser_context
        result = @client.command("Target.createBrowserContext")
        @browser_context_id = result["browserContextId"]
      end

      def create_page
        result = @client.command("Target.createTarget",
                                 { url: "about:blank", browserContextId: @browser_context_id }.compact)
        @target_id = result["targetId"]

        attach_result = @client.command("Target.attachToTarget", { targetId: @target_id, flatten: true })
        @session_id = attach_result["sessionId"]

        @turbo_event.set
        subscribe_to_console_logs
        subscribe_to_console_capture
        subscribe_to_execution_context
        subscribe_to_turbo_signals
        # Network owns the Network.* domain: enabling installs traffic
        # tracking AND the navigation-response capture behind status_code.
        # clear_session_state's network.reset flipped @enabled back, so this
        # re-subscribes on the fresh context.
        network.enable
        # Opt into file downloads when a destination exists (driver :save_path
        # or Capybara.save_path). No-op otherwise. Must run after the context
        # is loaded — Browser.setDownloadBehavior is a no-op without one.
        downloads.enable(configured_download_path)
        register_auto_scripts
        set_viewport
        # Subscribe to dialogs from the first page, not lazily on the first
        # accept_modal — otherwise a dialog nobody pre-armed is invisible and
        # the unhandled-modal check below has nothing to report.
        prepare_modals
      end

      # Download destination: explicit :save_path option wins, else
      # Capybara.save_path (Cuprite parity). nil => downloads stay off.
      def configured_download_path
        @options.save_path ||
          (defined?(Capybara) && Capybara.respond_to?(:save_path) ? Capybara.save_path : nil)
      end

      # Wipe per-session state — cookies, storage, all targets — and start
      # over with a fresh BrowserContext. Mirrors ferrum's Browser#reset:
      # one CDP call (`Target.disposeBrowserContext`) does the work that
      # would otherwise require explicit cookies.clear / storage.clear /
      # close-target dance, and the browser auto-isolates state for the
      # new context. Driver#reset! delegates here.
      def reset
        dispose_browser_context
        @client.clear_subscriptions
        clear_session_state
        create_browser_context
        create_page
      end

      # Recover after a WebSocket disconnect or process crash during navigation.
      # Restarts the process if it died, then creates a fresh client and page.
      def reconnect
        close_client_silently
        restart_process_if_dead

        ws_url = @options.ws_url? ? @options.ws_url : @process&.ws_url
        raise DeadBrowserError, "Cannot reconnect: no WebSocket URL" unless ws_url

        @client = Client.new(ws_url, @options)
        # Process may have died; the old browserContextId is gone with it.
        @browser_context_id = nil
        clear_session_state
        create_browser_context
        create_page
      end

      # Per-session in-memory state that must be wiped whenever the underlying
      # CDP connection is replaced (#reset disposes the BrowserContext, #reconnect
      # builds a fresh Client). Without this, a mid-test process crash leaves
      # stale frame_stack Nodes (whose objectIds belong to the dead V8 context)
      # and a `@modal_handler_installed = true` flag that makes prepare_modals
      # short-circuit on the new client, so find_modal silently sees no
      # javascriptDialogOpening events.
      def clear_session_state
        @page_events_enabled = false
        @modal_handler_installed = false
        @modal_messages_mutex.synchronize do
          @modal_messages.clear
          @modal_armed = false
          @unhandled_modal = nil
        end
        @console_logs_mutex.synchronize { @console_logs.clear }
        @page_errors_mutex.synchronize { @page_errors.clear }
        clear_frames
        # Network#reset, not #clear: disposing the BrowserContext also
        # destroyed the Network domain and its subscriptions, so we must
        # flip @enabled back to false — otherwise the next #enable
        # short-circuits and traffic tracking is silently dead.
        @network&.reset
        # Same contract for Downloads: the disposed context drops the
        # download config + subscriptions, so reset re-arms create_page's
        # downloads.enable on the fresh context.
        @downloads&.reset
      end

      # Liveness of the CDP transport. Driver#browser checks this to decide
      # whether to respawn a dead browser.
      def alive?
        !client.nil? && !client.closed?
      rescue StandardError
        false
      end

      def quit
        self.class.untrack(self)
        # Flip Network back to disabled so a later #start re-installs its
        # subscriptions — without this, quit→start reuse of the same
        # instance leaves @enabled true and create_page's network.enable
        # no-ops, silently killing status_code/traffic capture. Guarded on
        # @client: with no client the handlers are already moot and
        # unsubscribe would have nothing to detach from. Downloads carries the
        # same subscription contract, so it resets under the same guard.
        if @client
          @network&.reset
          @downloads&.reset
        end
        begin
          @client&.close
        rescue StandardError
          nil
        end
        begin
          @process&.stop
        rescue StandardError
          nil
        end
        @client = nil
        @process = nil
        @started = false
        @browser_context_id = nil
        @target_id = nil
        @session_id = nil
        @modal_handler_installed = false
        clear_frames
      end

      def command(method, **params)
        @client.command(method, params)
      end

      def page_command(method, **params)
        @client.command(method, params, session_id: @session_id)
      end

      def enable_page_events
        return if @page_events_enabled

        page_command("Page.enable")
        @page_events_enabled = true
      end

      # Block up to `timeout` seconds for a default V8 execution context to
      # exist. Returns true if available (immediately or after waiting),
      # false if the timeout elapses with no executionContextCreated event.
      def wait_for_default_context(timeout = 1.0)
        @default_context_event.wait(timeout)
      end

      # Run the block; if it raises NoExecutionContextError (the navigation
      # race window — lightpanda-io/browser#2187), wait for the next default
      # context to be signaled by Runtime.executionContextCreated, then
      # retry. Up to `attempts` total tries; defaults to 3, can be bumped
      # for stubborn flakes. Each retry blocks up to `timeout` seconds for
      # the executionContextCreated signal — no blind sleeps.
      def with_default_context_wait(timeout: 1.0, attempts: 3)
        Utils::Attempt.with_retry(errors: NoExecutionContextError, max: attempts, wait: 0) do
          wait_for_default_context(timeout)
          yield
        end
      end

      def current_url
        evaluate("window.location.href")
      end

      def title
        evaluate("document.title")
      end

      def body
        # Guard against the brief window after a fresh BrowserContext / target
        # is created where the V8 context exists but `document.documentElement`
        # is still null. Hit by Capybara's `#reset_session! resets page body`
        # spec since the 0.2.0 Ferrum-style reset rewrite.
        evaluate("(document.documentElement && document.documentElement.outerHTML) || ''")
      end
      alias html body

      # HTTP status of the last document navigation; nil before the first
      # navigation completes. Captured by Network's subscription (installed
      # via network.enable in create_page).
      def status_code
        network.last_navigation_response&.dig(:status)
      end

      # Response headers of the last document navigation, wrapped in a Headers
      # instance so `["Content-Type"]` works despite CDP lowercasing keys.
      # Returns an empty Headers (not nil) so callers can chain `[]` safely.
      def response_headers
        raw = network.last_navigation_response&.dig(:headers) || {}
        Headers.new.tap { |h| raw.each { |k, v| h[k.to_s.downcase] = v } }
      end

      # objectId of document.activeElement, or nil if none/document detached.
      def active_element
        result = evaluate_with_ref("document.activeElement")
        result&.dig("objectId")
      end

      # Resolve an objectId to its stable per-page backendNodeId.
      # objectIds are transient (re-issued per Runtime call) but backendNodeId is stable,
      # so this is what we compare for cross-query node equality.
      def backend_node_id(remote_object_id)
        page_command("DOM.describeNode", objectId: remote_object_id).dig("node", "backendNodeId")
      end

      # Populate a file <input> from one or more local file paths via
      # DOM.setFileInputFiles (PR #2635, build ≥6625): Lightpanda resolves the
      # objectId, replaces input.files with a real FileList, and fires
      # `input`/`change`. The submitted form then carries the bytes as
      # multipart/form-data (PR #2654, build ≥6672) — both halves are needed,
      # and both are guaranteed by the MINIMUM_NIGHTLY_BUILD floor. Paths are
      # read off the machine running Lightpanda (local for the spawned process).
      def set_file_input_files(remote_object_id, paths)
        page_command("DOM.setFileInputFiles", objectId: remote_object_id, files: paths)
      end

      def screenshot(path: nil, format: :png, quality: nil, full_page: false, encoding: :binary)
        params = { format: format.to_s }
        params[:quality] = quality if quality && format == :jpeg

        if full_page
          metrics = page_command("Page.getLayoutMetrics")
          content_size = metrics["contentSize"]

          params[:clip] = {
            x: 0,
            y: 0,
            width: content_size["width"],
            height: content_size["height"],
            scale: 1,
          }
        end

        result = page_command("Page.captureScreenshot", **params)
        data = result["data"]

        if encoding == :base64
          data
        else
          decoded = Base64.decode64(data)

          if path
            File.binwrite(path, decoded)
            path
          else
            decoded
          end
        end
      end

      # Wait for the page to settle after an action that may have kicked off
      # a Turbo fetch OR a full-page navigation. Used by Node#click and
      # Node#implicit_submit so callers can immediately read updated state
      # (title, current_url, …) without racing the navigation lifecycle.
      #
      # Sniff window: the action returns synchronously, but the CDP events
      # signalling its async fallout (Runtime.executionContextsCleared for
      # full nav; the turbo sentinel for Turbo) arrive later on the dispatch
      # thread. We poll briefly for either signal — if neither fires within
      # the window, assume the action was inert and exit fast.
      SNIFF_WINDOW = 0.05
      private_constant :SNIFF_WINDOW

      def wait_for_idle
        prior_context_iteration = @default_context_event.iteration
        sniff_deadline = monotonic_time + SNIFF_WINDOW
        loop do
          break if @default_context_event.iteration > prior_context_iteration
          break unless @turbo_event.set?
          break if monotonic_time > sniff_deadline

          sleep 0.001
        end

        @default_context_event.wait(@options.timeout)
        @turbo_event.wait(@options.timeout)
        check_unhandled_modal!
      end

      def keyboard
        @keyboard ||= Keyboard.new(self)
      end

      def network
        @network ||= Network.new(self)
      end

      def downloads
        @downloads ||= Downloads.new(self)
      end

      def cookies
        @cookies ||= Cookies.new(self)
      end

      # -- Frame Support --
      # `frame_stack` (Array<Node>) is the Capybara `switch_to_frame` stack;
      # it drives where `find` resolves selectors. Stored as Nodes so
      # callFunctionOn can scope to the iframe's contentDocument.

      def push_frame(node)
        @frame_stack.push(node)
      end

      def pop_frame
        @frame_stack.pop
      end

      def clear_frames
        @frame_stack.clear
      end

      # Capybara::Driver::Base resolves frame_url/frame_title via the top
      # execution context, which always reports the parent document. Resolve
      # them through the iframe element's contentWindow / contentDocument so
      # they reflect the active frame.
      def frame_url
        frame = frame_stack.last
        return current_url unless frame

        call_function_on(frame.remote_object_id, FRAME_URL_JS)
      end

      def frame_title
        frame = frame_stack.last
        return title unless frame

        call_function_on(frame.remote_object_id, FRAME_TITLE_JS)
      end

      FRAME_URL_JS = "function() { return this.contentWindow.location.href }"
      FRAME_TITLE_JS = "function() { return this.contentDocument.title }"
      private_constant :FRAME_URL_JS, :FRAME_TITLE_JS

      # Internal lifecycle steps defined above near their topical groups —
      # calling them out of order corrupts session state, so they are not API.
      private :create_browser_context, :create_page, :clear_session_state,
              :enable_page_events

      private

      def register_auto_scripts
        page_command("Page.addScriptToEvaluateOnNewDocument", source: AutoScripts::JS)
      end

      # Apply the `window_size` option as a JS-visible viewport: it drives
      # window.innerWidth/innerHeight and the viewport `matchMedia` / `@media`
      # evaluate against, so responsive branches resolve at the requested size.
      # It is NOT layout — Lightpanda has no rendering engine, so nothing
      # reflows and getBoundingClientRect stays synthetic.
      #
      # Re-applied on every create_page rather than once at connect. The
      # override lives on the CDP-connection-scoped Browser upstream, so it
      # already survives Driver#reset!'s disposeBrowserContext; re-sending is
      # one idempotent call that also covers the reconnect path, where the
      # connection (and therefore the override) is genuinely new.
      #
      # window_size is validated in Options#initialize, which runs before the
      # process is spawned — a bad value must not leave an orphaned browser
      # behind, and raising from here would (Browser#initialize starts the
      # process before create_page ever runs).
      #
      # Public (declared below the private section via `public :set_viewport`)
      # because Driver#resize_window_to drives it mid-test: with no arguments
      # it re-applies the configured size, which is what create_page wants.
      # SHARP EDGE, verified 2026-07-25 on nightly 8285: this updates
      # window.innerWidth/innerHeight and what `matchMedia` reports
      # immediately, but it does NOT re-resolve `@media` rules for the document
      # already loaded. Lightpanda fixes the cascade when a document is parsed
      # and nothing invalidates it on a metrics change, so a page loaded at
      # 1920 keeps rendering its desktop branch even while `matchMedia`
      # ("(max-width: 500px)") reports true. Navigating (Driver#visit) parses
      # under the new metrics and resolves correctly.
      #
      # No workaround shipped on purpose. DOM/CSSOM mutations look like they
      # force a re-cascade but don't survive scrutiny (the probe that suggested
      # otherwise had been contaminated by the previous iteration's viewport),
      # so anything here would be a guess dressed up as a fix. Driver's window
      # methods document the resize-then-visit shape instead.
      def set_viewport(width = nil, height = nil)
        width, height = @options.window_size if width.nil? || height.nil?
        page_command("Emulation.setDeviceMetricsOverride", width: width, height: height)
        [width, height]
      end

      # The viewport as the page currently sees it. Read back from JS rather
      # than echoing what we last set, so it stays truthful if a page (or a
      # direct Emulation call through #execute_cdp) moved it behind our back.
      def viewport_size
        evaluate("[window.innerWidth, window.innerHeight]")
      end

      # Track default-execution-context availability via Runtime events.
      # Lightpanda destroys the V8 default context at navigation start (long
      # before frameNavigated fires), then re-creates it once the new page
      # commits. During the gap, Runtime.evaluate / callFunctionOn rejects
      # with "Cannot find default execution context"
      # (lightpanda-io/browser#2187). We watch executionContextsCleared /
      # executionContextCreated and use the resulting Concurrent::Event to
      # gate retries deterministically instead of blind sleeping.
      def subscribe_to_execution_context
        @default_context_event = Utils::Event.new
        @default_context_event.set

        on("Runtime.executionContextsCleared") { @default_context_event.reset }
        on("Runtime.executionContextCreated") do |params|
          @default_context_event.set if params.dig("context", "auxData", "isDefault")
        end

        page_command("Runtime.enable")
      end

      def close_client_silently
        @client&.close
      rescue StandardError
        nil
      end

      def dispose_browser_context
        return unless @browser_context_id

        begin
          @client.command("Target.disposeBrowserContext", { browserContextId: @browser_context_id })
        rescue StandardError
          # Context may already be disposed or the WS may be down; we
          # recreate either way.
        ensure
          @browser_context_id = nil
          @target_id = nil
          @session_id = nil
        end
      end

      # Binary.update_hint would be a lie here: it prints a curl into a path the
      # gem controls, and under ws_url the browser is somebody else's process on
      # possibly another host.
      REMOTE_UPDATE_HINT = "the gem does not manage that browser — " \
                           "update the Lightpanda serving ws_url yourself."
      private_constant :REMOTE_UPDATE_HINT

      # The spawn path runs `lightpanda version` before the browser is even up
      # (Process#check_minimum_version). An externally-managed browser has no
      # binary to shell out to, so the same floor is enforced over CDP instead:
      # `LP.version` returns the identical string the CLI prints, and
      # Process.check_version! is the one parser both channels share.
      #
      # Without this, `ws_url:` was the one way into the driver that skipped the
      # floor entirely — an old browser connected happily and then failed later
      # as an unrelated-looking CDP error, with nothing naming the real cause.
      #
      # A browser that cannot answer `LP.version` is refused rather than assumed
      # new enough, matching the spawn path's rule that an unidentifiable binary
      # never passes. Two things land here: a Lightpanda predating the LP domain,
      # and a Chrome someone pointed ws_url at by mistake — the second being easy
      # to do and previously diagnosable only by watching later commands fail.
      #
      # Only #start calls this. #reconnect deliberately does not: it re-dials the
      # same endpoint, whose version cannot have changed, and the crash-recovery
      # path should not spend a round-trip re-asking.
      def check_remote_version
        result = @client.command("LP.version")
        @remote_version, @remote_nightly_build, @remote_release =
          Process.check_version!(result["version"]) { REMOTE_UPDATE_HINT }
      rescue BrowserError, TimeoutError => e
        raise BinaryError,
              "Could not read the Lightpanda version at #{@options.ws_url} " \
              "(LP.version failed: #{e.message}). ws_url: must point at a " \
              "Lightpanda CDP endpoint new enough to answer LP.version; the gem " \
              "cannot verify a browser it does not manage."
      end

      def restart_process_if_dead
        return unless @process && !@process.alive?

        begin
          @process.stop
        rescue StandardError
          nil
        end
        @process.start
      end

      def monotonic_time
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end

      # Viewport control is API, not lifecycle: Driver#resize_window_to and
      # #window_size call it mid-test. It lives up in the private section
      # beside register_auto_scripts because create_page is its other caller
      # and the two read together.
      public :set_viewport, :viewport_size
    end
  end
end
