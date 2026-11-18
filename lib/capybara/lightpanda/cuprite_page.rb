# frozen_string_literal: true

require "json"

module Capybara
  module Lightpanda
    # Ferrum page handles address one target for their entire lifetime.
    class CupritePage
      def initialize(browser)
        @client = browser.client
        @session_id = browser.session_id
        @remote = browser.options.ws_url?
      end

      def command(method, **params)
        if params.keys.any? { |key| %w[wait timeout slowmoable].include?(key.to_s) }
          raise ::Capybara::NotSupportedByDriverError, "Ferrum transport options are unsupported on page.command"
        end
        return send_command(method, params) unless method.to_s == "Emulation.setTimezoneOverride"

        if @remote
          raise ::Capybara::NotSupportedByDriverError, "Runtime timezones require a dedicated Lightpanda process"
        end

        set_timezone(method, params)
      end

      private

      def send_command(method, params)
        @client.command(method, params, session_id: @session_id)
      end

      def set_timezone(method, params)
        zone = params.fetch(:timezoneId) { params["timezoneId"] }
        raise ArgumentError, "timezoneId must be a string" unless zone.is_a?(String)

        result = send_command(method, params)
        # Older engines acknowledge this command without changing ICU's zone.
        # An empty ID restores the process default on engines that support it.
        return result if zone.empty? || timezone_matches?(zone)

        raise ::Capybara::NotSupportedByDriverError,
              "Lightpanda did not apply timezone #{zone.inspect}. " \
              "Set timezone: at launch or use a browser with runtime timezone support."
      end

      def timezone_matches?(zone)
        expression = <<~JS
          (() => {
            const actual = Intl.DateTimeFormat().resolvedOptions().timeZone;
            const requested = Intl.DateTimeFormat("en", {timeZone: #{JSON.generate(zone)}}).resolvedOptions().timeZone;
            // V8 can report an ICU GMT override as a fixed zero offset.
            const normalize = name => name === "+00:00" ? "UTC" : name;
            return normalize(actual) === normalize(requested);
          })()
        JS
        send_command("Runtime.evaluate", { expression: expression, returnByValue: true }).dig("result", "value") == true
      end
    end
  end
end
