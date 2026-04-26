# frozen_string_literal: true

require "yaml"

module Capybara
  module Lightpanda
    class Cookies
      # Typed wrapper around a CDP cookie hash so callers don't have to remember
      # the camelCase keys (`httpOnly`, `sameSite`, …) the CDP returns. Mirrors
      # ferrum's Cookies::Cookie. `attributes` exposes the raw hash for callers
      # that still need it (e.g. YAML serialization in store/load).
      class Cookie
        attr_reader :attributes

        def initialize(attributes)
          @attributes = attributes
        end

        def name      = attributes["name"]
        def value     = attributes["value"]
        def domain    = attributes["domain"]
        def path      = attributes["path"]
        def samesite  = attributes["sameSite"]
        def size      = attributes["size"]
        def secure?   = attributes["secure"]
        def httponly? = attributes["httpOnly"]
        def session?  = attributes["session"]

        alias same_site samesite
        alias http_only? httponly?

        # Time when the cookie expires, or nil for session cookies (CDP reports
        # session cookies with `expires: -1`).
        def expires
          exp = attributes["expires"]
          Time.at(exp) if exp.is_a?(Numeric) && exp.positive?
        end

        def ==(other)
          other.is_a?(self.class) && other.attributes == attributes
        end

        alias eql? ==

        def hash
          attributes.hash
        end

        def to_h
          attributes
        end
      end

      attr_reader :browser

      def initialize(browser)
        @browser = browser
      end

      def all
        result = browser.command("Network.getCookies")
        (result["cookies"] || []).map { |c| Cookie.new(c) }
      end

      def get(name)
        all.find { |cookie| cookie.name == name }
      end

      def set(name:, value:, domain: nil, path: "/", secure: false, http_only: false, expires: nil)
        params = {
          name: name,
          value: value,
          path: path,
          secure: secure,
          httpOnly: http_only,
        }

        params[:domain] = domain if domain
        params[:expires] = expires.to_i if expires

        browser.command("Network.setCookie", **params)
      end

      def remove(name:, domain: nil, path: "/")
        params = { name: name, path: path }
        params[:domain] = domain if domain

        browser.command("Network.deleteCookies", **params)
      end

      # Lightpanda gotchas observed on current nightly:
      #   * `Network.clearBrowserCookies` raises `InvalidParams` (so it does NOT
      #     clear anything despite the upstream PR #1821 / >= v0.2.6 note).
      #   * `Network.getCookies` (no `urls` param) is scoped to the CURRENT
      #     page's origin — cookies set on previously-visited domains are
      #     invisible from a different page.
      #   * `Network.getCookies` on `about:blank` raises `InvalidDomain`.
      #
      # To honor Capybara's `reset_session! removes ALL cookies` contract
      # across multiple test domains (e.g. `localhost` AND `127.0.0.1`), we
      # iterate every origin Browser has navigated to and per-origin call
      # `Network.getCookies(urls: [origin])` then `Network.deleteCookies(url:)`.
      # The bulk-clear call is still attempted first as a fast path / future-
      # proofing for when upstream fixes it.
      def clear
        begin
          browser.command("Network.clearBrowserCookies")
        rescue BrowserError, TimeoutError, StandardError
          # InvalidParams on current nightly; pre-v0.2.6 used to crash the
          # WebSocket. Either way, fall through to per-origin sweep.
        end

        sweep_visited_origins
      end

      # Persist all current cookies to a YAML file (ferrum parity).
      # Returns the number of bytes written.
      def store(path = "cookies.yml")
        File.write(path, all.map(&:to_h).to_yaml)
      end

      # Load cookies from a YAML file produced by `store` and re-set them.
      # CDP requires either domain or url for each cookie; entries from `store`
      # already include domain, so they round-trip cleanly. Returns true on
      # success (intentionally not a predicate — mirrors ferrum's API).
      def load(path = "cookies.yml") # rubocop:disable Naming/PredicateMethod
        cookies = YAML.load_file(path)
        cookies.each { |c| restore_cookie(c) }
        true
      end

      private

      def sweep_visited_origins
        origins = browser.visited_origins.to_a
        return if origins.empty?

        result = browser.command("Network.getCookies", urls: origins)
        cookies = result["cookies"] || []
        cookies.each do |cookie|
          # CDP needs either domain or url; build a url from the cookie's
          # own domain+path so we don't mismatch (e.g. cookie domain `.x.test`
          # against an origin we tracked as `https://x.test:443`).
          url = cookie_url(cookie)
          params = { name: cookie["name"] }
          params[:url] = url if url
          params[:domain] = cookie["domain"] unless url
          browser.command("Network.deleteCookies", **params)
        end
      rescue StandardError
        # Connection lost or origin no longer valid; nothing more to do.
      end

      def cookie_url(cookie)
        domain = cookie["domain"].to_s.sub(/\A\./, "")
        return nil if domain.empty?

        scheme = cookie["secure"] ? "https" : "http"
        path = cookie["path"] || "/"
        "#{scheme}://#{domain}#{path}"
      end

      # set() takes keyword args, but YAML round-trips give us a hash with the
      # raw CDP keys (camelCase). Normalize and forward.
      def restore_cookie(hash)
        attrs = hash.transform_keys(&:to_s)
        params = {
          name: attrs["name"],
          value: attrs["value"],
          path: attrs["path"] || "/",
          secure: attrs["secure"] || false,
          http_only: attrs["httpOnly"] || false,
        }
        params[:domain] = attrs["domain"] if attrs["domain"]
        exp = attrs["expires"]
        params[:expires] = Time.at(exp) if exp.is_a?(Numeric) && exp.positive?
        set(**params)
      end
    end
  end
end
