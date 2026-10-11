# frozen_string_literal: true

require_relative "../test_helper"

# Scripts run inside `within_frame` run in the frame's document.
#
# `Runtime.evaluate` and the document-bound `callFunctionOn` behind
# `execute_script` / `evaluate_script` / `evaluate_async_script` target the top
# document unless told otherwise, so inside `within_frame` they read and
# mutated the page around the frame: `evaluate_script("location.href")` gave
# the page URL. Chrome drivers (Selenium, Cuprite) run them in the frame.
# Capybara's shared battery never scripts inside a frame, so nothing caught
# it. The scripts now carry the frame's default execution context.
describe "Capybara::Lightpanda scripts inside within_frame" do
  let(:session) { TestSessions::Lightpanda }

  after { session.reset_session! }

  before { session.visit("/lightpanda/with_versioned_frame") }

  it "evaluates in the frame's document" do
    session.within_frame("versioned-frame") do
      assert_equal "Frame v1", session.evaluate_script("document.title")
      assert_match %r{/lightpanda/frame_versioned\?v=1\z}, session.evaluate_script("location.href")
    end

    assert_equal "Page with Versioned Frame", session.evaluate_script("document.title")
  end

  it "binds arguments in the frame's document" do
    session.within_frame("versioned-frame") do
      version = session.find(:css, "#version")

      assert_equal "v1 ?v=1", session.evaluate_script("arguments[0].textContent + ' ' + location.search", version)
    end
  end

  it "executes in the frame's document, leaving the page alone" do
    session.within_frame("versioned-frame") do
      session.execute_script("document.getElementById('version').textContent = 'changed'")
      session.execute_script("document.title = arguments[0]", "retitled")

      assert session.has_css?("#version", text: "changed")
      assert_equal "retitled", session.driver.frame_title
    end

    assert_equal "Page with Versioned Frame", session.title
  end

  it "runs async scripts in the frame's document" do
    session.within_frame("versioned-frame") do
      title = session.evaluate_async_script(
        "var done = arguments[0]; setTimeout(function() { done(document.title) }, 10)"
      )

      assert_equal "Frame v1", title
    end
  end

  # The script is compiled by the frame's eval but called from the top
  # context, where Lightpanda keeps every node handle — so a node a frame
  # script returns works as an argument and as an element, like any other.
  it "returns nodes usable as arguments and elements" do
    session.within_frame("versioned-frame") do
      version = session.evaluate_script("document.getElementById('version')")

      assert_equal "v1", session.evaluate_script("arguments[0].textContent", version)
      assert_equal "v1", version.text
    end
  end

  it "keeps var globals across calls and allows a const to be redeclared" do
    session.within_frame("versioned-frame") do
      session.execute_script("var counter = 41")
      session.execute_script("const step = 1; counter += step")
      session.execute_script("const step = 1; counter += step")

      assert_equal 43, session.evaluate_script("counter")
    end

    assert_nil session.evaluate_script("window.counter")
  end

  it "follows the frame to its new document after it navigates" do
    session.within_frame("versioned-frame") do
      session.click_link("Next")
      assert session.has_css?("#version", text: "v2")

      assert_equal "Frame v2", session.evaluate_script("document.title")
    end
  end
end
