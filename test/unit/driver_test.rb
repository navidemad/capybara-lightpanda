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

    # capybara-screenshot's fallback for unregistered drivers calls
    # `driver.render(path)`. Without the alias every
    # failing test in a capybara-screenshot suite logged a NoMethodError warn.
    it "responds to render as an alias of save_screenshot" do
      browser.expects(:screenshot).with(path: "/tmp/x.png")
      driver.render("/tmp/x.png")
    end
  end

  # Real suites call header writers on the driver (`page.driver.headers = ...`).
  # The driver delegates to Network, which owns lazy Network-domain enablement
  # and reset behavior.
  describe "headers delegation" do
    let(:driver) { Capybara::Lightpanda::Driver.allocate }
    let(:browser) { mock("Browser") }
    let(:network) { mock("Network") }

    before do
      driver.instance_variable_set(:@browser, browser)
      driver.define_singleton_method(:browser) { @browser }
      browser.stubs(:network).returns(network)
    end

    it "delegates headers= to network" do
      network.expects(:headers=).with({ "User-Agent" => "test" })
      driver.headers = { "User-Agent" => "test" }
    end

    it "delegates add_headers to network" do
      network.expects(:add_headers).with({ "X-Custom" => "1" })
      driver.add_headers({ "X-Custom" => "1" })
    end

    it "reads headers back from network" do
      network.stubs(:extra_headers).returns({ "X-Custom" => "1" })
      assert_equal({ "X-Custom" => "1" }, driver.headers)
    end
  end

  # Issue #219. A browser whose CDP connection died still owns its process
  # (running, or a zombie after a crash) and an at_exit registry slot. Dropping
  # it without #quit left one more Lightpanda running per respawn.
  describe "#browser after the connection died" do
    let(:driver) { Capybara::Lightpanda::Driver.new(nil) }

    it "quits the dead browser before spawning its replacement" do
      dead = mock("dead Browser")
      dead.stubs(:alive?).returns(false)
      replacement = mock("Browser")
      replacement.stubs(:alive?).returns(true)
      spawn = sequence("respawn")
      dead.expects(:quit).in_sequence(spawn)
      Capybara::Lightpanda::Browser.expects(:new).in_sequence(spawn).returns(replacement)
      driver.instance_variable_set(:@browser, dead)

      assert_same replacement, driver.browser
    end

    it "does not quit a browser that is still alive" do
      live = mock("Browser")
      live.stubs(:alive?).returns(true)
      live.expects(:quit).never
      Capybara::Lightpanda::Browser.expects(:new).never
      driver.instance_variable_set(:@browser, live)

      assert_same live, driver.browser
    end
  end

  # Capybara calls reset! after every touched session, including one whose
  # launch failed during `visit`. Launching Lightpanda there only to reset it
  # costs a second full process timeout per failing example (Cuprite #356).
  describe "#reset!" do
    let(:driver) { Capybara::Lightpanda::Driver.new(nil) }

    it "does not launch a browser when none has started" do
      Capybara::Lightpanda::Browser.expects(:new).never
      driver.reset!
    end

    it "does not relaunch after the first launch failed" do
      Capybara::Lightpanda::Browser.expects(:new).once
                                   .raises(Capybara::Lightpanda::ProcessTimeoutError, "slow launch")
      assert_raises(Capybara::Lightpanda::ProcessTimeoutError) { driver.browser }
      driver.reset!
    end

    it "still resets a browser that has started" do
      browser = mock("Browser")
      browser.stubs(:alive?).returns(true)
      browser.expects(:reset)
      driver.instance_variable_set(:@browser, browser)
      driver.reset!
    end

    it "forgets the visited host even when no browser exists" do
      driver.instance_variable_set(:@started, true)
      driver.reset!
      refute driver.instance_variable_get(:@started)
    end
  end
end
