# frozen_string_literal: true

require_relative "../test_helper"

# `Capybara::Element#hover` against Lightpanda.
#
# Capybara's own `#hover` shared example (`:hover` capability, in `capybara_skip`)
# asserts a CSS `:hover` reveal: `.box:hover .hidden { display: block }` becoming
# visible after hovering. Lightpanda can't satisfy that — CSS `:hover` state is
# driven by a real pointer position, which a headless/layout-free engine has no
# notion of. So the reveal half stays unsupported.
#
# But the gem's `Node#hover` dispatches real `mouseover` + `mouseenter` events
# (`node.rb` -> HOVER_JS), and JS listeners for both DO fire. That half has no
# shared-spec coverage (the whole describe block is skipped on the unreachable
# CSS-reveal case), so we lock the event-dispatch behavior in here.
describe "Capybara::Lightpanda::Node#hover" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/hover_test") }
  after { session.reset_session! }

  it "fires a mouseover event on the hovered element" do
    assert_empty session.find(:css, "#log").text

    session.find(:css, "#box").hover

    assert_equal "mouseover-fired", session.find(:css, "#log").text
  end

  # Regression guard: hover used to dispatch `mouseover` only. `mouseenter`
  # doesn't bubble, so a `mouseenter->menu#open` Stimulus action (the dominant
  # hover-menu idiom, and what Floating UI / tippy bind) never fired and the
  # menu stayed closed with no error — the failure surfaced far away, as
  # ElementNotFound on the menu item.
  it "also fires a mouseenter event, which does not bubble" do
    assert_empty session.find(:css, "#enter_log").text

    session.find(:css, "#box").hover

    assert_equal "mouseenter-fired", session.find(:css, "#enter_log").text
  end

  it "does NOT trigger CSS :hover reveal (no pointer state in Lightpanda)" do
    # Documents the browser limitation: dispatching `mouseover` is not the same
    # as the pointer entering the element, so `.box:hover` never matches. If a
    # future Lightpanda build wires pointer-driven :hover, this assertion flips
    # and the upstream `:hover` capability becomes a real un-skip candidate.
    session.find(:css, "#box").hover

    refute session.find(:css, "#reveal", visible: false).visible?,
           "CSS :hover reveal unexpectedly worked — re-evaluate the :hover skip"
  end
end
