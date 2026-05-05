# Changelog

## [Unreleased]

### Fixed

- Turbo Drive `<form>` submissions now intercept correctly under Lightpanda. Four upstream gaps were polyfilled / worked around (see `UPSTREAM_BUGS.md` Bugs #7–#10):
  - **Bug #7** — Polyfill `HTMLFormElement.{enctype, method, action, target}` and `HTMLButtonElement` / `HTMLInputElement` `{formEnctype, formMethod, formAction, formTarget, formNoValidate}` IDL getters. Lightpanda returned `undefined` instead of the spec's missing-value defaults, crashing Turbo's `FormSubmission` constructor with `Cannot read properties of undefined (reading 'toLowerCase')`.
  - **Bug #8** — Polyfill `addEventListener` / `removeEventListener` lifecycle so a sync remove + re-add of the same listener during a dispatch's capture phase no longer disappears for the in-flight bubble phase. Restores Turbo's `FormSubmitObserver.submitCaptured` ordering trick (the reason its `submitBubbled` never fired before).
  - **Bug #9** — Swallow `JsException` from `requestSubmit()` in `CLICK_JS` when a listener cancels the SubmitEvent. Per HTML spec a cancelled submission must be a silent no-op; Lightpanda raises.
  - **Bug #10** — Wrap user expressions in `evaluate` / `execute` no-args fast paths in an IIFE `(function(){return EXPR})()` so top-level `const` / `let` declarations don't collide across consecutive `Runtime.evaluate` calls. Also raises `JavaScriptError` on `execute` JS exceptions (previously swallowed because `awaitPromise: false` skipped the `exceptionDetails` check).
- `body` getter now guards against the `document.documentElement === null` window after a fresh BrowserContext / target is created, returning `''` instead of crashing the `reset_session! resets page body` shared spec.
- `Node#backend_node_id` returns `nil` instead of propagating `BrowserError` when the underlying remote object has been disposed (typical during cross-document navigation races).
- Same-document fragment-only `<a href="#…">` clicks update `location.hash` instead of assigning `location.href`. The latter triggered a real navigation tick on Lightpanda that cancelled pending `setTimeout` callbacks and cleared form values, breaking any test that drove DOM updates from an in-page anchor click.

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
