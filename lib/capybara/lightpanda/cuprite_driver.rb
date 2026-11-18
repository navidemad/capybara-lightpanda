# frozen_string_literal: true

module Capybara
  module Lightpanda
    # An application-owned registration lets a suite keep its driven_by name
    # while using real Cuprite for examples that require Chrome.
    def self.register_cuprite_driver(name, **settings)
      raise ArgumentError, "choose an application-owned driver name" if %i[cuprite lightpanda].include?(name.to_sym)

      CupriteDriver.validate_options!(settings)
      Capybara.register_driver(name) { |app| CupriteDriver.new(app, options.to_h.merge(settings)) }
    end

    class CupriteDriver < Driver
      def self.validate_options!(settings)
        if settings.key?(:url)
          raise ArgumentError, "url: is a Cuprite HTTP endpoint. Pass ws_url: with a Lightpanda WebSocket endpoint."
        end
        if settings[:ws_url] && !settings[:ws_url].to_s.match?(%r{\Awss?://[^/\s]+}i)
          raise ArgumentError, "ws_url: requires a Lightpanda ws:// or wss:// endpoint"
        end
        raise ArgumentError, "Lightpanda requires headless mode" if settings[:headless] == false

        unsupported = settings.keys - Options.new.to_h.keys - [:ws_url]
        return if unsupported.empty?

        raise ArgumentError, "Unsupported Lightpanda driver options: #{unsupported.map(&:inspect).join(', ')}"
      end
    end
  end
end
