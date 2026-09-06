# frozen_string_literal: true

require_relative "../test_helper"

# Keyboard-driven editing, upstream #3298 (build >= 8937, in the floor).
#
# A Backspace or Delete keydown that reaches an <input>/<textarea> through
# CDP `Input.dispatchKeyEvent` now runs `frame/user_input.zig#editKey`:
# a *trusted*, cancelable `beforeinput` first, then — unless a listener
# cancelled it — the `text_entry.zig` mixin removes one character on the
# caret's side and fires `input`, both events carrying inputType
# `deleteContentBackward` / `deleteContentForward`. Below 8937 the keys were
# dead: `send_keys(:backspace)` was a silent no-op.
#
# WHY THIS MATTERS ENOUGH TO PIN: the gem contributes nothing to it (the same
# fragility as keyboard_activation_test.rb). `Node#send_keys` focuses the
# control and hands the key to CDP; if upstream regresses, every downstream
# spec that "types then corrects" passes by leaving the wrong value in place.
#
# Caret placement is explicit in every example. Lightpanda's `.value =`
# setter does NOT move the caret to the end the way Chrome's does (Input.zig
# `setValue` never touches `_selection_start`), so after Capybara's `set` the
# caret still sits at 0 and a Backspace there is a legitimate no-op. Setting
# the range via `setSelectionRange` is what a suite has to do today; if
# upstream ever aligns the setter with the spec, these examples stay valid.
describe "Capybara::Lightpanda keyboard editing" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/keyboard_editing") }
  after { session.reset_session! }

  def place_caret(element, at)
    session.execute_script("arguments[0].setSelectionRange(arguments[1], arguments[1])", element, at)
  end

  it "Backspace removes the character before the caret in an <input>" do
    field = session.find(:css, "#field")
    place_caret(field, 3)

    field.send_keys(:backspace)

    assert_equal "ab", field.value
    assert_equal "beforeinput:deleteContentBackward;input:deleteContentBackward;",
                 session.find(:css, "#log").text
  end

  # Forward deletion is its own branch of `innerDelete` (caret stays put,
  # the character *after* it goes), so it can regress independently.
  it "Delete removes the character after the caret in an <input>" do
    field = session.find(:css, "#field")
    place_caret(field, 0)

    field.send_keys(:delete)

    assert_equal "bc", field.value
    assert_equal "beforeinput:deleteContentForward;input:deleteContentForward;",
                 session.find(:css, "#log").text
  end

  # <textarea> reaches `editKey` through a different dispatch arm than
  # <input> (user_input.zig branches on the element type before sharing the
  # TextEntry mixin), and a full selection takes `howSelected`'s `.full` path
  # rather than the caret arithmetic above.
  #
  # The value is assigned before selecting on purpose: `text_entry.zig`'s
  # `select`/`setSelectionRange` read the control's *assigned* `_value`, and a
  # <textarea> whose text came from its child text node has none, so on such a
  # control they silently reset the caret to 0 instead of moving it. `set`
  # then correct is the shape a suite actually uses, and it assigns the value.
  it "Backspace on a fully selected <textarea> clears it" do
    area = session.find(:css, "#area")
    area.set("abc")
    # `set` fires its own (untyped) `input`; only the keystroke's events matter.
    session.execute_script("document.getElementById('log').textContent = ''")
    session.execute_script("arguments[0].select()", area)

    area.send_keys(:backspace)

    assert_equal "", area.value
    assert_equal "beforeinput:deleteContentBackward;input:deleteContentBackward;",
                 session.find(:css, "#log").text
  end

  # Deliberately NOT pinned: `beforeinput.preventDefault()` vetoing the edit.
  # user_input.zig asks for a cancelable beforeinput, but
  # InputEvent.initWithTrusted hardcodes `_cancelable = false`, so the trusted
  # event reports cancelable=false and the edit goes through regardless
  # (verified 2026-09-06 on nightly 9204 and main 9213). Masked-input
  # libraries relying on the veto do not work yet — see
  # .claude/rules/lightpanda-io.md, keyboard editing bullet.
end
