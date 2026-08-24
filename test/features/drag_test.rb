# frozen_string_literal: true

require_relative "../test_helper"

# `Element#drag_to`, HTML5 half. The Capybara shared battery covers the event
# sequence, modifiers, and aliases (11/13 HTML5 examples run there); this file
# pins the gem-specific contract those specs can't see:
#
# - the legacy (coordinate-mouse) path raises NotImplementedError LOUDLY —
#   a suite migrating from Selenium/Cuprite must learn the drag didn't happen,
#   not get a silent no-op and a green-looking test;
# - Cuprite's legacy-path kwargs (`steps:`, `scroll:`) are tolerated, so a
#   migrated `drag_to(target, steps: 5)` doesn't ArgumentError before the
#   HTML5 simulation even runs.
describe "Capybara::Lightpanda::Node#drag_to" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/drag_test") }
  after { session.reset_session! }

  it "carries dragstart's setData payload through to the drop handler" do
    session.find(:css, "#drag_source").drag_to(session.find(:css, "#dropzone"))

    assert_equal "dropped: from-source", session.find(:css, "#log").text
  end

  it "raises NotImplementedError for a non-draggable source (legacy mouse path)" do
    err = assert_raises(NotImplementedError) do
      session.find(:css, "#not_draggable").drag_to(session.find(:css, "#dropzone"))
    end

    assert_match(/html5: true/, err.message)
  end

  it "ignores Cuprite's legacy-path kwargs instead of raising ArgumentError" do
    session.find(:css, "#drag_source")
           .drag_to(session.find(:css, "#dropzone"), steps: 5, scroll: false)

    assert_equal "dropped: from-source", session.find(:css, "#log").text
  end
end
