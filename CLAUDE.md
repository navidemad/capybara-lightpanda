# CLAUDE.md

## Project Overview

Self-contained Capybara driver for the Lightpanda headless browser. Includes its own CDP client (WebSocket transport, command dispatch, process management) — no external browser-client gem dependency.

```
Capybara → capybara-lightpanda (driver + CDP client) → Lightpanda browser (Zig/V8)
```

## Commands

```bash
bundle install                        # Install dependencies
bundle exec rake spec:incremental     # PREFERRED: run specs file-by-file, skipping ones already passing.
                                      #   Records pass/fail in tmp/spec_progress.json. Failed files re-run with
                                      #   --only-failures so iteration stays fast. Env: CLEAR=1 resets progress,
                                      #   FAIL_FAST=1 stops on first failure, ONLY=<glob> restricts the file set.
                                      #   Use this instead of `rake spec:all` (which runs everything from scratch
                                      #   and can take 10+ minutes per run).
bundle exec rake spec                 # Run only spec/features/driver_spec.rb (~2 min)
bundle exec rake spec:shared          # Run only spec/features/session_spec.rb (~10 min, full Capybara shared specs)
bundle exec rake spec:unit            # Run unit specs
bundle exec rubocop                   # Lint
bundle exec rubocop -a                # Lint with auto-fix
```

## Architecture Rules

- All CDP classes live under `Capybara::Lightpanda` namespace (Browser, Client, Cookies, etc.)
- `Browser#go_to` includes a `readyState` polling fallback — do not remove it. Lightpanda's `Page.loadEventFired` is unreliable.
- `Browser#back`/`#forward` use JS `history.back()`/`history.forward()` because `Page.getNavigationHistory` and `Page.navigateToHistoryEntry` don't exist in Lightpanda. `Browser#refresh` uses `Page.reload` (implemented upstream in PR #1992).
- `Cookies#clear` always sweeps via per-origin `Network.getCookies(urls:)` + `Network.deleteCookies(url:)` because (a) `Network.clearBrowserCookies` raises `InvalidParams` on current Lightpanda nightly (regressed from the >= v0.2.6 fix) and (b) `Network.getCookies` (no `urls`) is scoped to the current page's origin only, so cookies set on previously-visited domains are otherwise invisible. `Browser#visited_origins` tracks `scheme://host:port` strings across `go_to` calls so the sweep can enumerate cross-domain cookies.
- `Cookies#all` uses `Network.getCookies` (NOT `getAllCookies` — that method doesn't exist in Lightpanda). Result is scoped to the current page's origin only; pass `urls:` explicitly via `Browser#command("Network.getCookies", urls: [...])` for cross-origin enumeration.
- `javascripts/index.js` contains the XPath polyfill (`xpathFind` + `document.evaluate` shim), Turbo activity tracking, and the `requestSubmit` polyfill. `Browser#create_page` registers it via `Page.addScriptToEvaluateOnNewDocument` so Lightpanda auto-injects it on every navigation. No manual re-injection needed.
- Node identity uses CDP remote object IDs (`Runtime.callFunctionOn` with `this` binding). All node operations route through a single `call` method for centralized error handling. JS function declarations are self-contained constants (no `_lightpanda` dependency) so they work in any execution context including iframes.
- `Node#[]` returns resolved URLs for `src`/`href`/`action` attributes via `PROPERTY_OR_ATTRIBUTE_JS` (matching Capybara's expected semantics).
- Frame switching stores Node objects in `Browser#frame_stack`. Finding within frames uses `callFunctionOn` on the iframe element to scope to its `contentDocument`. XPath finding in iframes requires the polyfill (only available in top frame).
- Modal handling captures dialog messages via the `Page.javascriptDialogOpening` event (emitted upstream since 2026-04-03). Dialogs auto-dismiss in headless Lightpanda — alert→OK, confirm→false, prompt→null. The handler does NOT call `Page.handleJavaScriptDialog` (it errors with "No dialog is showing", and calling it from the dispatch thread deadlocks). `accept_modal(:alert)` and `dismiss_modal(:confirm|:prompt)` work correctly; `accept_modal(:confirm|:prompt)` cannot influence the JS return value (auto-dismiss has already returned the dismiss outcome).

## Lightpanda Browser Limitations

These are browser-level limitations, not fixable in this gem:

- No rendering engine → no screenshots, no `getComputedStyle`, no scroll/resize
- `Page.loadEventFired` may never fire on complex JS pages
- `Page.getNavigationHistory`, `Page.navigateToHistoryEntry` not implemented (worked around with JS)
- `Page.handleJavaScriptDialog` not implemented (no modal/dialog support)
- `Page.addScriptToEvaluateOnNewDocument` now working (PR #1993 merged 2026-03-30) — can register scripts once at session creation instead of re-injecting after every navigation
- `Network.getAllCookies` not implemented (use `Network.getCookies`)
- `XPathResult` not implemented (polyfilled by this gem)
- `Network.clearBrowserCookies` crashes on pre-v0.2.6 (safe on current nightly)

## Testing

To test against a real Rails app, add `gem "capybara-lightpanda", path: "../capybara-lightpanda"` to the app's Gemfile and run with `BROWSER=lightpanda bundle exec rails test test/system/`.

## Reference: Ferrum Gem

When implementing new CDP features or improving existing ones, refer to [Ferrum](https://github.com/rubycdp/ferrum) (Ruby CDP client for Chrome) for design inspiration — especially for API patterns, error handling, and Capybara driver conventions. However, always adapt for Lightpanda's constraints: missing CDP methods, unreliable events, XPath polyfill needs, async navigation, and crash recovery. Never blindly copy Ferrum patterns that assume Chrome behavior (e.g., synchronous `Page.navigate`, `Page.reload`, `getAllCookies`, native XPathResult).

## Sync Upstream

Run `/sync-upstream` (or ask Claude to run the sync-upstream skill) to check Lightpanda's upstream repo for CDP changes, fixed bugs, and new capabilities. This updates `.claude/rules/lightpanda-io.md`.
