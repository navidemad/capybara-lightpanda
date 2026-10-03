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
# The caret is placed explicitly where an example depends on it. The floor
# (build 9994) also guarantees our upstream fixes for the rest of the editing
# story — `.value =` moves the caret to the end (#3420), a <textarea> seeded by
# its child text can be selected (#3422) and a cancelled `beforeinput` vetoes
# the edit (#3414) — each pinned below.
describe "Capybara::Lightpanda keyboard editing" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/keyboard_editing") }
  after { session.reset_session! }

  # Focus first: `send_keys` moves the caret to the end of a field that does
  # not already have focus (WebDriver's Element Send Keys, chromedriver's
  # focus script), so a caret placed on an unfocused field would be discarded.
  def place_caret(element, at)
    session.execute_script(
      "arguments[0].focus(); arguments[0].setSelectionRange(arguments[1], arguments[1])", element, at
    )
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

  # Masked-input libraries cancel `beforeinput` to refuse a keystroke; the
  # trusted event was never cancelable before upstream #3414 (build 9217), so
  # the edit went through regardless.
  it "a cancelled beforeinput vetoes the edit" do
    field = session.find(:css, "#veto")
    place_caret(field, 3)

    field.send_keys(:backspace)

    assert_equal "abc", field.value
  end

  # `set` then correct, with no caret placement: `.value =` leaves the caret
  # at the end of the new value since upstream #3420 (build 9223), as in
  # Chrome. Below it the Backspace hit position 0 and deleted nothing.
  it "set then Backspace removes the last character" do
    field = session.find(:css, "#field")
    field.set("hello")
    field.send_keys(:backspace)

    assert_equal "hell", field.value
  end

  # A <textarea> whose text comes only from its child text node had no
  # assigned value, so `select()` reset the caret to 0 instead of selecting
  # (upstream #3422, build 9229).
  it "Backspace after select() clears a <textarea> that was never assigned" do
    area = session.find(:css, "#area")
    session.execute_script("arguments[0].focus(); arguments[0].select()", area)

    area.send_keys(:backspace)

    assert_equal "", area.value
  end

  # A Ctrl chord is a command (select-all), never text. Since upstream #3542
  # (build 9580) the browser inserts whatever a keyDown's `text` carries, so
  # the driver must not send any with Ctrl held — otherwise `[:ctrl, "a"]`
  # turned "abc" into "abca".
  it "Ctrl+A does not type an 'a'" do
    field = session.find(:css, "#field")
    place_caret(field, 3)

    field.send_keys([:ctrl, "a"])

    assert_equal "abc", field.value
  end
end
