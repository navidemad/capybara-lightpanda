# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Network
      attr_reader :browser

      def initialize(browser)
        @browser = browser
        @traffic = []
        @traffic_mutex = Mutex.new
        @enabled = false
        @request_handler = nil
        @response_handler = nil
      end

      def enable
        return if @enabled

        browser.command("Network.enable")
        subscribe
        @enabled = true
      end

      def disable
        return unless @enabled

        # Tell the browser to stop emitting BEFORE unsubscribing locally:
        # otherwise an in-flight Network.responseReceived can race past the
        # already-removed handler and leave a `response: nil` entry in
        # @traffic for the matching request — which then trips
        # wait_for_idle's pending count on a future call.
        browser.command("Network.disable")
        unsubscribe
        @enabled = false
      end

      def traffic
        @traffic_mutex.synchronize { @traffic.dup }
      end

      def clear
        @traffic_mutex.synchronize { @traffic.clear }
      end

      # Wipe local state without sending Network.disable. Called by
      # Browser#reset after Target.disposeBrowserContext, which destroys
      # the subscriptions and the Network domain along with the context —
      # leaving @enabled true would silently no-op the next #enable.
      # Also unsubscribes locally so we don't rely on the caller having
      # cleared the Subscriber first.
      def reset
        unsubscribe
        @traffic_mutex.synchronize { @traffic.clear }
        @enabled = false
      end

      # Setting extra headers also lazily enables the Network domain. Without
      # this, headers were silently ignored until the caller separately ran
      # `network.enable` (or `wait_for_network_idle`). Cuprite/Ferrum parity.
      def headers=(headers)
        enable
        @extra_headers = headers
        browser.page_command("Network.setExtraHTTPHeaders", headers: headers)
      end

      def add_headers(headers)
        enable
        @extra_headers = (@extra_headers || {}).merge(headers)
        browser.page_command("Network.setExtraHTTPHeaders", headers: @extra_headers)
      end

      def clear_headers
        enable
        @extra_headers = {}
        browser.page_command("Network.setExtraHTTPHeaders", headers: {})
      end

      # Count of in-flight requests (those with no response yet recorded).
      # Cheap predicate-friendly accessor (ferrum parity).
      def pending_connections
        @traffic_mutex.synchronize { @traffic.count { |t| t[:response].nil? } }
      end

      # True when no more than `connections` requests are in-flight.
      def idle?(connections = 0)
        pending_connections <= connections
      end

      def wait_for_idle(timeout: 5, connections: 0) # rubocop:disable Naming/PredicateMethod
        started_at = Time.now

        while Time.now - started_at < timeout
          return true if idle?(connections)

          sleep 0.1
        end

        false
      end

      # Raising variant of #wait_for_idle (ferrum parity). Returns true on
      # success, raises TimeoutError on timeout so callers that treat the
      # idle wait as a precondition don't have to remember to check a bool.
      def wait_for_idle!(timeout: 5, connections: 0)
        return true if wait_for_idle(timeout: timeout, connections: connections)

        raise TimeoutError, "Network did not become idle within #{timeout}s " \
                            "(pending=#{pending_connections}, allowed=#{connections})"
      end

      private

      def subscribe
        # CDP events arrive on the message thread while wait_for_idle /
        # pending_connections read from the main thread; serialize all
        # @traffic mutations and reads through @traffic_mutex.
        @request_handler = lambda do |params|
          entry = {
            request_id: params["requestId"],
            url: params.dig("request", "url"),
            method: params.dig("request", "method"),
            timestamp: params["timestamp"],
            response: nil,
          }
          @traffic_mutex.synchronize { @traffic << entry }
        end

        @response_handler = lambda do |params|
          @traffic_mutex.synchronize do
            request = @traffic.find { |t| t[:request_id] == params["requestId"] }
            next unless request

            request[:response] = {
              status: params.dig("response", "status"),
              headers: params.dig("response", "headers"),
              mime_type: params.dig("response", "mimeType"),
            }
          end
        end

        browser.on("Network.requestWillBeSent", &@request_handler)
        browser.on("Network.responseReceived", &@response_handler)
      end

      def unsubscribe
        browser.off("Network.requestWillBeSent", @request_handler) if @request_handler
        browser.off("Network.responseReceived", @response_handler) if @response_handler
        @request_handler = nil
        @response_handler = nil
      end
    end
  end
end
