# frozen_string_literal: true

require_relative "../test_helper"

# Two gaps a beta tester hit through raw CDP (2026-11-18, Lightpanda 1.0.4):
# Emulation.setTimezoneOverride answers {} and does nothing, and
# Emulation.setUserAgentOverride answers {} to a "Mozilla" value and keeps
# "Lightpanda/1.0". These pin what the gem offers instead.
describe "Capybara::Lightpanda emulation" do
  Capybara.register_driver(:lightpanda_new_york) do |app|
    Capybara::Lightpanda::Driver.new(
      app,
      timeout: 10,
      timezone: "America/New_York",
      browser_path: ENV["LIGHTPANDA_BIN"] || Capybara::Lightpanda::Binary.update
    )
  end

  # The zone is per process, so this session owns its own Lightpanda.
  def self.zoned_session
    @zoned_session ||= Capybara::Session.new(:lightpanda_new_york, TestApp)
  end

  Minitest.after_run { @zoned_session&.driver&.quit }

  let(:session) { TestSessions::Lightpanda }

  describe "timezone option" do
    # An app that reads the browser zone (Intl, Date offsets) sees the one the
    # suite asked for, whatever the host or CI runner is set to.
    it "makes Intl and Date report the configured zone" do
      zoned = self.class.zoned_session
      zoned.visit("/lightpanda/links")

      assert_equal "America/New_York", zoned.evaluate_script("Intl.DateTimeFormat().resolvedOptions().timeZone")
      assert_equal 300, zoned.evaluate_script("new Date(2026, 0, 15).getTimezoneOffset()")
    ensure
      zoned&.reset_session!
    end

    # The whole point of passing TZ to the child alone.
    it "leaves the test process on its own zone" do
      before = Time.now.utc_offset
      self.class.zoned_session.visit("/lightpanda/links")

      assert_equal before, Time.now.utc_offset
    ensure
      self.class.zoned_session.reset_session!
    end
  end

  describe "user_agent=" do
    # Server-side device detection reads the header, client-side code reads
    # navigator.userAgent: an override that moved only one would split them.
    it "moves the request header and navigator.userAgent together" do
      session.visit("/lightpanda/links")
      session.driver.user_agent = "Lightpanda/1.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Mobile"
      session.visit("/lightpanda/links")

      assert_equal "Lightpanda/1.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Mobile",
                   session.evaluate_script("navigator.userAgent")
      session.visit("/lightpanda/user-agent")
      assert_includes session.html, "Lightpanda/1.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Mobile"
    ensure
      session.reset_session!
    end

    # The desktop string the docs give for device detection: Chrome and Safari
    # tokens are fine, only "Mozilla" is refused.
    it "accepts a desktop Chrome user agent without the Mozilla prefix" do
      desktop = "Lightpanda/1.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/135.0.0.0 Safari/537.36"
      session.visit("/lightpanda/links")
      session.driver.user_agent = desktop
      session.visit("/lightpanda/links")

      assert_equal desktop, session.evaluate_script("navigator.userAgent")
    ensure
      session.reset_session!
    end

    # A mobile user agent must not follow the next example around.
    it "is dropped by reset!" do
      session.visit("/lightpanda/links")
      session.driver.user_agent = "Lightpanda/1.0 Mobile"
      session.reset_session!
      session.visit("/lightpanda/links")

      refute_includes session.evaluate_script("navigator.userAgent"), "Mobile"
    end
  end
end
