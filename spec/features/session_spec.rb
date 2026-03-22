# frozen_string_literal: true

require "spec_helper"

# Runs Capybara's cross-driver shared spec suite against Lightpanda.
#
# This exercises ~200 shared examples from Capybara itself — the same
# tests that Selenium, Cuprite, Apparition, and Rack::Test must pass.
# We skip categories that Lightpanda cannot support (no rendering engine,
# no modal dialogs, no multi-window, etc.) via capybara_skip.

Capybara::SpecHelper.run_specs(
  TestSessions::Lightpanda,
  "Lightpanda",
  capybara_skip: %i[
    windows
    modals
    screenshot
    css
    spatial
    scroll
    hover
    download
    active_element
    shadow_dom
    status_code
    response_headers
    html_validation
  ]
) do |example|
  case example.metadata[:full_description]
  when /node #reload/
    # Remote object IDs don't survive page navigation in Lightpanda
    skip "Node reload not supported"
  when /node #drag/
    skip "No drag and drop support"
  when /node #attach_file/, /attach_file/
    skip "File upload not supported by Lightpanda"
  when /matches_style/, /assert_style/
    skip "No CSS engine — getComputedStyle not available"
  when /evaluate_async_script.*(passing elements|returning elements|context of the element)/
    skip "Async scripts cannot pass/return DOM elements (returnByValue limitation)"
  end
end
