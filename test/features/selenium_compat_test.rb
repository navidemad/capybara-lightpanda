# frozen_string_literal: true

require_relative "../test_helper"

# Selenium-named entry points on Browser/Node.
#
# These exist because real suites put them in *shared* helpers, where a
# NoMethodError takes out every example in the file before any real assertion
# runs — so the cost of missing them is far larger than the one call site
# suggests. All three cases below are lifted from failures in the real-apps
# matrix (run 30116365373):
#
#   browser.logs.get(:browser)  — decidim's `expect_no_js_errors`
#                                 (decidim-dev/.../rspec_support/frontend.rb)
#   browser.execute_async_script — decidim's axe-core matcher, which gates the
#                                 whole shared "accessible page" example group
#   element.native.send_keys    — solidus's return_authorizations_spec.rb
#
# The point of these tests is the *foreign* API shape, not the underlying
# capability (console capture and async evaluation have their own coverage in
# console_logs_test.rb / driver_test.rb). So they assert what the callers
# actually touch: `.level` strings, `.message`, and that a driver node comes
# back from `native`.
describe "Capybara::Lightpanda selenium compatibility" do
  let(:session) { TestSessions::Lightpanda }
  let(:browser) { session.driver.browser }

  after { session.reset_session! }

  describe "Browser#logs" do
    before do
      session.visit("/lightpanda/console_logs")
      Capybara::Lightpanda::Utils::Wait.until(timeout: 2) { browser.console_logs.size >= 3 }
    end

    # The helper's whole contract is `error.level != "SEVERE"` — map the CDP
    # console type onto Selenium's severity vocabulary, not our own.
    it "maps console types onto Selenium severities" do
      entries = browser.logs.get(:browser)

      by_message = entries.to_h { |e| [e.message, e.level] }
      assert_equal "SEVERE", by_message["boom"], entries.inspect
      assert_equal "WARNING", by_message["careful"], entries.inspect
      assert_equal "INFO", by_message["hello 42 false"], entries.inspect
    end

    it "exposes the LogEntry accessors the helper reads" do
      entry = browser.logs.get(:browser).find { |e| e.level == "SEVERE" }

      refute_nil entry, "no SEVERE entry captured: #{browser.logs.get(:browser).inspect}"
      assert_equal "boom", entry.message
      assert_kind_of Numeric, entry.timestamp
      assert_includes entry.to_s, "boom"
    end

    # Chrome's getLog drains; ours deliberately doesn't, so a helper that reads
    # the log early can't swallow an error a later assertion should have seen.
    it "does not drain the buffer between reads" do
      first = browser.logs.get(:browser)
      refute_empty first
      assert_equal first.map(&:message), browser.logs.get(:browser).map(&:message)
    end

    # A helper probing several Selenium log types must not blow up on the ones
    # that have no analogue here.
    it "returns empty for log types this driver has no source for" do
      assert_empty browser.logs.get(:driver)
      assert_equal [:browser], browser.logs.available_types
    end
  end

  describe "Browser#execute_async_script" do
    # The axe-core shape: the completion callback arrives as the last argument.
    it "resolves through the trailing callback argument" do
      session.visit("/lightpanda/form_test")

      result = browser.execute_async_script(<<~JS)
        var done = arguments[arguments.length - 1];
        setTimeout(function () { done({ ok: true, tag: document.body.tagName }); }, 10);
      JS

      assert_equal({ "ok" => true, "tag" => "BODY" }, result)
    end
  end

  describe "Browser#execute_cdp" do
    before { session.visit("/lightpanda/form_test") }

    it "sends a raw CDP command against the page session" do
      result = browser.execute_cdp("Runtime.evaluate", expression: "6 * 7", returnByValue: true)

      assert_equal 42, result.dig("result", "value")
    end

    # The point of an escape hatch is reaching surface the gem hasn't wrapped.
    # Emulation is a good witness: nothing else in the driver routes through it
    # except set_viewport.
    it "reaches CDP domains the driver does not otherwise expose" do
      browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 640, height: 480)

      assert_equal 640, session.evaluate_script("window.innerWidth")
    ensure
      browser.set_viewport
    end

    # Unknown methods must surface Lightpanda's own error, not a wrapper of
    # ours — otherwise the hatch lies about what the browser supports.
    it "propagates the browser's error for an unknown method" do
      assert_raises(Capybara::Lightpanda::BrowserError) do
        browser.execute_cdp("Nonexistent.method")
      end
    end
  end

  describe "Browser#switch_to" do
    # Can't be honored (responses are pre-armed, see Modals), so the value here
    # is failing with the migration instead of NoMethodError.
    it "raises a driver error naming the pre-arm replacement" do
      error = assert_raises(Capybara::NotSupportedByDriverError) { browser.switch_to }

      assert_match(/accept_alert|accept_modal/, error.message)
    end
  end

  describe "Node#native" do
    before { session.visit("/lightpanda/form_test") }

    # Regression: Capybara::Driver::Node#native returned the CDP objectId
    # String, so `.native.send_keys` raised NoMethodError on String.
    it "returns the driver node so .native.send_keys works" do
      element = session.find(:css, "#name")
      element.set("Hello")

      assert_kind_of Capybara::Lightpanda::Node, element.native
      element.native.send_keys(" World")

      assert_equal "Hello World", element.value
    end

    # #native returning self would make Capybara::Driver::Node#== recurse
    # forever; our #== overrides it and must keep comparing by node identity.
    it "keeps node equality intact" do
      one = session.find(:css, "#name")
      same = session.find(:css, "#name")
      other = session.find(:css, "#readonly-input")

      assert_equal one.base, same.base
      refute_equal one.base, other.base
    end
  end
end
