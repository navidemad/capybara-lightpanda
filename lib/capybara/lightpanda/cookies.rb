# frozen_string_literal: true

require "yaml"

module Capybara
  module Lightpanda
    class Cookies
      include Enumerable

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
        result = browser.command("Network.getAllCookies")
        (result["cookies"] || []).map { |c| Cookie.new(c) }
      end

      # Yields each Cookie. Powers `Enumerable` (so callers can do
      # `cookies.find { … }`, `cookies.select { … }`, `cookies.to_a`, …
      # without going through `all` first).
      def each(&block)
        return enum_for(:each) unless block

        all.each(&block)
      end

      def get(name)
        find { |cookie| cookie.name == name }
      end
      # Ferrum/Cuprite spelling: `browser.cookies["session_id"]`.
      alias [] get

      # Returns whether the browser accepted the cookie (ferrum parity).
      # Lightpanda answers `{success: false}` and drops the cookie for an
      # invalid combination — notably `same_site: "None"` without `secure`
      # since upstream #3529 (build 9877), Chrome's rule — so callers that
      # need it to stick should check the result. A malformed field (a `;` or
      # control character in the name or value, surrounding whitespace) raises
      # BrowserError instead: since upstream #3791 (build 10212) the browser
      # answers `-32602 Sanitizing cookie failed`, as Chrome does.
      def set(name:, value:, domain: nil, path: "/", secure: false, http_only: false, # rubocop:disable Metrics/ParameterLists, Naming/PredicateMethod
              same_site: nil, expires: nil)
        params = {
          name: name,
          value: value,
          path: path,
          secure: secure,
          httpOnly: http_only,
        }

        params[:domain] = domain if domain
        # CDP rejects unknown SameSite values; pass through only the canonical
        # spec strings ("Strict" / "Lax" / "None") so YAML noise from a hand-
        # edited file doesn't reach the browser.
        params[:sameSite] = same_site if %w[Strict Lax None].include?(same_site)
        params[:expires] = expires.to_i if expires

        result = browser.command("Network.setCookie", **params)
        !(result.is_a?(Hash) && result["success"] == false)
      end

      def remove(name:, domain: nil, path: "/")
        params = { name: name, path: path }
        params[:domain] = domain if domain

        browser.command("Network.deleteCookies", **params)
      end

      def clear
        browser.command("Network.clearBrowserCookies")
      end

      # Persist all current cookies to a YAML file (ferrum parity).
      # Returns the number of bytes written.
      def store(path = "cookies.yml")
        File.write(path, all.map(&:to_h).to_yaml)
      end

      # Load cookies from a YAML file produced by `store` and re-set them.
      # CDP requires either domain or url for each cookie; entries from `store`
      # already include domain, so they round-trip cleanly. Returns true on
      # success (intentionally not a predicate — mirrors ferrum's API). A
      # cookie the browser refuses — `{success: false}`, or a malformed field
      # it rejects outright — is reported on stderr rather than raised, so one
      # bad entry doesn't abort restoring the rest. Builds before 10212 stored
      # malformed cookies, so files saved from them can hold such entries.
      def load(path = "cookies.yml") # rubocop:disable Naming/PredicateMethod
        cookies = YAML.load_file(path)
        rejected = cookies.reject { |c| restore_cookie(c) }.map { |c| c.transform_keys(&:to_s)["name"] }
        warn "Capybara::Lightpanda: the browser refused cookies from #{path}: #{rejected.join(', ')}" if rejected.any?
        true
      end

      private

      # set() takes keyword args, but YAML round-trips give us a hash with the
      # raw CDP keys (camelCase). Normalize and forward.
      def restore_cookie(hash) # rubocop:disable Metrics/PerceivedComplexity
        attrs = hash.transform_keys(&:to_s)
        params = {
          name: attrs["name"],
          value: attrs["value"],
          path: attrs["path"] || "/",
          secure: attrs["secure"] || false,
          http_only: attrs["httpOnly"] || false,
        }
        params[:domain] = attrs["domain"] if attrs["domain"]
        same_site = restored_same_site(attrs)
        params[:same_site] = same_site if same_site
        exp = attrs["expires"]
        params[:expires] = Time.at(exp) if exp.is_a?(Numeric) && exp.positive?
        set_or_refuse(**params)
      end

      def set_or_refuse(**params)
        set(**params)
      rescue BrowserError => e
        raise unless e.code == INVALID_PARAMS

        false
      end

      # Chrome's (and, since upstream #3791, Lightpanda's) answer to a cookie
      # whose fields fail sanitizing.
      INVALID_PARAMS = -32_602
      private_constant :INVALID_PARAMS

      # Lightpanda below build 9877 reported every cookie without a SameSite
      # attribute as "None", so a file stored then is full of insecure
      # SameSite=None cookies — which the browser now rejects (Chrome's rule,
      # upstream #3529). Leaving SameSite unset restores what the cookie
      # actually was: unspecified, i.e. Lax-by-default.
      def restored_same_site(attrs)
        same_site = attrs["sameSite"]
        return nil if same_site == "None" && !attrs["secure"]

        same_site
      end
    end
  end
end
