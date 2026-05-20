# frozen_string_literal: true

# Repro example for a Stimulus + Floating UI dropdown that beta testers hit:
#
#   first("button[aria-label='Modifier']").click
#   click_on("Archiver")
#   # => Capybara::ElementNotFound: Unable to find visible link or button "Archiver"
#
# The Stimulus controller is rewritten in vanilla JS (see support/dropdown_app.rb)
# so the repro stands on its own — no Stimulus / Floating UI from a CDN.
#
# Run: ruby examples/rails_dropdown_minitest_example.rb

require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"

  gem "rails"
  gem "puma"
  gem "capybara"
  gem "capybara-lightpanda", path: File.expand_path("..", __dir__)
end

require_relative "support/dropdown_app"
require "minitest/autorun"
require "capybara/minitest"

class DropdownSystemTest < Minitest::Test
  include Capybara::DSL
  include Capybara::Minitest::Assertions

  def teardown
    Capybara.reset_sessions!
  end
end

# Pattern A: click-outside listener is registered INSIDE open(), so the click
# that opened the menu doesn't trigger it. Dropdown stays open → Archiver
# button is findable.
class SafeDropdownTest < DropdownSystemTest
  def test_opens_dropdown_and_clicks_archive
    visit "/safe"
    first("button[aria-label='Modifier']").click
    click_on("Archiver")
    assert_css "#status", text: "Quotation q1 archived"
  end
end

# Pattern B: an unconditional `click@window->close` listener (Stimulus-style)
# is registered up-front. The opening click bubbles to window → close() fires
# in the same dispatch → menu is hidden by the time Capybara looks for
# "Archiver" → ElementNotFound.
class BuggyDropdownTest < DropdownSystemTest
  def test_opens_dropdown_and_clicks_archive
    visit "/buggy"
    first("button[aria-label='Modifier']").click
    click_on("Archiver")
    assert_css "#status", text: "Quotation q1 archived"
  end
end

# Pattern B + inline Tailwind-equivalent stylesheet: same buggy controller,
# but `.flex { display: flex }` in an inline `<style>` overrides `[hidden]`
# by source-order (utilities layer beats preflight at equal specificity).
# Under this hypothesis the `hidden` attribute set by close() is a no-op,
# the menu stays visually visible, and "Archiver" is findable — which is
# what would happen in Chrome with Tailwind loaded externally, or on
# Lightpanda under PR #2487's `--enable-external-stylesheets` flag.
class BuggyDropdownWithFlexCssTest < DropdownSystemTest
  def test_opens_dropdown_and_clicks_archive
    visit "/buggy_with_flex_css"
    first("button[aria-label='Modifier']").click
    click_on("Archiver")
    assert_css "#status", text: "Quotation q1 archived"
  end
end

# Pattern B + class-based `!important`: mirrors Tailwind compiled with
# `important: true` (or the `!flex` utility prefix). If Lightpanda honors
# class-level !important against the `[hidden]` UA rule, this test passes
# and confirms PR #2487 (external stylesheet loading) would unblock the
# beta tester — provided their Tailwind config uses `important: true`.
class BuggyDropdownWithImportantFlexCssTest < DropdownSystemTest
  def test_opens_dropdown_and_clicks_archive
    visit "/buggy_with_important_flex_css"
    first("button[aria-label='Modifier']").click
    click_on("Archiver")
    assert_css "#status", text: "Quotation q1 archived"
  end
end

# Debug — what does Lightpanda actually compute for the menu's display and
# checkVisibility once the open-then-close cycle has set `hidden` back AND
# `.flex { display: flex }` is in an inline stylesheet?
class DropdownCascadeDebugTest < DropdownSystemTest
  def test_inspect_menu_state_after_click
    visit "/buggy_with_flex_css"
    first("button[aria-label='Modifier']").click
    state = evaluate_script(<<~JS)
      (function() {
        var m = document.getElementById('menu');
        return {
          has_hidden_attr: m.hasAttribute('hidden'),
          computed_display: getComputedStyle(m).display,
          check_visibility: m.checkVisibility(),
          inline_style_display: m.style.display || ''
        };
      })()
    JS
    puts "  menu state after open+close cycle (hidden=true): #{state.inspect}"
  end

  def test_inspect_menu_state_without_hidden_attr
    visit "/buggy_with_flex_css"
    # Strip the hidden attribute via JS so we isolate whether `.flex` actually
    # applies at all from whether `[hidden]` short-circuits the cascade.
    execute_script("document.getElementById('menu').removeAttribute('hidden')")
    state = evaluate_script(<<~JS)
      (function() {
        var m = document.getElementById('menu');
        return {
          has_hidden_attr: m.hasAttribute('hidden'),
          class_list: Array.from(m.classList),
          matches_dot_flex: m.matches('.flex'),
          computed_display: getComputedStyle(m).display,
          check_visibility: m.checkVisibility(),
          styleSheets_count: document.styleSheets.length,
          first_rule_text: document.styleSheets[0] ? document.styleSheets[0].cssRules[0].cssText : null
        };
      })()
    JS
    puts "  menu state without [hidden]: #{state.inspect}"
  end

  def test_inline_style_vs_class_rule
    visit "/buggy_with_flex_css"
    execute_script("document.getElementById('menu').removeAttribute('hidden')")
    state = evaluate_script(<<~JS)
      (function() {
        var m = document.getElementById('menu');
        // Set display via inline style — highest specificity in the cascade.
        m.style.display = 'flex';
        return {
          computed_display_with_inline_flex: getComputedStyle(m).display,
          inline_style_display: m.style.display
        };
      })()
    JS
    puts "  inline style.display = flex result: #{state.inspect}"
  end

  def test_inline_important_vs_hidden_attr
    visit "/buggy_with_flex_css"
    state = evaluate_script(<<~JS)
      (function() {
        var m = document.getElementById('menu');
        // Force the highest priority short of UA !important — inline !important.
        m.style.setProperty('display', 'flex', 'important');
        return {
          has_hidden_attr: m.hasAttribute('hidden'),
          computed_display: getComputedStyle(m).display,
          check_visibility: m.checkVisibility(),
          inline_style_text: m.style.cssText
        };
      })()
    JS
    puts "  inline display:flex !important + [hidden]: #{state.inspect}"
  end

  def test_class_important_vs_hidden_attr
    # Same as above but the !important rule comes from a CLASS selector in an
    # inline <style> — mirrors what Tailwind generates with `important: true`
    # or the `!flex` utility prefix. Tells us whether Lightpanda's
    # checkVisibility / cascade respects author-class !important rules.
    visit "/buggy_with_important_flex_css"
    first("button[aria-label='Modifier']").click
    state = evaluate_script(<<~JS)
      (function() {
        var m = document.getElementById('menu');
        return {
          has_hidden_attr: m.hasAttribute('hidden'),
          matches_flex: m.matches('.flex'),
          computed_display: getComputedStyle(m).display,
          check_visibility: m.checkVisibility(),
          first_rule_text: document.styleSheets[0] ? document.styleSheets[0].cssRules[0].cssText : null
        };
      })()
    JS
    puts "  class .flex !important + [hidden]: #{state.inspect}"
  end
end
