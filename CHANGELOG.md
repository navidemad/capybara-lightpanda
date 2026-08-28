# Changelog

## [Unreleased]

> **Update Lightpanda before upgrading.** This release requires a Lightpanda nightly build ≥ 8875, and the rolling `nightly` tag now carries it (8925 as of 2026-08-28), so updating the browser is all it takes. **No tagged Lightpanda release is new enough yet**: 0.3.7 is below the floor, so version pinning stays unavailable until Lightpanda ships its next release.

### Added

- **The keyboard activates things.** Pressing Enter on a button, link or submit input — and Space on a button, checkbox or radio — now does what it does in a real browser: the control activates, forms submit, checkboxes toggle. Previously `send_keys(:enter)` and `send_keys(:space)` were silently ignored on those controls, so keyboard-accessibility specs passed by doing nothing. Printable keys also emit `keypress` now, and a handler that cancels `keypress` correctly suppresses Enter's implicit form submission.
- **A closed `<dialog>` is properly hidden.** Text and controls inside a `<dialog>` that has never been opened no longer match Capybara's default visibility filter. Suites using the `<dialog>`-as-confirmation idiom (Turbo, Spree 5's admin) could previously "find" and click a confirm button that was not on screen — passing where Chrome would have raised `ElementNotFound`.
- **Uppercase inline styles hide elements.** `style="display: NONE"` and `style="visibility: HIDDEN"` are now treated as hidden, matching the CSS spec's case-insensitive keywords. Legacy templates and CMS output that upcase keywords no longer read as visible.
- **`ws_url:` accepts `localhost`.** Connecting to an externally-managed Lightpanda over `ws://localhost:PORT/` works; previously only an IP literal such as `ws://127.0.0.1:PORT/` was accepted by the browser's handshake.

### Fixed

- **A browser you manage yourself is version-checked like one the gem spawns.** `ws_url:` was the only way into the driver that skipped the version floor: a Lightpanda too old for the gem connected happily, then failed further along as a CDP error naming neither the version nor the option that let it through. The driver now reads the version over CDP at connect and refuses anything below the floor, with the same message the spawn path produces. An endpoint that cannot report a version at all — a Lightpanda older than the command, or a Chrome pointed at by mistake — is refused for the same reason. `page.driver.browser.version`, `.nightly_build` and `.release` report the browser on this path now instead of returning `nil`.

## [0.11.0] - 2026-08-25

> **Update Lightpanda before upgrading.** This release requires a Lightpanda nightly build ≥ 8796 (2026-08-25 or newer). **No tagged Lightpanda release is new enough yet**: 0.3.7 is below the floor and is now refused, so version pinning is unavailable until Lightpanda ships its next release — CI runs on the rolling nightly in the meantime.

### Added

- **Drag and drop between elements.** `element.drag_to(target)` performs an HTML5 drag — `dragstart` through `drop` with a shared `DataTransfer`, so dropzone pages and `setData`/`getData` handlers behave as in Chrome, and drag events carry whole-number coordinates like Chrome's. Libraries that only respond to real mouse movement (SortableJS's fallback mode) remain out of reach — there is still no layout engine to drive a pointer through.
- **`load_images` driver option.** `load_images: true` makes the browser fetch `<img>` sources over the network, so image requests appear in `network.traffic` and are counted by `wait_for_network_idle` — useful for suites that assert on image traffic. Off by default (images are skipped entirely, as before). Needs a nightly from 2026-08-26 onward.
- **Screenshots show the page.** `save_screenshot` — and the automatic failure screenshots capybara-screenshot takes — now produce a real rendering of the page's content instead of a fixed placeholder image. It is a text-layout rendering, useful for seeing what the DOM held at failure time; pixel-accurate visual regression still needs a full browser.

### Removed

- The internal workaround for reading an element's `draggable` state is gone now that the browser answers natively — no change required on your end.

## [0.10.0] - 2026-08-19

> **Update Lightpanda before upgrading.** This release requires a Lightpanda nightly build ≥ 8448 **or a tagged release ≥ 0.3.7**. The driver refuses to start below either floor and tells you which version it found. If you pin the browser (see below), pin `0.3.7` or newer.

### Added

- **Tagged Lightpanda releases are accepted, and can be pinned.** Set `Capybara::Lightpanda::Binary.required_version = "0.3.7"` and the driver downloads that exact release, so CI runs against the same browser every time instead of whatever the rolling nightly is that morning. Pinned binaries live in their own path (`~/.cache/lightpanda/lightpanda-0.3.7`), so several can coexist and a stale nightly can no longer shadow the pin. The docs have a CI recipe, including the pre-provisioning step suites that stub HTTP (VCR/WebMock) need.
- **File downloads.** When your app sends a file with `Content-Disposition: attachment` (`send_file`, `send_data`), the browser saves it to disk. `page.driver.downloads` lists the completed files, `page.driver.wait_for_download` blocks until in-flight ones finish. Turned on automatically when a destination exists: the new `:save_path` driver option, else `Capybara.save_path`. Responses that rely on MIME type alone (a bare `text/csv` with no `Content-Disposition`) are rendered as a page, not downloaded.
- **Uncaught JavaScript errors are captured.** `page.driver.browser.page_errors` returns every uncaught exception and unhandled promise rejection from page JS (message, file, line, column, stack). Previously a handler dying on a `TypeError` left `console_logs` empty and the failure surfaced far away as `ElementNotFound`. Kept separate from `console_logs`, which still holds only explicit `console.*` calls.
- **`raise_on_unhandled_modal` driver option.** A `confirm`/`prompt`/`alert` that opens outside an `accept_*`/`dismiss_*` block used to be silently cancelled by the browser, so a runaway confirm cancelled the action and the spec still passed. The driver now warns on stderr naming the dialog text; with `raise_on_unhandled_modal: true` it raises `Capybara::Lightpanda::UnhandledModalError` from the click or `visit` that opened it. Wrapped dialogs are unaffected.
- **Window API.** `page.current_window.resize_to(w, h)`, `.size`, `.maximize`, `current_window_handle`/`window_handles`, `switch_to_window` — all single-window (Lightpanda has one page per connection; `open_new_window` says so). One sharp edge: resizing changes `window.innerWidth` and `matchMedia` immediately but does not re-evaluate `@media` for the page already loaded, so **resize, then `visit`** for responsive specs.
- **The `:window_size` driver option now does something.** It sets the viewport that `window.innerWidth`/`innerHeight`, `matchMedia` and `@media` rules see, so `@media`-gated markup resolves at the size you ask for. Nothing reflows (there is no layout engine), so an element off-viewport is not reported as obscured.
- **Selenium-named helpers shared across Rails suites work.** `page.driver.browser.logs.get(:browser)` (the "no JS errors" helper), `browser.execute_async_script` (axe-core), `element.native.send_keys(...)`, and `browser.execute_cdp` for raw protocol calls. `browser.switch_to.alert` raises with a message pointing at `accept_confirm`/`accept_alert` — dialogs here are answered before they open, so there is nothing to switch to afterwards.
- `Node#path` returns an XPath that re-finds the element (Capybara's contract), and `"(: Shadow DOM element - no XPath :)"` for an element inside a shadow root, as Selenium does. `Node#exists?` answers whether a node is still attached without raising.
- **Intel Macs and arm64 Linux** (Graviton-class CI runners) are supported; Lightpanda publishes binaries for both, the gem just refused to look them up.

### Changed

- **Minimum Lightpanda version raised** (nightly 8448 / release 0.3.7). What that buys your suite: elements hidden by Tailwind v4's layered CSS are correctly invisible; `<form method="dialog">` closes its dialog (the Turbo-confirm pattern in Spree 5's admin) instead of navigating away; `select` reaches options inside `<optgroup>`; pages scheduling more than 512 timers no longer stall; dynamically inserted scripts load and fire `load`/`error` correctly; setting a `<select>` value can no longer crash the browser mid-spec; and non-ASCII download filenames come through intact.
- **`Element#drop` hands files to the browser** instead of streaming their bytes through the driver, so there is no longer a size ceiling on dropped files and `file.type` is what the browser sniffs. Same call, same behavior for the page. Capybara's own `Element#drop` shared specs now run against the driver.
- **Visible text is what the browser renders.** `text` uses the browser's own `innerText`, so block breaks, hidden descendants and whitespace match what a real browser reports, instead of the driver's approximation.
- **Clicking a wrapper element reaches the widget inside it.** A click on a plain container descends to the first interactive child a pointer would have hit, so select2 dropdowns (and similar widgets that bind on an inner node) open when a helper clicks the outer container.
- **`hover` fires `mouseenter` as well as `mouseover`**, so Stimulus `mouseenter->` actions, Floating UI and tippy menus open. CSS `:hover` rules still do not apply (no pointer state).
- Default `window_size` is `[1920, 1080]`, Lightpanda's own default, rather than `[1024, 768]`; suites that want the old size pass it explicitly. An invalid `window_size` raises `ArgumentError` at driver construction.
- Large `execute_script` payloads (axe-core-sized bundles and bigger) no longer drop the connection: the CDP message cap is 100 MiB.
- More of Capybara's shared specs run and pass, and stay as regression cover: shadow DOM (`#shadow_root` finding/clicking/text), `node #style`/`#matches_style?`, `send_keys` key events, and `fetch`/XHR `FormData` submissions.

### Fixed

- **A redirect no longer stalls `wait_for_network_idle` for the rest of the session.** After any `redirect_to` (post-create, post-login), `page.driver.network.pending_connections` stayed at 1 and every `wait_for_network_idle` burned its full timeout. Redirect chains are tracked correctly now, `network.traffic` shows the 302 and the final 200 on the right URLs, and `status_code` still reports the final page. Regular clicks and visits were never affected.
- **A pinned browser version was silently ignored** whenever a binary was already cached, so CI kept running the nightly the pin was meant to replace. Pins are now self-verifying (see Added).
- **An interrupted browser download no longer corrupts the cached binary.** The refresh wrote over the file in place, so a dropped connection left a zero-byte "executable" that the fallback path then handed back as usable. Downloads go to a temp file and are renamed into place atomically.

### Internal

- Docs site resynced with what the gem does; a local `script/real-app` harness boots the real-apps CI targets and captures `console_logs`/`network.traffic` per failing example.

## [0.9.0] - 2026-06-18

### Fixed

- `send_keys(:ctrl, …)` (held or `[:ctrl, "a"]` array form) crashed with `NoMethodError` — `MODIFIERS` advertised `:ctrl` but `KEYS` lacked the entry. Both forms now dispatch Control correctly, and an unknown key symbol raises `ArgumentError` naming the key everywhere.
- `Driver#headers` no longer reports phantom values after `reset!` — the cached `extra_headers` are cleared with the disposed BrowserContext.
- A connection reset (RST) during the WebSocket handshake now raises `DeadBrowserError` like the FIN path instead of leaking a raw `Errno::ECONNRESET`.
- A duplicate CDP response frame for an already-answered command id no longer kills the process (`IVar#try_set` on the message thread).

### Changed

- `Browser` is now composed of include-modules (`Browser::Runtime` / `Finder` / `Navigation` / `Modals` / `Console`) — pure code motion, public API unchanged (verified method-for-method by reflection).
- The Network CDP domain has a single owner: `Network` captures the navigation response behind `Browser#status_code` / `#response_headers`, and traffic tracking is always on (cleared per `reset`, ferrum parity). `driver.network.disable` now visibly owns the caveat that it freezes status tracking.
- Port-in-use recovery dispatches on a typed `PortInUseError` (subclass of `ProcessTimeoutError`, so existing rescues keep working) instead of matching the error message; HTTP download failures raise `BinaryError` instead of `BinaryNotFoundError`.
- `Driver#reset!` rescues the gem's error hierarchy (plus `SystemCallError`/`IOError`) instead of `StandardError`, and warns on respawn — programmer errors no longer degrade into a silent browser restart per test.
- `Node#shadow_root` routes through the guarded `#call` path: reading the shadow root of a detached host now raises `ObsoleteNode` (handled by Capybara's `automatic_reload`) instead of silently returning stale content.
- Arrays without modifier symbols passed to `send_keys` now type via `insertText`, consistent with plain strings (previously synthesized per-char keyDown/keyUp).

- No-args `evaluate_script` / `execute_script` send the expression with `replMode: true` (DevTools-console REPL semantics) instead of wrapping it in an IIFE. Top-level `const`/`let` can now be redeclared across calls *and* state persists between calls, matching what users see in the Chrome console. JS exceptions still raise `JavaScriptError`.

### Removed

- Dead internal API swept (pre-1.0 cleanup; none had a caller or documented use): `Binary.run` / `.exec` / `.fetch` / `.version` / `.path` and the `Binary::Result` struct; `Browser#document_node_id`; `Client#ws_url` / `#options` readers; `WebSocket#open?`. Cuprite/Ferrum drop-in surface is deliberately KEPT and documented: `Options#window_size` / `#headless` (accepted, inert) and the never-raised `MouseEventFailed` / `NoSuchPageError` / `StatusError` (peer-taxonomy mirrors so migrated rescue lists keep loading).
- UPSTREAM_BUGS.md Bug #9 (`requestSubmit()` threw when a listener canceled the SubmitEvent) retired: fixed upstream, verified on the nightly this gem already requires. Contract tests pin both retired bugs in `test/features/upstream_bugs_test.rb`.

## [0.8.0] - 2026-06-12

> **Update Lightpanda before upgrading.** Requires a nightly build ≥ 6736 (published 2026-06-12). The driver refuses to start against older binaries.

### Added

- `lightpanda:binary:*` rake tasks now load automatically inside Rails apps (via a Railtie), and the "Lightpanda is too old" error suggests a require-the-gem one-liner instead of those rake tasks. The old hint was a dead end: the tasks weren't loaded in Rails apps at all, and even with the Railtie they only exist under `RAILS_ENV=test` when the gem sits in the `:test` Gemfile group. (Found beta-testing a private Rails suite.)
- `Driver#render` as an alias of `save_screenshot`. capybara-screenshot calls `driver.render(path)` for drivers it doesn't know, so every failing test in a capybara-screenshot suite logged "Screenshot could not be saved: undefined method 'render'" — once per failure.
- `Driver#headers=` / `#add_headers` / `#headers`, delegating to the existing `Network` support. Cuprite exposes header writers on the driver and real suites call them there (`page.driver.headers = …`).
- `Cookies#[]` as an alias of `#get` — the Ferrum/Cuprite spelling (`browser.cookies["session_id"]`).
- `Browser#console_logs` / `#clear_console_logs` — console messages captured since the last session reset, as `{type:, text:, timestamp:, args:}` hashes (driver-internal Turbo sentinels excluded, buffer capped at 1,000 entries). Suites that assert "no JS errors leaked" no longer need to wire a custom Ferrum-style logger: `page.driver.browser.console_logs.select { |m| m[:type] == "error" }`. Note that Lightpanda currently reports both `console.log` and `console.warn` as type `"info"` — filter on `text` when you need to distinguish them.

### Changed

- Modal assertions match dialogs by message text regardless of the alert/confirm/prompt type, like Selenium and Cuprite — `accept_alert` around a `data-confirm` delete button now works.
- Clicks dispatch the full pointer sequence (mousedown → mouseup → click). Widgets that open on mousedown — select2 v3 dropdowns, for example — now react to `click` / `select_from`.
- The driver no longer re-dispatches `readystatechange` itself. Lightpanda fires the event natively as of nightly 6736 (lightpanda-io/browser#2708), so the shim added in 0.7.0 became redundant and was removed. Behavior is unchanged for Turbo/Hotwire apps — `turbo:load` still fires on every visit, now from the browser's own event.

### Fixed

- A failed binary download that falls back to a stale cached binary now warns loudly on stderr (with the original error and a re-provision one-liner) instead of logging only under `LIGHTPANDA_DEBUG`. VCR-guarded suites hit this path silently — VCR's blocking error is a `StandardError`, unlike raw WebMock's — and the only visible symptom was a confusing "Lightpanda is too old" error much later.
- Turbo Streams over ActionCable now connect. Page-initiated WebSocket upgrades carry the document's `Origin` header as of nightly 6736 (lightpanda-io/browser#2710, guaranteed by the new minimum build), so ActionCable's request-forgery protection accepts the connection instead of rejecting it with `Request origin not allowed: nil`. `turbo-cable-stream-source` elements reach `[connected]` and `turbo_stream_for` broadcasts (solid_cable or any adapter) arrive in specs. If you had added `config.action_cable.disable_request_forgery_protection = true` to your test environment to work around this, you can remove it.

## [0.7.0] - 2026-06-12

### Changed

- The driver now lets the OS pick a free port by default instead of always binding `9222`. Parallel test suites (`parallel_tests`, `parallel_rspec`) work with zero configuration — each worker gets its own ephemeral port instead of every worker fighting over `9222` and all but one dying with a startup timeout — and a Lightpanda you started by hand on `9222` no longer collides with the one the driver spawns. If you rely on a fixed port (external tooling attaching to the browser, for instance), pin it with `Capybara::Lightpanda.configure { |c| c.port = 9222 }`.

### Fixed

- Turbo's `turbo:load` now fires on every visit. Lightpanda advances `document.readyState` and fires `DOMContentLoaded`/`load` correctly, but never dispatched `readystatechange` — the single event Turbo's page observer waits on — so on Turbo Drive pages `turbo:load` never ran, and any Stimulus controller or initializer hanging off it stayed dormant. The driver now emits `readystatechange` itself, so Hotwire apps behave the way they do in a real browser. (Caught by a beta tester running real Turbo 8.0.23.)

## [0.6.0] - 2026-06-11

> **Update Lightpanda before upgrading.** Requires a nightly build ≥ 6699 (published 2026-06-11). The driver refuses to start against older binaries.

### Added

- File upload through Capybara's standard `attach_file` now works end to end. `attach_file("Avatar", "/path/to/photo.png")` populates the `<input type=file>` and fires `change`, and — the piece that was missing before — the file's bytes are submitted with the form as proper multipart data (filename, `Content-Type`, content). So uploads the server actually receives (avatar pickers, CSV/import forms, ActiveStorage attachments) can be driven and asserted, not just the client-side `change` handler. File paths are read on the machine running Lightpanda.
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
