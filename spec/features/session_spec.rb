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
  #   NOTE :drag is deliberately NOT listed — the `#drag_to HTML5` examples
  #                        inherit it, and those run geometry-free through
  #                        Node#drag_to (HTML5 DragEvent simulation). The
  #                        legacy `#drag_to` examples (real coordinate mouse
  #                        dragging) are skipped by pattern in spec_helper.rb.
  #   NOTE :html5_drag is deliberately NOT listed. It gates `#drag_to HTML5`
  #                        and `Element#drop`, both of which the gem implements
  #                        geometry-free. Skipping whole features hid passing
  #                        specs for shipped behavior; audited 2026-07-26.
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
    scroll
    hover
    spatial
    download
    active_element
  ]
)
