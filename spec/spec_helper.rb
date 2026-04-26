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

    # Browser-level limitations whose Capybara shared spec isn't tagged with
    # a `requires:` flag we can pass through `capybara_skip`. Each entry maps
    # to a documented Lightpanda CDP gap in `.claude/rules/lightpanda-io.md`.
    browser_limitation_patterns = [
      # File uploads — `Page.setFileInputFiles` not implemented (upstream
      # #2175); `Node#set` raises NotImplementedError for `<input type=file>`.
      /#attach_file/,
      # Click coordinate / modifier / delay tests rely on real geometry and
      # `Input.dispatchMouseEvent` modifier flags. `Page.getLayoutMetrics`
      # returns hardcoded 1920x1080 and modifier propagation is incomplete.
      /node #click should allow modifiers/,
      /node #click should allow multiple modifiers/,
      /node #click should allow to adjust the click offset/,
      /node #click should not retry clicking when wait is disabled/,
      /node #click offset/,
      /node #click delay/,
      /node #double_click should allow modifiers/,
      /node #double_click should allow to adjust the offset/,
      /node #double_click offset/,
      /node #right_click should allow modifiers/,
      /node #right_click should allow to adjust the offset/,
      /node #right_click offset/,
      /node #right_click delay/,
      # Computed style — only inline styles round-trip through CSSOM;
      # property lookups against the cascade don't.
      /node #style/,
      /#assert_matches_style should raise error if the elements style/,
      /#assert_matches_style should wait for style/,
      /#matches_style\? should be true if the element has the given style/,
      /#matches_style\? should be false if the element does not have the given style/,
      /#has_css\? :style option should support Hash/,
      /#has_css\? with count should be true if the content occurs the given number of times in CSS processing drivers/,
      # Node #obscured? sub-tests requiring viewport / overlap detection.
      /node #obscured\? should see elements outside the viewport as obscured/,
      /node #obscured\? should see overlapped elements as obscured/,
      /node #obscured\? should work in frames/,
      /node #obscured\? should work in nested iframes/,
      # send_keys: special characters / modifier holding / key event
      # generation — `Input.dispatchKeyEvent` doesn't carry modifier
      # state across non-tuple keys and key codes are missing from events.
      /node #send_keys should send special characters/,
      /node #send_keys should hold modifiers at top level/,
      /node #send_keys should generate key events/,
      # Lightpanda doesn't propagate `Referer` reliably, so any test
      # asserting the rendered referer fails.
      /#visit should send a referer when following a link/,
      /#visit should preserve the original referer URL when following a redirect/,
      /#click_link should follow redirects back to itself/,
      # `Node#path` canonical XPath generation — Lightpanda's DOM
      # serialization differs from Chrome's expected output.
      /node #path returns xpath which points to itself/,
      # `window.location.pathname` setter doesn't trigger navigation
      # in Lightpanda (only `.href` does). The 'Change page' fixture
      # uses `window.location.pathname = '/with_html'`, so any test
      # waiting on that navigation never sees it complete.
      /#assert_current_path should wait for current_path/,
      /#assert_current_path should wait for current_path to disappear/,
      /#has_current_path\? should wait for current_path/,
    ].freeze

    if browser_limitation_patterns.any? { |re| description =~ re }
      metadata[:skip] = "Lightpanda browser limitation"
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
