# frozen_string_literal: true

require "json"
require "concurrent-ruby"

require_relative "client/web_socket"
require_relative "client/subscriber"

module Capybara
  module Lightpanda
    class Client
      attr_reader :ws_url, :options

      def initialize(ws_url, options)
        @ws_url = ws_url
        @options = options
        @ws = WebSocket.new(ws_url, options)
        @command_id = 0
        @pendings = Concurrent::Hash.new
        @subscriber = Subscriber.new
        @mutex = Mutex.new

        start_message_thread
      end

      def command(method, params = {}, async: false, session_id: nil, timeout: nil)
        message = build_message(method, params, session_id: session_id)

        if async
          @ws.send_message(JSON.generate(message))
          return true
        end

        pending = Concurrent::IVar.new
        @pendings[message[:id]] = pending

        @ws.send_message(JSON.generate(message))

        effective_timeout = timeout || @options.timeout
        response = pending.value!(effective_timeout)

        if response.nil?
          raise DeadBrowserError, "Browser closed during #{method}" if @ws.closed?

          raise TimeoutError, "Command #{method} timed out after #{effective_timeout}s"
        end

        handle_error(response) if response["error"]

        response["result"]
      ensure
        @pendings.delete(message[:id]) if message
      end

      def on(event, &)
        @subscriber.subscribe(event, &)
      end

      def off(event, block = nil)
        @subscriber.unsubscribe(event, block)
      end

      def close
        @ws&.close
        @message_thread&.join(1) || @message_thread&.kill
        @subscriber.clear
        @pendings.clear
      end

      def closed?
        @ws.closed?
      end

      private

      def build_message(method, params, session_id: nil)
        id = next_command_id
        message = { id: id, method: method, params: params }
        message[:sessionId] = session_id if session_id

        message
      end

      def next_command_id
        @mutex.synchronize { @command_id += 1 }
      end

      def start_message_thread
        @message_thread = Thread.new do
          Thread.current.abort_on_exception = true

          while (message = @ws.messages.pop)
            handle_message(message)
          end
        end
      end

      def handle_message(message)
        if message["id"]
          pending = @pendings[message["id"]]
          pending&.set(message)
        elsif message["method"]
          @subscriber.dispatch(message["method"], message["params"])
        end
      end

      def handle_error(response)
        error = response["error"]
        message = error["message"]

        case message
        when /No node with given id found/i
          raise NodeNotFoundError, message
        when /Cannot find context with specified id/i,
             /Execution context was destroyed/i,
             /Cannot find default execution context/i
          raise NoExecutionContextError, message
        else
          raise BrowserError, error
        end
      end
    end
  end
end
