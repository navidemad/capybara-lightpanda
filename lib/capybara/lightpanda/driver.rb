# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Driver < ::Capybara::Driver::Base
      attr_reader :app, :options

      def initialize(app, options = {})
        super()
        @app = app
        @options = options
        @browser = nil
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
        browser.go_to(url)
        inject_xpath_polyfill
      end

      def current_url
        browser.current_url
      end

      def html
        browser.body
      end
      alias body html

      def title
        browser.title
      end

      def find_xpath(selector)
        nodes = browser.evaluate(<<~JS)
          (function() {
            var result = document.evaluate(
              #{selector.inspect},
              document,
              null,
              XPathResult.ORDERED_NODE_SNAPSHOT_TYPE,
              null
            );
            var nodes = [];
            for (var i = 0; i < result.snapshotLength; i++) {
              nodes.push(result.snapshotItem(i));
            }
            return nodes;
          })()
        JS

        wrap_nodes(nodes || [])
      end

      def find_css(selector)
        count = browser.evaluate("document.querySelectorAll(#{selector.inspect}).length")
        return [] if count.nil? || count.zero?

        (0...count).map do |index|
          Node.new(self, { selector: selector, index: index }, index)
        end
      end

      def evaluate_script(script, *_args)
        browser.evaluate(script)
      end

      def execute_script(script, *_args)
        browser.execute(script)
        nil
      end

      def set_cookie(name, value, **options)
        cookie_options = {}
        cookie_options[:domain] = options[:domain] if options[:domain]
        cookie_options[:path] = options[:path] if options[:path]
        cookie_options[:secure] = options[:secure] if options.key?(:secure)
        cookie_options[:http_only] = options[:httpOnly] || options[:http_only] if options.key?(:httpOnly) || options.key?(:http_only)
        cookie_options[:expires] = options[:expires] if options[:expires]

        browser.cookies.set(name: name, value: value, **cookie_options)
      end

      def clear_cookies
        browser.cookies.clear
      end

      def remove_cookie(name, **options)
        browser.cookies.remove(name: name, **options)
      end

      def reset!
        browser.go_to("about:blank")
      rescue StandardError
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

      def invalid_element_errors
        [NodeNotFoundError, NoExecutionContextError]
      end

      private

      def inject_xpath_polyfill
        browser.execute(XPathPolyfill::JS)
      rescue StandardError
        # Ignore if page isn't ready yet
      end

      def wrap_nodes(nodes)
        return [] unless nodes.is_a?(Array)

        nodes.map.with_index do |node_data, index|
          Node.new(self, node_data, index)
        end
      end
    end
  end
end
