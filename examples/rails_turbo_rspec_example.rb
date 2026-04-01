# frozen_string_literal: true

# Rails + Turbo + RSpec + Capybara example for capybara-lightpanda.
#
# This file tests a REALISTIC Rails 7+ Turbo app — Turbo Drive is on by default,
# forms submit through Turbo, and Turbo Frames handle partial page updates.
#
# The gem automatically:
# - Disables Turbo Drive (body replacement via fetch doesn't work in Lightpanda)
# - Submits forms via fetch + document.write when Turbo is present
# - Keeps Turbo Frames fully functional (lazy-loading, scoped link navigation)
#
# NOTE: Turbo loads from CDN as an ES module (async). Tests that depend on Turbo
# being loaded (link clicks, form submissions) must wait for it — either via
# have_css matchers (Capybara auto-waits) or an explicit sleep after visit.
#
# Run: ruby examples/rails_turbo_rspec_example.rb

require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"

  gem "rails"
  gem "turbo-rails"
  gem "puma"
  gem "rspec-rails"
  gem "capybara"
  gem "capybara-lightpanda", path: File.expand_path("..", __dir__)
end

require_relative "support/turbo_app"
require "rspec/autorun"
require "capybara/rspec"

# ── Tests ──────────────────────────────────────────────────────────

RSpec.describe "Rails + Turbo system tests", type: :feature do
  # ── Turbo Frame: lazy loading ──────────────────────────────────

  describe "Turbo Frame lazy-loading" do
    it "fetches and renders frame content from src" do
      visit "/"
      expect(page).to have_css("#notif-badge", text: "3 unread")
      expect(page).to have_no_css("#notif-loading")
    end

    it "does not touch anything outside the frame" do
      visit "/"
      expect(page).to have_css("#notif-badge")
      expect(page).to have_css("#page-title", text: "Home")
      expect(page).to have_css("#footer")
    end
  end

  # ── Turbo Frame: link navigation ───────────────────────────────

  describe "Turbo Frame link navigation" do
    it "replaces frame content when clicking a link inside the frame" do
      visit "/posts/1"
      wait_for_turbo_init
      click_link "Edit"
      expect(page).to have_css("#edit-title")
      expect(page).to have_css("#page-title", text: "Post #1")
      expect(page).to have_css("#post-body")
    end

    it "clicking a frame link loads new content" do
      visit "/"
      expect(page).to have_css("#notif-badge", text: "3 unread")
      click_link "Write a post"
      expect(page).to have_css("#post-title")
      expect(page).to have_css("#page-title", text: "Home")
    end
  end

  # ── Link navigation (Drive auto-disabled) ──────────────────────

  describe "link navigation" do
    it "click_link works (Drive auto-disabled)" do
      visit "/"
      wait_for_turbo_init
      click_link "About"
      expect(page).to have_css("#page-title", text: "About")
      expect(page).to have_css("#about-text")
    end

    it "navigates back and forward" do
      visit "/"
      wait_for_turbo_init
      click_link "About"
      expect(page).to have_css("#page-title", text: "About")
      go_back
      expect(page).to have_css("#page-title", text: "Home")
      go_forward
      expect(page).to have_css("#page-title", text: "About")
    end
  end

  # ── Form submission (fetch-based when Turbo present) ───────────

  describe "form submission" do
    it "submits a form and renders the result" do
      visit "/"
      wait_for_turbo_init
      click_link "Write a post"
      fill_in "post-title", with: "My First Post"
      fill_in "post-body-input", with: "Hello world!"
      click_button "Publish"

      expect(page).to have_css("#page-title", text: "Post Created")
      expect(page).to have_css("#post-title-result", text: "My First Post")
      expect(page).to have_css("#post-body-result", text: "Hello world!")
    end

    it "submits an edit form" do
      visit "/posts/1"
      wait_for_turbo_init
      click_link "Edit"
      fill_in "edit-title", with: "Updated Title"
      click_button "Save"

      expect(page).to have_css("#edit-result", text: "Saved: Updated Title")
    end
  end

  # ── Full workflow ──────────────────────────────────────────────

  describe "full workflow" do
    it "navigates, uses frames, and submits forms" do
      visit "/"
      wait_for_turbo_init

      # Turbo Frame lazy-load
      expect(page).to have_css("#notif-badge", text: "3 unread")

      # Frame navigation: write a post form
      click_link "Write a post"
      expect(page).to have_css("#post-title")
      expect(page).to have_css("#page-title", text: "Home")

      # Link navigation (Drive disabled)
      click_link "Posts"
      expect(page).to have_css("#page-title", text: "Posts")
      expect(all(".post").length).to eq(2)

      # Visit post, edit via frame, submit
      visit "/posts/1"
      wait_for_turbo_init
      click_link "Edit"
      fill_in "edit-title", with: "My Updated Post"
      click_button "Save"
      expect(page).to have_css("#edit-result", text: "Saved: My Updated Post")
    end
  end
end
