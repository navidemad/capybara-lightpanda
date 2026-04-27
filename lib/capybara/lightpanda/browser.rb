# frozen_string_literal: true

require "forwardable"
require "concurrent-ruby"

module Capybara
  module Lightpanda
    class Browser
      extend Forwardable

      attr_reader :options, :process, :client, :target_id, :session_id, :frame_stack

      delegate %i[on off] => :client

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
        @started = false
        @page_events_enabled = false
        @modal_responses = []
        @modal_messages = []
        @modal_handler_installed = false
        @frame_stack = []
        @frames = Concurrent::Hash.new
        @turbo_event = Utils::Event.new
        @turbo_event.set

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

        create_page

        @started = true
      end

      def create_page
        result = @client.command("Target.createTarget", { url: "about:blank" })
        @target_id = result["targetId"]

        attach_result = @client.command("Target.attachToTarget", { targetId: @target_id, flatten: true })
        @session_id = attach_result["sessionId"]

        @frames.clear
        @turbo_event.set
        subscribe_to_console_logs
        subscribe_to_execution_context
        subscribe_to_frame_events
        subscribe_to_turbo_signals
        register_auto_scripts
      end

      def restart
        quit
        start
      end

      # Recover after a WebSocket disconnect or process crash during navigation.
      # Restarts the process if it died, then creates a fresh client and page.
      def reconnect
        close_client_silently
        restart_process_if_dead

        ws_url = @options.ws_url? ? @options.ws_url : @process&.ws_url
        raise DeadBrowserError, "Cannot reconnect: no WebSocket URL" unless ws_url

        @client = Client.new(ws_url, @options)
        create_page
        @page_events_enabled = false
      end

      def quit
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
        @modal_handler_installed = false
        @frame_stack.clear
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
      # retry once. Replaces blind 100 ms sleep retries.
      def with_default_context_wait(timeout: 1.0)
        yield
      rescue NoExecutionContextError
        raise unless wait_for_default_context(timeout)

        yield
      end

      def back
        wait_for_navigation { execute("history.back()") }
      end

      def forward
        wait_for_navigation { execute("history.forward()") }
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
        evaluate("document.documentElement.outerHTML")
      end
      alias html body

      # Evaluate JS and return a serialized value.
      # No-args fast path uses Runtime.evaluate; with args we wrap as a function
      # and dispatch via Runtime.callFunctionOn so `arguments[i]` is bound.
      # Both paths use `returnByValue: false` and unwrap so DOM-node returns
      # come back as `{ "__lightpanda_node__" => ... }` for the Driver to wrap.
      def evaluate(expression, *args)
        if args.empty?
          response = page_command("Runtime.evaluate", expression: expression, returnByValue: false, awaitPromise: true)
          raise JavaScriptError, response if response["exceptionDetails"]

          return unwrap_call_result(response["result"])
        end

        wrapped = "function() { return #{expression} }"
        call_with_args(wrapped, args)
      end

      # Execute JS without returning a value.
      def execute(expression, *args)
        if args.empty?
          page_command("Runtime.evaluate", expression: expression, returnByValue: false, awaitPromise: false)
          return nil
        end

        wrapped = "function() { #{expression} }"
        call_with_args(wrapped, args, return_by_value: false)
        nil
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
        raise JavaScriptError, response if response["exceptionDetails"]

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
        raise JavaScriptError, response if response["exceptionDetails"]

        result = response["result"]
        return nil if result["type"] == "undefined"

        return_by_value ? result["value"] : result
      end

      # Get properties of a remote object (used to extract array elements).
      def get_object_properties(remote_object_id)
        page_command("Runtime.getProperties", objectId: remote_object_id, ownProperties: true)
      end

      # Release a remote object reference to free V8 memory.
      def release_object(remote_object_id)
        page_command("Runtime.releaseObject", objectId: remote_object_id)
      rescue BrowserError, NoExecutionContextError
        # Object may already be released or context destroyed
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
      def find_within(remote_object_id, method, selector)
        result = call_function_on(remote_object_id, FIND_WITHIN_JS, method, selector, return_by_value: false)
        extract_node_object_ids(result)
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

      def css(selector)
        node_ids = page_command("DOM.querySelectorAll", nodeId: document_node_id, selector: selector)
        node_ids["nodeIds"] || []
      end

      def at_css(selector)
        result = page_command("DOM.querySelector", nodeId: document_node_id, selector: selector)

        result["nodeId"]
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

      # Wait for any pending Turbo operations to complete. Event-driven: the
      # injected JS in index.js calls `console.debug('__lightpanda_turbo_busy')`
      # when the pending-ops counter rises above 0 and `_idle` when it returns
      # to 0. We toggle @turbo_event accordingly (see subscribe_to_turbo_signals).
      #
      # Pages without Turbo never trigger _turboStart, so no sentinels fire and
      # @turbo_event stays set (initial state) — wait returns immediately. Same
      # for Turbo-loaded pages that have no pending work.
      def wait_for_turbo
        @turbo_event.wait(@options.timeout)
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

      # -- Frame Support --
      # Two parallel views of frames:
      #
      #   * `frame_stack` (Array<Node>) — the Capybara `switch_to_frame` stack;
      #     drives where `find` resolves selectors. Stored as Nodes so
      #     callFunctionOn can scope to the iframe's contentDocument.
      #
      #   * `@frames` (Concurrent::Hash<String, Frame>) — metadata view
      #     populated from Page.frame{Attached,Navigated,Detached,...} events.
      #     Used for diagnostics / introspection (frames, main_frame, frame_by).
      #     Lightpanda's frame events are not reliable enough to drive
      #     navigation waits, so this is read-only metadata.

      def push_frame(node)
        @frame_stack.push(node)
      end

      def pop_frame
        @frame_stack.pop
      end

      def clear_frames
        @frame_stack.clear
      end

      # All frames currently attached to the page (main frame + iframes).
      def frames
        @frames.values
      end

      # The top-level frame, or nil if it hasn't been registered yet (events
      # arrive asynchronously after Page.enable).
      def main_frame
        @frames.each_value.find(&:main?)
      end

      def frame_by(id: nil, name: nil)
        if id
          @frames[id]
        elsif name
          @frames.each_value.find { |f| f.name == name }
        end
      end

      # -- Modal/Dialog Support --
      # Lightpanda auto-dismisses dialogs in headless mode: alert→OK,
      # confirm→false, prompt→null. Page.javascriptDialogOpening fires
      # (since 2026-04-03), so we capture messages for find_modal, but
      # Page.handleJavaScriptDialog always errors with "No dialog is showing"
      # and we never call it (the dispatch thread cannot make synchronous
      # CDP calls without deadlocking). @modal_responses is retained so
      # accept_modal/dismiss_modal preserve their API contract; the
      # accept/dismiss choice is informational only.

      def prepare_modals
        return if @modal_handler_installed

        enable_page_events

        on("Page.javascriptDialogOpening") do |params|
          @modal_messages << { type: params["type"], message: params["message"] }
          @modal_responses.shift
        end

        @modal_handler_installed = true
      end

      def accept_modal(type, text: nil)
        prepare_modals
        @modal_responses << { accept: true, text: text, type: type.to_s }
      end

      def dismiss_modal(type)
        prepare_modals
        @modal_responses << { accept: false, type: type.to_s }
      end

      def find_modal(type, text: nil, wait: options.timeout)
        regexp = text.is_a?(Regexp) ? text : (text && Regexp.new(Regexp.escape(text.to_s)))
        deadline = monotonic_time + wait
        last_message = nil
        loop do
          msg = @modal_messages.find { |m| m[:type] == type.to_s }
          if msg
            last_message = msg[:message]
            if regexp.nil? || last_message.match?(regexp)
              @modal_messages.delete(msg)
              return last_message
            end
          end
          break if monotonic_time > deadline

          sleep 0.05
        end
        raise_modal_not_found(text, last_message)
      end

      def reset_modals
        @modal_responses.clear
        @modal_messages.clear
      end

      private

      def raise_modal_not_found(text, last_message)
        if last_message
          raise Capybara::ModalNotFound,
                "Unable to find modal dialog with #{text} - found '#{last_message}' instead."
        end
        raise Capybara::ModalNotFound, "Unable to find modal dialog#{" with #{text}" if text}"
      end

      # JS function for finding elements within a node.
      # Works in any execution context (top frame or iframe).
      FIND_WITHIN_JS = <<~JS
        function(method, selector) {
          if (method === 'xpath') {
            if (typeof _lightpanda !== 'undefined') return _lightpanda.xpathFind(selector, this);
            return [];
          }
          try { return Array.from(this.querySelectorAll(selector)); } catch(e) { return []; }
        }
      JS

      # JS function for finding elements in an iframe's contentDocument.
      FIND_IN_FRAME_JS = <<~JS
        function(method, selector) {
          var doc;
          try { doc = this.contentDocument || (this.contentWindow && this.contentWindow.document); } catch(e) {}
          if (!doc) return [];
          if (method === 'xpath') {
            if (typeof _lightpanda !== 'undefined') return _lightpanda.xpathFind(selector, doc);
            return [];
          }
          try { return Array.from(doc.querySelectorAll(selector)); } catch(e) { return []; }
        }
      JS

      def find_in_document(method, selector)
        with_default_context_wait do
          # Coerce Symbol selectors (e.g. Capybara warning path lets `have_css(:p)`
          # through) to a string before quoting. Symbol#inspect returns `:p`,
          # which would inject a bare token into the JS source.
          selector_literal = selector.to_s.inspect
          js = if method == "xpath"
                 "(typeof _lightpanda !== 'undefined') ? _lightpanda.xpathFind(#{selector_literal}, document) : []"
               else
                 "(function() { try { return Array.from(document.querySelectorAll(#{selector_literal})); } " \
                   "catch(e) { return []; } })()"
               end
          result = evaluate_with_ref(js)
          extract_node_object_ids(result)
        end
      end

      def find_in_frame(method, selector)
        frame_node = @frame_stack.last
        result = call_function_on(frame_node.remote_object_id, FIND_IN_FRAME_JS, method, selector,
                                  return_by_value: false)
        extract_node_object_ids(result)
      end

      # Extract individual node objectIds from a remote array reference.
      def extract_node_object_ids(result)
        return [] unless result && result["objectId"]

        props = get_object_properties(result["objectId"])
        properties = props["result"] || []

        ids = properties
              .select { |p| p["name"] =~ /\A\d+\z/ }
              .sort_by { |p| p["name"].to_i }
              .filter_map { |p| p.dig("value", "objectId") }

        release_object(result["objectId"])
        ids
      rescue StandardError
        []
      end

      def register_auto_scripts
        page_command("Page.addScriptToEvaluateOnNewDocument", source: XPathPolyfill::JS)
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

      # Maintain @frames from Page.frame* events. Subscribed once per page
      # (create_page resets @frames and re-subscribes on a fresh client, so
      # handlers don't accumulate across reconnects). Loading-state events
      # are best-effort: Lightpanda's Page.frameStoppedLoading is unreliable
      # on complex pages (#1801), so we track state for diagnostics only.
      def subscribe_to_frame_events
        on("Page.frameAttached") { |params| handle_frame_attached(params) }
        on("Page.frameNavigated") { |params| handle_frame_navigated(params) }
        on("Page.frameStartedLoading") { |params| set_frame_state(params["frameId"], :started_loading) }
        on("Page.frameStoppedLoading") { |params| set_frame_state(params["frameId"], :stopped_loading) }
        on("Page.frameDetached") { |params| handle_frame_detached(params) }
      end

      def handle_frame_attached(params)
        parent_id, frame_id = params.values_at("parentFrameId", "frameId")
        @frames[frame_id] ||= Frame.new(frame_id, parent_id)
      end

      def handle_frame_navigated(params)
        frame_data = params["frame"] || {}
        frame_id = frame_data["id"]
        return unless frame_id

        frame = @frames[frame_id] ||= Frame.new(frame_id, frame_data["parentId"])
        frame.name = frame_data["name"]
        frame.url = frame_data["url"]
        frame.state = :navigated
      end

      def handle_frame_detached(params)
        frame = @frames.delete(params["frameId"])
        frame&.state = :detached
      end

      def set_frame_state(frame_id, state)
        frame = @frames[frame_id]
        frame.state = state if frame
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

      def document_node_id
        result = page_command("DOM.getDocument")

        result.dig("root", "nodeId")
      end

      def handle_evaluate_response(response)
        raise JavaScriptError, response if response["exceptionDetails"]

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
        params = {
          objectId: document_object_id,
          functionDeclaration: function_declaration,
          returnByValue: return_by_value,
          awaitPromise: true,
          arguments: args.map { |a| serialize_argument(a) },
        }
        response = page_command("Runtime.callFunctionOn", **params)
        raise JavaScriptError, response if response["exceptionDetails"]

        return_by_value ? handle_evaluate_response(response) : unwrap_call_result(response["result"])
      end

      # Translate a non-by-value Runtime result into a plain Ruby value, surfacing
      # DOM nodes as `{ "__lightpanda_node__" => "..." }` so the Driver can wrap
      # them. The sentinel key (rather than a plain "objectId") prevents
      # misclassifying user JS that legitimately returns `{ objectId: "x" }`.
      def unwrap_call_result(result)
        return nil if result["type"] == "undefined"
        return nil if result["subtype"] == "null"

        object_id = result["objectId"]
        if object_id
          return { "__lightpanda_node__" => object_id } if result["subtype"] == "node"
          return serialize_remote_array(object_id) if result["subtype"] == "array"
          return serialize_remote_object(object_id) if result["type"] == "object"
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
        starting_url = safe_current_url
        deadline = monotonic_time + @options.timeout
        loaded = Utils::Event.new

        handler = proc { loaded.set }
        @client.on("Page.loadEventFired", &handler)

        @client.command("Page.navigate", { url: url }, async: true, session_id: @session_id)

        # Give loadEventFired a brief window (fast path), then fall back
        # to readyState polling with the remaining budget.
        unless loaded.wait([2, @options.timeout].min)
          remaining = deadline - monotonic_time
          poll_ready_state(remaining, loaded_event: loaded, starting_url: starting_url) if remaining.positive?
        end

        @client.off("Page.loadEventFired", handler)
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
            # reconnect itself failed (process won't restart, port stuck, etc.)
          end
        end

        return unless @client.closed?

        begin
          reconnect
        rescue StandardError
          nil
        end
        raise DeadBrowserError, "Lightpanda crashed navigating to #{url}"
      end

      def close_client_silently
        @client&.close
      rescue StandardError
        nil
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
      def wait_for_navigation
        enable_page_events

        starting_url = safe_current_url
        deadline = monotonic_time + @options.timeout
        loaded = Utils::Event.new
        handler = proc { loaded.set }
        @client.on("Page.loadEventFired", &handler)

        yield

        unless loaded.wait([2, @options.timeout].min)
          remaining = deadline - monotonic_time
          poll_ready_state(remaining, loaded_event: loaded, starting_url: starting_url) if remaining.positive?
        end

        @client.off("Page.loadEventFired", handler)
      end

      # Poll document.readyState as a fallback when Page.loadEventFired
      # doesn't fire. When starting_url is provided, the poll ignores
      # readyState values from the old page (e.g. about:blank reports
      # "complete" while the new page is still loading in the background).
      def poll_ready_state(timeout, loaded_event: nil, starting_url: nil)
        deadline = monotonic_time + timeout
        # Use a short per-evaluation timeout because Lightpanda may block
        # all commands while navigating. Without this, a single evaluate()
        # call would consume the entire @options.timeout, making the poll
        # loop effectively a single attempt.
        poll_cmd_timeout = [timeout / 5.0, 2].max

        loop do
          break if loaded_event&.set?
          break if @client.closed?
          break if page_ready?(poll_cmd_timeout, starting_url)
          break if monotonic_time > deadline

          sleep 0.1
        end
      end

      POLL_STATE_JS = "(function(){return{r:document.readyState,u:location.href}})()"

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
      rescue StandardError
        false
      end

      def monotonic_time
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end
    end
  end
end
