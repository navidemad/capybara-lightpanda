# frozen_string_literal: true

require_relative "../test_helper"

# `Node#click` dispatches the full pointer sequence, not a bare `click`.
#
# Widgets like select2 v3 open their dropdown from a `mousedown` listener
# (select2 binds "mousedown touchstart" on the choice container, never
# "click"), so a JS-driven click that skips mousedown leaves them inert —
# observed as the `input.select2-input.select2-focused` failures across the
# solidus admin suite. Chrome's native click is always mousedown -> mouseup
# -> click; CLICK_JS must match.
describe "Capybara::Lightpanda::Node#click event sequence" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/click_events_test") }
  after { session.reset_session! }

  it "fires mousedown, mouseup, click in order" do
    session.find(:css, "#btn").click

    assert_equal "mousedown mouseup click", session.find(:css, "#seq").text
  end

  it "opens a select2-style widget that listens on mousedown" do
    refute session.has_css?("#panel", wait: 0)

    session.find(:css, "#widget").click

    assert_equal "Option A", session.find(:css, "#option").text
  end

  # Chrome's centred click on a multi-select2 lands on the choices list (or
  # its search input), never inside the first existing choice, which select2
  # deliberately ignores. Descending to the first visible child at every level
  # landed inside "Brand 1", so the dropdown never opened (solidus
  # products/edit/taxons_spec.rb).
  it "opens a multi select2 that already holds a choice" do
    refute session.has_css?("#multi-drop", wait: 0)

    session.find(:css, "#multi").click

    assert_equal "Clothing", session.find(:css, "#multi-drop").text
  end

  # A select2 v4 with allowClear renders the value as `<span>×</span>Alpha`.
  # A centred pointer lands on the value's text, so the dropdown opens and the
  # selection stays. Descending into the first child pressed the "×": the
  # value was cleared, `change` fired, and an app that reloads on change threw
  # the dropdown away before the test could pick an option.
  it "opens a clearable select2 without pressing its clear button" do
    session.find(:css, "#clearable").click

    assert_equal "Beta", session.find(:css, "#clearable-drop").text
    assert_equal "", session.find(:css, "#clearable-log", visible: :all).text(:all)
  end

  it "opens a clearable select2 clicked on its rendered value" do
    session.find(:css, "#clearable-rendered").click

    assert_equal "Beta", session.find(:css, "#clearable-drop").text
    assert_equal "", session.find(:css, "#clearable-log", visible: :all).text(:all)
  end

  # The "×" itself stays clickable: the text rule must not swallow a click
  # aimed at it.
  it "still presses the clear button when it is the target" do
    session.find(:css, "#clearable-x").click

    assert_equal "cleared", session.find(:css, "#clearable-log").text
  end

  # innerText separates table cells with a tab, and Chrome drivers return it:
  # suites assert "Total due\t$0.00". Collapsing every run of blanks to one
  # space turned the tab into a space.
  it "keeps the tab between table cells in text" do
    assert_equal "Total due\t$0.00", session.find(:css, "#total-row").text
    assert session.has_text?("Total due\t$0.00", wait: 0)
  end
end
