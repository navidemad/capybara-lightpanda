# Lightpanda Browser Reference

Upstream repo: https://github.com/lightpanda-io/browser
License: AGPL-3.0 | Status: Beta (stability and coverage improving)

## Architecture

- Written in **Zig 0.15.2**, JS execution via **V8** (`zig-js-runtime`)
- HTML parsing: **html5ever** (standards-compliant, handles malformed HTML)
- HTTP: **libcurl** (custom headers, proxies, TLS control)
- No rendering engine: purely headless, no CSS layout/paint/compositing
- Platforms: Linux x86_64, macOS aarch64, Windows via WSL2

## CDP Server

Launched with `lightpanda serve --host 127.0.0.1 --port 9222`. Clients connect via WebSocket at `ws://127.0.0.1:9222`. Compatible with Puppeteer, Playwright (partial), and chromedp.

### Implemented CDP Domains (18 total)

| Domain | File | Notes |
|---|---|---|
| **Accessibility** | accessibility.zig | AXNode support; aria snapshots noisier than Chrome (#1813) |
| **Browser** | browser.zig | Basic browser-level commands |
| **CSS** | css.zig | Limited — no rendering engine, no `getComputedStyle` |
| **DOM** | dom.zig | `getDocument`, `querySelector`, `querySelectorAll` confirmed working |
| **Emulation** | emulation.zig | Viewport/device emulation stubs |
| **Fetch** | fetch.zig | Network interception at Fetch domain level |
| **Input** | input.zig | `dispatchMouseEvent`, `dispatchKeyEvent` |
| **Inspector** | inspector.zig | Inspector lifecycle |
| **Log** | log.zig | Console/log message forwarding |
| **LP** | lp.zig | Lightpanda-specific extensions |
| **Network** | network.zig | Cookies, request/response interception |
| **Page** | page.zig | Navigation, events, screenshots (limited); NO reload/history/dialog methods |
| **Performance** | performance.zig | Performance metrics |
| **Runtime** | runtime.zig | JS evaluation, object inspection |
| **Security** | security.zig | Security state |
| **Storage** | storage.zig | Storage state; `createContext` with storage state fails (#1550) |
| **Target** | target.zig | Target/session management |

### CDP Methods Used by This Gem

All verified present in upstream as of 2026-03-15:

```
Target.createTarget          Target.attachToTarget
Page.enable                  Page.navigate
Page.loadEventFired (event)  Page.getLayoutMetrics
Page.captureScreenshot
Runtime.evaluate             Runtime.callFunctionOn
Runtime.getProperties        Runtime.releaseObject
DOM.getDocument              DOM.querySelector           DOM.querySelectorAll
Network.enable               Network.disable
Network.getCookies           Network.setCookie
Network.deleteCookies        Network.clearBrowserCookies (safe on >= v0.2.6)
```

### CDP Methods NOT Available (gem uses JS workarounds)

```
Page.reload                  → gem uses go_to(current_url) instead
Page.getNavigationHistory    → gem uses history.back()/history.forward() JS instead
Page.navigateToHistoryEntry  → gem uses history.back()/history.forward() JS instead
Page.handleJavaScriptDialog  → not in page.zig (modal code guarded with rescue BrowserError)
Network.getAllCookies         → does not exist; gem uses Network.getCookies
```

### Available CDP Methods (not yet used by this gem)

```
Page.createIsolatedWorld     Page.getFrameTree
Page.addScriptToEvaluateOnNewDocument  (STUBBED — accepts call, returns {identifier:"1"}, does nothing)
DOM.resolveNode              DOM.getBoxModel (zeros for padding/border/margin)
DOM.describeNode             DOM.scrollIntoViewIfNeeded
Input.dispatchMouseEvent     Input.dispatchKeyEvent
Network.getCookies           Network.setCookies (batch)
```

## Known Bugs and Limitations

### Critical for This Gem

1. **`Page.loadEventFired` unreliable** (#1801, #1832)
   - May never fire on complex JS pages, Wikipedia, certain French real estate sites
   - This gem works around it with `document.readyState` polling fallback in `Browser#go_to`
   - DO NOT remove the readyState fallback

2. **`Network.clearBrowserCookies`** — Fixed in >= v0.2.6
   - Was: Lightpanda responded with `InvalidParams` AND killed the WebSocket
   - Now: calls `clearRetainingCapacity()` on in-memory cookie jar (safe)
   - Gem retains fallback for older binaries but primary path works

3. **`XPathResult` not implemented**
   - `document.evaluate` and the `XPathResult` interface do not exist in Lightpanda
   - This gem injects a JS polyfill that converts XPath to CSS selectors (~80% coverage)
   - Polyfill MUST be re-injected after every `visit` (JS context lost between navigations)

4. **No rendering engine**
   - No screenshots (returns blank/empty), no `getComputedStyle`, no scroll/resize
   - No visual regression testing possible
   - `window.innerWidth`/`innerHeight` may not reflect emulation settings

5. **JavaScript context lost between navigations**
   - All injected JS (polyfills, custom functions) must be re-injected after each page load
   - Node references (objectIds) become invalid after navigation

### Recently Merged Fixes (v0.2.6, 2026-03-14)

- **PR #1823**: Remove frame double-free on navigate error (merged 2026-03-14)
- **PR #1810**: Ensure valid cookie isn't interpreted as null (merged 2026-03-13)
- **PR #1824**: Fix memory leak in Option.getText() (merged 2026-03-14)

### Open Fix PRs (not yet merged)

- **PR #1836**: Fix AXValue integer→string serialization (for #1822)
- **PR #1821**: Ignore partitionKey in cookie operations (for #1818)

### Upstream Open Issues (verified 2026-03-15, all still open)

| Issue | Impact | Description |
|---|---|---|
| #1839 | CDP | Session management assertion error in Playwright |
| #1838 | CDP | CRSession._onMessage crash in Playwright |
| #1832 | Navigation | `Page.navigate` response never sent on some sites |
| #1830 | Startup | Port-already-in-use not handled gracefully |
| #1822 | CDP | AXValue.value serialized as integer instead of string |
| #1819 | CDP | Page unresponsive after `Target.detachFromTarget` |
| #1818 | Cookies | `Network.deleteCookies` rejects `partitionKey` parameter |
| #1816 | Crash | Segfault in serve mode with jQuery Migrate scripts |
| #1801 | Navigation | `Page.navigate` never completes for Wikipedia |
| #1800 | CDP | Playwright `connectOverCDP` fails: frame ID mismatch |
| #1550 | Storage | Creating context with storage state fails |

### General Limitations

- Many Web APIs not yet implemented (hundreds remain)
- Complex JS frameworks may not work (React SSR hydration, heavy SPA)
- No `window.getComputedStyle()` (no CSS engine)
- No `window.scrollTo()`, `element.scrollIntoView()` (no layout)
- No `MutationObserver` guarantees
- No WebSocket API in page context (CDP WebSocket is separate)
- No Web Workers, Service Workers, SharedArrayBuffer
- No `localStorage`/`sessionStorage` persistence across sessions
- File upload not supported (`input[type=file]` operations will fail)

## CLI Reference

```bash
# Single-page fetch (stdout output)
lightpanda fetch [--obey_robots] [--log_format pretty|json] [--log_level info|debug] <url>

# CDP server mode
lightpanda serve --host 127.0.0.1 --port 9222 [--log_format json]

# Flags
--obey_robots                              # Respect robots.txt
--insecure_disable_tls_host_verification   # Skip TLS verification (dev only)
--log_format pretty|json                   # Log output format
--log_level info|debug                     # Verbosity

# Environment
LIGHTPANDA_DISABLE_TELEMETRY=true          # Disable usage telemetry
```

## Process Management Notes

- Server startup: look for `server running.*address=(\d+\.\d+\.\d+\.\d+:\d+)` in stdout
- Use process groups (`pgroup: true`) for clean shutdown
- Send TERM signal for graceful stop
- Default startup timeout: 10 seconds
- WebSocket connect retry: 10 attempts, 0.1s delay between

## Binary Distribution

Nightly builds from: `https://github.com/lightpanda-io/browser/releases/download/nightly`
- Linux x86_64: `lightpanda-x86_64-linux` (ELF)
- macOS aarch64: `lightpanda-aarch64-macos` (Mach-O)
- Latest release: v0.2.6 (2026-03-14), also v0.2.5, v0.2.4, v0.2.3, v0.2.2 available

## Differences from Chrome/Chromium CDP

When writing CDP interactions, be aware of these divergences:

1. **Event timing**: CDP events may arrive in different order than Chrome
2. **Error responses**: Error messages/codes differ from Chrome's (e.g., `InvalidParams` instead of specific error codes)
3. **Missing methods**: Not all methods within a domain are implemented; unsupported methods return errors
4. **Parameter rejection**: Some Chrome-standard parameters (like `partitionKey` in `Network.deleteCookies`) are rejected
5. **Session management**: `Target.detachFromTarget` can leave pages unresponsive (#1819)
6. **Frame tree**: Frame IDs may not match Playwright expectations (#1800)
7. **Accessibility**: ARIA snapshots are more verbose than Chrome's (#1813)

## Development Tips

- Always test against Lightpanda nightly — behavior changes frequently
- When a CDP command fails, check if it's a known limitation before debugging
- Wrap CDP calls that might crash the connection in error handlers
- Prefer `Runtime.evaluate` for operations where direct CDP methods are unreliable
- Use `returnByValue: true` in `Runtime.evaluate` to get serialized values (avoids objectId lifetime issues)
- When adding new CDP interactions, verify the method exists in the corresponding domain .zig file upstream
