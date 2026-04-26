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
  # Capybara feature flags Lightpanda doesn't support (yet). Each entry has a
  # corresponding entry in `.claude/rules/lightpanda-io.md`.
  #   :windows           — `window.open` in flight upstream (PR #2237).
  #   :html5_drag, :drag — no real layout/pointer dispatch geometry.
  #   :scroll            — no rendering engine, no scroll.
  #   :hover             — no real layout for hover positioning.
  #   :spatial           — `find(above:|below:|near:)` needs real geometry.
  #   :status_code       — CDP doesn't expose response status.
  #   :response_headers  — CDP doesn't expose response headers.
  #   :trigger           — driver doesn't implement Node#trigger.
  #   :shadow_dom        — node #path doesn't traverse shadow DOM boundaries.
  #   :html_validation   — element.validationMessage not exposed.
  #   :download          — no file download support.
  #   :active_element    — Tab-key focus traversal isn't implemented, and
  #                        `el.click()` doesn't focus form controls the way
  #                        a native mouse click does, so `:focused` filters
  #                        can't track which element should be active.
  capybara_skip: %i[
    windows
    html5_drag drag
    scroll
    hover
    spatial
    status_code
    response_headers
    trigger
    shadow_dom
    html_validation
    download
    active_element
  ]
)
