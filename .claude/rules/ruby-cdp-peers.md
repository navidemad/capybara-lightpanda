# Ruby CDP Peer Gems

This file tracks design inspiration from peer Ruby CDP gems — separate from `lightpanda-io.md`, which documents the **browser** upstream. Findings here are about *how* we structure code, not about *what's possible* in the browser.

Maintained by the `sync-upstream` skill (Ferrum / Cuprite targets). Don't write a changelog — when a pattern is adopted in the gem, move it from "Outstanding" to "Adopted" inline.

---

## Ferrum

Repo: https://github.com/rubycdp/ferrum
Role: peer Ruby CDP client. Active, idiomatic; primary peer-gem reference.

**Last reviewed**: 2026-04-27 against Ferrum v0.17.2 (latest release 2026-03-24) and `main` HEAD `aa0b7adb` (2026-03-23).

### Adopted

- **`Utils::Event`** — `lib/ferrum/utils/event.rb` ↔ `lib/capybara/lightpanda/utils/event.rb`. Iteration-counting wrapper around `Concurrent::Event` so callers can detect a wait was raced by a reset. Our copy notes "Mirrors ferrum's Utils::Event".
- **`Cookies::Cookie` typed wrapper** — `lib/ferrum/cookies/cookie.rb` ↔ inner class in `lib/capybara/lightpanda/cookies.rb`. Typed accessors over the raw CDP hash (`name`, `value`, `domain`, `httponly?`, `secure?`, `same_site`, `expires` as Time). Our copy notes "Mirrors ferrum's Cookies::Cookie".
- **`Cookies#store` / `Cookies#load`** — Ferrum 0.16 (Dec 2024) ↔ our `lib/capybara/lightpanda/cookies.rb`. YAML round-trip of all current cookies. Same signatures (`store(path = "cookies.yml")`, `load(path = "cookies.yml") -> true`).
- **`Node#wait_for_stop_moving` shape** — `lib/ferrum/node.rb` ↔ `lib/capybara/lightpanda/node.rb`. Poll `getBoundingClientRect` until two consecutive samples agree. We deliberately deviate by NOT raising `NodeMovingError` — see "Diverged on purpose" below.

### Outstanding adoption candidates

- **[tiny] `Utils::Attempt.with_retry(errors:, max:, wait:)`** — `lib/ferrum/utils/attempt.rb` ↔ would live at `lib/capybara/lightpanda/utils/attempt.rb` (currently we only have `utils/event.rb`). Our `Browser#with_default_context_wait` does ad-hoc retry-on-`NoExecutionContextError`, but extracting it as a generic helper matches Ferrum's surface and lets us reuse it for transient `BrowserError` cases (e.g. issue #2187). Ferrum constants: `INTERMITTENT_ATTEMPTS = 6`, `INTERMITTENT_SLEEP = 0.1` (we use 3/0.1 — consider bumping to 6 for parity).
- **[tiny] Nest CDP error classes under `BrowserError`** — `lib/ferrum/errors.rb` ↔ `lib/capybara/lightpanda/errors.rb`. Ferrum: `NodeNotFoundError < BrowserError`, `NoExecutionContextError < BrowserError`, `JavaScriptError < BrowserError`. Ours all inherit from `Error` directly. Reason to mirror: lets a single `rescue BrowserError` catch all transient CDP-level errors, which matches the rescue patterns used in Ferrum-style retry helpers.
- **[tiny] `BrowserError#code` and `#data` accessors** — Ferrum exposes both via the response hash; we only expose `response`. Less ceremony when reading specific CDP error codes (e.g. `e.code == -32000`).
- **[tiny] `JavaScriptError#stack_trace`** — Ferrum extracts `response["stackTrace"]`; we drop it. Useful for debugging gem-side JS bugs; one extra line in the constructor.
- **[tiny] `Node#exists?` predicate** — `lib/ferrum/node.rb` ↔ our `Node`. We raise `ObsoleteNode` from `ensure_connected`; a quiet `exists?` check (returns boolean instead of raising) is a small ergonomic win.
- **[tiny] `Frame#parent` and `Frame#frame_element`** — Ferrum 0.17 (May 2025) ↔ our `lib/capybara/lightpanda/frame.rb`. We track `parent_id` already; exposing `parent` (resolves to the parent `Frame`) and `frame_element` (the `<iframe>` Node hosting this frame) matches Ferrum's API and is purely additive.
- **[tiny] `Cookies` includes `Enumerable`** — `lib/ferrum/cookies.rb` ↔ our `Cookies`. Our `all` returns an `Array<Cookie>`; including `Enumerable` (and yielding from `each`) lets callers do `cookies.find`, `cookies.select` without going through `all` first. We'd diverge from Ferrum's "all returns Hash-by-name" choice — Array+Enumerable is more conventional Ruby and avoids the breaking-change cost.
- **[medium] Frame `Runtime#evaluate` / `evaluate_async` / `execute` / `evaluate_func` / `evaluate_on` family** — `lib/ferrum/frame/runtime.rb` ↔ our `Node#call` + ad-hoc `Browser#call_function_on`. Ferrum's split (a) wraps raw expressions vs. function declarations consistently, (b) supports `awaitPromise: true` for async evaluation, (c) passes `Node` arguments through `DOM.resolveNode`. Worth at least pulling the `evaluate_async` shape — we don't currently have Promise-aware evaluation. Caveat: Lightpanda's `Runtime.evaluate` is shaky after navigation (issue #2187), so any async path needs the retry helper above.

### Diverged on purpose

- **`Cookies#each` uses `Network.getAllCookies`** — Ferrum can; Lightpanda doesn't implement that method. We use `Network.getCookies` (per-origin) plus a `visited_origins` sweep. Documented in `lightpanda-io.md` Known Bug #2.
- **`Cookies#clear` calls `Network.clearBrowserCookies`** — Ferrum trusts Chrome; we can't. The bulk call raises `InvalidParams` on current Lightpanda nightly, so we sweep per-origin via `Network.deleteCookies(url:)`. Documented in `lightpanda-io.md` Known Bug #2.
- **`Node#wait_for_stop_moving` does not raise `NodeMovingError`** — Ferrum raises if the element is still moving after `attempts`. Lightpanda has no real animation/rendering loop, so "movement" between samples is just JS style mutation; if it hasn't settled in `MOVING_WAIT_ATTEMPTS` polls, the caller is better off proceeding silently with the last rect than failing the test. Comment in `node.rb` documents this.
- **`Node#click` uses JS `this.click()` / fetch+swap, not CDP `Input.dispatchMouseEvent`** — Ferrum dispatches mouse events through CDP and computes content quads (hence its `CoordinatesNotFoundError`). Lightpanda has no real layout, so coordinate-based clicks don't help; JS click + the gem's submit-bypass pipeline is the only thing that actually navigates. See `CLICK_JS` in `node.rb` and Known Bug #9 in `lightpanda-io.md`.
- **No `Mouse` / `Keyboard` coordinate abstractions in our public API** — Ferrum exposes `Mouse#scroll_by`, `Mouse#move`, `Keyboard#type` etc. Lightpanda lacks rendering and `window.scrollTo` is a no-op, so most mouse abstractions would be misleading. We have `Browser#keyboard` for `send_keys` only.
- **Returns from CDP serialized via `returnByValue: true`** — Ferrum's `Frame::Runtime#handle_response` walks rich `Runtime.RemoteObject` types (boolean/number/string/undefined/function/object with array/date/null subtypes). We sidestep the whole tree by serializing values upfront, accepting the loss of node references in JS return values in exchange for simpler code paths. Different design, same goal.

---

## Cuprite

Repo: https://github.com/rubycdp/cuprite
Role: peer Capybara CDP driver (built on Ferrum). Lower-priority secondary reference.

**Last reviewed**: 2026-04-27 against Cuprite v0.17 (latest release 2025-05-11) and `main` HEAD `cc3a3da6` (2026-04-11). Active dev resumed Mar–Apr 2026 toward an unreleased version.

### Adopted

- **`Driver#send_keys` fans out to `active_element`** — `lib/capybara/cuprite/driver.rb` (delegate `send_keys` to `active_element`) ↔ `lib/capybara/lightpanda/driver.rb:60-62`. Capybara's `Session#send_keys` routes to `Driver#send_keys`; Cuprite's pattern is to forward to whatever element currently has focus. Our copy notes "Cuprite's pattern".
- **Expanded `invalid_element_errors` list** — `lib/capybara/cuprite/driver.rb` ↔ `lib/capybara/lightpanda/driver.rb:204-212`. Cuprite includes `ObsoleteNode`, `MouseEventFailed`, `CoordinatesNotFoundError`, `NoExecutionContextError`, `NodeNotFoundError` so Capybara's `automatic_reload` retries on transient CDP failures. Our copy includes the four we can raise (we never raise `CoordinatesNotFoundError` because we don't compute content quads); comment notes "Cuprite pattern".
- **`native_args` private helper** — `lib/capybara/cuprite/driver.rb` ↔ `lib/capybara/lightpanda/driver.rb:228-233`. Walks args before sending to the browser and unwraps `Capybara::Node::Element` to its `.base`. Comment notes "Cuprite's `native_args` pattern".
- **Smart `Node#[]` property/attribute resolver** — `lib/capybara/cuprite/node.rb#[]` ↔ `lib/capybara/lightpanda/node.rb:88-92` + `PROPERTY_OR_ATTRIBUTE_JS`. Returns resolved URLs for `src`/`href`/`action` and live property values for boolean attributes (checked/selected/etc.). Comment notes "Cuprite pattern".
- **Whitespace-normalized `filter_text`** — `lib/capybara/cuprite/node.rb#all_text` ↔ `lib/capybara/lightpanda/node.rb:322-333`. Strips control chars, collapses whitespace, trims, normalizes NBSP. Required because Lightpanda's `textContent` preserves source-template whitespace differently than Chrome. Comment notes "Cuprite pattern".
- **`Node#rect`** — Cuprite PR #276 (merged 2026-04-04) ↔ `lib/capybara/lightpanda/node.rb:40-42` + `GET_RECT_JS`. Exposes `getBoundingClientRect`. Lightpanda returns geometry from `DOM.getBoxModel` since 2026 (see `lightpanda-io.md`).
- **`Node#obscured?`** — Cuprite PR #291 (merged 2025-03-06) ↔ `lib/capybara/lightpanda/node.rb#obscured?` + `_lightpanda.isObscured`. Hit-tests `elementFromPoint` at the element's center.
- **`Node#shadow_root`** — Cuprite PR #234 (merged 2026-03-29) ↔ `lib/capybara/lightpanda/node.rb:75-86`. Returns a `Node` wrapper for the element's `shadowRoot`.
- **Time-input support in `Node#set`** — Cuprite PR #245 (merged 2026-03-28) ↔ `lib/capybara/lightpanda/node.rb#fill_input` (date / time / datetime-local cases).
- **Focus-before-value-set** — Cuprite PR #280 (merged 2026-04-03) ↔ our `SET_VALUE_JS` (which calls `this.focus()` before `this.value = value`).

### Outstanding adoption candidates

- **[tiny] `Driver#default_domain` + `started` flag** — `lib/capybara/cuprite/driver.rb` ↔ would live in `lib/capybara/lightpanda/driver.rb`. Cuprite's `set_cookie` falls back to the host of `browser.current_url` (or `Capybara.app_host`, or `"127.0.0.1"`) when no `domain` is given, gated by an internal `@started` flag flipped on first `visit`. Currently our `set_cookie` requires the caller to pass `domain` explicitly or else CDP errors with `InvalidParams`. Tiny add, makes pre-visit cookie setup work.
- **[tiny] `Node#parents`** — `lib/capybara/cuprite/node.rb#parents` ↔ would live in our `Node`. Returns the ancestor chain as an array of `Node`s. Tiny JS helper (walk `parentNode` until `document`); useful for diagnostics and the rare Capybara test that needs ancestor traversal.
- **[tiny] `Node#trigger(event)`** — `lib/capybara/cuprite/node.rb#trigger` ↔ would live in our `Node`. Fires an arbitrary DOM event by name (mouse/focus/form). Tests that need to dispatch custom events (e.g. `node.trigger('change')`) would otherwise fall through to `evaluate_script`.
- **[tiny] `month` and `week` input-type support in `Node#set`** — `lib/capybara/cuprite/node.rb#set` ↔ `lib/capybara/lightpanda/node.rb#fill_input`. We handle date / time / datetime-local but skip month and week. Trivial extension — same `value.to_date.strftime` shape as the existing types.
- **[tiny] `setValue` uses native HTMLInputElement value setter** — `lib/capybara/cuprite/javascripts/index.js#setValue` ↔ our `SET_VALUE_JS`. Cuprite calls `Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set` to bypass framework value setters (React-style). Lightpanda's React SSR/hydration support is limited so this is mostly latent; defer until we have a test that needs it.
- **[medium] `Node#drag_to` / `Node#drag_by`** — `lib/capybara/cuprite/node.rb#drag_to` ↔ would live in our `Node`. Cuprite implements drag via `Input.dispatchMouseEvent` step sequences. Lightpanda has no real layout/coordinates, so we'd need a JS-only `DragEvent` dispatch emulation (`dragstart` / `dragover` / `drop` / `dragend`). Useful for HTML5 drag-and-drop tests; non-trivial because the data-transfer object also has to be plumbed.

### Diverged on purpose

- **`Node#set` writes `.value` directly + dispatches input/change** — Cuprite types char-by-char and dispatches `keydown` / `keypress` / `input` / `keyup` per character (`lib/capybara/cuprite/javascripts/index.js#set`). Lightpanda's keyboard event handling is limited and per-char CDP dispatch is much slower and more error-prone; direct `.value` + `input`/`change` events is the right choice for the gem's perf and stability. Tests that assert keystroke-level handlers may need to use `node.send_keys` instead of `node.set`.
- **`Node#click` uses JS `this.click()` + the gem's submit-bypass pipeline** — Cuprite uses `Input.dispatchMouseEvent` with content-quad coordinates (hence its `mouseEventTest` JS helper and `CoordinatesNotFoundError`). Lightpanda has no rendering or coordinate system, so coordinate-based clicks don't help; JS click + our fetch+swap submit path (`CLICK_JS`) is the only thing that actually navigates. Same reason as the matching divergence in the Ferrum section.
- **`isObscured` is single-frame** — Cuprite's `isObscured` walks up `frameElement` chain and accumulates offsets to support obscuring detection across nested iframes (`lib/capybara/cuprite/javascripts/index.js#isObscured`). Our `_lightpanda.isObscured` only inspects the current document. Could be added but rarely needed in tests.
- **`window._lightpanda` namespace, not `window._cuprite`** — Cuprite's JS bundle exposes `window._cuprite` as the entrypoint. We use `window._lightpanda` because the bundle does more (XPath 1.0 evaluator, Turbo activity tracking, `#id` rewriter, `requestSubmit` polyfill) and is registered via `Page.addScriptToEvaluateOnNewDocument` rather than per-frame injection.
- **No generic JS-side `trigger()` event obtainer** — Cuprite's `lib/capybara/cuprite/javascripts/index.js#trigger` dispatches MouseEvent / FocusEvent / FormEvent by name. We inline event creation in `CLICK_JS` and friends. Acceptable — see "Outstanding adoption candidates" for promoting it.
