# frozen_string_literal: true

require_relative "../test_helper"

# Browser#console_logs — captured `Runtime.consoleAPICalled` events, the API
# real suites use to assert "no JS errors leaked" (peer drivers route this
# through custom Ferrum loggers; here it's first-class). The capture must
# survive without any IO logger configured, exclude the gem's own Turbo
# sentinels, and reset with the session — a stale buffer would leak one
# test's console errors into the next test's assertion.
describe "Capybara::Lightpanda::Browser#console_logs" do
  let(:session) { TestSessions::Lightpanda }
  let(:browser) { session.driver.browser }

  after { session.reset_session! }

  def visit_fixture_and_wait
    session.visit("/lightpanda/console_logs")
    # Console events ride the same WebSocket as commands but are dispatched
    # asynchronously by the subscriber thread — poll briefly for arrival.
    Capybara::Lightpanda::Utils::Wait.until(timeout: 2) { browser.console_logs.size >= 3 }
  end

  it "captures type, joined text, and timestamp per console call" do
    visit_fixture_and_wait

    # Lightpanda reports each console.* call with its own CDP type since
    # upstream #2731 (console.log → "log"); older nightlies collapsed
    # console.log/console.warn to "info". Assert the actual contract —
    # entries keyed by text.
    log = browser.console_logs.find { |m| m[:text].start_with?("hello") }
    refute_nil log, "console.log entry not captured: #{browser.console_logs.inspect}"
    assert_equal "log", log[:type]
    # Falsy args must survive the text join (no `||` short-circuit).
    assert_equal "hello 42 false", log[:text]
    assert_kind_of Numeric, log[:timestamp]
    assert_kind_of Array, log[:args]

    error = browser.console_logs.find { |m| m[:type] == "error" }
    refute_nil error, "console.error entry not captured"
    assert_equal "boom", error[:text]
  end

  # Since upstream #3504 (build 9414) only primitive args carry `value`; an
  # object or DOM node arrives as a bare RemoteObject. Reading `value` alone
  # rendered them as empty strings, so `console.log("user", user)` showed up
  # as "user " — an assertion on the logged object could never match.
  it "renders non-primitive arguments instead of dropping them" do
    session.visit("/lightpanda/console_logs")
    session.execute_script("console.log('obj', {a: 1}, document.body, undefined, [1, 2])")
    Capybara::Lightpanda::Utils::Wait.until(timeout: 2) do
      browser.console_logs.any? { |m| m[:text].start_with?("obj") }
    end

    text = browser.console_logs.find { |m| m[:text].start_with?("obj") }[:text]

    # Five arguments, five non-empty words: an argument rendered as "" shows
    # up as a doubled separator.
    refute_match(/\s{2}|\s\z/, text, "an argument rendered as nothing in #{text.inspect}")
    assert_equal 5, text.split.size, text
    assert_includes text.split, "undefined"
  end

  it "excludes the Turbo activity-tracker sentinels" do
    visit_fixture_and_wait

    sentinel = browser.console_logs.find { |m| m[:text].include?("__lightpanda_turbo_") }
    assert_nil sentinel, "driver-internal sentinel leaked into console_logs: #{sentinel.inspect}"
  end

  it "clears on session reset and on clear_console_logs" do
    visit_fixture_and_wait
    refute_empty browser.console_logs

    browser.clear_console_logs
    assert_empty browser.console_logs

    visit_fixture_and_wait
    session.reset_session!
    assert_empty browser.console_logs
  end
end
