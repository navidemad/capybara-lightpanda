# frozen_string_literal: true

require_relative "../test_helper"

# Ferrum 0.21 renamed the calls a Cuprite suite makes through
# page.driver.browser (rubycdp/ferrum#716, #717). The shared contract
# (test/compatibility/cuprite_contract.rb) runs go_to(referrer:), emulate,
# await_navigation and await_download against Chrome too. This file keeps the
# edges only Lightpanda has: its refusals, its nil-restore of the user agent,
# its error classes and await_download's path.
describe "Ferrum 0.21 browser API" do
  let(:session) { TestSessions::Lightpanda }
  let(:browser) { session.driver.browser }

  after { session.reset_session! }

  describe "network.emulate" do
    # Ferrum semantics: nil restores the browser's value for that key and
    # keeps the other override. Lightpanda keeps an empty user agent
    # literally, so the driver must send the default back itself.
    it "restores one key on nil and keeps the other" do
      session.visit("/lightpanda/request-headers")
      default_agent, default_language = session.evaluate_script("[navigator.userAgent, navigator.language]")
      browser.network.emulate(user_agent: "Probe/1.0", accept_language: "de-DE")

      browser.network.emulate(user_agent: nil)
      session.visit("/lightpanda/request-headers")
      assert_equal [default_agent, "de-DE"], session.evaluate_script("[navigator.userAgent, navigator.language]")

      browser.network.emulate(accept_language: nil)
      session.visit("/lightpanda/request-headers")
      assert_equal [default_agent, default_language],
                   session.evaluate_script("[navigator.userAgent, navigator.language]")
    end

    # Lightpanda refuses a Mozilla user agent and still answers {}: a silent
    # no-op would let the spec run on the default agent.
    it "raises on a user agent Lightpanda refuses, and on keys it can't emulate" do
      assert_raises(ArgumentError) { browser.network.emulate(user_agent: "Mozilla/5.0 (iPhone)") }
      error = assert_raises(ArgumentError) { browser.network.emulate(platform: "iPhone") }
      assert_match(/platform/, error.message)
    end
  end

  describe "network.wait_idle" do
    # Returns nil rather than raising, so `wait_idle || ...` reads naturally;
    # the bang form raises for callers that treat idleness as a precondition.
    it "returns nil while a request is pending, true once idle, and wait_idle! raises" do
      session.visit("/lightpanda/links")
      browser.network.enable
      session.execute_script("fetch('/lightpanda/probe/slow_frame')")

      assert_nil browser.network.wait_idle(timeout: 0.3)
      assert_raises(Capybara::Lightpanda::TimeoutError) { browser.network.wait_idle!(timeout: 0.3) }
      assert_equal true, browser.network.wait_idle(timeout: 10)
    end
  end

  describe "await_download" do
    # Ferrum returns the download's metadata hash; a path is what the
    # 0.20 downloads.wait callers already handle.
    it "returns the path of the file the block downloads, and await_download! raises" do
      session.visit("/lightpanda/download_page")

      path = browser.await_download { session.click_link("Download report") }
      assert_equal File.join(Capybara.save_path, "report.csv"), path
      assert_raises(Capybara::Lightpanda::TimeoutError) { browser.await_download!(timeout: 0.3) { nil } }
    end
  end
end
