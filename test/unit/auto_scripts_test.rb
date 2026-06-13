# frozen_string_literal: true

require_relative "../test_helper"
require "capybara/lightpanda/auto_scripts"

# AutoScripts is the linker that concatenates the plain-declaration source
# files in javascripts/ into the single frozen string injected via
# Page.addScriptToEvaluateOnNewDocument. These assertions guard the shipped
# artifact's shape from the Ruby side — the place it actually reaches RubyGems
# — so a regression is caught even when the Bun JS harness (test/js/) is
# skipped. The wire contract they protect: the IIFE + idempotency guard, the
# public _lightpanda surface node.rb calls, the Turbo sentinel prefix
# console.rb reads, and the "no module syntax" invariant that keeps every
# source file loadable both as a classic browser script and as a
# `new Function(...)` body.
describe Capybara::Lightpanda::AutoScripts do
  let(:js) { Capybara::Lightpanda::AutoScripts::JS }

  it "is a single frozen string" do
    assert_kind_of String, js
    assert js.frozen?
  end

  it "wraps the parts in an IIFE" do
    assert js.start_with?("(function() {")
    assert js.rstrip.end_with?("})();")
  end

  it "guards against double-injection before any listener registers" do
    guard = "if (window._lightpanda) return;"
    assert_includes js, guard
    # The guard must precede turbo.js's addEventListener calls, or a repeat
    # run double-registers them and desyncs the busy/idle counter.
    assert_operator js.index(guard), :<, js.index("addEventListener"),
                    "idempotency guard must come before the first addEventListener"
  end

  it "exposes the public _lightpanda surface node.rb depends on" do
    assert_includes js, "window._lightpanda = {"
    %w[isVisible isObscured isDisabled isContentEditable visibleText].each do |fn|
      # attach.js wires each predicate onto the namespace by name.
      assert_includes js, "#{fn}: #{fn}", "missing _lightpanda.#{fn} wiring"
    end
    assert_includes js, "turbo:", "missing _lightpanda.turbo wiring"
  end

  it "preserves the Turbo sentinel wire protocol console.rb reads" do
    assert_includes js, "__lightpanda_turbo_"
  end

  it "contains no module syntax (must parse as a classic script)" do
    refute_includes js, "export ", "source files must not use ESM export"
    refute_includes js, "import ", "source files must not use ESM import"
    refute_includes js, "require(", "source files must not use CommonJS require"
  end

  it "concatenates every declared part" do
    Capybara::Lightpanda::AutoScripts::PARTS.each do |name|
      path = File.join(Capybara::Lightpanda::AutoScripts::JS_DIR, name)
      assert File.exist?(path), "declared part #{name} is missing from javascripts/"
    end
  end
end
