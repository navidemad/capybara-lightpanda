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
  ["a\u200Bb", "a\u200Eb", "a\u200Fb", "a\u2028b\u2029c", "ΟΣ"].each do |text|
    it "preserves literal Unicode matches for #{text.dump}" do
      session.execute_script(
        "document.body.innerHTML = '<div></div>'; document.querySelector('div').textContent = arguments[0]", text
      )
      needle = text == "ΟΣ" ? "Σ" : text
      assert_equal text, session.find("div", text: needle, wait: 0).text
      next if text == "ΟΣ"

      assert_equal text, session.find("div", exact_text: text, wait: 0).text
    end
  end

  it "preserves visible zero-width marks with explicit and default whitespace normalization" do
    text = "a\u200Bb"
    session.execute_script(
      "document.body.innerHTML = '<div></div>'; document.querySelector('div').textContent = arguments[0]", text
    )
    previous = Capybara.default_normalize_ws
    assert_equal text, session.find("div", text: text, normalize_ws: true, wait: 0).text
    Capybara.default_normalize_ws = true
    assert_equal text, session.find("div", text: text, wait: 0).text
  ensure
    Capybara.default_normalize_ws = previous
  end

  it "does not reuse visibility from before lazy result enumeration" do
    session.execute_script("document.body.innerHTML = '<div id=x>x</div><div id=y>y</div>'")
    result = session.all("div", minimum: 1)
    session.execute_script("document.querySelector('#y').style.display = 'none'")

    assert_equal(["x"], result.map { |node| node[:id] })
  end

  it "does not reuse styles from before lazy result enumeration" do
    session.execute_script("document.body.innerHTML = '<div id=x>x</div><div id=y>y</div>'")
    result = session.all("div", style: { "display" => "block" }, minimum: 1, visible: :all)
    session.execute_script("document.querySelector('#y').style.display = 'inline'")

    assert_equal(["x"], result.map { |node| node[:id] })
  end

  it "does not reuse geometry from before lazy result enumeration" do
    session.execute_script(<<~JS)
      document.body.innerHTML = '<p>anchor</p><div id=x>x</div><div id=y>y</div>';
      window.moved = false;
      document.querySelector('p').getBoundingClientRect = function() {
        return {top: 0, bottom: 5, left: 0, right: 5};
      };
      document.querySelectorAll('div').forEach(function(el) {
        el.getBoundingClientRect = function() {
          var top = el.id === 'y' && window.moved ? 0 : 20;
          return {top: top, bottom: top + 5, left: 0, right: 5};
        };
      });
    JS
    result = session.all("div", below: session.find("p"), minimum: 1, visible: :all)
    session.execute_script("window.moved = true")

    assert_equal(["x"], result.map { |node| node[:id] })
  end

  it "uses the live ShadowRoot tag name for XPath self results" do
    session.execute_script(<<~JS)
      document.body.innerHTML = '<div id=host></div>';
      document.querySelector('#host').attachShadow({mode: 'open'});
    JS

    assert_equal "ShadowRoot", session.find("#host").shadow_root.find(:xpath, ".", visible: :all).tag_name
  end

  it "does not let page array overrides reorder caches or drop matches" do
    session.execute_script(<<~JS)
      document.body.innerHTML = '<div id=hidden hidden>needle</div><div id=shown>needle</div><div id=other>other</div>';
      var originalMap = Array.prototype.map;
      Array.prototype.map = function(fn) { return originalMap.call(this, fn).reverse(); };
      Array.prototype.filter = function() { return []; };
    JS

    assert_equal(%w[shown other], session.all("div").map { |node| node[:id] })
    assert_equal "shown", session.find("div", text: "needle", wait: 0)[:id]
  end

  it "ignores a page serializer that forges visibility and tag names" do
    session.execute_script(<<~JS)
      document.body.innerHTML = '<div hidden>needle</div>';
      JSON.stringify = function() { return '[{"visible":"false","tag_name":17}]'; };
    JS

    refute session.has_css?("div", visible: true, wait: 0)
    assert_equal "div", session.find("div", visible: :all).tag_name
  end

  it "uses original casing and serialization intrinsics after page overrides" do
    session.execute_script(<<~JS)
      document.body.innerHTML = '<div>needle</div>';
      String.prototype.toLowerCase = function() { throw new Error('page override'); };
      JSON.stringify = function() { throw new Error('page override'); };
      Object.freeze(Array.prototype);
    JS

    assert_equal "div", session.find("div", text: "needle", wait: 0).tag_name
  end
end
