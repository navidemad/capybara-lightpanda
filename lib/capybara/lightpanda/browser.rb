# frozen_string_literal: true

require "forwardable"
require "concurrent-ruby"

module Capybara
  module Lightpanda
    class Browser
      extend Forwardable

      attr_reader :options, :process, :client, :target_id, :session_id, :frame_stack

      delegate [:on, :off] => :client

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
      end

      def restart
        quit
        start
      end

      def quit
        @client&.close rescue nil
        @process&.stop rescue nil
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
      def go_to(url, wait: true)
        enable_page_events

        if wait
          loaded = Concurrent::Event.new

          handler = proc { loaded.set }
          @client.on("Page.loadEventFired", &handler)

          result = page_command("Page.navigate", url: url)

          unless loaded.wait(@options.timeout)
            poll_ready_state(@options.timeout)
          end

          @client.off("Page.loadEventFired", handler)

          result
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
      FIND_WITHIN_JS = <<~JS.freeze
        function(method, selector) {
          if (method === 'xpath') {
            if (typeof _lightpanda !== 'undefined') return _lightpanda.xpathFind(selector, this);
            return [];
          }
          try { return Array.from(this.querySelectorAll(selector)); } catch(e) { return []; }
        }
      JS

      # JS function for finding elements in an iframe's contentDocument.
      FIND_IN_FRAME_JS = <<~JS.freeze
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
        js = if method == "xpath"
          "(typeof _lightpanda !== 'undefined') ? _lightpanda.xpathFind(#{selector.inspect}, document) : []"
        else
          "(function() { try { return Array.from(document.querySelectorAll(#{selector.inspect})); } catch(e) { return []; } })()"
        end
        result = evaluate_with_ref(js)
        extract_node_object_ids(result)
      end

      def find_in_frame(method, selector)
        frame_node = @frame_stack.last
        result = call_function_on(frame_node.remote_object_id, FIND_IN_FRAME_JS, method, selector, return_by_value: false)
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

      # Wait for a navigation triggered by the given block.
      # Uses the same loadEventFired + readyState fallback as go_to.
      def wait_for_navigation
        enable_page_events

        loaded = Concurrent::Event.new
        handler = proc { loaded.set }
        @client.on("Page.loadEventFired", &handler)

        yield

        unless loaded.wait(@options.timeout)
          poll_ready_state(@options.timeout)
        end

        @client.off("Page.loadEventFired", handler)
      end

      def poll_ready_state(timeout)
        deadline = monotonic_time + timeout
        loop do
          ready = evaluate("document.readyState") rescue nil
          break if ready == "complete" || ready == "interactive"
          break if monotonic_time > deadline
          sleep 0.1
        end
      end

      def monotonic_time
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end
    end
  end
end
