# frozen_string_literal: true

require_relative "../test_helper"

# `Capybara::Session#active_element` against Lightpanda.
#
# Capybara's own `#active_element` shared examples are skipped (the `:active_element`
# capability is in `capybara_skip`) because the describe block bundles a
# Tab-traversal case — `send_keys(:tab)` walking focus across `[tabindex]`
# elements — that Lightpanda can't satisfy: it has no keyboard focus-traversal
# pipeline, so synthetic Tab events don't move `document.activeElement`.
#
# But explicit focus DOES work: a JS `.focus()` call, or a public-API
# interaction that focuses a control (`fill_in` runs `this.focus()` via
# SET_VALUE_JS), updates `document.activeElement`, and `Driver#active_element`
# reads it back faithfully (`browser.rb` -> `evaluate_with_ref("document.activeElement")`).
# That working slice has no shared-spec coverage, so we lock it in here.
describe "Capybara::Lightpanda#active_element" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/form") }
  after { session.reset_session! }

  it "returns a Capybara::Node::Element" do
    assert_kind_of Capybara::Node::Element, session.active_element
  end

  it "defaults to <body> before anything is focused" do
    assert session.active_element.matches_selector?(:css, "body"),
           "expected the body to be active before any focus, got #{session.active_element.tag_name}"
  end

  it "reflects an explicit JS .focus() on a field" do
    session.execute_script("document.querySelector('#form_first_name').focus()")

    assert_equal "form_first_name", session.active_element[:id]
  end

  it "tracks focus moving between fields" do
    session.execute_script("document.querySelector('#form_first_name').focus()")
    assert_equal "form_first_name", session.active_element[:id]

    session.execute_script("document.querySelector('#form_last_name').focus()")
    assert_equal "form_last_name", session.active_element[:id]
  end

  it "reflects focus set through a public Capybara interaction (fill_in focuses the field)" do
    session.fill_in("form_first_name", with: "Jane")

    assert_equal "form_first_name", session.active_element[:id]
  end
end
