# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Network
      attr_reader :browser

      def initialize(browser)
        @browser = browser
        @traffic = []
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
        @traffic.dup
      end

      def clear
        @traffic.clear
      end

      # Wipe local state without sending Network.disable. Called by
      # Browser#reset after Target.disposeBrowserContext, which destroys
      # the subscriptions and the Network domain along with the context —
      # leaving @enabled true would silently no-op the next #enable.
      # Also unsubscribes locally so we don't rely on the caller having
      # cleared the Subscriber first.
      def reset
        unsubscribe
        @traffic.clear
        @enabled = false
      end

      def headers=(headers)
        @extra_headers = headers
        browser.page_command("Network.setExtraHTTPHeaders", headers: headers)
      end

      def add_headers(headers)
        @extra_headers = (@extra_headers || {}).merge(headers)
        browser.page_command("Network.setExtraHTTPHeaders", headers: @extra_headers)
      end

      def clear_headers
        @extra_headers = {}
        browser.page_command("Network.setExtraHTTPHeaders", headers: {})
      end

      def wait_for_idle(timeout: 5, connections: 0) # rubocop:disable Naming/PredicateMethod
        started_at = Time.now

        while Time.now - started_at < timeout
          pending = @traffic.count { |t| t[:response].nil? }
          return true if pending <= connections

          sleep 0.1
        end

        false
      end

      private

      def subscribe
        @request_handler = lambda do |params|
          @traffic << {
            request_id: params["requestId"],
            url: params.dig("request", "url"),
            method: params.dig("request", "method"),
            timestamp: params["timestamp"],
            response: nil,
          }
        end

        @response_handler = lambda do |params|
          request = @traffic.find { |t| t[:request_id] == params["requestId"] }

          next unless request

          request[:response] = {
            status: params.dig("response", "status"),
            headers: params.dig("response", "headers"),
            mime_type: params.dig("response", "mimeType"),
          }
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
