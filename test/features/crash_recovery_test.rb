# frozen_string_literal: true

require_relative "../test_helper"

# Issue #219. go_to recovers from a browser that dies mid-navigation by
# restarting the process and retrying once (Browser#handle_navigation_crash).
# The restart hinged on Process#alive?, which probed with kill(0) — and kill(0)
# succeeds on the zombie a crashed child leaves until it is reaped. The dead
# browser looked alive, was never restarted, and the visit raised
# DeadBrowserError after dialling the dead port.
describe "Browser crash during navigation" do
  # Its own driver: this test kills the browser it drives.
  let(:session) { Capybara::Session.new(:lightpanda, TestApp) }

  after do
    TestApp.crash_pid = nil
    session.driver.quit
  end

  it "restarts the crashed browser and completes the visit" do
    session.visit("/lightpanda/simple")
    browser = session.driver.browser
    crashed_pid = browser.process.pid
    TestApp.crash_pid = crashed_pid

    session.visit("/lightpanda/probe/crash_browser")

    assert session.has_css?("#recovered"), "the retried visit should land on the page"
    assert_same browser, session.driver.browser, "recovery happens inside go_to, not by respawning"
    refute_equal crashed_pid, browser.process.pid, "a new Lightpanda process should serve the session"
  end
end
