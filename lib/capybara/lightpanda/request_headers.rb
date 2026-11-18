# frozen_string_literal: true

module Capybara
  module Lightpanda
    class RequestHeaders
      attr_reader :referrer

      def initialize(browser)
        @browser = browser
      end

      def get
        @browser.network.extra_headers.dup
      end

      def set(headers) # rubocop:disable Naming/PredicateMethod
        apply(headers)
        @referrer = nil
        true
      end

      # Ferrum applies a non-permanent Referer to Page.navigate calls only.
      def add(headers, permanent: true) # rubocop:disable Naming/PredicateMethod
        additions = headers.dup
        key = header_key(additions, "Referer") unless permanent
        referrer = additions.delete(key) if key
        merged = get.reject { |name, _| header_key(additions, name) }
        apply(merged.merge(additions))
        @referrer = referrer if key
        true
      end

      def clear
        set({})
      end

      def reset
        @navigator_defaults = nil
        @referrer = nil
      end

      private

      def header_key(headers, name)
        headers.keys.find { |key| key.to_s.casecmp?(name.to_s) }
      end

      def apply(headers)
        agent = headers[header_key(headers, "User-Agent")]
        language = headers[header_key(headers, "Accept-Language")]
        if Network.refused_user_agent?(agent)
          raise ArgumentError, 'Lightpanda refuses a User-Agent containing "Mozilla"'
        end

        if agent || language || @navigator_defaults
          @navigator_defaults ||= @browser.evaluate("[navigator.userAgent, navigator.language]")
          @browser.page_command("Emulation.setUserAgentOverride", userAgent: agent || @navigator_defaults.first,
                                                                  acceptLanguage: language || @navigator_defaults.last)
        end
        @browser.network.headers = headers.dup
      end
    end
  end
end
