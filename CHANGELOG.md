# Changelog

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
