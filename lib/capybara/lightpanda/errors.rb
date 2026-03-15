# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Error < StandardError; end

    class ProcessTimeoutError < Error; end
    class BinaryNotFoundError < Error; end
    class BinaryError < Error; end
    class UnsupportedPlatformError < Error; end

    class DeadBrowserError < Error; end
    class TimeoutError < Error; end

    class BrowserError < Error
      attr_reader :response

      def initialize(response)
        @response = response
        super(response["message"])
      end
    end

    class JavaScriptError < Error
      attr_reader :class_name, :message

      def initialize(response)
        @class_name = response.dig("exceptionDetails", "exception", "className")
        @message = response.dig("exceptionDetails", "exception",
                                "description") || response.dig("exceptionDetails", "text")

        super(@message)
      end
    end

    class NodeNotFoundError < Error; end
    class NoExecutionContextError < Error; end

    class ObsoleteNode < Error
      attr_reader :node

      def initialize(node, message = nil)
        @node = node
        super(message || "Element is no longer attached to the DOM")
      end
    end

    class MouseEventFailed < Error
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
