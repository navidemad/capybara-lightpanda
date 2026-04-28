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

  # AUDIT_SKIPS=1 bypasses the skip blocks below and tags those specs with
  # `:skip_audit` instead, then filter_run_when_matching narrows the run to
  # *just* those specs. Used by sync-upstream to validate which patterns can
  # be dropped after a Lightpanda upgrade.
  audit_skips = ENV["AUDIT_SKIPS"] == "1"
  config.filter_run_when_matching(:skip_audit) if audit_skips

  # Skip Capybara shared specs that depend on browser features Lightpanda doesn't
  # implement. See `.claude/rules/lightpanda-io.md` for the per-feature rationale.
  # Keep this list narrow — every entry is a known browser-side gap, not a gem bug.
  config.define_derived_metadata do |metadata|
    description = metadata[:full_description]
    next unless description

    # Lightpanda auto-dismisses JS dialogs (alert→OK, confirm→false, prompt→null)
    # and `Page.handleJavaScriptDialog` always errors. So tests that need the page's
    # JS to observe a non-default return value can't pass; specs that only inspect
    # the captured message ("should return the message presented") or the
    # ModalNotFound path ("if the message doesn't match") work fine and run.
    # See `.claude/rules/lightpanda-io.md` known-bug item on `Page.handleJavaScriptDialog`.
    modal_patterns = [
      /#accept_confirm should accept the confirm/,
      /#accept_confirm should work with nested modals/,
      /#accept_prompt should accept the prompt/,
      /#accept_prompt should allow special characters/,
      /#accept_alert.*work with nested modals/,
    ].freeze

    if modal_patterns.any? { |re| description =~ re }
      if audit_skips
        metadata[:skip_audit] = true
      else
        metadata[:skip] = "Lightpanda auto-dismisses JS dialogs; can't override return values"
      end
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
      # `node #send_keys should send special characters` — `Input.dispatchKeyEvent`
      # doesn't move the input caret on ArrowLeft/Home/End, so `:left` doesn't
      # reposition the cursor mid-string. Upstream gap, not yet filed.
      /node #send_keys should send special characters/,
      # `node #send_keys should generate key events` — `KeyboardEvent.keyCode`
      # is hardcoded to 0 upstream. Gated on lightpanda-io/browser PR #2292
      # (events: implement keyCode/charCode legacy attributes). Remove once
      # that ships in nightly.
      /node #send_keys should generate key events/,
      # Lightpanda doesn't propagate `Referer` reliably, so any test
      # asserting the rendered referer fails.
      /#visit should send a referer when following a link/,
      /#visit should preserve the original referer URL when following a redirect/,
      /#click_link should follow redirects back to itself/,
      # `Node#path` canonical XPath generation — Lightpanda's DOM
      # serialization differs from Chrome's expected output.
      /node #path returns xpath which points to itself/,
      # `<input type=range>` has no slider DOM in Lightpanda — `set` writes
      # the value but the browser doesn't clamp/validate it the way Chrome's
      # range widget does. Only the "valid values" test fails — the "respect
      # the range slider limits" test passes because Capybara doesn't drive
      # below-min / above-max writes through the same code path.
      /#fill_in with input\[type="range"\] should set the range slider to valid values/,
      # Frame-closed detection — Lightpanda doesn't expose enough state to
      # distinguish a closed iframe from a live one within the frame_stack.
      /#switch_to_frame works if the frame is closed/,
      /#within_frame works if the frame is closed/,
      # `validity` API not implemented — `el.validity` returns undefined,
      # so `:valid` filter and `el.validationMessage` don't work.
      /#has_field with valid should be true if field is valid/,
      /#has_field with valid should be false if field is invalid/,
      # CSS text-transform / case sensitivity for invisible text — depends
      # on getComputedStyle returning cascade-resolved `text-transform`,
      # which Lightpanda's CSSOM doesn't yet implement for non-inline rules.
      /#assert_text should raise error.*if requested text is present but invisible and with incorrect case/,
      # `obscured: true/false` for nodes outside viewport — needs real
      # geometry & viewport (Page.getLayoutMetrics is hardcoded 1920x1080).
      /#all with obscured filter should not find nodes on top outside the viewport when false/,
      /#all with obscured filter should find top nodes outside the viewport when true/,
      # `<input list=...>` datalist — Lightpanda renders the input but the
      # browser-side datalist UI/option-fill logic isn't implemented.
      /#select input with datalist should select an option/,
      # Lightpanda's `Page.reload` does not replay a POST navigation as a
      # POST — it issues a fresh GET to the same URL, so the form action
      # handler never runs again and the test's `post_count` doesn't bump.
      /#refresh it reposts/,
    ].freeze

    if browser_limitation_patterns.any? { |re| description =~ re }
      if audit_skips
        metadata[:skip_audit] = true
      else
        metadata[:skip] = "Lightpanda browser limitation"
      end
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
