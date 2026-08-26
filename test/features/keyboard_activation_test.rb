# frozen_string_literal: true

require_relative "../test_helper"

# Keyboard-driven activation, upstream #3264 (build >= 8842, in the floor).
#
# CDP `Input.dispatchKeyEvent` builds a *trusted* KeyboardEvent, so
# `frame/user_input.zig` now does two things it never did before:
#
#   1. fires a `keypress` after a printable-or-Enter keydown (no ctrl/meta),
#      and abandons the rest of the default action if a listener cancels it;
#   2. synthesizes a trusted PointerEvent `click` for Enter on
#      <button> / <a href> / input[type=button|submit|reset|image], and for
#      Space *keyup* on those plus checkbox/radio.
#
# Because `PointerEvent.Proto = MouseEvent`, that click is a real activation
# event — it runs `findClickActivationTarget` + `handleClick`, i.e. the same
# default-action machinery a mouse click gets. So `send_keys(:enter)` and
# `send_keys(:space)` went from silent no-ops to genuine activation.
#
# WHY THIS MATTERS ENOUGH TO PIN: the gem contributes no code to any of it,
# which is exactly what makes it fragile. `Node#send_keys` just focuses and
# hands the keys to CDP; if upstream reverts the trusted-event synthesis, or
# if the gem ever starts sending CDP `type: "char"` (which would make the
# browser's keypress a *duplicate* of one we send ourselves), these examples
# are the only thing standing between that and a silently dead
# keyboard-accessibility path in every downstream suite.
describe "Capybara::Lightpanda keyboard activation" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/keyboard_activation") }
  after { session.reset_session! }

  it "activates a <button> on Enter" do
    assert_empty session.find(:css, "#log").text

    session.find(:css, "#btn").send_keys(:enter)

    assert_equal "button-clicked", session.find(:css, "#log").text
  end

  # Space activates on *keyup*, not keydown — a separate upstream code path
  # (`handleKeyup` -> `spaceActivates`) wired through EventManager, so it can
  # regress independently of the Enter path above.
  it "activates a <button> on Space" do
    session.find(:css, "#btn").send_keys(:space)

    assert_equal "button-clicked", session.find(:css, "#log").text
  end

  # The anchor assertion deliberately stops at "the activation event arrived".
  # Whether Lightpanda then *navigates* is upstream issue #3179, still open —
  # pinning navigation here would couple this file to an unrelated bug.
  it "dispatches an activation click to an <a href> on Enter" do
    session.find(:css, "#link").send_keys(:enter)

    assert_equal "link-clicked", session.find(:css, "#log").text
  end

  # Space on a checkbox goes all the way through the activation behavior
  # (EventManager's ActivationState toggles `checked` before dispatch and
  # rolls it back if a listener cancels), so this asserts real state, not a
  # log line. Toggling exactly once also proves keydown and keyup aren't both
  # firing a click.
  it "toggles a checkbox on Space, exactly once" do
    checkbox = session.find(:css, "#cb")
    refute checkbox.checked?, "fixture should start unchecked"

    checkbox.send_keys(:space)

    assert checkbox.checked?, "expected Space to check the box (#3264)"

    checkbox.send_keys(:space)

    refute checkbox.checked?, "expected a second Space to uncheck it"
  end

  # A no-regression guard rather than a #3264 detector: Enter on an <input>
  # already submitted before 8842, via `handleKeydown`'s own `submitForm`
  # branch. What #3264 changed is the *route* — input[type=submit] is in
  # `enterActivates`, so Enter now returns early through the click activation
  # and never reaches that branch. Same outcome, different machinery, which is
  # precisely the kind of swap that quietly loses a form submission.
  # (Verified: this is the one example in the file that also passes on 8688.)
  it "submits the form on Enter in the submit button" do
    session.find(:css, "#submit-btn").send_keys(:enter)

    assert_equal "/lightpanda/other", URI.parse(session.current_url).path
    assert_includes session.current_url, "q=hello"
  end

  # A printable keydown now carries a `keypress` with it. Plain strings go
  # through `Input.insertText` (no key events at all), so a *modified* char is
  # what exercises `Input.dispatchKeyEvent` — and shift is neither ctrl nor
  # meta, so the keypress is not suppressed.
  it "fires keypress for a printable key" do
    session.find(:css, "#field").send_keys([:shift, "a"])

    assert_equal "keypress:A", session.find(:css, "#keypress-log").text
  end
end
