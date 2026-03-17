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
| **DOM** | dom.zig | 16 methods: `getDocument`, `querySelector`, `querySelectorAll`, `performSearch`, `resolveNode`, `describeNode`, `getBoxModel`, `getOuterHTML`, etc. |
| **Emulation** | emulation.zig | Viewport/device emulation stubs |
| **Fetch** | fetch.zig | Network interception at Fetch domain level |
| **Input** | input.zig | `dispatchMouseEvent`, `dispatchKeyEvent`, `insertText` |
| **Inspector** | inspector.zig | Inspector lifecycle |
| **Log** | log.zig | Console/log message forwarding |
| **LP** | lp.zig | Lightpanda-specific extensions |
| **Network** | network.zig | Cookies, request/response interception |
| **Page** | page.zig | Navigation, events, screenshots (1920x1080 PNG); NO reload/history/dialog methods |
| **Performance** | performance.zig | Performance metrics |
| **Runtime** | runtime.zig | JS evaluation, object inspection |
| **Security** | security.zig | Security state |
| **Storage** | storage.zig | Storage state; `createContext` with storage state fails (#1550) |
| **Target** | target.zig | Target/session management |

### CDP Methods Used by This Gem

All verified present in upstream as of 2026-03-17:

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
Page.setLifecycleEventsEnabled  Page.stopLoading (stub)    Page.close
DOM.resolveNode              DOM.getBoxModel (zeros for padding/border/margin)
DOM.describeNode             DOM.scrollIntoViewIfNeeded
DOM.performSearch            DOM.getSearchResults        DOM.discardSearchResults
DOM.getContentQuads          DOM.requestChildNodes
DOM.getFrameOwner            DOM.getOuterHTML            DOM.requestNode
Input.dispatchMouseEvent     Input.dispatchKeyEvent      Input.insertText
Network.setCookies (batch)   Network.getResponseBody
Network.setExtraHTTPHeaders  Network.setCacheDisabled (stub)
Network.setUserAgentOverride (stub)
Runtime.addBinding           Runtime.runIfWaitingForDebugger (stub)
Target.closeTarget           Target.createBrowserContext
Target.disposeBrowserContext Target.getBrowserContexts
Target.getTargets            Target.getTargetInfo        Target.setAutoAttach
Target.setDiscoverTargets (stub)  Target.activateTarget (stub)
Target.attachToBrowserTarget Target.detachFromTarget     Target.sendMessageToTarget
LP.getSemanticTree           LP.getInteractiveElements
LP.getStructuredData
```

## Known Bugs and Limitations

### Critical for This Gem

1. **`Page.loadEventFired` unreliable** (#1801, #1832)
   - May never fire on complex JS pages, Wikipedia, certain French real estate sites
   - **#1849 fixed** (PR #1850, merged 2026-03-16): WebSocket no longer dies during complex navigation, so readyState polling now works reliably as a fallback
   - This gem works around it with `document.readyState` polling fallback in `Browser#go_to`
   - DO NOT remove the readyState fallback — `Page.loadEventFired` itself is still unreliable (#1801, #1832 still open)

2. **`Network.clearBrowserCookies`** — Fixed in >= v0.2.6
   - Was: Lightpanda responded with `InvalidParams` AND killed the WebSocket
   - Now: calls `clearRetainingCapacity()` on in-memory cookie jar (safe)
   - Gem retains fallback for older binaries but primary path works

3. **`XPathResult` not implemented**
   - `document.evaluate` and the `XPathResult` interface do not exist in Lightpanda
   - This gem injects a JS polyfill that converts XPath to CSS selectors (~80% coverage)
   - Polyfill MUST be re-injected after every `visit` (JS context lost between navigations)

4. **No rendering engine**
   - Screenshots return a 1920x1080 PNG (hardcoded dimensions, no actual rendering)
   - No `getComputedStyle`, no scroll/resize, no visual regression testing
   - `Page.getLayoutMetrics` returns hardcoded 1920x1080 values
   - `window.innerWidth`/`innerHeight` may not reflect emulation settings

5. **JavaScript context lost between navigations**
   - All injected JS (polyfills, custom functions) must be re-injected after each page load
   - Node references (objectIds) become invalid after navigation

### Recently Merged Fixes (v0.2.6 and post-v0.2.6 nightly)

- **PR #1872**: Graceful WS socket close — send CLOSE message on browser-initiated disconnect, continue on accept failures (merged 2026-03-17)
- **PR #1883**: Show actionable error when server port is already in use (merged 2026-03-17)
- **PR #1876**: Add click, fill, scroll MCP interaction tools (merged 2026-03-17)
- **PR #1873**: Add default messages for all DOMException error codes (merged 2026-03-16)
- **PR #1870**: MutationObserver/IntersectionObserver now use reference counting (merged 2026-03-16)
- **PR #1864**: CDP click events now trusted (`isTrusted: true`) (merged 2026-03-16, fixes #1864)
- **PR #1863**: Add missing `disable` method to Security, Inspector, Performance CDP domains (merged 2026-03-16)
- **PR #1846**: Fix use-after-free with certain CDP scripts (origin takeover) (merged 2026-03-16, fixes #1846)
- **PR #1817**: window.postMessage across frames (merged 2026-03-16)
- **PR #1850**: Fix CDP WebSocket connection dying during complex page navigation (merged 2026-03-16, fixes #1849) — filed by us
- **PR #1845**: Don't kill WebSocket on unknown domain/method errors (merged 2026-03-15, fixes #1843) — filed by us
- **PR #1821**: Ignore partitionKey in cookie operations (merged 2026-03-16, fixes #1818)
- **PR #1836**: Fix AXValue integer→string serialization (merged 2026-03-16, fixes #1822)
- **PR #1852**: Fix DOMParser error document handling (merged 2026-03-15)
- **PR #1851**: Fix fetch() to reject with TypeError on network errors (merged 2026-03-15)
- **PR #1823**: Remove frame double-free on navigate error (merged 2026-03-14, in v0.2.6)
- **PR #1810**: Ensure valid cookie isn't interpreted as null (merged 2026-03-13, in v0.2.6)
- **PR #1824**: Fix memory leak in Option.getText() (merged 2026-03-14, in v0.2.6)
- **Cookie parsing on redirect** (commit 51e90f59, 2026-03-12): Fix cookie handling during HTTP redirects
- **Frame navigation improvements** (commits 9c7ecf22, 768c3a53, bfe2065b, cabd62b4, 2026-03-05–06): Target-aware navigation, optimized about:blank, improved sub-navigation
- **Dynamic inline script execution** (commit ec9a2d81, 2026-03-08): Execute dynamically inserted `<script>` elements
- **Origin-based frame data sharing** (commit 94ce5edd, 2026-03-08): Same-origin frames share V8 data
- **Page.captureScreenshot added** (commit 8672232e, 2026-03-09): Dummy 1920x1080 PNG
- **Page.getLayoutMetrics added** (commit d669d5c1, 2026-03-09): Hardcoded 1920x1080
- **LP.getSemanticTree** (commit 0f46277b, 2026-03-06): Native semantic DOM extraction for AI agents
- **LP.getInteractiveElements** (commit a417c73b, 2026-03-09): List interactive page elements
- **LP.getStructuredData** (commit 22d31b15, 2026-03-10): Extract structured data from pages
- **Charset detection** (commit 3dcdaa0a, 2026-03-14): Detect charset from first 1024 bytes of HTML
- **window.structuredClone** (commit 4f8a6b62, 2026-03-12): Added structuredClone API
- **Anchor/form target attribute** (commit ee637c36, 2026-03-11): Navigation respects `target` attribute on links and forms

### Open Fix PRs (not yet merged)

None currently tracked.

### Upstream Open Issues (verified 2026-03-17)

| Issue | Impact | Description | Filed by us |
|---|---|---|---|
| #1887 | Stability | MutationObserver weak ref issues (disable observer weak ref) | |
| #1848 | CDP | Multiclient: closing one CDP connection kills other active connections | |
| #1839 | CDP | Session management assertion error in Playwright | |
| #1838 | CDP | CRSession._onMessage crash in Playwright | |
| #1832 | Navigation | `Page.navigate` response never sent on some sites | |
| #1830 | Startup | Port-already-in-use not handled gracefully (PR #1883 adds better error message, but no auto-recovery) | |
| #1819 | CDP | Page unresponsive after `Target.detachFromTarget` | |
| #1816 | Crash | Segfault in serve mode with jQuery Migrate scripts | |
| #1801 | Navigation | `Page.navigate` never completes for Wikipedia | |
| #1800 | CDP | Playwright `connectOverCDP` fails: frame ID mismatch | |
| #1550 | Storage | Creating context with storage state fails | |

### Closed Issues We Filed

| Issue | Outcome |
|---|---|
| #1849 | Closed (2026-03-16) — Fixed by PR #1850: CDP WebSocket no longer dies during complex navigation |
| #1843 | Closed (2026-03-15) — Fixed by PR #1845: Unknown CDP methods no longer kill WebSocket |
| #1842 | Closed — was our driver bug (`switch_to_frame` passed Capybara wrapper instead of native Node) |
| #1844 | Closed — cascading from #1843, not a real stability issue. 500+ commands work fine. |

### General Limitations

- Many Web APIs not yet implemented (hundreds remain)
- Complex JS frameworks may not work (React SSR hydration, heavy SPA)
- No `window.getComputedStyle()` (no CSS engine)
- No `window.scrollTo()`, `element.scrollIntoView()` (no layout)
- `MutationObserver` now available (PR #1870, reference counting) but has weak ref issues (#1887)
- `window.postMessage` across frames now works (PR #1817)
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
4. **Parameter rejection**: `Network.deleteCookies` now silently ignores `partitionKey` (PR #1821, merged 2026-03-16)
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
