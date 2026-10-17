# frozen_string_literal: true

require_relative "../test_helper"

# `Element#drag_to`, HTML5 half. The Capybara shared battery covers the event
# sequence, modifiers, and aliases (11/13 HTML5 examples pass there); this file
# pins the gem-specific contract those specs can't see:
#
# - the legacy (coordinate-mouse) path raises NotImplementedError LOUDLY —
#   a suite migrating from a Chrome driver must learn the drag didn't happen,
#   not get a silent no-op and a green-looking test;
# - legacy-path kwargs (`steps:`, `scroll:`) are tolerated, so a
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

  it "ignores legacy-path kwargs instead of raising ArgumentError" do
    session.find(:css, "#drag_source")
           .drag_to(session.find(:css, "#dropzone"), steps: 5, scroll: false)

    assert_equal "dropped: from-source", session.find(:css, "#log").text
  end

  # Dropzones and sortable lists hit-test on clientX/Y. Lightpanda's
  # scrollIntoView ignores `block: 'center'` and aligns the target's top
  # with the viewport's, and since upstream #3658 rects follow the scroll,
  # so the source ended up above the viewport and the first dragover
  # carried a negative clientY.
  it "keeps every dragover's client position inside the viewport" do
    session.visit("/lightpanda/drag_scroll_test")
    session.find(:css, "#drag_source").drag_to(session.find(:css, "#dropzone"))

    positions = session.all(:css, "#log .dragover", minimum: 2).map { |p| p.text.split(",").map(&:to_f) }
    height = session.evaluate_script("window.innerHeight")

    positions.each do |(x, y)|
      assert_operator x, :>=, 0
      assert_operator y, :>=, 0, "dragover at #{x},#{y} is above the viewport"
      assert_operator y, :<, height
    end
  end

  # The first dragover enters the target where the line from the source's
  # center crosses its edge. Coming from straight above, that is the top
  # edge; the port read `rectPt.top` (a DOMPoint has none), so the top/bottom
  # branches never matched and the entry point was the source's own center.
  it "enters a target below the source through its top edge" do
    session.visit("/lightpanda/drag_scroll_test")
    session.find(:css, "#drag_source").drag_to(session.find(:css, "#dropzone"))

    _, entry_y = session.all(:css, "#log .dragover", minimum: 2).first.text.split(",").map(&:to_f)
    top = session.evaluate_script("document.getElementById('dropzone').getBoundingClientRect().top")

    assert_equal top.floor, entry_y.floor
  end

  # A browser ends a drag with `drop` on a target that accepted it (cancelled
  # dragover), otherwise with `dragleave` — never both. Capybara's Selenium
  # script fired `dragleave` then `drop`, and Pragmatic drag and drop reads a
  # relatedTarget-less `dragleave` as the drag leaving the window: it clears
  # its drop targets and the drop lands on nothing.
  describe "how the drag ends" do
    before { session.visit("/lightpanda/drag_end_test") }

    def events_on(zone)
      session.find(:css, "#drag_source").drag_to(session.find(:css, "##{zone}"), html5: true)
      session.all(:css, "#log .#{zone}", minimum: 3).map(&:text)
    end

    it "drops on a target that accepted the drag, without a dragleave" do
      assert_equal %w[dragenter dragover dragover drop], events_on("accepting")
    end

    it "leaves a target that refused the drag, without a drop" do
      assert_equal %w[dragenter dragover dragover dragleave], events_on("refusing")
    end
  end
end
