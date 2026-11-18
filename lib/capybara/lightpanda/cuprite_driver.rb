# frozen_string_literal: true

require_relative "cuprite_cookies"

module Capybara
  module Lightpanda
    # An application-owned registration lets a suite keep its driven_by name
    # while using real Cuprite for examples that require Chrome.
    def self.register_cuprite_driver(name, **settings)
      raise ArgumentError, "choose an application-owned driver name" if %i[cuprite lightpanda].include?(name.to_sym)

      # No custom Chrome flags and no error on a pending navigation are
      # already Lightpanda's behavior. Other values need a different driver.
      settings.delete(:browser_options) if settings[:browser_options] == {}
      settings.delete(:pending_connection_errors) if settings[:pending_connection_errors] == false
      settings.delete(:slowmo) if [nil, 0].include?(settings[:slowmo])
      settings.delete(:inspector) if [nil, false].include?(settings[:inspector])
      CupriteDriver.validate_options!(settings)
      Capybara.register_driver(name) { |app| CupriteDriver.new(app, options.to_h.merge(settings)) }
    end

    class CupriteDriver < Driver
      def visit(url)
        @started = true
        browser.go_to(url) do |result|
          error = result&.fetch("errorText", nil)
          next if error.to_s.empty? || error == "net::ERR_ABORTED"

          message = "Request to #{url} failed (#{error})"
          raise ::Ferrum::StatusError.new(url, message) if defined?(::Ferrum::StatusError)

          raise StatusError, message
        end
      end

      def wait_for_reload(timeout = 1)
        browser.wait_for_reload(timeout)
      end

      def network_traffic(type = nil)
        if type.to_s == "blocked"
          raise Capybara::NotSupportedByDriverError, "Lightpanda does not track Cuprite request interception"
        end

        network.traffic
      end

      def clear_network_traffic
        network.clear(:traffic)
      end

      def clear_memory_cache
        network.clear(:cache)
      end

      def cookies
        browser.cookies.all
      end

      def set_cookie(name, value, options = {})
        browser.cookies.set(options.merge(name: name, value: value))
      end

      def self.validate_options!(settings)
        if settings.key?(:url)
          raise ArgumentError, "url: is a Cuprite HTTP endpoint. Pass ws_url: with a Lightpanda WebSocket endpoint."
        end

        Client::WebSocket.endpoint_uri(settings[:ws_url]) if settings.key?(:ws_url)
        raise ArgumentError, "Lightpanda requires headless mode" if settings[:headless] == false

        unsupported = settings.keys - Options.new.to_h.keys - %i[ws_url base_url]
        return if unsupported.empty?

        raise ArgumentError, "Unsupported Lightpanda driver options: #{unsupported.map(&:inspect).join(', ')}"
      end

      private

      def build_browser
        Browser.new(options) do |instance|
          CupriteCookies.new(instance) do
            safe_uri_host(instance.current_url) || safe_uri_host(options[:base_url]) ||
              safe_uri_host(session_options.app_host) || session&.server&.host || "127.0.0.1"
          end
        end
      end
    end
  end
end
