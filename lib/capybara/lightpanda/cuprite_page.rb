# frozen_string_literal: true

module Capybara
  module Lightpanda
    # Ferrum's page.command sends CDP commands to the attached page session.
    class CupritePage
      def initialize(browser)
        @browser = browser
      end

      def command(method, **params)
        return @browser.page_command(method, **params) unless method.to_s == "Emulation.setTimezoneOverride"

        if @browser.options.ws_url?
          raise ::Capybara::NotSupportedByDriverError, "Runtime timezones require a dedicated Lightpanda process"
        end

        result = @browser.page_command(method, **params)
        zone = params.fetch(:timezoneId) { params["timezoneId"] }
        # Older engines acknowledge this command without changing ICU's zone.
        # An empty ID restores the process default on engines that support it.
        unless zone.is_a?(String) && (zone.empty? || @browser.evaluate(ZONE_MATCHES, zone))
          raise ::Capybara::NotSupportedByDriverError,
                "Lightpanda did not apply timezone #{zone.inspect}. " \
                "Set timezone: at launch or use a browser with runtime timezone support."
        end
        result
      end

      ZONE_MATCHES = <<~JS
        Intl.DateTimeFormat().resolvedOptions().timeZone ===
          Intl.DateTimeFormat("en", {timeZone: arguments[0]}).resolvedOptions().timeZone
      JS
      private_constant :ZONE_MATCHES
    end
  end
end
