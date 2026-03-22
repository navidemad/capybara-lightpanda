# frozen_string_literal: true

require "forwardable"
require "concurrent-ruby"

module Capybara
  module Lightpanda
    class Browser
      extend Forwardable

      attr_reader :options, :process, :client, :target_id, :session_id, :frame_stack

      delegate %i[on off] => :client

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

        subscribe_to_console_logs
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

      def back
        wait_for_navigation { execute("history.back()") }
      end

      def forward
        wait_for_navigation { execute("history.forward()") }
      end

      def refresh
        go_to(current_url)
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
      def evaluate(expression)
        response = page_command("Runtime.evaluate", expression: expression, returnByValue: true, awaitPromise: true)

        handle_evaluate_response(response)
      end

      # Execute JS without returning a value.
      def execute(expression)
        page_command("Runtime.evaluate", expression: expression, returnByValue: false, awaitPromise: false)
        nil
      end

      # Evaluate async JS with a callback. The user's script receives
      # a `arguments[arguments.length - 1]` callback to signal completion
      # (matching Capybara's evaluate_async_script contract).
      def evaluate_async(expression, wait: @options.timeout)
        wrapped = <<~JS
          new Promise(function(__resolve, __reject) {
            var __timer = setTimeout(function() {
              __reject(new Error('Async script timeout after #{(wait * 1000).to_i}ms'));
            }, #{(wait * 1000).to_i});
            var __done = function(val) { clearTimeout(__timer); __resolve(val); };
            (function() { #{expression} }).call(null, __done);
          })
        JS
        evaluate(wrapped)
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

      # Wait for any pending Turbo operations to complete.
      # Returns immediately if Turbo is not loaded or has no pending work.
      # Uses the tracking counters injected by index.js.
      def wait_for_turbo
        idle = evaluate(
          "typeof window._lightpanda === 'undefined' || " \
          "!window._lightpanda.turbo || window._lightpanda.turbo.idle()"
        )
        return if idle

        deadline = monotonic_time + @options.timeout
        loop do
          sleep 0.05
          idle = begin
            evaluate("window._lightpanda.turbo.idle()")
          rescue StandardError
            true
          end
          break if idle
          break if monotonic_time > deadline
        end
      rescue StandardError
        # Page may have navigated (full page load), JS context lost — safe to continue
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
      # Frame stack stores Node objects (with remote_object_id).
      # Finding scopes to the innermost frame via callFunctionOn on the iframe element.

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
      # Page.handleJavaScriptDialog is not yet implemented in Lightpanda.
      # This code is ready for when it's added upstream.

      def prepare_modals
        return if @modal_handler_installed

        enable_page_events

        on("Page.javascriptDialogOpening") do |params|
          type = params["type"]
          message = params["message"]
          @modal_messages << { type: type, message: message }

          response = @modal_responses.shift
          begin
            if response
              accept_params = { accept: response[:accept] }
              accept_params[:promptText] = response[:text] if response[:text]
              page_command("Page.handleJavaScriptDialog", **accept_params)
            else
              page_command("Page.handleJavaScriptDialog", accept: type == "alert")
            end
          rescue BrowserError
            # Page.handleJavaScriptDialog may not be implemented in Lightpanda yet
          end
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

      def find_modal(type, wait: options.timeout)
        deadline = monotonic_time + wait
        loop do
          msg = @modal_messages.find { |m| m[:type] == type.to_s }
          if msg
            @modal_messages.delete(msg)
            return msg[:message]
          end
          break if monotonic_time > deadline

          sleep 0.05
        end
        raise Capybara::ModalNotFound, "Unable to find modal dialog"
      end

      def reset_modals
        @modal_responses.clear
        @modal_messages.clear
      end

      private

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
        Utils.with_retry(errors: [NoExecutionContextError], max: 3, wait: 0.1) do
          js = if method == "xpath"
                 "(typeof _lightpanda !== 'undefined') ? _lightpanda.xpathFind(#{selector.inspect}, document) : []"
               else
                 "(function() { try { return Array.from(document.querySelectorAll(#{selector.inspect})); } " \
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

      def subscribe_to_console_logs
        logger = @options.logger
        return unless logger

        on("Runtime.consoleAPICalled") do |params|
          params["args"]&.each { |r| logger.puts(r["value"]) }
        end
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

      def wait_for_page_load(url, retried:)
        starting_url = safe_current_url
        deadline = monotonic_time + @options.timeout
        loaded = Concurrent::Event.new

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
        loaded = Concurrent::Event.new
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
