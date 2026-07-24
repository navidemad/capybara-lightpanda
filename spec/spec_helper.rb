# frozen_string_literal: true

require "bundler/setup"
require "rspec"
require "zlib"
require "capybara/spec/spec_helper"
require "capybara/spec/test_app"
require "capybara-lightpanda"

PROJECT_ROOT = File.expand_path("..", __dir__)

# Worker partitioning: when RSPEC_WORKER_COUNT > 1, each worker process
# (identified by RSPEC_WORKER_INDEX) runs ~1/Nth of the examples, partitioned
# by a CRC32 hash of the example's full description. Stable across runs so
# the same example always lands on the same worker.
WORKER_COUNT = ENV.fetch("RSPEC_WORKER_COUNT", "1").to_i
WORKER_INDEX = ENV.fetch("RSPEC_WORKER_INDEX", "0").to_i

# Per-worker paths so concurrent workers don't stomp on each other's
# tmp files (rspec status persistence, Capybara save_path).
worker_suffix = WORKER_COUNT > 1 ? "_#{WORKER_INDEX}" : ""
Capybara.save_path = File.join(PROJECT_ROOT, "spec", "tmp#{worker_suffix}")
Capybara.server = :puma, { Silent: true }

Capybara.register_driver(:lightpanda) do |app|
  options = {
    timeout: 10,
    browser_path: ENV["LIGHTPANDA_BIN"] || Capybara::Lightpanda::Binary.update,
  }
  Capybara::Lightpanda::Driver.new(app, options)
end

module TestSessions
  Lightpanda = Capybara::Session.new(:lightpanda, TestApp)
end

RSpec.configure do |config|
  config.example_status_persistence_file_path = File.join(PROJECT_ROOT, "tmp", "rspec_status#{worker_suffix}.txt")

  # Worker partitioning: skip examples whose CRC32 bucket doesn't match this
  # worker. Uses before(:each) + skip so the partitioning runs per-example
  # (define_derived_metadata propagates to all examples in a group, which
  # would force every example in a top-level describe onto the same worker).
  if WORKER_COUNT > 1
    config.before(:each) do |example|
      desc = example.full_description
      if (Zlib.crc32(desc) % WORKER_COUNT) != WORKER_INDEX
        skip "partitioned to a different worker (#{WORKER_INDEX} of #{WORKER_COUNT})"
      end
    end
  end

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

    # Browser-level limitations whose Capybara shared spec isn't tagged with
    # a `requires:` flag we can pass through `capybara_skip`. Each entry maps
    # to a documented Lightpanda CDP gap in `.claude/rules/lightpanda-io.md`.
    browser_limitation_patterns = [
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
      # Computed style. Narrowed 2026-07-24 (AUDIT_SKIPS run against nightly
      # 8285): getComputedStyle now resolves cascade-aware display/visibility,
      # synthetic width/height, and CSS initial values for
      # color/opacity/background-color, so `node #style`, `#matches_style?` and
      # the counting `#has_css?` spec all pass and their patterns were dropped.
      # These two still fail because they need genuine cascade resolution for
      # arbitrary properties, which Lightpanda does not do (it returns "").
      /#assert_matches_style should raise error if the elements style/,
      /#has_css\? :style option should support Hash/,
      # Node #obscured? sub-tests requiring viewport / overlap detection.
      /node #obscured\? should see elements outside the viewport as obscured/,
      /node #obscured\? should see overlapped elements as obscured/,
      /node #obscured\? should work in frames/,
      /node #obscured\? should work in nested iframes/,
      # `node #send_keys should send special characters` — `Input.dispatchKeyEvent`
      # doesn't move the input caret on ArrowLeft/Home/End, so `:left` doesn't
      # reposition the cursor mid-string. Upstream gap, not yet filed.
      /node #send_keys should send special characters/,
      # `Node#path` canonical XPath generation — Lightpanda's DOM
      # serialization differs from Chrome's expected output.
      /node #path returns xpath which points to itself/,
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
    # Clean up any temp files after each test. Guard against nil: a few
    # Capybara shared specs (save_page, save_screenshot) set save_path to nil
    # in their `before`, and if a Lightpanda failure mid-example prevents
    # their `after` from restoring it, the next example's around lands here
    # with nil. Skip cleanup in that case rather than crashing the around.
    save_path = Capybara.save_path
    FileUtils.rm_rf(save_path) if save_path && File.directory?(save_path)
    example.run
  end

  Capybara::SpecHelper.configure(config)
end
