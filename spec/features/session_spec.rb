# frozen_string_literal: true

require "spec_helper"

# Runs Capybara's cross-driver shared spec suite against Lightpanda.
#
# This exercises ~200 shared examples from Capybara itself — the same
# tests every Capybara driver (Selenium, Rack::Test, …) must pass.
# We skip categories the driver cannot support (no rendering engine, a
# single window, etc.) via capybara_skip.

Capybara::SpecHelper.run_specs(
  TestSessions::Lightpanda,
  "Lightpanda",
  # Capybara feature flags the driver doesn't support (yet), each with its
  # reason. Browser-level limits are detailed in
  # `.claude/rules/lightpanda-io.md`.
  #   :windows           — the driver serves a single window: one CDP target
  #                        per session (see Driver#open_new_window). This is
  #                        the gem's model, not a browser gap — `window.open`
  #                        (PR #2237) and multi-target CDP (#3945) have landed.
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
  #   NOTE :active_element is deliberately NOT listed: Tab moves focus since
  #                        upstream #2699, and CLICK_JS focuses its target
  #                        itself (upstream #3702 stopped doing it), so all 3
  #                        examples pass on the 12015 floor (first audited
  #                        2026-10-03 on 9994).
  capybara_skip: %i[
    windows
    scroll
    hover
    spatial
    download
  ]
)
