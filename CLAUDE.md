# CLAUDE.md

## Project Overview

Self-contained Capybara driver for the Lightpanda headless browser. Includes its own CDP client (WebSocket transport, command dispatch, process management) — no external browser-client gem dependency.

```
Capybara → capybara-lightpanda (driver + CDP client) → Lightpanda browser (Zig/V8)
```

## Commands

The local suite is Minitest (`test/`). RSpec is retained only for the Capybara
shared-spec battery distributed by the `capybara` gem (`spec/features/session_spec.rb`).

```bash
bundle install                        # Install dependencies
bundle exec rake test:incremental     # PREFERRED: run test files one at a time, skipping ones already passing.
                                      #   Records pass/fail in tmp/test_progress.json. Failed files re-run from scratch.
                                      #   Env: CLEAR=1 resets progress, FAIL_FAST=1 stops on first failure,
                                      #   ONLY=<glob> restricts the file set.
bundle exec rake test                 # Run only test/features/driver_test.rb (~2 min)
bundle exec rake test:unit            # Run test/unit/*_test.rb (~1s)
bundle exec rake test:all             # Run every Minitest file under test/
bundle exec rake spec:shared          # Run spec/features/session_spec.rb (~10 min, RSpec — full Capybara shared specs)
bundle exec rake suite                # Full suite: test:all + spec:shared
bundle exec rubocop                   # Lint
bundle exec rubocop -a                # Lint with auto-fix
```

## Architecture Rules

- All CDP classes live under `Capybara::Lightpanda` namespace (Browser, Client, Cookies, etc.)
- `Browser#go_to` includes a `readyState` polling fallback — do not remove it. Lightpanda's `Page.loadEventFired` is unreliable.
- `Browser#back`/`#forward` use JS `history.back()`/`history.forward()` because `Page.getNavigationHistory` and `Page.navigateToHistoryEntry` don't exist in Lightpanda. `Browser#refresh` uses `Page.reload` (implemented upstream in PR #1992).
- `Cookies#clear` calls `Network.clearBrowserCookies` directly (single CDP round-trip, browser-wide). Pre-PR-#2255 we swept per-origin via `Network.deleteCookies` because the bulk method crashed; once the upstream fix landed (`MINIMUM_NIGHTLY_BUILD = 5817`), the sweep was retired and `Browser#visited_origins` removed.
- `Cookies#all` calls `Network.getAllCookies` (PR #2255, merged 2026-04-27) to return cookies across every origin in the current `BrowserContext`. Per-origin scoping is still available via `Browser#command("Network.getCookies", urls: [...])` for callers that explicitly want it.
- `javascripts/index.js` contains the XPath polyfill (`xpathFind` + `document.evaluate` shim), Turbo activity tracking, and the `requestSubmit` polyfill. `Browser#create_page` registers it via `Page.addScriptToEvaluateOnNewDocument` so Lightpanda auto-injects it on every navigation. No manual re-injection needed.
- Node identity uses CDP remote object IDs (`Runtime.callFunctionOn` with `this` binding). All node operations route through a single `call` method for centralized error handling. JS function declarations are self-contained constants (no `_lightpanda` dependency) so they work in any execution context including iframes.
- `Node#[]` returns resolved URLs for `src`/`href`/`action` attributes via `PROPERTY_OR_ATTRIBUTE_JS` (matching Capybara's expected semantics).
- Frame switching stores Node objects in `Browser#frame_stack`. Finding within frames uses `callFunctionOn` on the iframe element to scope to its `contentDocument`. XPath finding in iframes requires the polyfill (only available in top frame).
- Modal handling uses Lightpanda's pre-arm model (`LP.handleJavaScriptDialog`, PR #2261). `Browser#accept_modal`/`#dismiss_modal` send the LP command BEFORE the action that triggers the dialog; Lightpanda stashes the response and consumes it when the dialog opens. `Page.javascriptDialogOpening` is still subscribed to capture the message text for `find_modal`. We do NOT call `Page.handleJavaScriptDialog` — it deliberately errors with "No dialog is showing" and points clients at the LP method.

## Lightpanda Browser Limitations

These are browser-level limitations, not fixable in this gem:

- No rendering engine → no screenshots, no real scroll/resize, hardcoded 1920×1080 layout metrics. `getComputedStyle` is partial: CSSOM merged (PR #1797) so `checkVisibility`/inline styles work, but cascade-resolved property lookups don't.
- `Page.loadEventFired` may never fire on complex JS pages — `Browser#go_to` keeps a `readyState` polling fallback.
- `Page.getNavigationHistory`, `Page.navigateToHistoryEntry` not implemented (worked around with `history.back()`/`history.forward()` JS; our PR #2289 OPEN to add native CDP).
- `Page.handleJavaScriptDialog` deliberately errors — use `LP.handleJavaScriptDialog` pre-arm (PR #2261, in nightly ≥5900). Already wired through `Browser#accept_modal`/`#dismiss_modal`.
- `Page.addScriptToEvaluateOnNewDocument` works (PR #1993, merged 2026-03-30) — `Browser#create_page` registers `javascripts/index.js` once per session.
- `XPathResult`/`document.evaluate` not implemented natively (polyfilled by this gem; native upstream PR #2305 OPEN).
- File uploads not supported — `Page.setFileInputFiles` missing (#2175); `Node#set` raises `NotImplementedError` for `<input type=file>`.

## Testing

To test against a real Rails app, add `gem "capybara-lightpanda", path: "../capybara-lightpanda"` to the app's Gemfile and run with `BROWSER=lightpanda bundle exec rails test test/system/`.

## Reference: Ferrum Gem

When implementing new CDP features or improving existing ones, refer to [Ferrum](https://github.com/rubycdp/ferrum) (Ruby CDP client for Chrome) for design inspiration — especially for API patterns, error handling, and Capybara driver conventions. However, always adapt for Lightpanda's constraints: missing CDP methods, unreliable events, XPath polyfill needs, async navigation, and crash recovery. Never blindly copy Ferrum patterns that assume Chrome behavior (e.g., synchronous `Page.navigate`, `Page.reload`, `getAllCookies`, native XPathResult).

## Sync Upstream

Run `/sync-upstream` (or ask Claude to run the sync-upstream skill) to check Lightpanda's upstream repo for CDP changes, fixed bugs, and new capabilities. This updates `.claude/rules/lightpanda-io.md`.
