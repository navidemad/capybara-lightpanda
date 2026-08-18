# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Network
      # Tracking is always on (create_page enables it), so the buffer needs
      # the same unbounded-growth cap as Browser's console ring buffer —
      # one very long session would otherwise grow @traffic indefinitely.
      TRAFFIC_LIMIT = 1_000

      attr_reader :browser

      # Status/headers of the last top-level document navigation; nil before
      # the first navigation completes. Backs Browser#status_code /
      # #response_headers. Captured by #subscribe's handlers.
      attr_reader :last_navigation_response

      def initialize(browser)
        @browser = browser
        @traffic = []
        @traffic_mutex = Mutex.new
        @enabled = false
        @request_handler = @response_handler = nil
        @last_navigation_response = nil
        @document_request_id = nil
      end

      # The domain toggle is connection-scoped (browser.command), while
      # setExtraHTTPHeaders is session-scoped (browser.page_command) — see
      # #headers=. Browser#create_page calls this, so tracking (traffic AND
      # the navigation-response capture) is on for every page.
      def enable
        return if @enabled

        # Subscribe BEFORE flipping the wire toggle (mirror image of
        # #disable's ordering): events can't be emitted while the domain is
        # off, so this order can never miss one. If the command fails
        # (Lightpanda can block commands mid-navigation), roll the handlers
        # back — orphaned duplicates would double-count every request and
        # wedge pending_connections above zero for the session.
        subscribe
        begin
          browser.command("Network.enable")
        rescue StandardError
          unsubscribe
          raise
        end
        @enabled = true
      end

      # Caveat: disabling the domain also stops the navigation-response
      # capture, so Browser#status_code / #response_headers freeze at their
      # last values until the next #enable.
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
        clear
        @enabled = false
        @extra_headers = nil # the fresh context never received setExtraHTTPHeaders
        @last_navigation_response = nil
        @document_request_id = nil
      end

      # Headers applied via headers= / add_headers. Backs Driver#headers.
      def extra_headers = @extra_headers || {}

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

      def wait_for_idle(timeout: 5, connections: 0)
        wait_for_idle!(timeout: timeout, connections: connections)
      rescue TimeoutError
        false
      end

      # Raising variant of #wait_for_idle (ferrum parity). Returns true on
      # success, raises TimeoutError on timeout so callers that treat the
      # idle wait as a precondition don't have to remember to check a bool.
      def wait_for_idle!(timeout: 5, connections: 0) # rubocop:disable Naming/PredicateMethod
        Utils::Wait.until(
          timeout: timeout,
          interval: 0.1,
          message: "Network did not become idle within #{timeout}s " \
                   "(pending=#{pending_connections}, allowed=#{connections})"
        ) { idle?(connections) }
        true
      end

      private

      # CDP events arrive on the message thread while wait_for_idle /
      # pending_connections read from the main thread; serialize all
      # @traffic mutations and reads through @traffic_mutex.
      #
      # The handlers also capture the last top-level navigation response
      # (mirrors capybara-playwright-driver's navigation_request? hook). CDP
      # normally marks the main-document response via
      # `Network.responseReceived.type`. Lightpanda only started emitting that
      # field on responses in build 8318 (#3037) — far above the gem's floor —
      # so match the long way instead: remember the document requestId, store
      # the response whose requestId equals it. Works on every supported build;
      # don't "simplify" it to read response.type until the floor clears 8318.
      def subscribe
        @request_handler = build_request_handler
        @response_handler = build_response_handler
        browser.on("Network.requestWillBeSent", &@request_handler)
        browser.on("Network.responseReceived", &@response_handler)
      end

      # Redirects follow Chrome's shape (Lightpanda since #3175, build ≥8602):
      # every followed hop re-emits requestWillBeSent with the SAME requestId
      # and the 3xx riding along as `redirectResponse`; the 3xx never gets a
      # responseReceived of its own. So the hop's event is what closes the
      # previous entry — without it that entry stays `response: nil` forever,
      # pending_connections wedges at ≥1 and every wait_for_idle burns its
      # full timeout after the first redirect (Ferrum's
      # subscribe_request_will_be_sent does the same close). Deliberately NOT
      # fed into @last_navigation_response: status_code must report the final
      # hop, and the redirected requestWillBeSent resets it below anyway.
      def build_request_handler
        lambda do |params|
          if params["type"] == "Document"
            @document_request_id = params["requestId"]
            @last_navigation_response = nil
          end
          entry = {
            request_id: params["requestId"],
            url: params.dig("request", "url"),
            method: params.dig("request", "method"),
            timestamp: params["timestamp"],
            response: nil,
          }
          @traffic_mutex.synchronize do
            if (redirect = params["redirectResponse"]) && (previous = last_open_entry(params["requestId"]))
              previous[:response] = response_summary(redirect)
            end
            @traffic << entry
            @traffic.shift(@traffic.size - TRAFFIC_LIMIT) if @traffic.size > TRAFFIC_LIMIT
          end
        end
      end

      def build_response_handler
        lambda do |params|
          if params["requestId"] == @document_request_id
            @last_navigation_response = {
              status: params.dig("response", "status"),
              headers: params.dig("response", "headers") || {},
            }
          end
          @traffic_mutex.synchronize do
            # Last open entry, not `find`: after a redirect chain several
            # entries share the requestId and only the newest is still open.
            request = last_open_entry(params["requestId"])
            next unless request

            request[:response] = response_summary(params["response"])
          end
        end
      end

      # Caller holds @traffic_mutex.
      def last_open_entry(request_id)
        @traffic.reverse_each.find { |t| t[:request_id] == request_id && t[:response].nil? }
      end

      def response_summary(response)
        response ||= {}
        {
          status: response["status"],
          headers: response["headers"],
          mime_type: response["mimeType"],
        }
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
