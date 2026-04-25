# Lightpanda Browser Reference

Upstream repo: https://github.com/lightpanda-io/browser
License: AGPL-3.0 | Status: Beta (stability and coverage improving)

## Architecture

- Written in **Zig 0.15.2**, JS execution via **V8**
- HTML parsing: **html5ever** (standards-compliant, handles malformed HTML)
- HTTP: **libcurl** (custom headers, proxies, TLS control)
- CSS: **CSSOM** (PR #1797 merged 2026-03-23, built on StyleManager PR #1897) — `insertRule`/`deleteRule`/`replace`/`replaceSync`, `checkVisibility` matches all active stylesheets; no full layout/paint/compositing
- Platforms: Linux x86_64, macOS aarch64, Windows via WSL2

## CDP Server

Launched with `lightpanda serve --host 127.0.0.1 --port 9222`. Clients connect via WebSocket at `ws://127.0.0.1:9222`. Compatible with Puppeteer, Playwright (partial), and chromedp.

### Implemented CDP Domains (18 total)

| Domain | File | Notes |
|---|---|---|
| **Accessibility** | accessibility.zig | AXNode support; aria snapshots noisier than Chrome (#1813) |
| **Browser** | browser.zig | Basic browser-level commands |
| **CSS** | css.zig | CSSOM merged (PR #1797, 2026-03-23): `insertRule`/`deleteRule`/`replace`/`replaceSync`; `checkVisibility` matches all stylesheets; CDP `CSS.getComputedStyleForNode` not yet implemented |
| **DOM** | dom.zig | 16 methods: `getDocument`, `querySelector`, `querySelectorAll`, `performSearch`, `resolveNode`, `describeNode`, `getBoxModel`, `getOuterHTML`, etc. |
| **Emulation** | emulation.zig | Viewport/device emulation stubs |
| **Fetch** | fetch.zig | Network interception: `enable`, `disable`, `continueRequest`, `failRequest`, `fulfillRequest`, `continueWithAuth`; events: `requestPaused`, `authRequired` |
| **Input** | input.zig | `dispatchMouseEvent`, `dispatchKeyEvent`, `insertText` |
| **Inspector** | inspector.zig | Inspector lifecycle |
| **Log** | log.zig | Console/log message forwarding |
| **LP** | lp.zig | Lightpanda-specific extensions |
| **Network** | network.zig | Cookies, request/response interception |
| **Page** | page.zig | Navigation, events, screenshots (1920x1080 PNG), reload (PR #1992), addScriptToEvaluateOnNewDocument (PR #1993), `handleJavaScriptDialog` exists but always errors (auto-dismiss, commit 7208934b 2026-04-06), `javascriptDialogOpening` event NOW EMITTED (commit 95f80c96 2026-04-03); NO history methods |
| **Performance** | performance.zig | Performance metrics |
| **Runtime** | runtime.zig | JS evaluation, object inspection |
| **Security** | security.zig | Security state |
| **Storage** | storage.zig | Storage state; `createContext` with storage state fails (#1550) |
| **Target** | target.zig | Target/session management |

### CDP Methods Used by This Gem

```
Target.createTarget          Target.attachToTarget
Page.enable                  Page.navigate
Page.reload                  Page.loadEventFired (event)
Page.getLayoutMetrics        Page.captureScreenshot
Runtime.evaluate             Runtime.callFunctionOn
Runtime.getProperties        Runtime.releaseObject
DOM.getDocument              DOM.querySelector           DOM.querySelectorAll
Network.enable               Network.disable
Network.getCookies           Network.setCookie
Network.deleteCookies        Network.clearBrowserCookies (safe on >= v0.2.6)
```

### CDP Methods NOT Available (gem uses JS workarounds)

```
Page.getNavigationHistory    → gem uses history.back()/history.forward() JS instead
Page.navigateToHistoryEntry  → gem uses history.back()/history.forward() JS instead
Network.getAllCookies         → does not exist; gem uses Network.getCookies
```

### CDP Methods Partially Implemented (event but no handler)

```
Page.handleJavaScriptDialog  → DISPATCH HANDLER EXISTS (commit 7208934b, 2026-04-06) but
                                always returns "-32000 No dialog is showing" because
                                dialogs auto-dismiss in headless mode. The
                                Page.javascriptDialogOpening EVENT IS NOW EMITTED
                                (commit 95f80c96, 2026-04-03). Gem captures messages
                                in the event handler but does NOT call
                                handleJavaScriptDialog — calling synchronous CDP
                                commands from the dispatch thread deadlocks the
                                client. accept_modal(:alert) and dismiss_modal()
                                work; accept_modal(:confirm|:prompt) cannot override
                                the auto-dismiss return value.
```

### CDP Methods Recently Implemented

```
Network.setUserAgentOverride → IMPLEMENTED (PR #2139, merged ~2026-04-11)
Emulation.setUserAgentOverride → IMPLEMENTED (PR #2153, merged 2026-04-14)
Page.createIsolatedWorld → NOW WORKING (PR #2164, merged 2026-04-16). Previously returned
                            wrong executeContextId; fix pulls correct value from v8 inspector.
```

### Available CDP Methods (not yet used by this gem)

```
Page.createIsolatedWorld     Page.getFrameTree
Page.addScriptToEvaluateOnNewDocument  (WORKING — PR #1993 merged 2026-03-30)
Page.removeScriptToEvaluateOnNewDocument (PR #1993 merged 2026-03-30)
Page.setLifecycleEventsEnabled  Page.stopLoading (stub)    Page.close
Page.printToPDF (fake PDF — PR #2197 merged 2026-04-20)
DOM.resolveNode              DOM.getBoxModel (now returns real getBoundingClientRect geometry)
DOM.describeNode             DOM.scrollIntoViewIfNeeded
DOM.performSearch            DOM.getSearchResults        DOM.discardSearchResults
DOM.getContentQuads          DOM.requestChildNodes
DOM.getFrameOwner            DOM.getOuterHTML            DOM.requestNode
Input.dispatchMouseEvent     Input.dispatchKeyEvent      Input.insertText
Network.setCookies (batch)   Network.getResponseBody
Network.setExtraHTTPHeaders  Network.setCacheDisabled (stub)
Network.setUserAgentOverride (now implemented — PR #2139)
Runtime.enable               Runtime.addBinding
Runtime.runIfWaitingForDebugger (stub)
DOM.enable                   CSS.enable
Fetch.enable                 Fetch.disable
Fetch.continueRequest        Fetch.failRequest
Fetch.fulfillRequest         Fetch.continueWithAuth
Target.closeTarget           Target.createBrowserContext
Target.disposeBrowserContext Target.getBrowserContexts
Target.getTargets            Target.getTargetInfo        Target.setAutoAttach
Target.setDiscoverTargets (stub)  Target.activateTarget (stub)
Target.attachToBrowserTarget Target.detachFromTarget     Target.sendMessageToTarget
LP.getSemanticTree           LP.getInteractiveElements
LP.getStructuredData         LP.waitForSelector
```

## Known Bugs and Limitations

### Critical for This Gem

1. **`Page.loadEventFired` unreliable** (#1801, #1832)
   - May never fire on complex JS pages, Wikipedia, certain French real estate sites
   - **#1849 fixed** (PR #1850, merged 2026-03-16): WebSocket no longer dies during complex navigation, so readyState polling now works reliably as a fallback
   - **PR #2032** (merged 2026-03-30) reordered navigation events: `Loaded` (= `Page.loadEventFired`) now fires after DOMContentLoaded, at the very end of the navigation sequence. This is closer to Chrome's behavior and may improve reliability, but #1801/#1832 remain open.
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
   - **`Page.addScriptToEvaluateOnNewDocument` now works** (PR #1993, merged 2026-03-30) — could register polyfill once at session creation instead of re-injecting after every navigation

4. **No rendering engine (CSS much improved)**
   - Screenshots return a 1920x1080 PNG (hardcoded dimensions, no actual rendering)
   - `getComputedStyle` significantly improved: CSSOM merged (PR #1797, 2026-03-23) — `checkVisibility` now matches all active stylesheets (not just inline), `insertRule`/`deleteRule` work
   - No scroll/resize, no visual regression testing
   - `Page.getLayoutMetrics` returns hardcoded 1920x1080 values
   - `window.innerWidth`/`innerHeight` may not reflect emulation settings

5. **Cookies on redirects not sent on follow-up request**
   - Cookies set via `Set-Cookie` on a 302 response are stored in the cookie jar
   - But they are NOT included in the follow-up GET request to the redirect target
   - Verified on v0.2.7 and nightly — pre-existing behavior, not a PR #1889 regression
   - Workaround: after redirect, do a second navigation to the same URL if cookie-dependent

6. **JavaScript context lost between navigations**
   - All injected JS (polyfills, custom functions) must be re-injected after each page load — OR use `Page.addScriptToEvaluateOnNewDocument` for auto-injection (PR #1993, merged 2026-03-30)
   - Node references (objectIds) become invalid after navigation

7. **Turbo Drive — RESOLVED via gem-side `#id` selector polyfill (2026-04-25)**
   - **History**: `document.body = newBody` setter was missing → fixed by PR #2215 (merged 2026-04-23, shipped in nightly 2026-04-24). After that landed, removing the gem's `Turbo.session.drive = false` disabler still broke 2/9 real-Rails link-navigation specs. Turbo Drive's pipeline (`fetch → DOMParser → body.replaceWith`) was running cleanly — body was replaced, URL updated, events fired — but `expect(page).to have_css("#page-title", ...)` returned no match.
   - **Real root cause**: Lightpanda's CSS selector engine has a bug where `querySelector('#id')` / `querySelectorAll('#id')` returns `null` / `[]` after the body is mutated via `innerHTML` and then replaced via `replaceWith` (or twice via `replaceWith`). `getElementById('id')` and `[id="id"]` always work; only the `#id` shorthand is broken. Bug triggers in Turbo Drive's snapshot-then-swap path because `PageRenderer.replaceBody` populates a new body via `innerHTML` before `document.body.replaceWith(newBody)`. Pure single `replaceWith` on an unmodified body does not trigger the bug.
   - **Repro** (`/tmp/bug_when.rb`): a 12-row matrix shows only the modify-then-replace pattern breaks `#id`; tag-with-id (`h1#id`), descendant from class (`.cls h1`), and attribute equals (`[id="id"]`) keep working.
   - **Gem fix (2026-04-25)**: `lib/capybara/lightpanda/javascripts/index.js` patches `Document.prototype.querySelector{,All}` and `Element.prototype.querySelector{,All}` to rewrite `#id` → `[id="id"]` in user-supplied selectors before delegating to the native engine. The rewriter walks the selector char-by-char, tracks bracket depth and quoted strings so it leaves attribute values like `[href="#frag"]` untouched, and supports compound selectors (`h1.foo#bar.baz`), pseudo-class arguments (`:not(#x)`), commas, and Unicode/escape identifier chars. 19/19 unit cases pass.
   - **Verification (2026-04-25)**: `bundle exec rake spec` → 134/134 (1 unrelated pending cookies-on-redirect). `ruby examples/rails_turbo_rspec_example.rb` → 9/9 with Turbo Drive **enabled** against real Rails+Turbo 8.0.12.
   - **Disabler removed**: the `Turbo.session.drive = false` auto-disabler IIFE that was at `javascripts/index.js:48-63` is gone. Turbo Drive runs natively. The previous disabler-asserting spec at `driver_spec.rb:605` was replaced with a polyfill regression test.
   - **Remaining gem workaround**: `fetch()` + `document.write()` submit bypass in `CLICK_JS` (`lib/capybara/lightpanda/node.rb:161-203`). Form-submit tests route through this; left in place pending a separate investigation.
   - **Upstream fix in flight (PR #2244, OPEN, 2026-04-25, filed by us)**: root-cause patch in `Frame.getElementByIdFromNode`. The fast path used by the selector engine for `#id` only checked the `lookup` map; after a body removal the original `<h1>` lived in `_removed_ids` and the new `<h1>` was never re-registered, so `lookup.get(id)` missed and `getElementByIdFromNode` returned null. The fix mirrors the existing `Document.getElementById` / `ShadowRoot.getElementById` recovery: on a `lookup` miss, walk `removed_ids` + the scope root and re-register. Adds an HTML test asserting `querySelector('#id')`, `querySelectorAll('#id')`, and `getElementById('id')` all agree after duplicate removal. Once merged, the gem-side `querySelector{,All}` rewriter polyfill can be removed.
   - **Turbo Frames (GET navigation)**: Already work — lazy-loading via `src=` and scoped link navigation use Turbo's fetch + innerHTML replacement on the frame element.

### Open Fix PRs (not yet merged)

- **PR #2244**: **Fix `Frame.getElementByIdFromNode` to recover from removed_ids** (filed by us) — **DIRECTLY UNBLOCKS removing the gem-side `#id` rewriter**. Mirrors the `Document.getElementById` / `ShadowRoot.getElementById` recovery into `Frame.getElementByIdFromNode` (the selector engine's `#id` fast path), so `querySelector('#id')` no longer returns `null` after the body's been mutated via `innerHTML` and replaced (Turbo Drive's `PageRenderer.replaceBody` pattern). PR includes a regression test in `src/browser/tests/element/duplicate_ids.html`. See Known Bug #7. When merged: remove the `Document.prototype.querySelector{,All}` and `Element.prototype.querySelector{,All}` patches from `lib/capybara/lightpanda/javascripts/index.js` and the polyfill regression test from `driver_spec.rb`.
- **PR #2241**: **browser: bound per-tick memory growth on JS-heavy pages** — caps `HttpClient.processMessages` at 16 completions per tick and fires `memoryPressureNotification(.moderate)` once a second from `Runner._wait`. Our gem uses CDP not fetch, but if the cap also lands on the CDP path it should harden long-lived sessions on heavy SPAs.
- **PR #2237**: **window.open** — limited support: no `target=window_name`/`_blank`, sub-pages share the parent's lifetime, no CDP-side validation. Useful for sites that call `window.open` defensively (login popups). Capybara tests that open popups would previously have errored — they'd now work for the duration of the parent page.
- **PR #2172**: **Improve safety of Node.replaceChild and Element.replaceWith** — DOM manipulation stability; Turbo Drive exercises both paths.
- **PR #2157**: **Feat: add full SVG DOM support** — could affect tests that interact with SVG elements (icons, charts).
- **PR #2078**: **WIP: Worker** — Web Workers implementation starting. Would fix #2017. Major new capability if/when shipped.
- **PR #2077**: **fix: Target.attachToTarget returns unique session id per call** — fixes bug where multiple `attachToTarget` calls return the same session ID. Our gem only calls `attachToTarget` once per page, but improves CDP spec compliance.

### Upstream Open Issues That Affect This Gem

| Issue | Impact | Description |
|---|---|---|
| #2187 | CDP | **`Runtime.evaluate` after click-driven navigation fails with "Cannot find default execution context"**. DIRECTLY RELEVANT: our `Node#call` already wraps in `Utils.with_retry(errors: [NoExecutionContextError], max: 3, wait: 0.1)` and the driver's `invalid_element_errors` includes `NoExecutionContextError`. Keep retry logic until this is fixed. |
| #2175 | JS/CDP | **Implement `<input type="file">` support**. Aligned with our existing `NotImplementedError` in `Node#set` for file inputs. |
| #2173 | Crash | `TargetClosedError` navigating to React apps via CDP — browser crashes. Our `handle_navigation_crash` reconnect logic covers this, but would appear as `DeadBrowserError` after retry. |
| #2043 | CDP | Roadmap discussion for CDP automation features (setFileInputFiles, Input events, dialog, history, window.open); directly relevant to our workarounds. |
| #1890 | Navigation | Multi-step form POST does not update page content (SAP SAML login). |
| #1801 | Navigation | `Page.navigate` never completes for Wikipedia. Drives our readyState polling fallback. |
| #2017 | JS | Implement Worker and SharedWorker (PR #2078 WIP). |

### General Limitations

- Many Web APIs not yet implemented (hundreds remain)
- Complex JS frameworks may not work (React SSR hydration, heavy SPA)
- `window.getComputedStyle()` significantly improved — CSSOM merged (PR #1797, 2026-03-23); `checkVisibility` matches all active stylesheets
- No `window.scrollTo()`, `element.scrollIntoView()` (no layout)
- `MutationObserver` now available (PR #1870, reference counting; weak refs disabled by PR #1887)
- `window.postMessage` across frames now works (PR #1817)
- No CORS enforcement (acknowledged in upstream README as of 2026-03-27)
- In-page `WebSocket` API now implemented (PR #2179 merged 2026-04-18, closes #1952)
- No Web Workers, Service Workers, SharedArrayBuffer (PR #2078 WIP for Worker support)
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
- Latest release: 0.2.9 (2026-04-24). Tags now drop the `v` prefix (`0.2.9`, `0.2.8`); pre-2026-04 tags still use `v` (`v0.2.6`, `v0.2.5`). Asset matrix per release: `lightpanda-{aarch64,x86_64}-{linux,macos}` plus `lightpanda-0.2.9-1-{aarch64,x86_64}.pkg.tar.zst` (Arch).

## Differences from Chrome/Chromium CDP

When writing CDP interactions, be aware of these divergences:

1. **Event timing**: CDP events may arrive in different order than Chrome
2. **Error responses**: Error messages/codes differ from Chrome's (e.g., `InvalidParams` instead of specific error codes)
3. **Missing methods**: Not all methods within a domain are implemented; unsupported methods return errors
4. **Parameter rejection**: `Network.deleteCookies` now silently ignores `partitionKey` (PR #1821, merged 2026-03-16)
5. **Session management**: `Target.detachFromTarget` now sends `detachedFromTarget` event (PR #1929, fixes #1819)
6. **Frame tree**: Frame ID mismatch on STARTUP fixed (PR #1949, fixes #1800)
7. **Accessibility**: ARIA snapshots are more verbose than Chrome's (#1813)

## Development Tips

- Always test against Lightpanda nightly — behavior changes frequently
- When a CDP command fails, check if it's a known limitation before debugging
- Wrap CDP calls that might crash the connection in error handlers
- Prefer `Runtime.evaluate` for operations where direct CDP methods are unreliable
- Use `returnByValue: true` in `Runtime.evaluate` to get serialized values (avoids objectId lifetime issues)
- When adding new CDP interactions, verify the method exists in the corresponding domain .zig file upstream
