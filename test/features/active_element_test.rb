# frozen_string_literal: true

require_relative "../test_helper"

# `Capybara::Session#active_element` against Lightpanda.
#
# Capybara's own `#active_element` shared examples run too (Tab traversal
# works since upstream #2699); these pin the finer-grained explicit-focus
# paths — a JS `.focus()`, and `fill_in` focusing the field it fills — that
# `Driver#active_element` reads back through `document.activeElement`.
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
