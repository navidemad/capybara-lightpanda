# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Error < StandardError; end

    class ProcessTimeoutError < Error; end
    class BinaryNotFoundError < Error; end
    class BinaryError < Error; end
    class UnsupportedPlatformError < Error; end

    class TimeoutError < Error; end

    # Base class for any error originating from a CDP response or live browser
    # state. Lets callers `rescue BrowserError` to catch the whole CDP family
    # in one go (mirrors ferrum's hierarchy). Accepts either a CDP error hash
    # (`{"message" => ..., "code" => ...}`) or a plain string for callsites
    # that raise with a literal message.
    class BrowserError < Error
      attr_reader :response

      def initialize(response_or_message = nil)
        if response_or_message.is_a?(Hash)
          @response = response_or_message
          super(response_or_message["message"])
        else
          @response = nil
          super
        end
      end

      def code
        @response&.dig("code")
      end

      def data
        @response&.dig("data")
      end
    end

    class DeadBrowserError < BrowserError; end
    class NodeNotFoundError < BrowserError; end
    class NoExecutionContextError < BrowserError; end

    class JavaScriptError < BrowserError
      attr_reader :class_name, :stack_trace

      def initialize(response)
        @class_name = response.dig("exceptionDetails", "exception", "className")
        @stack_trace = response.dig("exceptionDetails", "stackTrace")
        message = response.dig("exceptionDetails", "exception", "description") ||
                  response.dig("exceptionDetails", "text")
        super(message)
      end
    end

    class ObsoleteNode < BrowserError
      attr_reader :node

      def initialize(node, message = nil)
        @node = node
        super(message || "Element is no longer attached to the DOM")
      end
    end

    class MouseEventFailed < BrowserError
      attr_reader :node, :selector, :position

      PATTERN = /at position \((\d+),\s*(\d+)\).*selector:\s*(.+)/i

      def initialize(node, message = nil)
        @node = node
        if message && (match = message.match(PATTERN))
          @position = { x: match[1].to_i, y: match[2].to_i }
          @selector = match[3]
        end
        super(message || "Failed mouse event")
      end
    end

    class InvalidSelector < Error
      attr_reader :method, :selector

      def initialize(message, method = nil, selector = nil)
        @method = method
        @selector = selector
        super(message)
      end
    end

    class NoSuchPageError < Error; end
    class StatusError < Error; end
  end
end
