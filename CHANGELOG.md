# Changelog

## [0.3.0] - 2026-05-12

> **Update Lightpanda before upgrading.** Requires a nightly build ≥ 6109 (published 2026-05-12). The driver refuses to start against older binaries.

### Fixed

- Iframe tests no longer crash with `NoExecutionContextError` when the page inside the iframe navigates. `switch_to_frame` and `within_frame` now re-resolve the iframe element on a stale-handle error and retry once, so multi-step flows inside an `<iframe>` (logins, embedded checkouts, OAuth dialogs) stay stable across child-frame navigations.
- Clicking a submit button no longer fires `submit` twice. On Turbo Drive pages this previously produced duplicate `turbo:submit-start` events and could abort the real fetch mid-flight.

### Removed

- The gem no longer ships its own XPath engine — Lightpanda evaluates XPath natively now, including the full XPath 1.0 selector surface. `find(:xpath, …)`, Capybara's automatic XPath fallback, and any custom XPath finders all keep working unchanged; the same behavior, with ~750 fewer lines injected per test process.
- The gem's JavaScript shim for `back` / `forward` is gone. Navigation history now routes through Lightpanda directly, which is more reliable across navigation crashes.

## [0.2.2] - 2026-05-06

> **Update Lightpanda before upgrading.** Requires a nightly build ≥ 6065 (published 2026-05-06). The driver refuses to start against older binaries.

### Fixed

- Turbo Drive `<form>` submissions now intercept correctly. Forms inside a
  Hotwire / Turbo Drive page no longer crash on submit, and Turbo's `submit`
  interceptors fire as they should — `click_button`, `find('form').submit`,
  and Enter-key implicit submission all complete end-to-end.
- `evaluate_script` and `execute_script` calls with top-level `const` / `let`
  no longer collide across calls. Consecutive scripts that each declare the
  same identifier used to fail with `Identifier 'foo' has already been
  declared`; they're now isolated. `execute_script` also now raises on
  JavaScript errors instead of silently swallowing them.
- Same-document fragment-only `<a href="#…">` clicks update the URL hash
  instead of triggering a real navigation. Tests that drive DOM updates from
  an anchor click no longer lose pending `setTimeout` callbacks or have form
  values cleared from under them.
- `body` returns an empty string rather than crashing during the brief window
  after `reset_session!` when the new session has a target but no document yet.
- Stale element references during cross-document navigation now resolve to
  `nil` internally instead of bubbling a browser error up to your test,
  letting Capybara's automatic-reload pick a fresh element.

### Internal

- One internal polyfill removed: Lightpanda now matches the spec when a DOM
  event listener throws (a throwing listener no longer halts the rest of the
  bubble walk), so the gem doesn't need to compensate. No code change required
  on your end.

## [0.2.1] - 2026-05-05

### Fixed

- Turbo Frame links now correctly swap the frame instead of falling through to a full-page navigation. Affects any test that clicks a link or submits a form inside a `<turbo-frame>`.
- Internal driver errors (`NoMethodError`, `NameError`, `Errno::*`) inside `extract_node_object_ids` and `page_ready?` are no longer swallowed and silently downgraded to `[]` / `false` — they surface as real exceptions so bugs are visible.

### Internal

- Local test suite migrated from RSpec to Minitest::Spec. The Capybara shared-spec battery (`spec/features/session_spec.rb`) still runs on RSpec.

## [0.2.0] - 2026-05-04

Reliability and feature polish as Lightpanda matured. **Update Lightpanda before upgrading**: this release requires a current nightly (the gem will tell you if yours is too old).

### Added

- `Driver#wait_for_network_idle(timeout:, connections:)` — wait until in-flight HTTP requests drop to a threshold. Useful for SPAs and pages with deferred XHR.
- `handshake_timeout` driver option — cap how long the gem waits for the browser process to come up, separate from per-command timeouts.
- `Cookies` is now `Enumerable` — `cookies.find`, `cookies.select`, etc. work directly.
- `set_cookie` now infers the domain from the current URL (or `Capybara.app_host`) when you don't pass one.

### Changed

- `accept_modal(:confirm)` and `accept_modal(:prompt)` now actually drive the JS return value. Previously they only captured the dialog message; the page-side `confirm()` / `prompt()` always saw the dismiss outcome.
- `prompt` dialogs now respect the `defaultText` argument when you call `accept_modal(:prompt)` without `with:`.
- Form interactions are noticeably more reliable on Turbo Drive pages, redirects, and JS-heavy SPAs — many subtle navigation/form-submit edge cases are now handled natively.
- All transient CDP errors inherit from `BrowserError`. A single `rescue Capybara::Lightpanda::BrowserError` catches the lot.

### Fixed

- Capybara's `node #send_keys should generate key events`, `#has_field with valid`, `#fill_in` with range/date/time inputs, `#refresh reposts`, `attach_file` (most cases), `accept_confirm`, label clicks, image-button submits, and `<summary>` clicks all pass against the new nightly floor.
- A subscription leak in `Page.loadEventFired` after navigation could slowly accumulate listeners on long-running suites.
- `visibleText` no longer inserts a stray newline between adjacent empty block elements.
- A clearer error message when `lsof` isn't installed and the gem can't reclaim a stuck port.

### Removed

- Most of the gem's JS polyfills — Lightpanda implements these natively now: the `#id` selector rewriter, the form-submission fetch+swap, the label/image-button/summary click handlers, and large parts of the visibility/disabled-state polyfills. No code change required on your end; tests should just pass.

### Internal

- 91-case XPath 1.0 conformance battery (replaced ad-hoc specs).
- README redesign.

## [0.1.0] - 2026-04-27

Initial release. Capybara driver for the [Lightpanda](https://github.com/lightpanda-io/browser) headless browser.

### Driver

- Capybara driver registered as `:lightpanda`
- Auto-downloads the Lightpanda binary on first use; binary version exposed via `Browser#binary_version`
- Reliable navigation: `Page.loadEventFired` + `document.readyState` polling fallback
- Crash recovery: detects WebSocket disconnects on heavy SPAs and reconnects transparently

### CDP client (no external browser-client gem)

- WebSocket transport, command dispatch, process management — all in-gem
- `Capybara::Lightpanda::Utils::Event` (iteration-counted `Concurrent::Event` wrapper, Ferrum-style)

### Nodes

- Identity via CDP remote object IDs (`Runtime.callFunctionOn`)
- `Node#[]` resolves URLs for `src`/`href`/`action` and returns live property values for boolean attributes
- `Node#rect`, `Node#obscured?`, `Node#shadow_root`, `Node#moving?`, `Node#wait_for_stop_moving`
- Whitespace-normalized `Node#text` / `#all_text` (works around Lightpanda's `textContent` divergence from Chrome)

### JavaScript polyfills (auto-injected via `Page.addScriptToEvaluateOnNewDocument`)

- XPath 1.0 evaluator (`document.evaluate` + `XPathResult` shim — Lightpanda doesn't implement XPath natively)
- `#id` selector rewriter for `querySelector{,All}` (Turbo Drive snapshot+swap workaround)
- `requestSubmit` polyfill
- Turbo activity tracking sentinels for event-driven `wait_for_turbo` / `wait_for_idle`
- `fetch()` + body-swap submit pipeline (works around Lightpanda's no-op `form.submit()`)

### Cookies

- Typed `Cookie` wrapper (Ferrum-style: `name`, `value`, `domain`, `httponly?`, `secure?`, `same_site`, `expires`)
- `Cookies#store` / `Cookies#load` — YAML round-trip
- Cross-origin `Cookies#clear` sweep via `visited_origins` tracking (works around `Network.clearBrowserCookies` returning `InvalidParams` on current Lightpanda nightly)

### Frames & modals

- Frame switching via `contentDocument` scoping; XPath polyfill inherited
- Frame metadata view populated from CDP frame events (`Frame#parent_id`, etc.)
- Modal capture via `Page.javascriptDialogOpening`. `accept_modal(:alert)` and `dismiss_modal(:confirm|:prompt)` work; `accept_modal(:confirm|:prompt)` cannot override Lightpanda's auto-dismiss

### Tested against

- Capybara `>= 3.0, < 5` — runs Capybara's shared spec suite
- Ruby 3.3 and 4.0
- Lightpanda nightly (verified against `1.0.0-nightly.5812+b3257754`, 2026-04-26)
