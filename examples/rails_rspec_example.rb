# frozen_string_literal: true

# Standalone Rails + RSpec + Capybara example for capybara-lightpanda.
# Based on: https://github.com/rails/rails/blob/main/guides/bug_report_templates/action_controller.rb
#
# Run: ruby examples/rails_rspec_example.rb

require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"

  gem "rails"
  gem "puma"
  gem "rspec-rails"
  gem "capybara"
  gem "capybara-lightpanda", path: File.expand_path("..", __dir__)
end

require_relative "support/plain_app"
require "rspec/autorun"
require "capybara/rspec"

# ── Tests ──────────────────────────────────────────────────────────

RSpec.describe "capybara-lightpanda system tests", type: :feature do
  # ── Navigation ─────────────────────────────────────────────────

  describe "navigation" do
    it "visits pages and reads content" do
      visit "/"
      expect(page).to have_css("h1", text: "Welcome")
      expect(page).to have_css("#intro", text: "Test suite")
    end

    it "follows links" do
      visit "/"
      click_link "About"
      expect(page).to have_css("h1", text: "About")
      expect(page).to have_css("#description")
    end

    it "navigates back and forward" do
      visit "/"
      click_link "About"
      expect(page).to have_css("h1", text: "About")

      go_back
      expect(page).to have_css("h1", text: "Welcome")

      go_forward
      expect(page).to have_css("h1", text: "About")
    end

    it "reads page title and current URL" do
      visit "/about"
      expect(page).to have_current_path("/about")
    end
  end

  # ── Form submission with all input types ───────────────────────

  describe "form submission" do
    before { visit "/contacts/new" }

    it "fills and submits a complete form" do
      fill_in "Name", with: "Jane Doe"
      fill_in "Email", with: "jane@example.com"
      fill_in "Phone", with: "555-0123"
      fill_in "Notes", with: "Met at conference.\nFollow up next week."
      select "Work", from: "Category"
      choose "Phone"
      check "Newsletter"

      click_button "Save Contact"

      expect(page).to have_css("h1", text: "Contact Saved")
      expect(find("#show-name")).to have_text("Jane Doe")
      expect(find("#show-email")).to have_text("jane@example.com")
      expect(find("#show-phone")).to have_text("555-0123")
      expect(find("#show-notes")).to have_text("Met at conference.")
      expect(find("#show-category")).to have_text("work")
      expect(find("#show-preferred")).to have_text("phone")
      expect(find("#show-newsletter")).to have_text("1")
    end

    it "submits and navigates back to create another" do
      fill_in "Name", with: "Quick Test"
      fill_in "Email", with: "q@t.com"
      click_button "Save Contact"
      expect(page).to have_css("h1", text: "Contact Saved")

      click_link "Create another"
      expect(page).to have_css("h1", text: "New Contact")
    end
  end

  # ── Element inspection ─────────────────────────────────────────

  describe "element state" do
    before { visit "/contacts/new" }

    it "reads disabled state" do
      expect(find("#vip")).to be_disabled
      expect(find("#newsletter")).not_to be_disabled
    end

    it "reads tag names" do
      expect(find("#contact-form").tag_name).to eq("form")
      expect(find("fieldset").tag_name).to eq("fieldset")
    end

    it "reads attributes" do
      expect(find("#name")["placeholder"]).to eq("Full name")
      expect(find("#email")["type"]).to eq("email")
    end
  end

  # ── Scoped finding with `within` ───────────────────────────────

  describe "scoped finding" do
    before { visit "/dashboard" }

    it "finds elements within a table" do
      within "#stats" do
        rows = all(".stat")
        expect(rows.length).to eq(3)
        expect(rows[0]).to have_css(".name", text: "Visitors")
        expect(rows[0]).to have_css(".value", text: "1234")
      end
    end

    it "scopes finding to a specific container" do
      within "#actions" do
        items = all(".action")
        expect(items.length).to eq(3)
        expect(items.map(&:text)).to eq(%w[Export Refresh Settings])
      end
    end

    it "nested within blocks" do
      within "#stats" do
        within "tbody" do
          expect(all("tr").length).to eq(3)
        end
      end
    end
  end

  # ── XPath selectors ────────────────────────────────────────────

  describe "XPath" do
    before { visit "/dashboard" }

    it "finds by XPath with predicates" do
      el = find(:xpath, "//td[contains(., 'Visitors')]")
      expect(el.text).to eq("Visitors")
    end

    it "finds by XPath with axes" do
      el = find(:xpath, "//td[text()='Visitors']/following-sibling::td")
      expect(el.text).to eq("1234")
    end

    it "counts with XPath union" do
      els = all(:xpath, "//th | //td")
      expect(els.length).to eq(8) # 2 headers + 6 data cells
    end
  end

  # ── Dynamic content & JS interaction ───────────────────────────

  describe "dynamic content" do
    before { visit "/dynamic" }

    it "adds elements dynamically" do
      click_button "Add Item"
      click_button "Add Item"
      expect(all(".dynamic-item").length).to eq(2)
      expect(first(".dynamic-item")).to have_text("Item 1")
    end

    it "replaces content" do
      click_button "Add Item"
      expect(page).to have_css(".dynamic-item")

      click_button "Replace Content"
      expect(page).to have_css("#replaced", text: "Content replaced")
      expect(page).to have_no_css(".dynamic-item")
    end

    it "toggles a section via class" do
      expect(find("#toggleable", visible: :all)["class"]).to include("hidden")

      click_button "Toggle Section"
      expect(find("#toggleable")["class"]).not_to include("hidden")
      expect(find("#toggleable")).to have_text("Hidden section revealed")

      click_button "Toggle Section"
      expect(find("#toggleable", visible: :all)["class"]).to include("hidden")
    end

    it "increments a counter" do
      expect(find("#counter")).to have_text("Count: 0")
      3.times { click_button "Increment" }
      expect(find("#counter")).to have_text("Count: 3")
    end

    it "waits for delayed content" do
      click_button "Delayed Append"
      # Capybara's automatic waiting should find the element after 200ms delay
      expect(page).to have_css("#delayed-item", text: "Appeared after delay")
    end

    it "live search with input events" do
      fill_in "live-search", with: "rails"
      expect(page).to have_css(".result", text: "Result for: rails")
    end
  end

  # ── JavaScript execution ───────────────────────────────────────

  describe "JavaScript" do
    it "evaluates expressions" do
      visit "/"
      expect(evaluate_script("1 + 1")).to eq(2)
      expect(evaluate_script("document.title")).to be_a(String)
    end

    it "executes scripts that modify the DOM" do
      visit "/"
      execute_script("document.getElementById('intro').textContent = 'Modified'")
      expect(find("#intro")).to have_text("Modified")
    end

    it "returns complex objects" do
      visit "/"
      result = evaluate_script("({items: [1, 2], nested: {ok: true}})")
      expect(result["items"]).to eq([1, 2])
      expect(result["nested"]["ok"]).to be true
    end
  end

  # ── Cookies ────────────────────────────────────────────────────

  describe "cookies" do
    it "sets and reads cookies via the driver" do
      visit "/"
      host = URI.parse(current_url).host
      page.driver.browser.cookies.set(name: "test_cookie", value: "hello", domain: host)

      cookie = page.driver.browser.cookies.get("test_cookie")
      expect(cookie["value"]).to eq("hello")
    end

    it "clears cookies" do
      visit "/"
      host = URI.parse(current_url).host
      page.driver.browser.cookies.set(name: "c1", value: "v1", domain: host)
      page.driver.browser.cookies.set(name: "c2", value: "v2", domain: host)
      expect(page.driver.browser.cookies.all.length).to be >= 2

      page.driver.browser.cookies.clear
      expect(page.driver.browser.cookies.all).to be_empty
    end
  end

  # ── Frames ─────────────────────────────────────────────────────

  describe "frames" do
    before { visit "/frame_host" }

    it "finds content in the main page" do
      expect(find("#main-title")).to have_text("Main Page")
      expect(find("#main-text")).to have_text("Content outside the frame")
    end

    it "switches into and out of an iframe" do
      frame = find("#inner-frame")
      within_frame(frame) do
        expect(page).to have_css("#frame-content", text: "Inside the iframe")
      end
      # Back in main page context
      expect(find("#main-title")).to have_text("Main Page")
    end
  end

  # ── Capybara matchers ──────────────────────────────────────────

  describe "matchers" do
    it "has_text / has_no_text" do
      visit "/"
      expect(page).to have_text("Welcome")
      expect(page).to have_no_text("Nonexistent content")
    end

    it "has_css / has_no_css" do
      visit "/dashboard"
      expect(page).to have_css("#stats")
      expect(page).to have_no_css("#nonexistent")
    end

    it "has_link / has_button" do
      visit "/"
      expect(page).to have_link("About")
      expect(page).to have_no_button("Save")
    end

    it "has_field with value" do
      visit "/contacts/new"
      fill_in "Name", with: "Test"
      expect(page).to have_field("Name", with: "Test")
    end

    it "has_select" do
      visit "/contacts/new"
      expect(page).to have_select("Category")
    end

    it "has_checked_field / has_unchecked_field" do
      visit "/contacts/new"
      expect(page).to have_unchecked_field("Newsletter")
      check "Newsletter"
      expect(page).to have_checked_field("Newsletter")
    end
  end

  # ── Multi-page workflow ────────────────────────────────────────

  describe "full workflow" do
    it "navigates across multiple pages" do
      visit "/"
      expect(page).to have_css("h1", text: "Welcome")

      click_link "About"
      expect(page).to have_css("#description")

      click_link "Home"
      click_link "Dashboard"
      within "#stats" do
        expect(page).to have_css(".value", text: "1234")
      end

      go_back # back to home
      click_link "New Contact"
      fill_in "Name", with: "Integration Test"
      fill_in "Email", with: "test@test.com"
      select "Personal", from: "Category"
      click_button "Save Contact"

      expect(page).to have_css("h1", text: "Contact Saved")
      expect(find("#show-name")).to have_text("Integration Test")
    end
  end
end
