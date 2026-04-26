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
  config.example_status_persistence_file_path = File.join(PROJECT_ROOT, "tmp", "rspec_status.txt")

  # Skip Capybara shared specs that depend on browser features Lightpanda doesn't
  # implement. See `.claude/rules/lightpanda-io.md` for the per-feature rationale.
  # Keep this list narrow — every entry is a known browser-side gap, not a gem bug.
  config.define_derived_metadata do |metadata|
    description = metadata[:full_description]
    next unless description

    # Lightpanda auto-dismisses JS dialogs (alert→OK, confirm→false, prompt→null)
    # and `Page.handleJavaScriptDialog` always errors. So `accept_modal(:confirm|:prompt)`
    # cannot override the return value the page sees, and text-mismatch
    # `ModalNotFound` expectations (where the test expects accept_alert to NOT accept
    # when the text doesn't match) cannot be honored.
    # See `.claude/rules/lightpanda-io.md` known-bug item on `Page.handleJavaScriptDialog`.
    modal_patterns = [
      /#accept_confirm/,
      /#accept_prompt/,
      /#accept_alert.*if the text doesn'?t match/,
      /#accept_alert.*work with nested modals/,
    ].freeze

    if modal_patterns.any? { |re| description =~ re }
      metadata[:skip] = "Lightpanda auto-dismisses JS dialogs; can't override return values"
      next
    end

    # Honor `capybara_skip:` from the run_specs caller. The Capybara shared specs
    # tag describe-blocks with `requires: %i[windows js]` etc.; `capybara_skip`
    # marks the feature names this driver explicitly opts out of supporting.
    requires = metadata[:requires]
    skip_list = metadata[:capybara_skip]
    if requires && skip_list && (matched = requires & skip_list).any?
      metadata[:skip] = "Lightpanda doesn't support: #{matched.join(', ')}"
    end
  end

  config.around do |example|
    # Clean up any temp files after each test
    FileUtils.rm_rf(Capybara.save_path) if File.directory?(Capybara.save_path)
    example.run
  end

  Capybara::SpecHelper.configure(config)
end
