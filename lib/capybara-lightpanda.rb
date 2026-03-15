# frozen_string_literal: true

require "capybara"

require_relative "capybara/lightpanda/version"
require_relative "capybara/lightpanda/errors"
require_relative "capybara/lightpanda/options"
require_relative "capybara/lightpanda/binary"
require_relative "capybara/lightpanda/process"
require_relative "capybara/lightpanda/client"
require_relative "capybara/lightpanda/network"
require_relative "capybara/lightpanda/cookies"
require_relative "capybara/lightpanda/browser"
require_relative "capybara/lightpanda/xpath_polyfill"
require_relative "capybara/lightpanda/node"
require_relative "capybara/lightpanda/driver"

module Capybara
  module Lightpanda
    class << self
      def configure
        yield(options) if block_given?
      end

      def options
        @options ||= Options.new
      end

      def reset_options!
        @options = nil
      end
    end
  end
end

Capybara.register_driver(:lightpanda) do |app|
  Capybara::Lightpanda::Driver.new(app, Capybara::Lightpanda.options.to_h)
end
