# frozen_string_literal: true

require_relative "../test_helper"

# Capybara only sends finder hints to a find_css/find_xpath that accepts them;
# without them it asks every candidate for its visibility and text in separate
# CDP calls — thousands of round-trips for one `find("li", text:)` on a long
# list. The hints must cut those calls without changing a single result.
# Counts every CDP command the block sends, through a prepended module so the
# real Client#command still runs.
module FinderHintsCommandCounter
  attr_accessor :command_count

  def command(...)
    self.command_count = command_count.to_i + 1
    super
  end
end

describe "Capybara finder hints" do
  let(:session) { TestSessions::Lightpanda }
  let(:client) { session.driver.browser.client }

  before { session.visit("/lightpanda/finder_hints") }
  after { session.reset_session! }

  def count_commands
    client.singleton_class.prepend(FinderHintsCommandCounter) unless client.singleton_class < FinderHintsCommandCounter
    client.command_count = 0
    yield
    client.command_count
  end

  it "finds by text in a handful of calls instead of one per node" do
    found = nil
    calls = count_commands { found = session.find(:css, "li", text: "Item 298") }

    assert_equal "Item 298", found.text
    assert_operator calls, :<, 20, "find(text:) made #{calls} CDP calls"
  end

  it "keeps Capybara's visibility semantics" do
    assert_equal 200, session.all(:css, "li").size
    assert_equal 300, session.all(:css, "li", visible: :all).size
    assert_equal 100, session.all(:css, "li", visible: :hidden).size
    assert_equal 1, session.all(:css, "li", text: "Item 2", count: 1, exact_text: true).size
  end

  it "does not drop a node whose text Capybara would match" do
    # Hidden: its text is only in textContent, never in the visible text.
    assert_equal "li", session.find(:css, "li", text: "Item 3", exact_text: true, visible: :hidden).tag_name
    session.assert_selector(:css, "#spaced", text: "Spaced out words")
    session.assert_selector(:xpath, "//li", text: "Item 299")
  end

  it "answers position hints the way the node would" do
    first = session.find(:css, "#list li", match: :first)

    refute_empty session.all(:css, "#list li", below: first, minimum: 1)
  end
end
