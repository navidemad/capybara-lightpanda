# frozen_string_literal: true

require "socket"
require "capybara"
require "capybara-lightpanda"
require_relative "test_app"

module DriverSetup
  module_function

  def find_available_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end
end

Capybara.register_driver(:lightpanda) do |app|
  options = {
    timeout: 10,
    port: DriverSetup.find_available_port,
    browser_path: ENV["LIGHTPANDA_PATH"] || Capybara::Lightpanda::Binary.ensure_nightly,
  }
  Capybara::Lightpanda::Driver.new(app, options)
end

module TestSessions
  Lightpanda = Capybara::Session.new(:lightpanda, TestApp) unless const_defined?(:Lightpanda)
end
