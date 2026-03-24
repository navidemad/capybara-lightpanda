# frozen_string_literal: true

require "bundler/setup"
require "rspec"
require "socket"
require "capybara/spec/spec_helper"
require "capybara-lightpanda"
require_relative "support/test_app"

PROJECT_ROOT = File.expand_path("..", __dir__)

Capybara.save_path = File.join(PROJECT_ROOT, "spec", "tmp")

# Find an available port to avoid conflicts with running Lightpanda instances.
def find_available_port
  server = TCPServer.new("127.0.0.1", 0)
  port = server.addr[1]
  server.close
  port
end

Capybara.register_driver(:lightpanda) do |app|
  options = {
    timeout: 10,
    port: find_available_port,
    browser_path: ENV["LIGHTPANDA_PATH"] || Capybara::Lightpanda::Binary.ensure_nightly,
  }
  Capybara::Lightpanda::Driver.new(app, options)
end

module TestSessions
  Lightpanda = Capybara::Session.new(:lightpanda, TestApp)
end

RSpec.configure do |config|
  config.define_derived_metadata do |metadata|
    # Lightpanda limitations — skip by full test description.
    regexes = [
      # No rendering engine — no computed styles, layout, visual state
      /matches_style/,
      /assert_style/,

      # No drag and drop support
      /drag_to/,
      /drag_by/,

      # No file upload support
      /attach_file/,

      # No shadow DOM
      /shadow_root/,
      /shadow dom/i,

      # No download support
      /download/i,

      # Element obscuring checks need rendering
      /Element not found, or not visible, or element is obscured/,
      /obscured/,

      # No proper headers/status code access
      /response_headers/,
      /status_code/,

      # save_page/screenshot filesystem tests can be flaky without rendering
      /save_and_open_screenshot/,
    ].freeze

    metadata[:skip] = "Not supported by Lightpanda" if metadata[:full_description]&.match?(Regexp.union(regexes))
  end

  config.around do |example|
    # Clean up any temp files after each test
    FileUtils.rm_rf(Capybara.save_path) if File.directory?(Capybara.save_path)
    example.run
  end

  Capybara::SpecHelper.configure(config)
end
