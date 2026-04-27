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

1. **`Page.loadEventFired` unreliable** (#1801)
   - May never fire on complex JS pages, Wikipedia, certain French real estate sites
   - **#1849 fixed** (PR #1850, merged 2026-03-16): WebSocket no longer dies during complex navigation, so readyState polling now works reliably as a fallback
   - **PR #2032** (merged 2026-03-30) reordered navigation events: `Loaded` (= `Page.loadEventFired`) now fires after DOMContentLoaded, at the very end of the navigation sequence. This is closer to Chrome's behavior and may improve reliability, but #1801 remains open.
   - **#1832 closed** (2026-04-09): the guy-hoquet.com URL no longer hangs `Page.navigate`, but the broader category (#1801) is still open and the readyState fallback is still load-bearing.
   - This gem works around it with `document.readyState` polling fallback in `Browser#go_to`
   - DO NOT remove the readyState fallback — `Page.loadEventFired` itself is still unreliable (#1801 still open)

2. **`Network.clearBrowserCookies` + `Network.getAllCookies`** — fix MERGED upstream, NOT yet in nightly (verified 2026-04-27 on `1.0.0-nightly.5816+a578f4d6`)
   - **History**: PR #1821 (>= v0.2.6) added the missing `clearRetainingCapacity()` call on the in-memory cookie jar (stopped the WebSocket crash). But an inverted-logic guard in `clearBrowserCookies` then rejected any caller sending `params: {}` (which is most CDP clients) with `InvalidParams`. `Network.getAllCookies` was missing from the dispatch enum entirely.
   - **PR #2255 MERGED 2026-04-27 04:15 UTC, by us** — drops the inverted guard and adds `getAllCookies` to the dispatch. NOT in today's nightly (`5816`, built 03:18 UTC, ~57 min before the merge). Empirically verified on 5816: `Network.getAllCookies` → `UnknownMethod`, `Network.clearBrowserCookies` (empty params) → `InvalidParams`.
   - **Action when next nightly ships**: bump `MINIMUM_NIGHTLY_BUILD` past the post-merge build, then in `Cookies#clear` drop the per-origin `sweep_visited_origins` workaround and trust the bulk `clearBrowserCookies` call. Also switch `Cookies#all` to `Network.getAllCookies` (currently `Network.getCookies`, origin-scoped). Removes `Browser#visited_origins`, `record_visited_origin`, and the `sweep_visited_origins` private method (~50 LOC total).
   - Until then, the existing workaround stands: `Cookies#clear` calls `clearBrowserCookies` (currently no-op), then sweeps per-origin via `Network.getCookies(urls: visited_origins)` + `Network.deleteCookies(url: ...)`. `Browser#visited_origins` accumulates `scheme://host:port` strings as the gem navigates.
   - `Network.getCookies` (without `urls`) is scoped to the current page's origin — cookies on previously-visited domains are invisible from a different page; `Network.getCookies` on `about:blank` raises `InvalidDomain`. The `urls:` parameter accepts a list and returns cross-domain cookies (verified working).
   - `Network.deleteCookies(name:, url:)` works correctly per-origin.

3. **`XPathResult` not implemented**
   - `document.evaluate` and the `XPathResult` interface do not exist in Lightpanda
   - This gem injects a JS polyfill that converts XPath to CSS selectors (~80% coverage)
   - Polyfill is auto-injected on every navigation via `Page.addScriptToEvaluateOnNewDocument` (PR #1993, merged 2026-03-30) — registered once at session creation in `Browser#create_page`. No manual re-injection on each `visit` is needed.

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
   - JS execution context is reset on every page load: globals, polyfills, and any custom functions evaluated in a previous document are gone.
   - Polyfills are auto-injected on every navigation via `Page.addScriptToEvaluateOnNewDocument` (PR #1993, merged 2026-03-30), registered once at session creation in `Browser#create_page`. Ad-hoc `Runtime.evaluate` calls still need to be re-run after each `visit`.
   - Node references (objectIds) become invalid after navigation

7. **Turbo Drive `#id` selector engine bug — FULLY RESOLVED (upstream + gem, 2026-04-27)**
   - **History**: `document.body = newBody` setter was missing → fixed by PR #2215 (merged 2026-04-23, shipped in nightly 2026-04-24). After that landed, the CSS selector engine still had a bug: `querySelector('#id')` / `querySelectorAll('#id')` returned null / `[]` after the body was mutated via `innerHTML` and then replaced via `replaceWith` (Turbo Drive's snapshot-then-swap pattern). `getElementById('id')` and `[id="id"]` always worked; only the `#id` shorthand was broken because `Frame.getElementByIdFromNode` (the fast path) only consulted the `lookup` map and missed elements that had moved to `_removed_ids` after a body removal.
   - **Upstream fix (PR #2244, merged 2026-04-27 00:46 UTC, commit `e1e9a0d7`, filed by us)**: on `lookup` miss, walk `_removed_ids` + scope root and re-register, mirroring the existing `Document.getElementById` / `ShadowRoot.getElementById` recovery.
   - **Confirmed in nightly 5816+** (`1.0.0-nightly.5816+a578f4d6`, built 2026-04-27 03:18 UTC). Empirically verified.
   - **Gem-side cleanup completed (2026-04-27)**: `Process::MINIMUM_NIGHTLY_BUILD` bumped to 5816 in `lib/capybara/lightpanda/process.rb`, the `Document.prototype.querySelector{,All}` / `Element.prototype.querySelector{,All}` rewriter IIFE was removed from `lib/capybara/lightpanda/javascripts/index.js`, the polyfill regression test was removed from `spec/features/driver_spec.rb`, and the gem-side polyfill mention was dropped from `CLAUDE.md`. `bundle exec rake spec:incremental` → 1396 examples, all pass (1 pre-existing #2187 frame-context flake).
   - **Disabler note (kept for context)**: the `Turbo.session.drive = false` auto-disabler that was previously at `javascripts/index.js:48-63` was removed earlier (2026-04-25). Turbo Drive runs natively.
   - **Remaining gem workaround for plain forms**: `fetch()` + body-innerHTML swap in `CLICK_JS` / `IMPLICIT_SUBMIT_JS` (`lib/capybara/lightpanda/node.rb`). Tracks Known Bug #9 and wishlist item A4 (`form.submit()` does not navigate). Independent of this `#id` issue.
   - **Turbo Frames (GET navigation)**: Already work — lazy-loading via `src=` and scoped link navigation use Turbo's fetch + innerHTML replacement on the frame element.

8. **`textContent` whitespace differs from Chrome** (surfaced 2026-04-26)
   - In Chrome, `<div>Ancestor<div>Ancestor<div>Ancestor<div>Child</div></div></div></div>.textContent` flattens to roughly `"AncestorAncestorAncestorChild"` (Capybara's `normalize_ws` collapses runs to single spaces). Lightpanda preserves the source-template whitespace differently, so `textContent` ends up with embedded newlines that survive normalization in different positions.
   - Surfaced via Capybara's `#ancestor` shared spec: `el.ancestor('//div', text: "Ancestor\nAncestor\nAncestor")` matches in Chrome but fails on Lightpanda because the candidate's normalized `textContent` doesn't equal that exact literal.
   - Affects any test that uses Capybara's `text:` filter (or `node.text` / `node.all_text` direct comparison) against a fixed literal containing newlines from multi-level nested fixtures.
   - Not a polyfill or `Node#==` issue — the XPath axes return the right nodes; only the text serialization differs. Lives in Lightpanda's html5ever / DOM text-node coalescing path.
   - **Workaround in tests**: prefer `text: /Ancestor/` (regex), drop the embedded `\n`s from the expectation, or compare on an attribute instead.

9. **`form.submit()` does NOT navigate** and **`document.write()` is a no-op** (verified 2026-04-26 against current nightly)
   - `form.submit()` (and the fall-through path of `form.requestSubmit()` after the submit event) parses and validates but never issues the HTTP request. The page stays on the original URL with the form still rendered.
   - `document.open(); document.write(html); document.close()` leaves `document.body.innerHTML.length` unchanged. No content is replaced.
   - Combined: any Capybara test that does `fill_in … ; click_button …; expect(page).to have_css(…)` against the response page would fail with the original `CLICK_JS` (which used `requestSubmit` for non-Turbo and `document.write` for Turbo bypass).
   - **Gem fix (`lib/capybara/lightpanda/node.rb` `CLICK_JS`, 2026-04-26)**: when a submit button is clicked, dispatch a `SubmitEvent` (so user/Turbo handlers can `preventDefault`), then if not prevented, **fetch the form action ourselves**, parse the response with `DOMParser`, swap `document.body.innerHTML`, and `history.replaceState(response.url)`. Skip the dispatch entirely when `typeof Turbo !== 'undefined'` (Turbo's own submit pipeline throws on Lightpanda; let the gem handle it). Polyfills (`_lightpanda`, XPath, `#id` rewriter) survive the swap because we don't reload the document.
   - Pinned by `driver_spec.rb` regression block "plain form submission (Lightpanda fetch+swap)".

### Open Fix PRs (not yet merged)

- **PR #2237**: **window.open** — limited support: no `target=window_name`/`_blank`, sub-pages share the parent's lifetime, no CDP-side validation. Useful for sites that call `window.open` defensively (login popups). Capybara tests that open popups would previously have errored — they'd now work for the duration of the parent page.
- **PR #2157**: **Feat: add full SVG DOM support** — could affect tests that interact with SVG elements (icons, charts).
- **PR #2077**: **fix: Target.attachToTarget returns unique session id per call** — fixes bug where multiple `attachToTarget` calls return the same session ID. Our gem only calls `attachToTarget` once per page, but improves CDP spec compliance.
- **PR #2259** (by us): **Page.reload replays POST**. Fixes #2258 — currently `Browser#refresh` (which calls `Page.reload`) silently downgrades a POST navigation to a GET. When merged: removes the `#refresh it reposts` skip pattern in `spec/spec_helper.rb`.
- **PR #2261** (by us): **handleJavaScriptDialog drives confirm/prompt return values**. Fixes #2260 — currently `accept_modal(:confirm|:prompt)` cannot influence the JS return value (Lightpanda auto-dismisses). When merged: rewires `Browser#prepare_modals` to call `Page.handleJavaScriptDialog` (off the dispatch thread); removes 4 modal skip patterns in `spec/spec_helper.rb`.
- **PR #2257** (by us): trigger navigation when `window.location.pathname` / `.search` is assigned. Currently only `.href =` navigates. When merged: removes 5 `assert_current_path` / `has_current_path` skip patterns.
- **PR #2264** (by us): skip FormData entry for `<select>` with no selectedness candidate. When merged: removes the `#click_button on HTML4 form should not serialize a select tag without options` skip pattern.
- **PR #2265** (by us): inherit URL fragment across fragment-less redirect. When merged: removes the `#current_url maintains fragment` skip pattern.
- **PR #2267** (by us): clamp `<input type=range>` value to min/max. When merged: removes `#fill_in with input[type="range"]` range-related skip patterns.

### Upstream Open Issues That Affect This Gem

| Issue | Impact | Description |
|---|---|---|
| #2187 | CDP | **`Runtime.evaluate` after click-driven navigation fails with "Cannot find default execution context"**. DIRECTLY RELEVANT: our `Node#call` already wraps in `Utils.with_retry(errors: [NoExecutionContextError], max: 3, wait: 0.1)` and the driver's `invalid_element_errors` includes `NoExecutionContextError`. Keep retry logic until this is fixed. |
| #2175 | JS/CDP | **Implement `<input type="file">` support**. Aligned with our existing `NotImplementedError` in `Node#set` for file inputs. |
| #2173 | Crash | `TargetClosedError` navigating to React apps via CDP — browser crashes. Our `handle_navigation_crash` reconnect logic covers this, but would appear as `DeadBrowserError` after retry. |
| #2043 | CDP | Roadmap discussion for CDP automation features (setFileInputFiles, Input events, dialog, history, window.open); directly relevant to our workarounds. |
| #1890 | Navigation | Multi-step form POST does not update page content (SAP SAML login). |
| #1801 | Navigation | `Page.navigate` never completes for Wikipedia. Drives our readyState polling fallback. |
| #2017 | JS | Implement Worker and SharedWorker. Partial Worker support landed (PR #2078 merged 2026-04-14, more APIs in PR #2208/#2218); SharedWorker still missing and many Worker APIs still unimplemented, so issue stays open. |
| #2258 | Navigation | `Page.reload` regresses POST navigations to GET. Affects `Browser#refresh` after a POST. Our PR #2259 OPEN. |
| #2260 | Modal | `Page.handleJavaScriptDialog` cannot influence `confirm()`/`prompt()` return values (Lightpanda auto-dismisses before handler runs). Our PR #2261 OPEN proposes a pre-arm model. |

### General Limitations

- Many Web APIs not yet implemented (hundreds remain)
- Complex JS frameworks may not work (React SSR hydration, heavy SPA)
- `window.getComputedStyle()` significantly improved — CSSOM merged (PR #1797, 2026-03-23); `checkVisibility` matches all active stylesheets
- No `window.scrollTo()`, `element.scrollIntoView()` (no layout)
- `MutationObserver` now available (PR #1870, reference counting; weak refs disabled by PR #1887)
- `window.postMessage` across frames now works (PR #1817)
- No CORS enforcement (acknowledged in upstream README as of 2026-03-27)
- In-page `WebSocket` API now implemented (PR #2179 merged 2026-04-18, closes #1952)
- Web Workers: partial support landed (PR #2078 merged 2026-04-14; PR #2208 merged 2026-04-23 added `URL`, `AbortController`, `AbortSignal` for workers; PR #2218 merged 2026-04-23 added `OffscreenCanvas` for workers). Many Worker APIs still missing — issue #2017 remains open. Workers run in the same thread as the page and have a separate context (`WorkerGlobalScope`, no `Window`/`Node`).
- No Service Workers, SharedArrayBuffer
- No `localStorage`/`sessionStorage` persistence across sessions
- File upload not supported (`input[type=file]` operations will fail)
- Long-lived sessions on JS-heavy pages now better-bounded (PR #2241 merged 2026-04-25): `HttpClient.processMessages` capped at 16 completions per tick and `memoryPressureNotification(.moderate)` fires once per second from `Runner._wait`, reducing per-tick memory blow-ups on heavy SPAs (e.g. github.com/features/copilot). Main-page lifetime now uses an `ArenaPool` arena rather than `page.arena` (PR #2245 merged 2026-04-26) so memory is released sooner after navigation.

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
