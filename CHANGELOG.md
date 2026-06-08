# Changelog

## [Unreleased]

> **Needs a Lightpanda build with the drag-and-drop DataTransfer APIs** ([lightpanda-io/browser#2671](https://github.com/lightpanda-io/browser/pull/2671), closing the last gap in [#2043](https://github.com/lightpanda-io/browser/issues/2043)). Until that ships in a nightly, the drop test fails against released binaries.

### Added

- Drag-and-drop file and data upload through Capybara's standard `Element#drop`. `find("#dropzone").drop("/path/to/report.pdf")` reads the file and rebuilds it as a `File` inside the page; `find("#dropzone").drop("text/plain" => "hello")` drops typed string data. The driver builds a `DataTransfer` and fires `dragenter` → `dragover` → `drop`, so HTML5 dropzones (React Dropzone, Uppy, ActiveStorage direct-upload) receive the payload through `event.dataTransfer.files` / `.items`. This is drag-and-drop *upload*, not element-to-element `drag_to`, which still needs the layout geometry Lightpanda doesn't have.

## [0.5.0] - 2026-05-22

> **Update Lightpanda before upgrading.** Requires a nightly build ≥ 6353 (published 2026-05-21). The driver refuses to start against older binaries.

### Changed

- External `<link rel="stylesheet">` CSS is now fetched and applied by default. Responsive variants gated by an external stylesheet — a desktop-vs-mobile CTA defined in your app's compiled CSS bundle, say — now resolve to the single variant matching the fixed 1920×1080 viewport, so finding or clicking them no longer raises `Capybara::Ambiguous`. Specs that previously had to fall back to cuprite or Selenium for externally-loaded responsive CSS now run on lightpanda. The cost is one extra synchronous CSS fetch per `<link>` while the page loads.

### Fixed

- Suites no longer hang at exit. After the last test, the browser process could absorb the shutdown signal and keep the run blocked for minutes (much longer on CI) before being force-killed. The gem now closes the CDP connection before signaling the process and escalates to a hard kill if it doesn't exit promptly, so the process always dies fast and leaves no orphaned `lightpanda` behind.
- Elements toggled via the `[hidden]` attribute now respect an explicit `display` set by your app's CSS, the way a real browser does. This clears the `Capybara::ElementNotFound` and visibility failures that hit dropdowns and disclosure widgets built with Stimulus or Alpine.
- When your installed Lightpanda binary is too old, the update hint now matches where that binary actually lives — a `PATH` install, the gem's download cache, or a Homebrew install each get the right command instead of a generic one. Especially handy this release, since the raised floor means an outdated binary will refuse to start.

## [0.4.1] - 2026-05-19

### Fixed

- The gem now picks up a pre-installed `lightpanda` from `PATH` (e.g. `brew install lightpanda-io/lightpanda/lightpanda` or a manual `curl` install) instead of always re-downloading the nightly binary into `~/.cache/lightpanda/`. Test suites that block outbound HTTP via VCR/WebMock no longer crash on the surprise GET to `github.com` the first time the driver starts. Auto-download still kicks in if no `lightpanda` is on `PATH` and the gem cache is empty/stale, so default setups are unaffected.

## [0.4.0] - 2026-05-17

> **Update Lightpanda before upgrading.** Requires a nightly build ≥ 6269 (published 2026-05-16 or later). The driver refuses to start against older binaries.

### Added

- `Driver#status_code` and `Driver#response_headers` — read the HTTP status code and response headers from the most recent document navigation. Lookups on `response_headers` are case-insensitive (`response_headers["Content-Type"]` works against any header casing). Caveat: calling `driver.network.disable` also disables the navigation-response handler — they share a CDP toggle.
- `Driver#with_lightpanda_browser { |browser| … }` and `element.with_lightpanda_node { |node| … }` — escape hatches for tests that need raw access to Lightpanda's CDP client and `LP.*` extensions. Mixed-driver setups are safe: the element helper no-ops against non-Lightpanda elements.
- Shifted-symbol keyboard input — `send_keys([:shift, "1"])` now produces `"!"`, `[:shift, "2"]` produces `"@"`, etc., matching a US keyboard layout. Letters fall through to their existing upcase path unchanged.
- `LIGHTPANDA_EXTRA_ARGS` env var — whitespace-split tokens get appended to the spawned `lightpanda serve` command line, so you can experiment with opt-in upstream flags (e.g. `LIGHTPANDA_EXTRA_ARGS="--log_format pretty"`) without forking the gem.
- `Binary.configure { |b| b.required_version = "…"; b.cache_time = …; b.install_dir = "…"; b.proxy_addr = … }`, plus `Binary.update`, `Binary.remove`, `Binary.current_version`, `Binary.install_path` — explicit, scriptable binary management. Pair with the new `rake lightpanda:binary:{version, update[version], remove}` tasks if you want to download the binary once before parallel workers start.

### Changed

- Inline `<style> @media` rules and `window.matchMedia(q).matches` now evaluate against the fixed 1920×1080 viewport, so visibility checks on mobile-vs-desktop CTAs gated by **inline** `@media` queries no longer surface both variants. External `<link rel="stylesheet">` responsive CSS is still out of scope (browser limitation — see README).
- `network.headers = { … }`, `network.add_headers(…)`, and `network.clear_headers` now enable the Network domain on first call. No need to flip `network.enable` separately.

### Fixed

- A WebSocket-level error (bad frame, oversized message) no longer tears down the Ruby process. Pending CDP commands now fail immediately on disconnect instead of blocking for the full 30 s timeout, so teardown after a browser crash no longer freezes the suite.
- `Cookies#load` now restores the `SameSite` attribute. Auth-cookie flows that rely on `SameSite=Strict` / `Lax` survive a YAML round-trip through `cookies.store` / `cookies.load`.
- Stale (detached) element references now raise `ObsoleteNode` from every node operation, not just `text` / `all_text` / `visible_text`. Capybara's automatic-reload re-runs the original query instead of silently reading stale data.
- A browser crash followed by reconnect now wipes session state (modal subscriptions, frame stack). Subsequent tests no longer see "no dialog fired" or stale iframe handles.
- `save_screenshot` from Rails' `before_teardown` after a failed system test no longer masks the original failure with a "browser already gone" stack trace.
- `find_modal` of the wrong type now reports the message of whatever other dialog actually fired — so an `alert` firing where the test expected a `confirm` shows up clearly in the failure message.
- A `find(...)` immediately after a click that triggers navigation no longer raises `NoExecutionContextError`.
- A broken or permission-denied `lsof` now surfaces as a `BinaryError` pointing at the underlying problem instead of silently failing port reclamation.
- `session.scroll_to(node)` no longer raises `NotImplementedError`. Lightpanda still has no rendering so the call does nothing, but callers who didn't care about the result no longer crash.
- `network.traffic` reads (used by `wait_for_network_idle`) are now thread-safe — no more inconsistent counts when the CDP message thread is busy.
- Several internal browser-side handle leaks plugged — long shared-spec sessions no longer accumulate orphaned object references.

### Removed

- The last JavaScript polyfill bundle (form-IDL accessors like `form.enctype` and submitter `formAction` / `formMethod`) is gone — Lightpanda implements these natively now. No code change required on your end.
- The iframe-context retry workaround and the `HTMLDialogElement.show` / `showModal` / `close` polyfill — both implemented natively upstream. No code change required.

### Internal

- `rake spec:shared:parallel` — the Capybara shared-spec battery now runs in parallel across N worker processes (~3.7× at 4 workers, ~6.6× at 8). Default worker count is `Etc.nprocessors / 2`; override with `RSPEC_WORKERS=N`.

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
