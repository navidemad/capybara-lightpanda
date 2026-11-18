# frozen_string_literal: true

require_relative "network/exchange"

module Capybara
  module Lightpanda
    class Network
      # Tracking is always on (create_page enables it), so the buffer needs
      # the same unbounded-growth cap as Browser's console ring buffer —
      # one very long session would otherwise grow @traffic indefinitely.
      TRAFFIC_LIMIT = 1_000

      attr_reader :browser

      # Status/headers of the last main-frame document navigation; nil before
      # the first navigation completes. Backs Browser#status_code /
      # #response_headers. Captured by #subscribe's handlers.
      attr_reader :last_navigation_response
      alias response last_navigation_response

      def status = response&.status

      def initialize(browser)
        @browser = browser
        @traffic = []
        @pending = {}
        @traffic_mutex = Mutex.new
        @enabled = false
        @request_handler = @response_handler = @failure_handler = nil
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
        # Completion events for these requests may arrive while observation is off.
        @traffic_mutex.synchronize { @pending.clear }
        @enabled = false
      end

      def traffic
        @traffic_mutex.synchronize { @traffic.dup }
      end

      def clear(type = nil)
        case type
        when nil, :traffic
          # Forget observations while continuing to track active network I/O.
          @traffic_mutex.synchronize { @traffic.clear }
          return [] if type.nil?
        when :cache
          browser.command("Network.clearBrowserCache")
        else
          raise ArgumentError, "expected :traffic or :cache, got #{type.inspect}"
        end
        true
      end

      # Wipe local state without sending Network.disable. Called by
      # Browser#reset after Target.disposeBrowserContext, which destroys
      # the subscriptions and the Network domain along with the context —
      # leaving @enabled true would silently no-op the next #enable.
      # Also unsubscribes locally so we don't rely on the caller having
      # cleared the Subscriber first.
      def reset
        unsubscribe
        @traffic_mutex.synchronize do
          @traffic.clear
          @pending.clear
        end
        @enabled = false
        @extra_headers = nil # the fresh context never received setExtraHTTPHeaders
        @last_navigation_response = nil
        @document_request_id = nil
      end

      # Headers applied via headers= / add_headers. Backs Driver#headers.
      def extra_headers = @extra_headers || {}

      # Setting extra headers also lazily enables the Network domain. Without
      # this, headers were silently ignored until the caller separately ran
      # `network.enable` (or `wait_for_network_idle`).
      def headers=(headers)
        enable
        warn_on_refused_user_agent(headers)
        apply_extra_headers(headers)
      end

      def add_headers(headers)
        enable
        warn_on_refused_user_agent(headers)
        apply_extra_headers(extra_headers.merge(headers))
      end

      def clear_headers
        enable
        apply_extra_headers({})
      end

      # Lightpanda refuses a user agent containing "Mozilla" by design, and
      # answers {} either way.
      def self.refused_user_agent?(value)
        value.to_s.match?(/mozilla/i)
      end

      # Sets the User-Agent request header AND navigator.userAgent, which a
      # User-Agent in headers= does not touch. The override ends with the
      # BrowserContext, so reset! restores "Lightpanda/1.0". Raises on a value
      # the browser would silently drop, rather than let a spec run on the
      # default user agent.
      def user_agent=(value)
        if Network.refused_user_agent?(value)
          raise ArgumentError,
                "Lightpanda refuses a user agent containing \"Mozilla\" (got #{value.inspect}). Keep the device " \
                "tokens and drop the prefix, e.g. \"Lightpanda/1.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Mobile\"."
        end

        browser.page_command("Emulation.setUserAgentOverride", userAgent: value.to_s)
      end

      # Count through body completion, including requests evicted from the traffic history.
      # Cheap predicate-friendly accessor (ferrum parity).
      def pending_connections
        @traffic_mutex.synchronize { @pending.size }
      end

      # True when no more than `connections` requests are in-flight.
      def idle?(connections = 0)
        pending_connections <= connections
      end

      def wait_for_idle(timeout: 5, connections: 0, duration: 0.1)
        wait_for_idle!(timeout: timeout, connections: connections, duration: duration)
      rescue TimeoutError
        false
      end

      # Raising variant of #wait_for_idle (ferrum parity). Returns true on
      # success, raises TimeoutError on timeout so callers that treat the
      # idle wait as a precondition don't have to remember to check a bool.
      def wait_for_idle!(timeout: 5, connections: 0, duration: 0.1) # rubocop:disable Naming/PredicateMethod
        Utils::Wait.until(
          timeout: timeout,
          interval: duration,
          message: "Network did not become idle within #{timeout}s " \
                   "(pending=#{pending_connections}, allowed=#{connections})"
        ) { idle?(connections) }
        true
      end

      private

      def apply_extra_headers(headers)
        browser.page_command("Network.setExtraHTTPHeaders", headers: headers).tap { @extra_headers = headers.dup }
      end

      def warn_on_refused_user_agent(headers)
        value = headers.find { |name, _| name.to_s.casecmp?("user-agent") }&.last
        return unless Network.refused_user_agent?(value)

        warn "[capybara-lightpanda] Lightpanda ignores a User-Agent containing \"Mozilla\" (#{value.inspect}): " \
             "requests keep the default user agent. Drop the \"Mozilla/5.0\" prefix, or use page.driver.user_agent=."
      end

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
        @failure_handler = build_failure_handler
        @finished_handler = ->(params) { @traffic_mutex.synchronize { finish_request(params["requestId"]) } }
        browser.on("Network.requestWillBeSent", &@request_handler)
        browser.on("Network.responseReceived", &@response_handler)
        browser.on("Network.loadingFinished", &@finished_handler)
        browser.on("Network.loadingFailed", &@failure_handler)
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
          if main_frame_document?(params)
            @document_request_id = params["requestId"]
            @last_navigation_response = nil
          end
          entry = Exchange.new(params)
          id = entry[:request_id]
          @traffic_mutex.synchronize do
            previous = finish_request(id)
            previous[:response] = Response.new(params["redirectResponse"]) if previous && params["redirectResponse"]
            @pending[id] = entry
            @traffic << entry
            @traffic.shift(@traffic.size - TRAFFIC_LIMIT) if @traffic.size > TRAFFIC_LIMIT
          end
        end
      end

      def build_response_handler
        lambda do |params|
          summary = Response.new(params["response"])
          @last_navigation_response = summary if params["requestId"] == @document_request_id
          @traffic_mutex.synchronize do
            request = @pending[params["requestId"]]
            request[:response] = summary if request
          end
        end
      end

      # A request that never gets a response — refused connection, CORS
      # block, abort — ends with Network.loadingFailed instead. Without this
      # handler its entry stayed open forever, so pending_connections never
      # reached zero and every wait_for_idle burned its full timeout. Routine
      # since Lightpanda enforces CORS by default (upstream #3654, build 9883:
      # a blocked fetch reports errorText "CorsBlocked"). Ferrum closes its
      # exchange on the same event.
      def build_failure_handler
        lambda do |params|
          @traffic_mutex.synchronize do
            request = finish_request(params["requestId"])
            next unless request

            request[:error] = params["errorText"].to_s
          end
        end
      end

      # Iframes load by default (Browser#configure_loading) and their document
      # requests are typed "Document" too; counting them made the last iframe's
      # response the page's status_code. The main frame shares the target's id,
      # the same test Browser#main_frame_document_request? applies.
      def main_frame_document?(params)
        params["type"] == "Document" && params["frameId"] == browser.target_id
      end

      # Caller holds @traffic_mutex.
      def finish_request(id)
        entry = @pending.delete(id)
        entry&.finish!
        entry
      end

      def unsubscribe
        browser.off("Network.requestWillBeSent", @request_handler) if @request_handler
        browser.off("Network.responseReceived", @response_handler) if @response_handler
        browser.off("Network.loadingFinished", @finished_handler) if @finished_handler
        browser.off("Network.loadingFailed", @failure_handler) if @failure_handler
        @request_handler = nil
        @response_handler = nil
        @failure_handler = nil
        @finished_handler = nil
      end
    end
  end
end
