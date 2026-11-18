# frozen_string_literal: true

module Capybara
  module Lightpanda
    class CupriteCookies < Cookies
      def initialize(browser, &default_domain)
        super(browser)
        @default_domain = default_domain
      end

      # Enumeration still includes cookies with the same name at different paths.
      def all
        to_h { |cookie| [cookie.name, cookie] }
      end

      COOKIE_KEYS = { httponly: :http_only, httpOnly: :http_only, samesite: :same_site, sameSite: :same_site }.freeze
      private_constant :COOKIE_KEYS

      def set(options)
        return restore_cookie(options.to_h) if options.is_a?(Cookie)

        attributes = options.transform_keys { |key| COOKIE_KEYS.fetch(key.to_sym, key.to_sym) }
        attributes[:domain] ||= @default_domain.call unless attributes[:url]
        super(**attributes)
      end

      def remove(name:, domain: nil, url: nil, path: nil) # rubocop:disable Naming/PredicateMethod
        domain ||= @default_domain.call unless url
        super
        true
      end
    end
  end
end
