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
  #   :drag              — no real layout/pointer dispatch geometry.
  #                        NOTE :html5_drag is deliberately NOT listed. It gates
  #                        both `#drag_to HTML5` (needs coordinates — still
  #                        skipped, by pattern in spec_helper.rb) and
  #                        `Element#drop`, which the gem implements
  #                        geometry-free via DROP_JS. Skipping the whole feature
  #                        hid 5 passing specs for shipped behavior; audited
  #                        2026-07-26.
  #                        :shadow_dom is likewise NOT listed: all 9 examples
  #                        pass on nightly ≥8609 (audited 2026-08-18) once
  #                        Node#path returns Selenium's shadow-DOM sentinel.
  #   :scroll            — no rendering engine, no scroll.
  #   :hover             — no real layout for hover positioning.
  #   :spatial           — `find(above:|below:|near:)` needs real geometry.
  #   :download          — downloads ARE supported (Browser.setDownloadBehavior,
  #                        PR #2722), but only for `Content-Disposition: attachment`
  #                        responses. Capybara's fixture serves text/csv with no
  #                        such header (MIME-triggered), which Lightpanda renders
  #                        rather than downloads — so this spec can't pass. The
  #                        real path is covered by test/features/download_test.rb.
  #   :active_element    — Tab-key focus traversal isn't implemented, and
  #                        `el.click()` doesn't focus form controls the way
  #                        a native mouse click does, so `:focused` filters
  #                        can't track which element should be active.
  capybara_skip: %i[
    windows
    drag
    scroll
    hover
    spatial
    download
    active_element
  ]
)
