# frozen_string_literal: true

require_relative "../test_helper"

# Browser#page_errors — uncaught page exceptions, which console_logs structurally
# cannot see. Lightpanda emits no Runtime.exceptionThrown (wishlist B19), so a
# handler dying on a TypeError leaves no CDP trace at all; the failure then
# surfaces far away as ElementNotFound on whatever the handler was supposed to
# produce. That is how the solidus taxon-tree failure presented, and diagnosing
# it needed a hand-injected window error listener.
#
# javascripts/errors.js now ships that listener. These tests pin the contract:
# the exception lands in page_errors, it does NOT land in console_logs, and the
# sentinel never leaks into user-facing console output.
describe "Capybara::Lightpanda::Browser#page_errors" do
  let(:session) { TestSessions::Lightpanda }
  let(:browser) { session.driver.browser }

  before { session.visit("/lightpanda/page_errors") }
  after { session.reset_session! }

  def wait_for_page_errors(count = 1)
    Capybara::Lightpanda::Utils::Wait.until(timeout: 2) { browser.page_errors.size >= count }
  end

  it "captures an uncaught TypeError with its message and location" do
    assert_empty browser.page_errors, "buffer should start clean"

    session.find(:css, "#thrower").click
    wait_for_page_errors

    error = browser.page_errors.first
    refute_nil error, "uncaught TypeError not captured: #{browser.page_errors.inspect}"
    assert_equal "error", error[:kind]
    # Engines word this differently ("Cannot read properties of undefined",
    # "undefined is not an object"), so assert on the part that is stable rather
    # than on V8's exact phrasing.
    assert_match(/undefined/i, error[:message])
    assert_kind_of Numeric, error[:timestamp]
  end

  it "does not put page errors into console_logs" do
    session.find(:css, "#thrower").click
    wait_for_page_errors

    # The separation is the design decision, not an accident: Chrome models an
    # exception as exceptionThrown rather than consoleAPICalled, and suites
    # already assert console_logs holds no errors.
    assert_empty browser.console_logs.select { |m| m[:type] == "error" },
                 "an uncaught exception leaked into console_logs: #{browser.console_logs.inspect}"
  end

  it "never leaks the sentinel into console_logs" do
    session.find(:css, "#thrower").click
    wait_for_page_errors

    leaked = browser.console_logs.select { |m| m[:text].to_s.include?("__lightpanda_page_error_") }
    assert_empty leaked, "driver sentinel leaked into console_logs: #{leaked.inspect}"
  end

  it "captures an unhandled promise rejection" do
    session.find(:css, "#rejecter").click

    # Rejection reporting is a separate upstream code path from `error`, and
    # Lightpanda may not implement `unhandledrejection` at all — in which case
    # the listener simply never fires. Skip rather than fail: the `error` half
    # above is the contract this feature is for, and a hard failure here would
    # block the suite on an upstream gap we don't control.
    unless Capybara::Lightpanda::Utils::Wait.until(timeout: 2) { browser.page_errors.any? }
      skip "Lightpanda did not deliver unhandledrejection on this build"
    end

    rejection = browser.page_errors.find { |e| e[:kind] == "unhandledrejection" }
    refute_nil rejection, "rejection not captured: #{browser.page_errors.inspect}"
    assert_match(/rejected on purpose/, rejection[:message])
  end

  it "clears on session reset and on clear_page_errors" do
    session.find(:css, "#thrower").click
    wait_for_page_errors
    refute_empty browser.page_errors

    browser.clear_page_errors
    assert_empty browser.page_errors

    session.visit("/lightpanda/page_errors")
    session.find(:css, "#thrower").click
    wait_for_page_errors
    session.reset_session!
    assert_empty browser.page_errors, "a stale buffer would leak one test's errors into the next"
  end
end
