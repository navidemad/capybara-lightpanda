# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Client
      class Subscriber
        # Default error sink: write a one-line warning so a misbehaving handler
        # is visible without crashing the CDP message thread. Tests can inject
        # a custom proc via `on_error:` to capture failures.
        DEFAULT_ON_ERROR = lambda do |event, error|
          warn("[capybara-lightpanda] subscriber callback for #{event.inspect} raised " \
               "#{error.class}: #{error.message}")
        end

        def initialize(on_error: DEFAULT_ON_ERROR)
          @subscriptions = Hash.new { |h, k| h[k] = [] }
          @mutex = Mutex.new
          @on_error = on_error
        end

        def subscribe(event, &block)
          @mutex.synchronize do
            @subscriptions[event] << block
          end
        end

        def unsubscribe(event, block = nil)
          @mutex.synchronize do
            if block
              @subscriptions[event].delete(block)
            else
              @subscriptions.delete(event)
            end
          end
        end

        # Run every callback registered for `event`. Exceptions in one
        # callback must not stop the others or propagate out — the message
        # thread sets `abort_on_exception = true`, so an unhandled raise
        # would tear down the entire CDP connection.
        #
        # Two layers of rescue:
        #   1. The callback itself may raise — route to @on_error.
        #   2. @on_error itself may raise (custom hook, broken stderr) —
        #      swallow at the last level so the dispatch loop survives.
        def dispatch(event, params)
          callbacks = @mutex.synchronize { @subscriptions[event].dup }

          callbacks.each do |callback|
            callback.call(params)
          rescue StandardError => e
            begin
              @on_error.call(event, e)
            rescue StandardError
              # The error sink failed — nothing to do but keep going. We
              # cannot log here without re-entering the broken path.
            end
          end
        end

        def subscribed?(event)
          @mutex.synchronize { @subscriptions.key?(event) && @subscriptions[event].any? }
        end

        def clear
          @mutex.synchronize { @subscriptions.clear }
        end
      end
    end
  end
end
