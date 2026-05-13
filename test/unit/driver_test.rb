# frozen_string_literal: true

require_relative "../test_helper"
require "capybara/lightpanda/errors"
require "capybara/lightpanda/driver"

# Focused unit tests for Driver methods whose behavior is independent of
# the live browser. Full-stack driver behavior lives in test/features.
describe Capybara::Lightpanda::Driver do
  describe "#save_screenshot" do
    # Rails' before_teardown runs save_screenshot on every failure. If the
    # real test failure was a browser crash, the screenshot grab will hit a
    # dead WebSocket — propagating that error masks the original failure.
    let(:driver) { Capybara::Lightpanda::Driver.allocate }
    let(:browser) { mock("Browser") }

    before do
      driver.instance_variable_set(:@browser, browser)
      # Skip the alive-check path; we're testing the rescue, not browser warmup.
      driver.define_singleton_method(:browser) { @browser }
    end

    it "swallows DeadBrowserError so teardown doesn't mask the original failure" do
      browser.stubs(:screenshot).raises(Capybara::Lightpanda::DeadBrowserError, "WS down")
      assert_nil driver.save_screenshot("/tmp/x.png")
    end

    it "swallows TimeoutError when the CDP screenshot call times out" do
      browser.stubs(:screenshot).raises(Capybara::Lightpanda::TimeoutError, "command timed out")
      assert_nil driver.save_screenshot("/tmp/x.png")
    end

    it "swallows any BrowserError subclass (CDP-level errors)" do
      browser.stubs(:screenshot).raises(Capybara::Lightpanda::BrowserError, "weird CDP error")
      assert_nil driver.save_screenshot("/tmp/x.png")
    end

    it "still swallows BinaryError when the process can't start" do
      browser.stubs(:screenshot).raises(Capybara::Lightpanda::BinaryError, "version too old")
      assert_nil driver.save_screenshot("/tmp/x.png")
    end

    it "does not swallow unrelated errors" do
      # We deliberately don't catch Ruby/system errors — those signal a bug
      # in the gem or environment, not a transient teardown nuisance.
      browser.stubs(:screenshot).raises(RuntimeError, "unexpected")
      assert_raises(RuntimeError) { driver.save_screenshot("/tmp/x.png") }
    end
  end
end
