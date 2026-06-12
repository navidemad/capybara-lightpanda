# frozen_string_literal: true

require "forwardable"

module Capybara
  module Lightpanda
    class Browser
      extend Forwardable

      attr_reader :options, :process, :client, :target_id, :session_id, :browser_context_id, :frame_stack

      delegate %i[on off] => :client

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

      # Lightpanda binary version (e.g. "lightpanda 0.2.9 nightly.5267") and
      # parsed nightly build number, captured at Process startup. nil when
      # the gem is connecting to an externally-managed Lightpanda via ws_url.
      def version
        @process&.version
      end

      def nightly_build
        @process&.nightly_build
      end

      def initialize(options = {})
        @options = Options.new(options)
        @process = nil
        @client = nil
        @target_id = nil
        @session_id = nil
        @browser_context_id = nil
        @started = false
        @page_events_enabled = false
        @modal_messages = []
        @modal_messages_mutex = Mutex.new
        @modal_handler_installed = false
        @console_logs = []
        @console_logs_mutex = Mutex.new
        @frame_stack = []
        @turbo_event = Utils::Event.new
        @turbo_event.set
        @last_navigation_response = nil
        @document_request_id = nil

        start
      end

      def start
        return if @started

        if @options.ws_url?
          @client = Client.new(@options.ws_url, @options)
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
        subscribe_to_navigation_response
        register_auto_scripts
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
        @modal_messages_mutex.synchronize { @modal_messages.clear }
        @console_logs_mutex.synchronize { @console_logs.clear }
        @last_navigation_response = nil
        @document_request_id = nil
        clear_frames
        # Network#reset, not #clear: disposing the BrowserContext also
        # destroyed the Network domain and its subscriptions, so we must
        # flip @enabled back to false — otherwise the next #enable
        # short-circuits and traffic tracking is silently dead.
        @network&.reset
      end

      def quit
        self.class.untrack(self)
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

      # Navigation with readyState fallback.
      #
      # Lightpanda may never fire Page.loadEventFired on complex JS pages
      # (lightpanda-io/browser#1801, #1832). When the event times out,
      # we poll document.readyState as a fallback.
      #
      # Page.navigate is sent asynchronously because Lightpanda may not
      # return the command result until the page is fully loaded (unlike
      # Chrome which returns immediately with frameId/loaderId). If we
      # waited synchronously, the readyState fallback would never be
      # reached on pages that fail to fully load.
      #
      # Uses a single shared deadline so the worst-case wait is 1x timeout,
      # not 2x (lightpanda-io/browser#1849).
      def go_to(url, wait: true, retried: false)
        enable_page_events

        if wait
          wait_for_page_load(url, retried: retried)
        else
          page_command("Page.navigate", url: url)
        end
      end
      alias goto go_to

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

      def back
        wait_for_navigation { navigate_history(-1) }
      end

      def forward
        wait_for_navigation { navigate_history(+1) }
      end

      def refresh
        wait_for_navigation { page_command("Page.reload") }
      end
      alias reload refresh

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
      # navigation completes. Driven by the Network.responseReceived
      # subscription installed in create_page.
      def status_code
        @last_navigation_response&.dig(:status)
      end

      # Response headers of the last document navigation, wrapped in a Headers
      # instance so `["Content-Type"]` works despite CDP lowercasing keys.
      # Returns an empty Headers (not nil) so callers can chain `[]` safely.
      def response_headers
        raw = @last_navigation_response&.dig(:headers) || {}
        Headers.new.tap { |h| raw.each { |k, v| h[k.to_s.downcase] = v } }
      end

      # Evaluate JS and return a serialized value.
      # No-args fast path uses Runtime.evaluate; with args we wrap as a function
      # and dispatch via Runtime.callFunctionOn so `arguments[i]` is bound.
      # Both paths use `returnByValue: false` and unwrap so DOM-node returns
      # come back as `{ "__lightpanda_node__" => ... }` for the Driver to wrap.
      #
      # The no-args path sends the user's text verbatim with `replMode: true`
      # (V8's DevTools-console REPL mode — Lightpanda forwards Runtime.evaluate
      # to the V8 inspector, which handles the flag natively). Without it,
      # top-level `const`/`let` persist in the global lexical environment
      # across classic scripts — per spec, and Chrome behaves identically —
      # so a second `const sel = ...` raises `SyntaxError: Identifier 'sel'
      # has already been declared`. REPL mode keeps the bindings (visible to
      # later calls, like the DevTools console) but allows redeclaration.
      # Completion-value semantics cover a bare expression (`'foo'`), a
      # `throw` statement, and multi-statement scripts alike.
      def evaluate(expression, *args)
        if args.empty?
          response = page_command("Runtime.evaluate", expression: expression, returnByValue: false, awaitPromise: true,
                                                      replMode: true)
          if response["exceptionDetails"]
            debug_js_failure("evaluate", expression, response)
            raise JavaScriptError, response
          end

          return unwrap_call_result(response["result"])
        end

        wrapped = "function() { return #{expression} }"
        call_with_args(wrapped, args)
      end

      # Execute JS without returning a value.
      #
      # Like `evaluate`, the no-args path uses `replMode: true` so top-level
      # `const`/`let` redeclarations across calls don't raise. Also raises
      # on JS exceptions so silent failures don't mask test bugs (the
      # previous fast path swallowed them because `awaitPromise: false` was
      # checked but `exceptionDetails` was not).
      def execute(expression, *args)
        if args.empty?
          response = page_command("Runtime.evaluate", expression: expression, returnByValue: false,
                                                      awaitPromise: false, replMode: true)
          if response["exceptionDetails"]
            debug_js_failure("execute", expression, response)
            raise JavaScriptError, response
          end
          return nil
        end

        wrapped = "function() { #{expression} }"
        call_with_args(wrapped, args, return_by_value: false)
        nil
      end

      # When LIGHTPANDA_DEBUG=1 is set, log the JS expression and full CDP
      # response for every JsException to STDERR. Invaluable for isolating
      # which exact JS triggers an upstream Lightpanda bug.
      def debug_js_failure(site, expression, response)
        return unless ENV["LIGHTPANDA_DEBUG"]

        warn "[lightpanda:#{site}] expression:\n#{expression}\n[lightpanda:#{site}] response:\n#{response.inspect}\n"
      end

      # Evaluate async JS with a callback. The user's script receives
      # the callback as its last argument (`arguments[arguments.length - 1]`),
      # matching Capybara's evaluate_async_script contract.
      def evaluate_async(expression, *args, wait: @options.timeout)
        timeout_ms = (wait * 1000).to_i
        wrapped = <<~JS
          function() {
            var __args = Array.prototype.slice.call(arguments);
            return new Promise(function(__resolve, __reject) {
              var __timer = setTimeout(function() {
                __reject(new Error('Async script timeout after #{timeout_ms}ms'));
              }, #{timeout_ms});
              var __done = function(val) { clearTimeout(__timer); __resolve(val); };
              __args.push(__done);
              (function() { #{expression} }).apply(null, __args);
            });
          }
        JS
        call_with_args(wrapped, args)
      end

      # Evaluate JS and return a RemoteObject reference (for DOM nodes, arrays).
      def evaluate_with_ref(expression)
        response = page_command("Runtime.evaluate", expression: expression, returnByValue: false, awaitPromise: true)
        if response["exceptionDetails"]
          debug_js_failure("evaluate_with_ref", expression, response)
          raise JavaScriptError, response
        end

        result = response["result"]
        return nil if result["type"] == "undefined"

        result
      end

      # Call a function on a remote object via Runtime.callFunctionOn.
      # Binds `this` to the DOM element referenced by remote_object_id.
      def call_function_on(remote_object_id, function_declaration, *args, return_by_value: true)
        params = {
          objectId: remote_object_id,
          functionDeclaration: function_declaration,
          returnByValue: return_by_value,
          awaitPromise: true,
        }
        params[:arguments] = args.map { |a| serialize_argument(a) } unless args.empty?

        response = page_command("Runtime.callFunctionOn", **params)
        if response["exceptionDetails"]
          debug_js_failure("call_function_on", function_declaration, response)
          raise JavaScriptError, response
        end

        result = response["result"]
        return nil if result["type"] == "undefined"

        return_by_value ? result["value"] : result
      end

      # Get properties of a remote object (used to extract array elements).
      def get_object_properties(remote_object_id)
        page_command("Runtime.getProperties", objectId: remote_object_id, ownProperties: true)
      end

      # Release a remote object reference to free V8 memory. Cleanup is
      # best-effort: callers wrap their work in `ensure release_object(...)`,
      # so a TimeoutError or transport hiccup here must not propagate out of
      # the ensure block and bury the original failure.
      def release_object(remote_object_id)
        page_command("Runtime.releaseObject", objectId: remote_object_id)
      rescue Error
        # Object may already be released, context destroyed, or the CDP call
        # itself timed out / failed in transport.
      end

      # Find elements in the current context (top frame or active frame).
      # Returns an array of remote object ID strings.
      def find(method, selector)
        if @frame_stack.empty?
          find_in_document(method, selector)
        else
          find_in_frame(method, selector)
        end
      end

      # Find child elements within a specific node.
      # Returns an array of remote object ID strings.
      #
      # Wrapped in `with_default_context_wait` so a click that triggered a
      # navigation immediately before the find (e.g. a fill_in following a
      # link that mutated the DOM) doesn't race against
      # `Runtime.executionContextCreated` and surface as
      # `NoExecutionContextError`. `find_in_document` and `find_in_frame`
      # already use the same wrapper; `find_within` was the odd one out.
      def find_within(remote_object_id, method, selector)
        with_default_context_wait do
          result = call_function_on(remote_object_id, FIND_WITHIN_JS, method, selector, return_by_value: false)
          extract_node_object_ids(result)
        end
      rescue JavaScriptError => e
        raise_invalid_selector(e, method, selector)
      end

      # Ancestor chain of `remote_object_id` from parentNode up to (but
      # excluding) `document`, returned as an array of remote object IDs.
      # Mirrors Cuprite's JS `parents` helper. Same `with_default_context_wait`
      # wrapping as `find_within` — same race window applies.
      def parents_of(remote_object_id)
        with_default_context_wait do
          result = call_function_on(remote_object_id, PARENTS_JS, return_by_value: false)
          extract_node_object_ids(result)
        end
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
      # which is why MINIMUM_NIGHTLY_BUILD sits at the 6672 floor. Paths are
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
      end

      def keyboard
        @keyboard ||= Keyboard.new(self)
      end

      def network
        @network ||= Network.new(self)
      end

      def cookies
        @cookies ||= Cookies.new(self)
      end

      # Console messages captured from `Runtime.consoleAPICalled` since the
      # last `reset` (Turbo-tracker sentinels excluded). Loose hashes, like
      # Network#traffic: `{type:, text:, timestamp:, args:}` where `type` is
      # the console method name ("log", "error", "warning", ...), `text` joins
      # the arguments' primitive values/descriptions, and `args` keeps the raw
      # CDP RemoteObjects. Lets suites assert on JS console errors
      # (`browser.console_logs.select { |m| m[:type] == "error" }`) the way
      # peer drivers do via custom Ferrum loggers.
      def console_logs
        @console_logs_mutex.synchronize { @console_logs.dup }
      end

      def clear_console_logs
        @console_logs_mutex.synchronize { @console_logs.clear }
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

      # -- Modal/Dialog Support --
      # Lightpanda's JS dialogs (alert/confirm/prompt) are driven via the
      # `LP.handleJavaScriptDialog` pre-arm model (PR #2261, nightly ≥5900):
      # the client sends `LP.handleJavaScriptDialog {accept, promptText}`
      # BEFORE the action that triggers the dialog, and the response is
      # consumed when the dialog opens. `Page.javascriptDialogOpening` still
      # fires, so we capture the message text for `find_modal`. Single-shot:
      # `pending_dialog_response` is one slot, so a second pre-arm before
      # the first dialog opens overwrites the first.

      def prepare_modals
        return if @modal_handler_installed

        enable_page_events

        on("Page.javascriptDialogOpening") do |params|
          entry = { type: params["type"], message: params["message"] }
          @modal_messages_mutex.synchronize { @modal_messages << entry }
        end

        @modal_handler_installed = true
      end

      def accept_modal(_type, text: nil)
        prepare_modals
        params = { accept: true }
        params[:promptText] = text if text
        page_command("LP.handleJavaScriptDialog", **params)
      end

      def dismiss_modal(_type)
        prepare_modals
        page_command("LP.handleJavaScriptDialog", accept: false)
      end

      # `type` is accepted for the error message only: like Selenium (where
      # alert/confirm are indistinguishable) and Cuprite (whose dialog handler
      # accepts whatever fires), we deliberately do NOT reject a dialog whose
      # reported type differs from the one Capybara asked for. Real suites
      # wrap `data-confirm` deletes in `accept_alert` (e.g. solidus admin) and
      # expect it to work; only the message text is matched.
      def find_modal(type, text: nil, wait: options.timeout)
        regexp = text.is_a?(Regexp) ? text : (text && Regexp.new(Regexp.escape(text.to_s)))
        last_seen_message = nil
        claimed = nil
        Utils::Wait.until(timeout: wait, interval: 0.05) do
          claimed = pop_modal_message(regexp)
          next true if claimed

          last_seen_message = peek_last_modal_message || last_seen_message
          false
        end
        claimed[:message]
      rescue TimeoutError
        raise_modal_not_found(type, text, last_seen_message)
      end

      private

      # Pop the first queued dialog whose message matches the requested
      # pattern (any dialog when `regexp` is nil). Returns the entry or nil.
      # Serialized with the message-thread writer.
      def pop_modal_message(regexp)
        @modal_messages_mutex.synchronize do
          match = @modal_messages.find do |m|
            regexp.nil? || m[:message].to_s.match?(regexp)
          end
          @modal_messages.delete(match) if match
          match
        end
      end

      # Most recent dialog message of any type, for diagnostics.
      def peek_last_modal_message
        @modal_messages_mutex.synchronize { @modal_messages.last&.dig(:message) }
      end

      def raise_modal_not_found(type, text, last_seen_message)
        if last_seen_message
          raise Capybara::ModalNotFound,
                "Unable to find #{type} modal with #{text} - found '#{last_seen_message}' instead."
        end
        raise Capybara::ModalNotFound, "Unable to find modal dialog#{" with #{text}" if text}"
      end

      # Sentinel string thrown from FIND_*_JS when querySelectorAll rejects a
      # malformed selector, so the Ruby side can convert JavaScriptError into
      # Capybara::Lightpanda::InvalidSelector. Cuprite uses a JS subclass for
      # the same purpose; a plain prefixed string keeps our inline JS simple.
      INVALID_SELECTOR_MARKER = "LIGHTPANDA_INVALID_SELECTOR:"

      # JS function for finding elements within a node.
      # Works in any execution context (top frame or iframe). For CSS, any
      # throw from querySelectorAll means the selector is malformed
      # (re-throw with the marker prefix so Ruby converts to InvalidSelector).
      # XPath routes through native `Document.evaluate` + `XPathResult`
      # (Lightpanda PR #2305, in nightly >=6109); on parse error we return
      # [] silently to match Capybara's internal XPath generator, which
      # sometimes produces selectors with empty trailing predicates like
      # `(...)[]` that native rejects but `has_element?` expects to behave
      # as "not found" rather than raise InvalidSelector.
      # `XPathResult.ORDERED_NODE_SNAPSHOT_TYPE` is `7` in the spec — inlined
      # so the JS doesn't depend on the enum being defined as a constant.
      FIND_WITHIN_JS = <<~JS.freeze
        function(method, selector) {
          if (method === 'xpath') {
            try {
              var r = this.ownerDocument.evaluate(selector, this, null, 7, null);
              var nodes = [];
              for (var i = 0; i < r.snapshotLength; i++) nodes.push(r.snapshotItem(i));
              return nodes;
            } catch(e) { return []; }
          }
          try { return Array.from(this.querySelectorAll(selector)); }
          catch(e) { throw new Error('#{INVALID_SELECTOR_MARKER}' + selector); }
        }
      JS
      private_constant :FIND_WITHIN_JS

      # JS function for finding elements in an iframe's contentDocument.
      FIND_IN_FRAME_JS = <<~JS.freeze
        function(method, selector) {
          var doc;
          try { doc = this.contentDocument || (this.contentWindow && this.contentWindow.document); } catch(e) {}
          if (!doc) return [];
          if (method === 'xpath') {
            try {
              var r = doc.evaluate(selector, doc, null, 7, null);
              var nodes = [];
              for (var i = 0; i < r.snapshotLength; i++) nodes.push(r.snapshotItem(i));
              return nodes;
            } catch(e) { return []; }
          }
          try { return Array.from(doc.querySelectorAll(selector)); }
          catch(e) { throw new Error('#{INVALID_SELECTOR_MARKER}' + selector); }
        }
      JS
      private_constant :FIND_IN_FRAME_JS

      # Walks `parentNode` from `this` up to (but excluding) `document`,
      # returning the chain as a JS array. Each entry is an element node so
      # `extract_node_object_ids` can wrap them as Lightpanda::Nodes.
      PARENTS_JS = <<~JS
        function() {
          var nodes = [];
          var p = this.parentNode;
          while (p && p !== this.ownerDocument) {
            nodes.push(p);
            p = p.parentNode;
          }
          return nodes;
        }
      JS
      private_constant :PARENTS_JS

      def find_in_document(method, selector)
        with_default_context_wait do
          # Coerce Symbol selectors (e.g. Capybara warning path lets `have_css(:p)`
          # through) to a string before quoting. Symbol#inspect returns `:p`,
          # which would inject a bare token into the JS source.
          selector_literal = selector.to_s.inspect
          # XPath parse errors return [] silently to match Capybara's expected
          # "not found" behavior (see FIND_WITHIN_JS comment above for why).
          js = if method == "xpath"
                 <<~XPATH_FIND
                   (function() {
                     try {
                       var r = document.evaluate(#{selector_literal}, document, null, 7, null);
                       var nodes = [];
                       for (var i = 0; i < r.snapshotLength; i++) nodes.push(r.snapshotItem(i));
                       return nodes;
                     } catch(e) { return []; }
                   })()
                 XPATH_FIND
               else
                 <<~CSS_FIND
                   (function() {
                     try { return Array.from(document.querySelectorAll(#{selector_literal})); }
                     catch(e) { throw new Error('#{INVALID_SELECTOR_MARKER}' + #{selector_literal}); }
                   })()
                 CSS_FIND
               end
          result = evaluate_with_ref(js)
          extract_node_object_ids(result)
        end
      rescue JavaScriptError => e
        raise_invalid_selector(e, method, selector)
      end

      def find_in_frame(method, selector)
        with_default_context_wait do
          frame_node = @frame_stack.last
          result = call_function_on(frame_node.remote_object_id, FIND_IN_FRAME_JS, method, selector,
                                    return_by_value: false)
          extract_node_object_ids(result)
        end
      rescue JavaScriptError => e
        raise_invalid_selector(e, method, selector)
      end

      def raise_invalid_selector(js_error, method, selector)
        if js_error.message.include?(INVALID_SELECTOR_MARKER)
          raise InvalidSelector.new("Invalid #{method} selector: #{selector.inspect}", method, selector)
        end

        raise js_error
      end

      # Extract individual node objectIds from a remote array reference.
      # `ensure release_object` so the outer array handle is freed even when
      # property walking raises — without this, a transient CDP error during
      # property enumeration leaks one V8 handle per failed find call.
      def extract_node_object_ids(result)
        return [] unless result && result["objectId"]

        outer_id = result["objectId"]
        begin
          props = get_object_properties(outer_id)
          properties = props["result"] || []
          properties
            .select { |p| p["name"] =~ /\A\d+\z/ }
            .sort_by { |p| p["name"].to_i }
            .filter_map { |p| p.dig("value", "objectId") }
        rescue Error
          []
        ensure
          release_object(outer_id)
        end
      end

      def register_auto_scripts
        page_command("Page.addScriptToEvaluateOnNewDocument", source: AutoScripts::JS)
      end

      def subscribe_to_console_logs
        logger = @options.logger
        return unless logger

        on("Runtime.consoleAPICalled") do |params|
          params["args"]&.each do |r|
            value = r["value"]
            next if value.is_a?(String) && value.start_with?(TURBO_SENTINEL_PREFIX)

            logger.puts(value)
          end
        end
      end

      TURBO_SENTINEL_PREFIX = "__lightpanda_turbo_"
      private_constant :TURBO_SENTINEL_PREFIX

      # Oldest entries are dropped past this cap so a chatty page can't grow
      # the buffer unbounded across a long session.
      CONSOLE_LOGS_LIMIT = 1_000

      # Ring-buffer every console.* call for `Browser#console_logs`. Separate
      # from subscribe_to_console_logs (which streams to an optional IO logger)
      # so capture works without any logger configured. Skips the Turbo
      # activity-tracker sentinels — they're driver plumbing, not page output.
      def subscribe_to_console_capture
        on("Runtime.consoleAPICalled") do |params|
          args = params["args"]
          next unless args.is_a?(Array)

          first = args.first&.dig("value")
          next if first.is_a?(String) && first.start_with?(TURBO_SENTINEL_PREFIX)

          entry = {
            type: params["type"],
            text: args.map { |a| a.fetch("value") { a["description"] }.to_s }.join(" "),
            timestamp: params["timestamp"],
            args: args,
          }
          @console_logs_mutex.synchronize do
            @console_logs << entry
            @console_logs.shift(@console_logs.size - CONSOLE_LOGS_LIMIT) if @console_logs.size > CONSOLE_LOGS_LIMIT
          end
        end
      end

      # Wire @turbo_event to the JS-side _signalTurbo emissions. The JS calls
      # console.debug('__lightpanda_turbo_busy') / '_idle' on transitions across
      # zero pending ops; Lightpanda forwards those to Runtime.consoleAPICalled.
      # Idle → set the event (wakes any waiter); busy → reset.
      #
      # On Runtime.executionContextsCleared (navigation), unconditionally set
      # the event: if we navigated away mid-busy state, no further idle signal
      # would ever come from the old context, and we'd block for the full
      # timeout. The new context will signal busy again if Turbo is active.
      def subscribe_to_turbo_signals
        on("Runtime.consoleAPICalled") do |params|
          next unless params["args"].is_a?(Array)

          marker = params["args"].first&.dig("value")
          next unless marker.is_a?(String) && marker.start_with?(TURBO_SENTINEL_PREFIX)

          case marker
          when "#{TURBO_SENTINEL_PREFIX}busy" then @turbo_event.reset
          when "#{TURBO_SENTINEL_PREFIX}idle" then @turbo_event.set
          end
        end

        on("Runtime.executionContextsCleared") { @turbo_event.set }
      end

      # Remember the latest top-level navigation response so
      # `Driver#status_code` / `#response_headers` can answer it. Mirrors the
      # capybara-playwright-driver page hook that captures
      # `request.navigation_request?` (lib/capybara/playwright/page.rb#L33-L37);
      # CDP normally signals "this is the main-document response" via
      # `Network.responseReceived.type`, but Lightpanda omits that field on
      # responses (only emits `type` on `Network.requestWillBeSent`). So we
      # do the matching the long way: capture the document requestId from
      # `requestWillBeSent {type: "Document"}`, then store the response whose
      # `requestId` equals it. Re-installed per `create_page` so the new
      # BrowserContext after `Driver#reset!` starts with a fresh slot.
      #
      # Caveat: sending `Network.disable` (e.g. through `driver.network.disable`)
      # also silences this handler — they share the same CDP toggle.
      def subscribe_to_navigation_response
        @last_navigation_response = nil
        @document_request_id = nil

        on("Network.requestWillBeSent") do |params|
          next unless params["type"] == "Document"

          @document_request_id = params["requestId"]
          @last_navigation_response = nil
        end

        on("Network.responseReceived") do |params|
          next unless params["requestId"] == @document_request_id

          @last_navigation_response = {
            status: params.dig("response", "status"),
            headers: params.dig("response", "headers") || {},
          }
        end

        command("Network.enable")
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

      def serialize_argument(arg)
        if arg.respond_to?(:remote_object_id)
          { objectId: arg.remote_object_id }
        else
          { value: arg }
        end
      end

      def handle_evaluate_response(response)
        if response["exceptionDetails"]
          debug_js_failure("handle_evaluate_response", "(unknown — already-issued call)", response)
          raise JavaScriptError, response
        end

        result = response["result"]
        return nil if result["type"] == "undefined"

        result["value"]
      end

      # Run a wrapped function via Runtime.callFunctionOn with `arguments` bound.
      # `args` is converted via `serialize_argument` (Nodes → objectId, scalars → value).
      # When `return_by_value: false` (the default) the return value is unwrapped via
      # `unwrap_call_result` so that DOM nodes come back as `{ "__lightpanda_node__" => ... }`
      # hashes the Driver can wrap as Capybara nodes.
      def call_with_args(function_declaration, args, return_by_value: false)
        # document_object_id returns a fresh RemoteObject handle every call.
        # Release it on the way out so long-running shared-spec sessions don't
        # accumulate orphaned V8 handles between resets.
        doc_oid = document_object_id
        params = {
          objectId: doc_oid,
          functionDeclaration: function_declaration,
          returnByValue: return_by_value,
          awaitPromise: true,
          arguments: args.map { |a| serialize_argument(a) },
        }
        response = page_command("Runtime.callFunctionOn", **params)
        if response["exceptionDetails"]
          debug_js_failure("call_with_args", function_declaration, response)
          raise JavaScriptError, response
        end

        return_by_value ? handle_evaluate_response(response) : unwrap_call_result(response["result"])
      ensure
        release_object(doc_oid) if doc_oid
      end

      # Translate a non-by-value Runtime result into a plain Ruby value, surfacing
      # DOM nodes as `{ "__lightpanda_node__" => "..." }` so the Driver can wrap
      # them. The sentinel key (rather than a plain "objectId") prevents
      # misclassifying user JS that legitimately returns `{ objectId: "x" }`.
      #
      # When the result carries an objectId we can't unwrap (function, regexp,
      # date, …), release the handle before falling back to `result["value"]`
      # so V8 doesn't accumulate orphaned references across long sessions.
      def unwrap_call_result(result)
        return nil if result["type"] == "undefined"
        return nil if result["subtype"] == "null"

        object_id = result["objectId"]
        if object_id
          return { "__lightpanda_node__" => object_id } if result["subtype"] == "node"
          return serialize_remote_array(object_id) if result["subtype"] == "array"
          return serialize_remote_object(object_id) if result["type"] == "object"

          release_object(object_id)
        end

        result["value"]
      end

      # Re-fetch a remote object as JSON-serializable value for plain objects/arrays.
      # Cheaper than walking properties and good enough for shared specs. Releases
      # the original handle so long-lived sessions don't accumulate leaked objectIds.
      def serialize_remote_object(object_id)
        json = page_command(
          "Runtime.callFunctionOn",
          objectId: object_id,
          functionDeclaration: "function() { return this }",
          returnByValue: true
        )
        handle_evaluate_response(json)
      ensure
        release_object(object_id)
      end

      # Walk an array's own indexed properties via `Runtime.getProperties`,
      # unwrapping each element through the regular result pipeline so that
      # DOM-node entries surface as `{ "__lightpanda_node__" => ... }` instead
      # of being flattened to `{}` by `returnByValue: true`. Releases the
      # outer array's objectId once we've harvested its elements.
      def serialize_remote_array(object_id)
        properties = get_object_properties(object_id).fetch("result", [])
        properties
          .select { |p| p["enumerable"] && p["name"] =~ /\A\d+\z/ }
          .sort_by { |p| p["name"].to_i }
          .map { |p| unwrap_call_result(p["value"] || {}) }
      ensure
        release_object(object_id)
      end

      # objectId of `document`, used as the `this` context for callFunctionOn when
      # we need `arguments` binding but don't care about `this`. Re-resolved per
      # call because the document objectId is invalidated by navigation.
      def document_object_id
        result = page_command("Runtime.evaluate", expression: "document", returnByValue: false)
        result.dig("result", "objectId")
      end

      def wait_for_page_load(url, retried:)
        deadline = await_navigation do
          @client.command("Page.navigate", { url: url }, async: true, session_id: @session_id)
        end
        handle_navigation_crash(url, deadline, retried: retried)
      end

      # Lightpanda may kill the WebSocket or crash during complex page
      # navigation (lightpanda-io/browser#1849, #1854). Reconnect and
      # retry once. If the retry also crashes, raise a clear error
      # instead of leaving the client in a dead state.
      def handle_navigation_crash(url, deadline, retried:)
        if @client.closed? && !retried
          begin
            reconnect
            remaining = deadline - monotonic_time
            go_to(url, wait: remaining.positive?, retried: true) if remaining.positive?
          rescue DeadBrowserError
            raise
          rescue StandardError
            # reconnect itself failed (process won't restart, port stuck, etc.).
            # Fall through to the raise below — a second immediate reconnect
            # attempt would just duplicate the failure we already swallowed.
          end
        end

        return unless @client.closed?

        raise DeadBrowserError, "Lightpanda crashed navigating to #{url}"
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

      def restart_process_if_dead
        return unless @process && !@process.alive?

        begin
          @process.stop
        rescue StandardError
          nil
        end
        @process.start
      end

      def safe_current_url
        current_url
      rescue StandardError
        nil
      end

      # Wait for a navigation triggered by the given block.
      # Uses the same loadEventFired + readyState fallback as go_to.
      def wait_for_navigation(&)
        enable_page_events
        await_navigation(&)
      end

      # Step the session history by `offset` (-1 = back, +1 = forward) using
      # native CDP. `Page.getNavigationHistory` returns the entry list and
      # `currentIndex`; `Page.navigateToHistoryEntry` jumps to the chosen
      # entry's `id`. No-op when the offset would step past either end so
      # the behavior matches `history.back()` / `history.forward()` on a
      # bounded session history.
      def navigate_history(offset)
        history = page_command("Page.getNavigationHistory")
        target_index = history["currentIndex"] + offset
        entries = history["entries"]
        return if target_index.negative? || target_index >= entries.length

        page_command("Page.navigateToHistoryEntry", entryId: entries[target_index]["id"])
      end

      # Common navigation lifecycle shared by `wait_for_page_load` (fresh
      # `Page.navigate`) and `wait_for_navigation` (back / forward / reload).
      # Subscribes to Page.loadEventFired, runs the trigger, waits briefly for
      # the event, falls back to readyState polling for the remaining budget.
      # The handler is unsubscribed via `ensure` so a raising trigger doesn't
      # leak a subscription onto the next navigation. Returns the deadline so
      # the caller can decide whether to attempt crash recovery.
      def await_navigation
        starting_url = safe_current_url
        deadline = monotonic_time + @options.timeout
        loaded = Utils::Event.new
        handler = proc { loaded.set }
        @client.on("Page.loadEventFired", &handler)

        begin
          yield

          unless loaded.wait([2, @options.timeout].min)
            remaining = deadline - monotonic_time
            poll_ready_state(remaining, loaded_event: loaded, starting_url: starting_url) if remaining.positive?
          end
        ensure
          @client.off("Page.loadEventFired", handler)
        end

        deadline
      end

      # Poll document.readyState as a fallback when Page.loadEventFired
      # doesn't fire (CLAUDE.md rules call this out as load-bearing — do
      # not remove). When starting_url is provided, the poll ignores
      # readyState values from the old page (e.g. about:blank reports
      # "complete" while the new page is still loading in the background).
      def poll_ready_state(timeout, loaded_event: nil, starting_url: nil)
        # Use a short per-evaluation timeout because Lightpanda may block
        # all commands while navigating. Without this, a single evaluate()
        # call would consume the entire @options.timeout, making the poll
        # loop effectively a single attempt.
        poll_cmd_timeout = [timeout / 5.0, 2].max

        Utils::Wait.until(timeout: timeout, interval: 0.1) do
          loaded_event&.set? || @client.closed? || page_ready?(poll_cmd_timeout, starting_url)
        end
      rescue TimeoutError
        # Expected — readyState fallback exhausted its budget. The caller
        # (await_navigation) keeps going and lets handle_navigation_crash
        # decide whether the session is recoverable.
      end

      POLL_STATE_JS = "(function(){return{r:document.readyState,u:location.href}})()"
      private_constant :POLL_STATE_JS

      def page_ready?(cmd_timeout, starting_url)
        response = @client.command(
          "Runtime.evaluate",
          { expression: POLL_STATE_JS, returnByValue: true, awaitPromise: true },
          session_id: @session_id,
          timeout: cmd_timeout
        )
        state = response.dig("result", "value")
        return false unless state

        url_changed = starting_url.nil? || state["u"] != starting_url
        url_changed && %w[complete interactive].include?(state["r"])
      rescue Error
        false
      end

      def monotonic_time
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end
    end
  end
end
