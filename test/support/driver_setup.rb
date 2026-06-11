# frozen_string_literal: true

require "capybara"
require "capybara-lightpanda"
require_relative "test_app"

Capybara.register_driver(:lightpanda) do |app|
  options = {
    timeout: 10,
    browser_path: ENV["LIGHTPANDA_BIN"] || Capybara::Lightpanda::Binary.update,
  }
  Capybara::Lightpanda::Driver.new(app, options)
end

module TestSessions
  Lightpanda = Capybara::Session.new(:lightpanda, TestApp) unless const_defined?(:Lightpanda)
end
