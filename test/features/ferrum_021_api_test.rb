# frozen_string_literal: true

require_relative "../test_helper"

# Ferrum 0.21 renamed the calls a Cuprite suite makes through
# page.driver.browser (rubycdp/ferrum#716, #717) and Cuprite 0.21's docs show
# only the new names. A suite written against them must not hit NoMethodError
# or ArgumentError on this driver. The 0.20 names stay (other tests pin them).
describe "Ferrum 0.21 browser API" do
  let(:session) { TestSessions::Lightpanda }
  let(:browser) { session.driver.browser }

  after { session.reset_session! }

  def request_headers
    session.visit("/lightpanda/request-headers")
    session.find(:css, "body").text.split("|", -1)
  end

  describe "go_to(referrer:)" do
    # The referrer belongs to that one navigation: a later visit must not
    # carry it, unlike a header set for the session.
    # Same-origin, so the default referrer policy keeps the full URL (an
    # https referrer would be dropped on this http server, as in Chrome).
    it "sends the Referer with that navigation only" do
      referrer = "#{session.server.base_url}/lightpanda/links"
      browser.go_to("#{session.server.base_url}/lightpanda/request-headers", referrer: referrer)
      assert_equal referrer, session.find(:css, "body").text.split("|").first

      assert_equal "", request_headers.first
    end
  end

  describe "network.emulate" do
    # The header and navigator must move together: server-side detection
    # reads one, client code the other.
    it "overrides the user agent and language for requests and navigator" do
      browser.network.emulate(user_agent: "Probe/1.0", accept_language: "de-DE")

      _, language, agent = request_headers
      assert_equal ["Probe/1.0", "de-DE"], [agent, language]
      assert_equal ["Probe/1.0", "de-DE"], session.evaluate_script("[navigator.userAgent, navigator.language]")
    end

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

  describe "await_navigation" do
    it "returns true once the page the block navigates to has loaded" do
      session.visit("/lightpanda/links")
      navigated = browser.await_navigation { session.execute_script("location.href = '/lightpanda/request-headers'") }
      assert_equal true, navigated
      assert_match %r{/lightpanda/request-headers\z}, session.current_url
    end

    # `watch:` is for an action that may or may not navigate: nothing starting
    # within the window is success, not a timeout.
    it "returns true at once with watch: when nothing navigates, nil without it" do
      session.visit("/lightpanda/links")

      assert_equal true, browser.await_navigation(watch: 0.2, timeout: 5) { session.execute_script("1") }
      assert_nil browser.await_navigation(timeout: 0.3) { session.execute_script("1") }
      assert_raises(Capybara::Lightpanda::TimeoutError) { browser.await_navigation!(timeout: 0.3) { nil } }
      assert_raises(ArgumentError) { browser.await_navigation }
    end
  end

  describe "await_download" do
    it "returns the file the block downloads, nil when none finishes" do
      session.visit("/lightpanda/download_page")

      path = browser.await_download { session.click_link("Download report") }
      assert_equal File.join(Capybara.save_path, "report.csv"), path
      assert_nil browser.await_download(timeout: 0.3) { nil }
      assert_raises(Capybara::Lightpanda::TimeoutError) { browser.await_download!(timeout: 0.3) { nil } }
    end
  end
end
