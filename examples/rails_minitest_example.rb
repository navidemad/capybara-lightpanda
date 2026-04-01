# frozen_string_literal: true

# Standalone Rails + Minitest + Capybara example for capybara-lightpanda.
# Based on: https://github.com/rails/rails/blob/main/guides/bug_report_templates/action_controller.rb
#
# Run: ruby examples/rails_minitest_example.rb

require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"

  gem "rails"
  gem "puma"
  gem "capybara"
  gem "capybara-lightpanda", path: File.expand_path("..", __dir__)
end

require_relative "support/plain_app"
require "minitest/autorun"
require "capybara/minitest"

# ── Test base class ────────────────────────────────────────────────

class SystemTest < Minitest::Test
  include Capybara::DSL
  include Capybara::Minitest::Assertions

  def teardown
    Capybara.reset_sessions!
  end
end

# ── Navigation tests ───────────────────────────────────────────────

class NavigationTest < SystemTest
  def test_visit_and_read_content
    visit "/"
    assert_text "Welcome"
    assert_css "#intro", text: "Test suite"
  end

  def test_follow_links
    visit "/"
    click_link "About"
    assert_css "h1", text: "About"
    assert_css "#description"
  end

  def test_back_and_forward
    visit "/"
    click_link "About"
    assert_text "About"

    go_back
    assert_text "Welcome"

    go_forward
    assert_text "About"
  end

  def test_current_path
    visit "/about"
    assert_current_path "/about"
  end
end

# ── Form tests ─────────────────────────────────────────────────────

class FormTest < SystemTest
  def test_complete_form_submission
    visit "/contacts/new"

    fill_in "Name", with: "Jane Doe"
    fill_in "Email", with: "jane@example.com"
    fill_in "Phone", with: "555-0123"
    fill_in "Notes", with: "Met at conference.\nFollow up next week."
    select "Work", from: "Category"
    choose "Phone"
    check "Newsletter"

    click_button "Save Contact"

    assert_css "h1", text: "Contact Saved"
    assert_css "#show-name", text: "Jane Doe"
    assert_css "#show-email", text: "jane@example.com"
    assert_css "#show-phone", text: "555-0123"
    assert_css "#show-notes", text: "Met at conference."
    assert_css "#show-category", text: "work"
    assert_css "#show-preferred", text: "phone"
    assert_css "#show-newsletter", text: "1"
  end

  def test_submit_and_create_another
    visit "/contacts/new"
    fill_in "Name", with: "Quick Test"
    fill_in "Email", with: "q@t.com"
    click_button "Save Contact"
    assert_css "h1", text: "Contact Saved"

    click_link "Create another"
    assert_css "h1", text: "New Contact"
  end
end

# ── Element state tests ────────────────────────────────────────────

class ElementStateTest < SystemTest
  def test_disabled_state
    visit "/contacts/new"
    assert find("#vip").disabled?
    refute find("#newsletter").disabled?
  end

  def test_tag_names
    visit "/contacts/new"
    assert_equal "form", find("#contact-form").tag_name
    assert_equal "fieldset", find("fieldset").tag_name
  end

  def test_attributes
    visit "/contacts/new"
    assert_equal "Full name", find("#name")["placeholder"]
    assert_equal "email", find("#email")["type"]
  end
end

# ── Scoped finding tests ──────────────────────────────────────────

class ScopedFindingTest < SystemTest
  def test_within_table
    visit "/dashboard"
    within "#stats" do
      rows = all(".stat")
      assert_equal 3, rows.length
      assert_css ".name", text: "Visitors"
      assert_css ".value", text: "1234"
    end
  end

  def test_within_list
    visit "/dashboard"
    within "#actions" do
      items = all(".action")
      assert_equal 3, items.length
      assert_equal %w[Export Refresh Settings], items.map(&:text)
    end
  end

  def test_nested_within
    visit "/dashboard"
    within "#stats" do
      within "tbody" do
        assert_equal 3, all("tr").length
      end
    end
  end
end

# ── XPath tests ────────────────────────────────────────────────────

class XPathTest < SystemTest
  def test_xpath_with_predicates
    visit "/dashboard"
    el = find(:xpath, "//td[contains(., 'Visitors')]")
    assert_equal "Visitors", el.text
  end

  def test_xpath_with_axes
    visit "/dashboard"
    el = find(:xpath, "//td[text()='Visitors']/following-sibling::td")
    assert_equal "1234", el.text
  end

  def test_xpath_union
    visit "/dashboard"
    els = all(:xpath, "//th | //td")
    assert_equal 8, els.length # 2 headers + 6 data cells
  end
end

# ── Dynamic content tests ─────────────────────────────────────────

class DynamicContentTest < SystemTest
  def test_add_elements
    visit "/dynamic"
    click_button "Add Item"
    click_button "Add Item"
    assert_equal 2, all(".dynamic-item").length
    assert_css ".dynamic-item", text: "Item 1"
  end

  def test_replace_content
    visit "/dynamic"
    click_button "Add Item"
    assert_css ".dynamic-item"

    click_button "Replace Content"
    assert_css "#replaced", text: "Content replaced"
    assert_no_css ".dynamic-item"
  end

  def test_toggle_section_via_class
    visit "/dynamic"
    assert_includes find("#toggleable", visible: :all)["class"], "hidden"

    click_button "Toggle Section"
    refute_includes find("#toggleable")["class"].to_s, "hidden"
    assert_text "Hidden section revealed"

    click_button "Toggle Section"
    assert_includes find("#toggleable", visible: :all)["class"], "hidden"
  end

  def test_counter
    visit "/dynamic"
    assert_css "#counter", text: "Count: 0"
    3.times { click_button "Increment" }
    assert_css "#counter", text: "Count: 3"
  end

  def test_delayed_content
    visit "/dynamic"
    click_button "Delayed Append"
    # Capybara auto-waiting finds the element after 200ms JS delay
    assert_css "#delayed-item", text: "Appeared after delay"
  end

  def test_live_search
    visit "/dynamic"
    fill_in "live-search", with: "rails"
    assert_css ".result", text: "Result for: rails"
  end
end

# ── JavaScript tests ───────────────────────────────────────────────

class JavaScriptTest < SystemTest
  def test_evaluate_script
    visit "/"
    assert_equal 2, evaluate_script("1 + 1")
  end

  def test_execute_script
    visit "/"
    execute_script("document.getElementById('intro').textContent = 'Modified'")
    assert_css "#intro", text: "Modified"
  end

  def test_complex_return_values
    visit "/"
    result = evaluate_script("({items: [1, 2], nested: {ok: true}})")
    assert_equal [1, 2], result["items"]
    assert result["nested"]["ok"]
  end
end

# ── Cookie tests ───────────────────────────────────────────────────

class CookieTest < SystemTest
  def test_set_and_read_cookie
    visit "/"
    host = URI.parse(current_url).host
    page.driver.browser.cookies.set(name: "test_cookie", value: "hello", domain: host)

    cookie = page.driver.browser.cookies.get("test_cookie")
    assert_equal "hello", cookie["value"]
  end

  def test_clear_cookies
    visit "/"
    host = URI.parse(current_url).host
    page.driver.browser.cookies.set(name: "c1", value: "v1", domain: host)
    page.driver.browser.cookies.set(name: "c2", value: "v2", domain: host)
    assert page.driver.browser.cookies.all.length >= 2

    page.driver.browser.cookies.clear
    assert_empty page.driver.browser.cookies.all
  end
end

# ── Frame tests ────────────────────────────────────────────────────

class FrameTest < SystemTest
  def test_main_page_content
    visit "/frame_host"
    assert_css "#main-title", text: "Main Page"
    assert_css "#main-text", text: "Content outside the frame"
  end

  def test_switch_into_frame
    visit "/frame_host"
    frame = find("#inner-frame")
    within_frame(frame) do
      assert_css "#frame-content", text: "Inside the iframe"
    end
    # Back in main context
    assert_css "#main-title", text: "Main Page"
  end
end

# ── Capybara matchers tests ────────────────────────────────────────

class MatcherTest < SystemTest
  def test_has_text
    visit "/"
    assert_text "Welcome"
    assert_no_text "Nonexistent content"
  end

  def test_has_css
    visit "/dashboard"
    assert_css "#stats"
    assert_no_css "#nonexistent"
  end

  def test_has_link_and_button
    visit "/"
    assert_link "About"
    assert_no_button "Save"
  end

  def test_has_field_with_value
    visit "/contacts/new"
    fill_in "Name", with: "Test"
    assert_field "Name", with: "Test"
  end

  def test_has_select
    visit "/contacts/new"
    assert_select "Category"
  end

  def test_checked_and_unchecked
    visit "/contacts/new"
    assert_unchecked_field "Newsletter"
    check "Newsletter"
    assert_checked_field "Newsletter"
  end
end

# ── Full workflow test ─────────────────────────────────────────────

class FullWorkflowTest < SystemTest
  def test_multi_page_workflow
    visit "/"
    assert_css "h1", text: "Welcome"

    click_link "About"
    assert_css "#description"

    click_link "Home"
    click_link "Dashboard"
    within "#stats" do
      assert_css ".value", text: "1234"
    end

    go_back # back to home
    click_link "New Contact"
    fill_in "Name", with: "Integration Test"
    fill_in "Email", with: "test@test.com"
    select "Personal", from: "Category"
    click_button "Save Contact"

    assert_css "h1", text: "Contact Saved"
    assert_css "#show-name", text: "Integration Test"
  end
end
