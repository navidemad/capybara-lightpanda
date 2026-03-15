# CLAUDE.md

## Project Overview

Self-contained Capybara driver for the Lightpanda headless browser. Includes its own CDP client (WebSocket transport, command dispatch, process management) — no external browser-client gem dependency.

```
Capybara → capybara-lightpanda (driver + CDP client) → Lightpanda browser (Zig/V8)
```

## Commands

```bash
bundle install                        # Install dependencies
bundle exec rake test                 # Run tests
bundle exec rubocop                   # Lint
bundle exec rubocop -a                # Lint with auto-fix
```

## Architecture Rules

- All CDP classes live under `Capybara::Lightpanda` namespace (Browser, Client, Cookies, etc.)
- `Browser#go_to` includes a `readyState` polling fallback — do not remove it. Lightpanda's `Page.loadEventFired` is unreliable.
- `Cookies#clear` catches `BrowserError` and falls back to deleting individually — do not simplify. `Network.clearBrowserCookies` crashes Lightpanda's CDP connection.
- `XPathPolyfill` must be re-injected after every `visit` — the JS context is lost between navigations.

## Lightpanda Browser Limitations

These are browser-level limitations, not fixable in this gem:

- No rendering engine → no screenshots, no `getComputedStyle`, no scroll/resize
- `Page.loadEventFired` may never fire on complex JS pages
- `Network.clearBrowserCookies` crashes the CDP WebSocket connection
- `XPathResult` not implemented (polyfilled by this gem)

## Testing

To test against a real Rails app, add `gem "capybara-lightpanda", path: "../capybara-lightpanda"` to the app's Gemfile and run with `BROWSER=lightpanda bundle exec rails test test/system/`.
