# frozen_string_literal: true

require_relative "../test_helper"

# Window and Document carry the GlobalEventHandlers `on*` attributes, as in
# Chrome.
#
# WHY THIS MATTERS: Lightpanda puts the full set on HTMLElement only, so
# `'onchange' in window` and `'onsubmit' in window` are false. jQuery 1.x reads
# exactly those two at load time to decide whether change and submit bubble;
# told they don't, it swaps in IE-only shims and no delegated or ancestor
# handler ever runs, although the native event bubbles fine. On Solidus's admin
# that broke the country → state swap, the payment form and the calculator
# picker (real-apps, 2026-10-14). Our upstream #3958 (10613, in the floor) gave
# Window and Document the full set; the gem used to polyfill it.
describe "Capybara::Lightpanda GlobalEventHandlers on window and document" do
  let(:session) { TestSessions::Lightpanda }

  after { session.reset_session! }

  before { session.visit("/lightpanda/global_event_handlers") }

  it "lets jQuery 1.x detect that change and submit bubble" do
    support = session.evaluate_script("window.support")

    assert support["change"], "'onchange' in window is false: jQuery 1.x would shim change"
    assert support["submit"], "'onsubmit' in window is false: jQuery 1.x would shim submit"
  end

  # Chrome 155 on desktop has none of these on window, and feature detection
  # reads them: `'ontouchstart' in window` is how libraries spot a touch device.
  it "adds nothing Chrome lacks on window" do
    refute session.evaluate_script("window.support.focusin")
    %w[ontouchstart oncopy onpaste onfullscreenchange].each do |name|
      refute session.evaluate_script("'#{name}' in window"), "window.#{name} exists; Chrome has none on desktop"
    end
  end

  it "runs window.onchange and document.onchange for a change that bubbles up" do
    session.select("Brazil", from: "country")

    assert_equal %w[document:country window:country], session.evaluate_script("window.__seen")
  end

  # A real `change` is not cancelable, so this dispatches one that is: the
  # point is the return-false contract, which keeps its slot ahead of the
  # page's later addEventListener even after reassignment.
  it "cancels a cancelable event when the handler returns false" do
    session.execute_script(<<~JS)
      window.onchange = function () { return false; };
      document.getElementById('country')
        .dispatchEvent(new Event('change', {bubbles: true, cancelable: true}));
    JS

    assert_equal [true], session.evaluate_script("window.__cancelled")
  end

  it "replaces the handler on reassignment and drops it on null" do
    session.execute_script(<<~JS)
      window.onchange = function () { window.__seen.push('second'); };
      document.onchange = null;
    JS

    session.select("Brazil", from: "country")

    assert_equal ["second"], session.evaluate_script("window.__seen")
    assert_nil session.evaluate_script("document.onchange")
  end
end
