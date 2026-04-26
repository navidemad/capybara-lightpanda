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
  #   :windows    — `window.open` is in flight upstream (PR #2237). New target
  #                 doesn't materialize when a target=_blank link is clicked, so
  #                 the `become_closed`/`window_opened_by` shared specs can't
  #                 produce a second window to operate on.
  #   :html5_drag, :drag — no real layout/pointer dispatch geometry.
  capybara_skip: %i[windows html5_drag drag]
)
