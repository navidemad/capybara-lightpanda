# frozen_string_literal: true

# Rails + Turbo + Minitest + Capybara example for capybara-lightpanda.
#
# This file tests a REALISTIC Rails 7+ Turbo app — Turbo Drive is on by default,
# forms submit through Turbo, and Turbo Frames handle partial page updates.
#
# The gem automatically:
# - Disables Turbo Drive (body replacement via fetch doesn't work in Lightpanda)
# - Submits forms via fetch + document.write when Turbo is present
# - Keeps Turbo Frames fully functional (lazy-loading, scoped link navigation)
#
# Run: ruby examples/rails_turbo_minitest_example.rb

require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"

  gem "rails"
  gem "turbo-rails"
  gem "puma"
  gem "capybara"
  gem "capybara-lightpanda", path: File.expand_path("..", __dir__)
end

require_relative "support/turbo_app"
require "minitest/autorun"
require "capybara/minitest"

# ── Tests ──────────────────────────────────────────────────────────

class TurboSystemTest < Minitest::Test
  include Capybara::DSL
  include Capybara::Minitest::Assertions

  def teardown
    Capybara.reset_sessions!
  end
end

class TurboFrameTest < TurboSystemTest
  def test_lazy_loads_frame_content
    visit "/"
    assert_css "#notif-badge", text: "3 unread"
    assert_no_css "#notif-loading"
  end

  def test_frame_link_navigation
    visit "/posts/1"
    wait_for_turbo_init
    click_link "Edit"
    assert_css "#edit-title"
    assert_css "#page-title", text: "Post #1"
    assert_css "#post-body"
  end

  def test_frame_link_loads_new_content
    visit "/"
    assert_css "#notif-badge", text: "3 unread"
    click_link "Write a post"
    assert_css "#post-title"
    assert_css "#page-title", text: "Home"
  end
end

class TurboLinkNavigationTest < TurboSystemTest
  def test_click_link_works
    visit "/"
    wait_for_turbo_init
    click_link "About"
    assert_css "#page-title", text: "About"
    assert_css "#about-text"
  end

  def test_back_and_forward
    visit "/"
    wait_for_turbo_init
    click_link "About"
    assert_css "#page-title", text: "About"
    go_back
    assert_css "#page-title", text: "Home"
    go_forward
    assert_css "#page-title", text: "About"
  end
end

class TurboFormSubmissionTest < TurboSystemTest
  def test_submits_form
    visit "/"
    wait_for_turbo_init
    click_link "Write a post"
    fill_in "post-title", with: "My First Post"
    fill_in "post-body-input", with: "Hello world!"
    click_button "Publish"

    assert_css "#page-title", text: "Post Created"
    assert_css "#post-title-result", text: "My First Post"
    assert_css "#post-body-result", text: "Hello world!"
  end

  def test_submits_edit_form
    visit "/posts/1"
    wait_for_turbo_init
    click_link "Edit"
    fill_in "edit-title", with: "Updated Title"
    click_button "Save"

    assert_css "#edit-result", text: "Saved: Updated Title"
  end
end

class TurboFullWorkflowTest < TurboSystemTest
  def test_full_workflow
    visit "/"
    wait_for_turbo_init

    assert_css "#notif-badge", text: "3 unread"

    click_link "Write a post"
    assert_css "#post-title"
    assert_css "#page-title", text: "Home"

    click_link "Posts"
    assert_css "#page-title", text: "Posts"
    assert_equal 2, all(".post").length

    visit "/posts/1"
    wait_for_turbo_init
    click_link "Edit"
    fill_in "edit-title", with: "My Updated Post"
    click_button "Save"
    assert_css "#edit-result", text: "Saved: My Updated Post"
  end
end
