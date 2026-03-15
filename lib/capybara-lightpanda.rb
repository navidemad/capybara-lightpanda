# frozen_string_literal: true

require "capybara"
require "lightpanda"

require_relative "capybara/lightpanda/version"
require_relative "capybara/lightpanda/xpath_polyfill"
require_relative "capybara/lightpanda/browser_ext"
require_relative "capybara/lightpanda/cookies_ext"
require_relative "capybara/lightpanda/node"
require_relative "capybara/lightpanda/driver"

# Apply patches to the lightpanda gem
Lightpanda::Browser.prepend(Capybara::Lightpanda::BrowserExt)
Lightpanda::Cookies.prepend(Capybara::Lightpanda::CookiesExt)

module Capybara
  module Lightpanda
    class << self
      def configure
        yield(configuration) if block_given?
      end

      def configuration
        @configuration ||= Configuration.new
      end
    end

    class Configuration
      attr_accessor :host, :port, :timeout, :process_timeout, :browser_path

      def initialize
        @host = "127.0.0.1"
        @port = 9222
        @timeout = 15
        @process_timeout = 10
        @browser_path = nil
      end

      def to_h
        {
          host: host,
          port: port,
          timeout: timeout,
          process_timeout: process_timeout,
          browser_path: browser_path,
        }.compact
      end
    end
  end
end

Capybara.register_driver(:lightpanda) do |app|
  Capybara::Lightpanda::Driver.new(app, Capybara::Lightpanda.configuration.to_h)
end
