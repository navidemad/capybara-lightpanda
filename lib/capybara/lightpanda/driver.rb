# frozen_string_literal: true

require "forwardable"
require "uri"

module Capybara
  module Lightpanda
    class Driver < ::Capybara::Driver::Base
      extend Forwardable

      attr_reader :app, :options

      delegate %i[current_url title] => :browser

      def initialize(app, options = {})
        super()
        @app = app
        @options = options
        @browser = nil
        @started = false
      end

      def browser
        @browser = nil if @browser && !browser_alive?
        @browser ||= Browser.new(@options)
      end

      def browser_alive?
        @browser.client && !@browser.client.closed?
      rescue StandardError
        false
      end

      def visit(url)
        @started = true
        browser.go_to(url)
      end

      def go_back
        browser.back
      end

      def go_forward
        browser.forward
      end

      def refresh
        browser.refresh
      end

      def html
        browser.body
      end
      alias body html

      def active_element
        oid = browser.active_element
        oid && Node.new(self, oid)
      end

      # Capybara's Session#send_keys routes to Driver#send_keys; Cuprite's pattern
      # is to fan that out to whatever element currently has focus.
      def send_keys(*keys)
        active_element&.send_keys(*keys)
      end

      def find_xpath(selector)
        object_ids = browser.find("xpath", selector)
        object_ids.map { |oid| Node.new(self, oid) }
      end

      def find_css(selector)
        object_ids = browser.find("css", selector)
        object_ids.map { |oid| Node.new(self, oid) }
      end

      def evaluate_script(script, *args)
        unwrap_script_result(browser.evaluate(script.strip, *native_args(args)))
      end

      def execute_script(script, *args)
        browser.execute(script.strip, *native_args(args))
        nil
      end

      def evaluate_async_script(script, *args)
        unwrap_script_result(browser.evaluate_async(script.strip, *native_args(args)))
      end

      # -- Network Inspection --

      # Network tracker (lazily auto-enabled). Exposes `traffic`, `clear`,
      # `wait_for_idle`, header overrides, etc. Cuprite parity.
      def network
        browser.network
      end

      # Block until in-flight HTTP traffic settles. Auto-enables the tracker
      # on first call so callers don't have to remember to flip it on.
      # Returns true on success, false on timeout.
      def wait_for_network_idle(timeout: 5, connections: 0)
        network.enable
        network.wait_for_idle(timeout: timeout, connections: connections)
      end

      # -- Cookie Management --

      def set_cookie(name, value, **options)
        cookie_options = { domain: options[:domain] || default_domain }
        cookie_options[:path] = options[:path] if options[:path]
        cookie_options[:secure] = options[:secure] if options.key?(:secure)
        if options.key?(:httpOnly) || options.key?(:http_only)
          cookie_options[:http_only] =
            options[:httpOnly] || options[:http_only]
        end
        cookie_options[:expires] = options[:expires] if options[:expires]

        browser.cookies.set(name: name, value: value, **cookie_options)
      end

      def clear_cookies
        browser.cookies.clear
      end

      def remove_cookie(name, **)
        browser.cookies.remove(name: name, **)
      end

      # -- Frame Support --
      # Passes Node objects (with remote_object_id) to Browser's frame stack.
      # callFunctionOn on the iframe element scopes finding to its contentDocument.

      def switch_to_frame(frame)
        case frame
        when :top
          browser.clear_frames
        when :parent
          browser.pop_frame
        when Node
          browser.push_frame(frame)
        else
          # Capybara passes a Capybara::Node::Element; extract our driver Node
          browser.push_frame(frame.base)
        end
      end

      # Capybara::Driver::Base falls back to running these via the top
      # execution context, which always reports the parent document. Resolve
      # them through the iframe element's contentWindow / contentDocument so
      # they reflect the active frame.
      def frame_url
        frame = browser.frame_stack.last
        return browser.current_url unless frame

        browser.call_function_on(frame.remote_object_id,
                                 "function() { return this.contentWindow.location.href }")
      end

      def frame_title
        frame = browser.frame_stack.last
        return browser.title unless frame

        browser.call_function_on(frame.remote_object_id,
                                 "function() { return this.contentDocument.title }")
      end

      # -- Modal/Dialog Support --

      def accept_modal(type, **options, &block)
        browser.accept_modal(type, text: options[:with])
        block&.call
        browser.find_modal(type,
                           text: options[:text],
                           wait: options.fetch(:wait, browser.options.timeout))
      end

      def dismiss_modal(type, **options, &block)
        browser.dismiss_modal(type)
        block&.call
        browser.find_modal(type,
                           text: options[:text],
                           wait: options.fetch(:wait, browser.options.timeout))
      end

      # -- Screenshots --
      # Lightpanda has no rendering engine so screenshots are blank,
      # but we handle the call gracefully so Rails' before_teardown
      # (screenshot on failure) doesn't raise NotSupportedByDriverError.

      def save_screenshot(path, **_options)
        browser.screenshot(path: path)
      rescue BinaryError, BinaryNotFoundError
        # Browser can't start (e.g., version too old) — don't crash teardown
        nil
      end

      # -- Lifecycle --

      def reset!
        browser.clear_frames
        browser.reset_modals
        browser.cookies.clear
        browser.network.clear
        browser.go_to("about:blank")
      rescue StandardError
        @browser&.quit
        @browser = nil
      end

      def quit
        @browser&.quit
        @browser = nil
      end

      def needs_server?
        true
      end

      def wait?
        true
      end

      # Expanded error list for Capybara retry logic (Cuprite pattern).
      def invalid_element_errors
        [
          NodeNotFoundError,
          NoExecutionContextError,
          ObsoleteNode,
          MouseEventFailed,
        ]
      end

      # Pause execution for interactive debugging.
      def pause
        if $stdin.tty?
          warn "\nPaused. Press Enter to continue."
          $stdin.gets
        else
          warn "\nPaused. Send SIGCONT (kill -CONT #{::Process.pid}) to continue."
          trap("CONT") {} # rubocop:disable Lint/EmptyBlock
          ::Process.kill("STOP", ::Process.pid)
        end
      end

      private

      # Unwrap arguments before sending to the browser. Capybara::Node::Element wraps
      # our Lightpanda::Node — pull `.base` out so `serialize_argument` can build
      # `{objectId: …}` for the CDP payload. Cuprite's `native_args` pattern.
      def native_args(args)
        args.map { |a| a.is_a?(Capybara::Node::Element) ? a.base : a }
      end

      # Lightpanda's `Network.setCookie` requires either `domain` or `url`
      # (storage.zig → Cookie.parseDomain). When the caller doesn't supply one,
      # use the host of the current page if any, else `Capybara.app_host`,
      # else loopback. Cuprite parity — lets pre-visit cookie setup just work.
      def default_domain
        candidate = (@started && safe_uri_host(browser.current_url)) ||
                    safe_uri_host(Capybara.app_host)
        candidate || "127.0.0.1"
      end

      def safe_uri_host(url)
        return nil if url.nil? || url.empty? || url == "about:blank"

        URI(url).host
      rescue URI::InvalidURIError
        nil
      end

      # Walk through evaluate-script results turning DOM-node markers (the
      # `{ "__lightpanda_node__" => "..." }` hashes produced by `Browser#unwrap_call_result`)
      # into Lightpanda::Node instances so Capybara can wrap them as elements.
      def unwrap_script_result(value)
        case value
        when Array then value.map { |v| unwrap_script_result(v) }
        when Hash
          if value.size == 1 && value.key?("__lightpanda_node__")
            Node.new(self, value["__lightpanda_node__"])
          else
            value.transform_values { |v| unwrap_script_result(v) }
          end
        else value
        end
      end
    end
  end
end
