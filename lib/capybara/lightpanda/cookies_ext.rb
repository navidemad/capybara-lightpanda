# frozen_string_literal: true

module Capybara
  module Lightpanda
    # Patches to Lightpanda::Cookies#clear to handle the CDP connection crash.
    #
    # Lightpanda responds to Network.clearBrowserCookies with InvalidParams
    # AND kills the WebSocket connection (Connection reset by peer).
    # This module falls back to deleting cookies individually.
    module CookiesExt
      def clear
        super
      rescue ::Lightpanda::BrowserError
        begin
          all.each { |cookie| remove(name: cookie["name"], domain: cookie["domain"]) }
        rescue StandardError
          # Connection already dead — silently ignore
        end
      end
    end
  end
end
