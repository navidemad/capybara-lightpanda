# frozen_string_literal: true

require_relative "../test_helper"

# Focus after `click`, and where `send_keys` types.
#
# WHY THIS MATTERS: three upstream changes regressed these on every build users
# run today (nightly and release 1.0.0), while the gem's suites stayed green:
#
# - #3702 (build 9968) dropped `focus()` from Lightpanda's click handling, and
#   CLICK_JS's mousedown is untrusted, so nothing focused the clicked field:
#   `find(...).click; page.send_keys("x")` typed into <body> and was lost.
# - #3424 (build 9234) made `Input.insertText` insert at the caret; a value
#   seeded by the `value=` attribute leaves the caret at 0, so
#   `send_keys("x")` on a pre-filled field produced "xfoo" instead of "foox".
# - #3592 (build 9646) made `focus()` a no-op on non-focusable elements, so
#   `send_keys` on a plain <div> left the previous field focused and the keys
#   landed there.
#
# Every expectation below is Chrome's behavior.
describe "Capybara::Lightpanda pointer focus and typing" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/focus") }
  after { session.reset_session! }

  def active_id
    session.evaluate_script("document.activeElement.id || document.activeElement.tagName")
  end

  describe "click" do
    it "focuses the clicked field" do
      session.find(:css, "#second").click

      assert_equal "second", active_id
    end

    it "lets page.send_keys type into the field that was clicked" do
      session.find(:css, "#second").click
      session.send_keys("typed")

      assert_equal "typed", session.find(:css, "#second").value
      assert_equal "", session.find(:css, "#first").value
    end

    it "moves focus to the body when it lands on something not focusable" do
      session.find(:css, "#first").click
      session.find(:css, "#plain").click

      assert_equal "BODY", active_id
    end

    it "keeps focus where it was when mousedown is cancelled" do
      session.find(:css, "#first").click
      session.find(:css, "#guarded-inner").click

      assert_equal "first", active_id
    end

    it "focuses a label's control, not the label" do
      session.find(:css, "#label").click

      assert_equal "labelled", active_id
    end

    it "focuses the editing host when clicking inside contenteditable" do
      session.find(:css, "#editor-child").click

      assert_equal "editor", active_id
    end

    it "does not focus a disabled control" do
      session.find(:css, "#first").click
      session.find(:css, "#disabled-button", visible: :all).click

      refute_equal "disabled-button", active_id
    end
  end

  describe "send_keys" do
    it "types after a server-rendered value, not before it" do
      session.find(:css, "#prefilled").send_keys("x")

      assert_equal "foox", session.find(:css, "#prefilled").value
    end

    it "types after a <textarea>'s initial content" do
      session.find(:css, "#area").send_keys("x")

      assert_equal "foox", session.find(:css, "#area").value
    end

    # An element that already has focus keeps its caret: page.send_keys in
    # the middle of an edit continues where the user left it.
    it "keeps the caret of an already-focused field" do
      field = session.find(:css, "#prefilled")
      session.execute_script("arguments[0].focus(); arguments[0].setSelectionRange(0, 0)", field)

      field.send_keys("x")

      assert_equal "xfoo", field.value
    end

    it "does not type into the previously focused field when the target cannot take focus" do
      session.find(:css, "#first").click
      session.find(:css, "#plain").send_keys("x")

      assert_equal "", session.find(:css, "#first").value
    end
  end

  describe "select" do
    it "does not select a disabled option" do
      session.find(:css, "#pets").find(:css, "option[value=dog]").select_option

      assert_equal "cat", session.find(:css, "#pets").value
    end

    it "does not select an option inside a disabled <optgroup>" do
      session.find(:css, "#pets").find(:css, "option[value=axolotl]", visible: :all).select_option

      assert_equal "cat", session.find(:css, "#pets").value
    end
  end
end
