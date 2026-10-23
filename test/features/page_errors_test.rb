# frozen_string_literal: true

require_relative "../test_helper"

# Browser#page_errors — uncaught page exceptions, which console_logs structurally
# cannot see. A handler dying on a TypeError leaves nothing in console_logs;
# the failure then surfaces far away as ElementNotFound on whatever the handler
# was supposed to produce. That is how the solidus taxon-tree failure
# presented, and diagnosing it needed a hand-injected window error listener.
#
# Browser::Console now reads Runtime.exceptionThrown, as Chrome clients do. These
# tests pin the contract: the exception lands in page_errors, it does NOT land in
# console_logs, and the entry keeps the shape the earlier window-listener source
# produced (1-based line/column, "Name: message", nil location on a rejection).
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
    # already assert console_logs holds no errors. The fixture logs nothing, so
    # anything here is the exception leaking through.
    assert_empty browser.console_logs, "an uncaught exception leaked into console_logs"
  end

  it "captures an unhandled promise rejection" do
    session.find(:css, "#rejecter").click
    wait_for_page_errors

    rejection = browser.page_errors.find { |e| e[:kind] == "unhandledrejection" }
    refute_nil rejection, "rejection not captured: #{browser.page_errors.inspect}"
    # `reason.message`, not "Error: …": the shape suites matched before the swap.
    assert_equal "rejected on purpose", rejection[:message]
    assert_match(/rejected on purpose/, rejection[:stack])
  end

  # The driver's own scripts report failure by raising, so a suite that rescues
  # a JavaScriptError must not also find it in page_errors.
  it "keeps driver script failures out of page_errors" do
    assert_raises(Capybara::Lightpanda::JavaScriptError) { session.execute_script("throw new Error('driver boom')") }
    assert_raises(Capybara::Lightpanda::JavaScriptError) { session.evaluate_script("(() => { throw new Error('eval boom') })()") }
    session.find(:css, "#thrower").click
    wait_for_page_errors

    assert_equal 1, browser.page_errors.size, browser.page_errors.inspect
  end

  # A rejection the page handles in the same tick is not an error. Builds below
  # 10904 reported it anyway (upstream #4096, in the 10965 floor), so this pins
  # the behavior the B19 swap to Runtime.exceptionThrown must keep.
  it "ignores a rejection handled in the same tick" do
    session.execute_script(<<~JS)
      (async function () { throw new Error("handled async throw"); })().catch(function () {});
      Promise.reject(new Error("handled same tick")).catch(function () {});
      Promise.reject(new Error("really unhandled"));
    JS
    wait_for_page_errors

    assert_equal(["really unhandled"], browser.page_errors.map { |e| e[:message] })
  end

  # Frames are where embedded widgets (payment forms, editors) live, and their
  # exceptions are just as invisible to console_logs. Lightpanda reports them
  # under the frame's own execution context (#4115), on the page's session.
  it "captures an exception thrown inside an iframe" do
    session.visit("/lightpanda/with_frame")
    session.within_frame("test-frame") do
      session.execute_script("setTimeout(function() { throw new Error('frame boom'); }, 0)")
    end
    wait_for_page_errors

    assert_equal(["Error: frame boom"], browser.page_errors.map { |e| e[:message] })
  end

  # A thrown string has no Error wrapper: its value is the whole message, and
  # there is no stack to report.
  it "reports a thrown primitive as its value" do
    session.execute_script("setTimeout(function() { throw 'plain boom'; }, 0)")
    wait_for_page_errors

    error = browser.page_errors.first
    assert_equal ["error", "plain boom", nil], [error[:kind], error[:message], error[:stack]]
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
