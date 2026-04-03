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
| **Page** | page.zig | Navigation, events, screenshots (1920x1080 PNG), reload (PR #1992), addScriptToEvaluateOnNewDocument (PR #1993); NO history/dialog methods |
| **Performance** | performance.zig | Performance metrics |
| **Runtime** | runtime.zig | JS evaluation, object inspection |
| **Security** | security.zig | Security state |
| **Storage** | storage.zig | Storage state; `createContext` with storage state fails (#1550) |
| **Target** | target.zig | Target/session management |

### CDP Methods Used by This Gem

All verified present in upstream as of 2026-04-03:

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
Page.handleJavaScriptDialog  → not in page.zig (modal code guarded with rescue BrowserError)
Network.getAllCookies         → does not exist; gem uses Network.getCookies
```

### Available CDP Methods (not yet used by this gem)

```
Page.createIsolatedWorld     Page.getFrameTree
Page.addScriptToEvaluateOnNewDocument  (WORKING — PR #1993 merged 2026-03-30)
Page.removeScriptToEvaluateOnNewDocument (PR #1993 merged 2026-03-30)
Page.setLifecycleEventsEnabled  Page.stopLoading (stub)    Page.close
DOM.resolveNode              DOM.getBoxModel (now returns real getBoundingClientRect geometry)
DOM.describeNode             DOM.scrollIntoViewIfNeeded
DOM.performSearch            DOM.getSearchResults        DOM.discardSearchResults
DOM.getContentQuads          DOM.requestChildNodes
DOM.getFrameOwner            DOM.getOuterHTML            DOM.requestNode
Input.dispatchMouseEvent     Input.dispatchKeyEvent      Input.insertText
Network.setCookies (batch)   Network.getResponseBody
Network.setExtraHTTPHeaders  Network.setCacheDisabled (stub)
Network.setUserAgentOverride (stub)
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

7. **Turbo Drive / Turbo form submission broken — `document.body` is read-only**
   - **Root cause**: `HTMLDocument.body` accessor in `src/browser/webapi/HTMLDocument.zig:254` has no setter (`bridge.accessor(HTMLDocument.getBody, null, .{})`). `document.body = newBody` silently fails.
   - **Turbo Drive**: fetches page via JS `fetch()`, extracts `<body>`, tries `document.body = newBody` → fails → page blanks. Gem auto-disables Drive via `Turbo.session.drive = false` polled from injected JS.
   - **Turbo form submission in frames**: Turbo intercepts `requestSubmit()`, does a fetch POST, tries to extract matching `<turbo-frame>` from response and replace it via DOM manipulation → fails with JsException. Gem bypasses by using `fetch()` + `document.write()` for submit buttons when Turbo is detected.
   - **Turbo Frames (GET navigation)**: Work correctly — lazy-loading via `src=` and scoped link navigation use Turbo's fetch + innerHTML replacement on the frame element, which works.
   - **Potential upstream fix**: Add `setBody()` to HTMLDocument.zig (spec: https://html.spec.whatwg.org/multipage/dom.html#dom-document-body). Would fix Turbo Drive and likely Turbo Stream rendering.
   - **Turbo Streams**: Not supported. Depend on Turbo's form submission pipeline completing. Even if `document.body` setter were fixed, streams use `<turbo-stream>` custom elements with `connectedCallback` which may have additional issues.

### Recently Merged Fixes (v0.2.7 and nightly)

- **PR #2075**: **use proxy for integration tests** (merged 2026-04-03) — CI only, no runtime impact.
- **PR #2074**: **Store TAO in IdentityMap** (merged 2026-04-03) — internal memory management: stores tree-accessible objects in IdentityMap. No API changes.
- **PR #2073**: **stricter Page.isSameOrigin** (merged 2026-04-02) — **SECURITY FIX**: origin comparison now properly validates full origin. Previously `https://origin.com` could match `https://origin.com.attacker.com`. No impact on our gem (we don't do cross-origin navigation tricks).
- **PR #2069**: **Move finalizers to pure reference counting** (merged 2026-04-02) — internal memory management refactor. All finalizers now use pure reference counting instead of mixed weak-ref/RC approach. Should improve stability.
- **PR #2071**: **Relax assertion on httpclient abort** (merged 2026-04-02) — stability fix: relaxes an assertion that could trigger during HTTP client abort. Prevents potential crashes during network error recovery.
- **PR #2066**: **mcp: improve navigation reliability and add CDP support** (merged 2026-04-03) — MCP-focused: fixes inactivity timeout handling, handles `CDPWaitResult.done` instead of `unreachable`. Server-side fix for CDP wait results — could indirectly improve stability.
- **PR #2068**: **markdown: simplify and optimize anchor rendering** (merged 2026-04-02) — MCP markdown output only.
- **PR #2067**: **percent encode version query string for crash report** (merged 2026-04-01) — internal telemetry fix.
- **PR #2014**: **build: add check step to verify compilation** (merged 2026-04-01) — CI improvement, no runtime impact
- **PR #2064**: **Improve network naming consistency** (merged 2026-04-01) — internal refactor: `Runtime.zig` renamed to `Network.zig` in HTTP client code. No CDP-level changes.
- **PR #2061**: **Add `Element.ariaAtomic` and `Element.ariaLive` properties** (merged 2026-04-01) — ARIAMixin attribute reflection on Element per ARIA spec. Improves accessibility support.
- **PR #2060**: **Add `HTMLAnchorElement.rel` property** (merged 2026-04-01) — string `rel` accessor on anchor elements (the `relList` DOMTokenList was already implemented).
- **PR #2057**: **Add `HTMLElement.title` property** (merged 2026-04-01) — getter/setter reflecting the `title` HTML attribute. Our `Node#[]` uses `getAttribute` so no impact, but `element.title` now works in JS.
- **PR #2046/2065**: **Fix URL resolve path scheme** (merged 2026-04-01) — fixes URL resolution for paths with scheme prefixes per URL spec. Could affect URL handling in navigation.
- **PR #2055**: **Add `HTMLElement.dir` and `HTMLElement.lang` properties** (merged 2026-03-31) — attribute-backed accessors on HTMLElement and HTMLDocument.
- **PR #2054**: **`URLSearchParams`: support passing arrays to constructor** (merged 2026-03-31) — spec compliance for URLSearchParams.
- **PR #2051**: **Provide a failing callback to ValueSerializer for host objects** (merged 2026-03-31) — prevents V8 assertion failure when serializing Zig DOM objects. Fixes crash path (returns error instead of panic).
- **PR #2052**: **Expand the lifetime of the XHR reference** (merged 2026-03-31) — fixes race condition where V8 could drop XHR reference before HTTP start callback. Prevents use-after-free crashes.
- **PR #2047**: **Add `--wait-selector`, `--wait-script` and `--wait-script-file` options to fetch** (merged 2026-03-31) — CLI-only, no CDP impact.
- **PR #2036**: **Removing remaining CDP generic** (merged 2026-03-31) — internal refactor removing generic CDP dispatcher code. BrowserContext and Command are now non-generic. No method-level changes, but error messages/codes for unsupported methods may differ.
- **PR #2032**: **Improve/Fix CDP navigation event order** (merged 2026-03-30) — **MAJOR CHANGE**: `Page.frameNavigated` now fires on header response (earlier than before). New explicit DOMContentLoaded/Loaded events separated from `pageNavigated`. Context clear+reset now happens after main page navigation but before frame creation. New event flow: `Start Page Navigation → Response Received → End Page Navigation → context clear+reset → Start Frame Navigation → Response Received → End Frame Navigation → DOMContentLoaded → Loaded`. Our `Page.loadEventFired` listener should still work since "Loaded" fires at the end. ReadyState fallback remains essential.
- **PR #2044**: HTTP: add connect code into auth challenge detection (merged 2026-03-30) — improves HTTP auth handling
- **PR #2028**: Protect transfer.kill() the way transfer.abort() is protected (merged 2026-03-30) — network stability improvement
- **PR #2024**: Rework finalizers (merged 2026-03-30) — internal memory management refactor
- **PR #2022/#2033**: Cache canvas 2D context and lock context type per spec (merged 2026-03-30) — spec compliance
- **PR #2021**: Fix `navigator.languages` to include base language per spec (merged 2026-03-30) — e.g. returns `["en-US", "en"]` instead of just `["en-US"]`
- **PR #1993**: **CDP: implement `Page.addScriptToEvaluateOnNewDocument`** (merged 2026-03-30, filed by us) — replaces the hardcoded stub with a working implementation. Scripts stored on `BrowserContext`, evaluated after context clear+reset but before frames and DOMContentLoaded (post PR #2032 event reorder). Also adds `Page.removeScriptToEvaluateOnNewDocument`. Eliminates need to re-inject XPath polyfill after every navigation.
- **PR #2031**: Follow-up to #1993 — internal refactoring for addScriptToEvaluateOnNewDocument (merged 2026-03-30)
- **PR #2026**: Add missing `InvalidAccessError` DOMException mapping (merged 2026-03-30)
- **PR #1889**: **Rework header/data callbacks in HttpClient** (merged 2026-03-27) — major refactor: disables libcurl built-in redirects, follows redirect chain explicitly in processMessages. Moves data callbacks to processMessages for thread safety. Could affect redirect behavior, cookie handling on redirects, and response timing.
- **Commit 9068fe71**: **Fix SameSite cookies** (2026-03-27) — passes `cookie_origin` (top-level URL) instead of subrequest URL for SameSite evaluation. Fixes incorrect SameSite=Strict/Lax cookie inclusion on cross-origin subrequests.
- **PR #2005**: MCP/CDP: unify node registration (merged 2026-03-27) — internal refactor
- **PR #2002**: Support `FormDataEvent` (merged 2026-03-27) — enables `formdata` event handling in JS context
- **PR #2011**: MCP fixes (merged 2026-03-27)
- **PR #2009**: MCP: improve argument parsing error handling (merged 2026-03-27)
- **PR #2008**: Fix dead code and error swallowing warnings (merged 2026-03-27)
- **PR #1992**: **CDP: implement `Page.reload`** (merged 2026-03-26) — proper reload navigation via `NavigationKind.reload`. Accepts `ignoreCache` and `scriptToEvaluateOnLoad` params per CDP spec. Gem adopted via `page_command("Page.reload")` in `Browser#refresh`. Filed by us.
- **PR #2004**: `ResizeObserver.unobserve` available in JS context (merged 2026-03-26)
- **PR #2003**: `CanvasRenderingContext2D` canvas element access (merged 2026-03-26)
- **PR #1998**: Improve authority parsing (merged 2026-03-26) — URL parsing improvements
- **PR #1999**: Fix `--wait-until` default value (merged 2026-03-26)
- **PR #1991**: Set v8::Signature on FunctionTemplates (merged 2026-03-26) — V8 binding correctness
- **PR #1997**: Bump zig-v8 to v0.3.7 (merged 2026-03-26)
- **PR #1990**: Remove CDP generic dispatcher (merged 2026-03-25) — internal refactor
- **PR #1985**: Allow Document as root of IntersectionObserver (merged 2026-03-25)
- **PR #1981**: Window cross-origin scripting improvements (merged 2026-03-25)
- **PR #1984**: Fix `Form.requestSubmit(submitter)` not setting `SubmitEvent.submitter` (merged 2026-03-25) — `e.submitter` was always `null`; now correctly set per WHATWG spec. Critical for Turbo/Stimulus/Rails UJS that inspect `e.submitter` for `formaction`/`formmethod` overrides. Our `CLICK_JS` uses `form.requestSubmit(this)` and benefits directly.
- **PR #1987**: Handle `Connection: close` without TLS `close_notify` (merged 2026-03-25) — fixes network errors on servers like ec.europa.eu that close TCP without TLS alert
- **PR #1951**: MCP: add `detectForms` tool for structured form discovery (merged 2026-03-25)
- **PR #1979**: Support (and prefer) dash-separated CLI arguments (merged 2026-03-24) — e.g. `--log-format` preferred over `--log_format`
- **PR #1977**: Only check StyleSheet dirty flag at start of operation — CSS perf optimization (merged 2026-03-24)
- **PR #1972**: Fix Expo Web crash by gracefully handling at-rules in CSSStyleSheet.insertRule (merged 2026-03-24)
- **PR #1975**: Percent-encode pathname in URL.setPathname per URL spec (merged 2026-03-23)
- **PR #1969**: Handle `appendAllChildren` mutating children list — DOM stability fix (merged 2026-03-23)
- **PR #1968**: Handle nested `document.write` where parent gets deleted — DOM stability fix (merged 2026-03-23)
- **PR #1967**: Anchor(...) CSS property normalization (merged 2026-03-23)
- **PR #1964**: Add `Image.currentSrc` and `Media.currentSrc` (merged 2026-03-23)
- **PR #1963**: Use double-queue for recursive navigation — navigation stability (merged 2026-03-23)
- **PR #1959**: Expose `form.iterator()` (merged 2026-03-23)
- **PR #1955**: Add `--advertise_host` option to serve command (merged 2026-03-23)
- **PR #1948**: CDP: add `waitForSelector` to `lp.actions` (merged 2026-03-23)
- **PR #1946**: Encode non-UTF8 `Network.getResponseBody` in base64 (merged 2026-03-23)
- **PR #1797**: Implement CSSOM and Enhanced Visibility Filtering — `insertRule`/`deleteRule`/`replace`/`replaceSync`, `checkVisibility` now matches all active stylesheets (merged 2026-03-23)
- **PR #1949**: Fix Page.getFrameTree on STARTUP when browser context and target exist — fixes #1800 frame ID mismatch (merged 2026-03-21)
- **PR #1945**: Add validation to `replaceChildren` (merged 2026-03-21)
- **PR #1944**: Fix `new URL('about:blank')` parsing (merged 2026-03-21)
- **PR #1942**: Search for base page when resolving from about:blank — improves about:blank URL handling (merged 2026-03-21)
- **PR #1939**: More aggressive timer cleanup — reduces timer leaks (merged 2026-03-21)
- **PR #1933**: Optimize CSS visibility engine with lazy parsing and cache-friendly evaluation (merged 2026-03-20)
- **PR #1929**: Send `Target.detachedFromTarget` event on detach — fixes #1819 (merged 2026-03-20)
- **PR #1927**: Fetch `wait_until` parameter for page load options (merged 2026-03-20)
- **PR #1925**: Return correct errors in promise rejections (merged 2026-03-20)
- **PR #1918**: Add `adoptedStyleSheets` property to ShadowRoot (merged 2026-03-19)
- **PR #1916**: Add `Request.signal` — AbortController support for fetch (merged 2026-03-19)
- **PR #1915**: Improve unhandled rejection handling (merged 2026-03-19)
- **PR #1911/1884**: Stub `navigator.permissions`, `navigator.storage`, `navigator.deviceMemory` — unblocks Cloudflare Turnstile (merged 2026-03-19)
- **PR #1900**: Dispatch `InputEvent` on input/TextArea changes — native InputEvent support (merged 2026-03-18)
- **PR #1898**: Keyboard events are now bubbling, cancelable, and composed (merged 2026-03-18)
- **PR #1897**: Introduce StyleManager — foundation for CSS support (merged 2026-03-18)
- **PR #1901**: Remove Origins (internal refactor) (merged 2026-03-20)
- **PR #1891**: Implement `Form.requestSubmit` — our `Node#click` CLICK_JS now has native support for this (merged 2026-03-18)
- **PR #1885**: Fallback to Incumbent Context when Current Context is dangling — reduces "execution context destroyed" errors (merged 2026-03-18)
- **PR #1902**: `Emulation.setUserAgentOverride` now logs when ignored instead of silent (merged 2026-03-18)
- **PR #1899**: Only run idle tasks from root page (merged 2026-03-18)
- **PR #1894**: SemanticTree: implement interactiveOnly filter and optimize token usage (merged 2026-03-18)
- **PR #1893**: Expand rel's that trigger link onload (merged 2026-03-18)
- **PR #1887**: Disable MutationObserver/IntersectionObserver weak refs — fixes #1887 stability issues (merged 2026-03-17)
- **PR #1882**: Special-case `Window#onerror` per WHATWG spec (5-arg signature) (merged 2026-03-17)
- **PR #1878**: Implement `window.event` property (merged 2026-03-17)
- **PR #1877**: Support blob URLs in XHR and Fetch (merged 2026-03-17)
- **Commit 58641335**: Close all CDP clients on shutdown — cleaner process termination (2026-03-17)
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

- **PR #2078**: **WIP: Worker** (OPEN, WIP) — Web Workers implementation starting. Would fix #2017. Major new capability.
- **PR #2077**: **fix: Target.attachToTarget returns unique session id per call** (OPEN) — fixes bug where multiple `attachToTarget` calls return the same session ID (breaking Playwright). Our gem only calls `attachToTarget` once per page, but this fix improves CDP spec compliance. Adds `alt_session_id` slot for second attach.
- **PR #2070**: **mcp: Add hover, press, selectOption, setChecked** (OPEN) — MCP interaction tools. No CDP impact.
- **PR #2063**: **WebSocket WebAPI** (OPEN, WIP) — implements in-page `WebSocket` API using libcurl. Would fix #1952. Major new capability once merged.
- **PR #2062**: **Add `XMLHttpRequest.timeout` with curl enforcement** (OPEN) — JS-visible timeout property for XHR, enforced via CURLOPT_TIMEOUT_MS.
- **PR #2035**: **Add `--user-agent` flag for full User-Agent override** (OPEN) — CLI flag for setting User-Agent. Could be useful for our driver if we want to customize UA.

### Upstream Open Issues (verified 2026-04-03)

| Issue | Impact | Description | Filed by us |
|---|---|---|---|
| #2072 | MCP | MCP server exits immediately — incompatible with Claude Code persistent sessions. Doesn't affect CDP mode or our gem. | |
| #2020 | Crash | Crash on load event dispatch on kitandace.com — `Image` element as event target causes GPF in `asEventTarget()`. SIGSEGV in serve mode. | |
| #2043 | CDP | Roadmap discussion for CDP automation features (setFileInputFiles, Input events, dialog, history, window.open); directly relevant to our workarounds | |
| #2019 | CDP | Playwright CDP fails to connect on Bun (WebSocket closes with 1006); Bun-specific, doesn't affect us | |
| #1962 | CDP | `Target.createTarget` fails with `-31998 TargetAlreadyLoaded` on second call (Stagehand; we only call once, low risk) | |
| #1953 | CDP | Missing console API coverage breaks `console.log` interception | |
| #1952 | JS | `WebSocket` not defined in page context (PR #2063 WIP to fix) | |
| #1932 | CDP | Missing Chromium-style discovery endpoints (`/json`, `/json/list`); doesn't affect us | |
| #1892 | CDP | Multiclient: closing one CDP connection kills all other active connections (re-filed from #1848) | |
| #1890 | Navigation | Multi-step form POST does not update page content (SAP SAML login) | |
| #1839 | CDP | Session management assertion error in Playwright | |
| #1838 | CDP | CRSession._onMessage crash in Playwright | |
| #1832 | Navigation | `Page.navigate` response never sent on some sites | |
| #1830 | Startup | Port-already-in-use not handled gracefully (PR #1883 adds better error message, but no auto-recovery) | |
| #1816 | Crash | Segfault in serve mode with jQuery Migrate scripts | |
| #1801 | Navigation | `Page.navigate` never completes for Wikipedia | |
| #2017 | JS | Implement Worker and SharedWorker (PR #2078 WIP) | |
| #2015 | JS | Implement CORS mechanism | |
| #1550 | Storage | Creating context with storage state fails | |

### Closed Issues We Filed

| Issue | Outcome |
|---|---|
| #1849 | Closed (2026-03-16) — Fixed by PR #1850: CDP WebSocket no longer dies during complex navigation |
| #1848 | Closed (2026-03-18) — Multiclient connection kills; re-filed as #1892 with more detail |
| #1887 | Merged (2026-03-17) — PR disabled observer weak refs, fixing MutationObserver stability |
| #1843 | Closed (2026-03-15) — Fixed by PR #1845: Unknown CDP methods no longer kill WebSocket |
| #1842 | Closed — was our driver bug (`switch_to_frame` passed Capybara wrapper instead of native Node) |
| #1844 | Closed — cascading from #1843, not a real stability issue. 500+ commands work fine. |

### Recently Closed Tracked Issues

| Issue | Outcome |
|---|---|
| #1738 | Closed (2026-04-01) — SIGSEGV when fetching nist.gov. Fixed in latest nightly. Related SIGSEGV issues remain (PR #2050 open for Sentry/GTM crash path). |
| #1922 | Closed (2026-03-27) — WebSocketDebuggerUrl 0.0.0.0 issue resolved. Docker/remote only; never affected us. |
| #1900 | Merged (2026-03-18) — `InputEvent` now dispatched natively on input/TextArea changes. Our `SET_VALUE_JS` uses programmatic `.value =` which should NOT trigger native events (Chrome behavior), but monitor for double-event issues. |
| #1819 | Closed (2026-03-20) — Fixed by PR #1929: `Target.detachFromTarget` now sends `detachedFromTarget` event properly |
| #2050 | Closed (2026-04-01) — PR closed without merging. Null pointer SIGSEGV fix for Sentry/GTM crash path. Issue #1738 already closed separately. |
| #2039 | Closed (2026-03-30) — PR closed without merging. Was auto-close existing target on createTarget. Issue #1962 remains open. |
| #2040 | Closed — PR closed without merging; URL resolve path scheme work completed in PR #2046/2065 (merged 2026-04-01) |
| #1800 | Closed (2026-03-21) — Fixed by PR #1949: Frame ID mismatch in `Page.getFrameTree` resolved |

### General Limitations

- Many Web APIs not yet implemented (hundreds remain)
- Complex JS frameworks may not work (React SSR hydration, heavy SPA)
- `window.getComputedStyle()` significantly improved — CSSOM merged (PR #1797, 2026-03-23); `checkVisibility` matches all active stylesheets
- No `window.scrollTo()`, `element.scrollIntoView()` (no layout)
- `MutationObserver` now available (PR #1870, reference counting; weak refs disabled by PR #1887)
- `window.postMessage` across frames now works (PR #1817)
- No CORS enforcement (acknowledged in upstream README as of 2026-03-27)
- No WebSocket API in page context yet (CDP WebSocket is separate) — PR #2063 WIP to add `WebSocket` WebAPI
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
- Latest release: v0.2.8 (2026-04-02), also v0.2.7, v0.2.6, v0.2.5, v0.2.4 available

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
