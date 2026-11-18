# frozen_string_literal: true

require_relative "../test_helper"

# Key events around text entry, from a beta suite that passed on Cuprite and
# failed here.
#
# Selenium and Cuprite both type `fill_in`, so a page can filter a table or
# open an autocomplete from a `keyup` listener alone and every suite written
# against them passes. This driver wrote the value and fired `input` +
# `change`; `send_keys` went through `Input.insertText`, which fires `input`
# only. Either way the listener never ran and the table stayed unfiltered
# ("Showing 1 to 57 of 57 entries"), with nothing pointing at the cause.
describe "Capybara::Lightpanda key events on text entry" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/key_listeners") }
  after { session.reset_session! }

  it "runs a keyup-only filter on fill_in" do
    session.fill_in "Province", with: "NT"

    session.assert_selector(:css, "#info", text: "Showing 1 of 3 entries")
  end

  it "runs a keyup-only filter when fill_in clears the field" do
    session.fill_in "Province", with: "NT"
    session.fill_in "Province", with: ""

    session.assert_selector(:css, "#info", text: "Showing 3 of 3 entries")
  end

  it "sends keydown, keypress and keyup for each typed character" do
    session.find(:css, "#filter").send_keys("NT")

    assert_equal "keydown:N keypress:N keyup:N keydown:T keypress:T keyup:T", session.find(:css, "#keys").text
    assert_equal "NT", session.find(:css, "#filter").value
    session.assert_selector(:css, "#info", text: "Showing 1 of 3 entries")
  end

  # An iframe whose <body> is the editing host: TinyMCE, CKEditor 4. A <body>
  # is `activeElement` whenever nothing has focus, so the driver took it for
  # focused and never focused the <iframe>; Lightpanda sends keys down the
  # chain of focused iframes, so they went to the top page instead.
  describe "an iframe whose body is the editing host" do
    it "types after the existing text" do
      session.within_frame("editor") do
        session.find(:css, "body").send_keys(" edited")

        assert_equal "Draft edited", session.find(:css, "body").text
      end
    end

    it "does not type into the field the top page had focused" do
      session.find(:css, "#top-field").click
      session.within_frame("editor") { session.find(:css, "body").send_keys("x") }

      assert_equal "", session.find(:css, "#top-field").value
      session.within_frame("editor") { assert_equal "Draftx", session.find(:css, "body").text }
    end

    it "continues at the caret on a second send_keys" do
      session.within_frame("editor") do
        body = session.find(:css, "body")
        body.send_keys("a")
        body.send_keys("b")

        assert_equal "Draftab", body.text
      end
    end

    # Suites target the paragraph the editor renders, not the host. A <p>
    # can't take focus; in Chrome its editing host does.
    it "types into a paragraph inside the editing host" do
      session.within_frame("editor") do
        session.find(:css, "p").send_keys("!")

        assert_equal "Draft!", session.find(:css, "body").text
      end
    end
  end
end
