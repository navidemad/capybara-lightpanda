# Lightpanda Browser Reference

Upstream repo: https://github.com/lightpanda-io/browser
License: AGPL-3.0 | Status: Beta (stability and coverage improving)

Current nightly floor enforced by the gem: `Process::MINIMUM_NIGHTLY_BUILD = 6109` (XPath 1.0 evaluator + `Page.navigateToHistoryEntry`, both in nightly ≥6109).

## Architecture

- Written in **Zig 0.15.2**, JS execution via **V8**
- HTML parsing: **html5ever** (standards-compliant, handles malformed HTML)
- HTTP: **libcurl** (custom headers, proxies, TLS control)
- CSS: **CSSOM** — `insertRule`/`deleteRule`/`replace`/`replaceSync`, `checkVisibility` matches all active stylesheets; no full layout/paint/compositing
- Platforms: Linux x86_64, macOS aarch64, Windows via WSL2

## CDP Server

Launched with `lightpanda serve --host 127.0.0.1 --port 9222`. Clients connect via WebSocket at `ws://127.0.0.1:9222`. Compatible with Puppeteer, Playwright (partial), and chromedp.

### Implemented CDP Domains (18 total)

| Domain | File | Notes |
|---|---|---|
| **Accessibility** | accessibility.zig | AXNode support; aria snapshots noisier than Chrome (#1813) |
| **Browser** | browser.zig | Basic browser-level commands |
| **CSS** | css.zig | CSSOM: `insertRule`/`deleteRule`/`replace`/`replaceSync`; `checkVisibility` matches all stylesheets; CDP `CSS.getComputedStyleForNode` not yet implemented |
| **DOM** | dom.zig | 16 methods: `getDocument`, `querySelector`, `querySelectorAll`, `performSearch`, `resolveNode`, `describeNode`, `getBoxModel`, `getOuterHTML`, etc. |
| **Emulation** | emulation.zig | Viewport/device emulation stubs; `setUserAgentOverride` works |
| **Fetch** | fetch.zig | Network interception: `enable`, `disable`, `continueRequest`, `failRequest`, `fulfillRequest`, `continueWithAuth`; events: `requestPaused`, `authRequired` |
| **Input** | input.zig | `dispatchMouseEvent`, `dispatchKeyEvent`, `insertText` |
| **Inspector** | inspector.zig | Inspector lifecycle |
| **Log** | log.zig | Console/log message forwarding |
| **LP** | lp.zig | Lightpanda-specific extensions: `getMarkdown`, `getSemanticTree`, `getInteractiveElements`, `getNodeDetails`, `getStructuredData`, `detectForms`, `clickNode`, `fillNode`, `scrollNode`, `waitForSelector`, `handleJavaScriptDialog` (pre-arm), `configureLoading` (per-session opt-out for iframe/worker loading; was `setSubframeLoading` until PR #2426, also extended in PR #2440 to accept a `worker` flag) |
| **Network** | network.zig | Cookies (`getAllCookies`, `clearBrowserCookies` bulk both work), request/response interception, `setUserAgentOverride` |
| **Page** | page.zig | Navigation, events, screenshots (1920x1080 PNG), `reload`, `addScriptToEvaluateOnNewDocument`, `getNavigationHistory`/`navigateToHistoryEntry`, `javascriptDialogOpening` event. `handleJavaScriptDialog` deliberately errors (use `LP.handleJavaScriptDialog`). |
| **Performance** | performance.zig | Performance metrics |
| **Runtime** | runtime.zig | JS evaluation, object inspection |
| **Security** | security.zig | Security state |
| **Storage** | storage.zig | Storage state; `createContext` with storage state fails (#1550) |
| **Target** | target.zig | Target/session management |

### CDP Methods Used by This Gem

```
Target.createTarget          Target.attachToTarget
Target.createBrowserContext  Target.disposeBrowserContext
Page.enable                  Page.navigate
Page.reload                  Page.loadEventFired (event)
Page.addScriptToEvaluateOnNewDocument                    Page.getLayoutMetrics
Page.captureScreenshot       Page.javascriptDialogOpening (event)
Page.getNavigationHistory    Page.navigateToHistoryEntry
Runtime.enable               Runtime.evaluate
Runtime.callFunctionOn       Runtime.getProperties       Runtime.releaseObject
Runtime.executionContextCreated (event)                  Runtime.executionContextsCleared (event)
DOM.getDocument              DOM.querySelector           DOM.querySelectorAll
DOM.describeNode
Network.getAllCookies        Network.setCookie
Network.deleteCookies        Network.clearBrowserCookies
Network.enable               Network.disable
Network.setExtraHTTPHeaders  Network.requestWillBeSent (event)
Network.responseReceived (event)
LP.handleJavaScriptDialog
```

### CDP Methods Partially Implemented (event but no usable handler)

```
Page.handleJavaScriptDialog  → DISPATCH HANDLER EXISTS but DELIBERATELY ALWAYS ERRORS
                                with "-32000 No dialog is showing". Lightpanda-aware
                                clients pre-arm the accept/promptText response via
                                LP.handleJavaScriptDialog BEFORE the action that triggers
                                the dialog (Browser#accept_modal / #dismiss_modal).
                                The Page.javascriptDialogOpening event is emitted and
                                the gem captures the message text from there for
                                find_modal.
```

### Available CDP Methods (not yet used by this gem)

```
Page.createIsolatedWorld     Page.getFrameTree
Page.removeScriptToEvaluateOnNewDocument
Page.setLifecycleEventsEnabled  Page.stopLoading (stub)    Page.close
Page.printToPDF (fake PDF)
DOM.resolveNode              DOM.getBoxModel (returns real getBoundingClientRect geometry)
DOM.scrollIntoViewIfNeeded
DOM.performSearch            DOM.getSearchResults        DOM.discardSearchResults
DOM.getContentQuads          DOM.requestChildNodes
DOM.getFrameOwner            DOM.getOuterHTML            DOM.requestNode
Input.dispatchMouseEvent     Input.dispatchKeyEvent      Input.insertText
Network.setCookies (batch)   Network.getResponseBody
Network.setCacheDisabled (stub)
Runtime.addBinding           Runtime.runIfWaitingForDebugger (stub)
DOM.enable                   CSS.enable
Fetch.enable                 Fetch.disable
Fetch.continueRequest        Fetch.failRequest
Fetch.fulfillRequest         Fetch.continueWithAuth
Target.closeTarget           Target.getBrowserContexts
Target.getTargets            Target.getTargetInfo        Target.setAutoAttach
Target.setDiscoverTargets (stub)  Target.activateTarget (stub)
Target.attachToBrowserTarget Target.detachFromTarget     Target.sendMessageToTarget
LP.getSemanticTree           LP.getInteractiveElements
LP.getStructuredData         LP.waitForSelector
LP.getMarkdown               LP.getNodeDetails
LP.detectForms               LP.clickNode
LP.fillNode                  LP.scrollNode
LP.configureLoading          (per-session opt-out for iframe AND/OR worker loading,
                              params {subFrame, worker}; NOT applicable to this gem —
                              disabling subframes breaks switch_to_frame/within_frame.
                              Previously named LP.setSubframeLoading until PR #2426.)
```

## Known Bugs and Limitations

### Critical for This Gem

1. **`Page.loadEventFired` unreliable** (#1801)
   - May never fire on complex JS pages, Wikipedia, certain French real estate sites
   - This gem works around it with `document.readyState` polling fallback in `Browser#go_to`
   - DO NOT remove the readyState fallback — `Page.loadEventFired` itself is still unreliable

2. **No rendering engine (CSS much improved)**
   - Screenshots return a 1920x1080 PNG (hardcoded dimensions, no actual rendering)
   - `getComputedStyle` works for many properties via CSSOM; `checkVisibility` matches all active stylesheets
   - No scroll/resize, no visual regression testing
   - `Page.getLayoutMetrics` returns hardcoded 1920x1080 values
   - `window.innerWidth`/`innerHeight` may not reflect emulation settings

3. **Cookies on redirects not sent on follow-up request**
   - Cookies set via `Set-Cookie` on a 302 response are stored in the cookie jar
   - But they are NOT included in the follow-up GET request to the redirect target
   - Workaround: after redirect, do a second navigation to the same URL if cookie-dependent

4. **JavaScript context lost between navigations**
   - JS execution context is reset on every page load: globals, polyfills, and any custom functions evaluated in a previous document are gone.
   - Polyfills are auto-injected on every navigation via `Page.addScriptToEvaluateOnNewDocument`, registered once at session creation in `Browser#create_page`. Ad-hoc `Runtime.evaluate` calls still need to be re-run after each `visit`.
   - Node references (objectIds) become invalid after navigation

5. **`HTMLElement.isContentEditable` IDL attribute always returns false** (closes #2309)
   - Native getter ALWAYS returns `false` and logs `.not_implemented` when the spec walk would have returned true. Rationale: Lightpanda has no caret/keyboard editing pipeline.
   - Gem polyfill at `javascripts/index.js` (`_lightpanda.isContentEditable`) MUST stay — it walks ancestors itself.

6. **`Node#shadow_root should get visible text` failing** (gem-side TODO)
   - `_lightpanda.visibleText` in `javascripts/index.js` wraps every `display:block` element with `\n…\n` even when empty, producing a phantom line break between siblings. Gem-side fix needed in the polyfill.

### Open Fix PRs (not yet merged)

- **PR #2157**: Feat: add full SVG DOM support — could affect tests that interact with SVG elements (icons, charts).
- **PR #2077**: fix: Target.attachToTarget returns unique session id per call — fixes bug where multiple `attachToTarget` calls return the same session ID. Our gem only calls `attachToTarget` once per page, but improves CDP spec compliance.

### Upstream Open Issues That Affect This Gem

| Issue | Impact | Description |
|---|---|---|
| #2175 | JS/CDP | **Implement `<input type="file">` support**. Aligned with our existing `NotImplementedError` in `Node#set` for file inputs. |
| #2173 | Crash | `TargetClosedError` navigating to React apps via CDP — browser crashes. Our `handle_navigation_crash` reconnect logic covers this, but would appear as `DeadBrowserError` after retry. |
| #2043 | CDP | Roadmap discussion for CDP automation features (setFileInputFiles, Input events, dialog, history, window.open); directly relevant to our workarounds. |
| #1890 | Navigation | Multi-step form POST does not update page content (SAP SAML login). |
| #1801 | Navigation | `Page.navigate` never completes for Wikipedia. Drives our readyState polling fallback. |
| #2017 | JS | Implement Worker and SharedWorker. Partial Worker support landed; SharedWorker still missing and many Worker APIs still unimplemented. |
| #2363 | Navigation | `Page.navigate("about:blank")` against a non-blank tab fires the full event sequence but does NOT replace the document — `window.location.href`, `document.URL`, and the frame tree all still report the previous URL. **Gem sidesteps it**: `Browser#reset` disposes the BrowserContext via `Target.disposeBrowserContext` (ferrum/cuprite parity) instead of navigating to `about:blank`. |
| #2400 | Runtime | Child iframe navigation invalidates main frame's `executionContextId` for CDP drivers. Root cause: shared V8 inspector `CONTEXT_GROUP_ID` + single `IsolatedWorld` per BrowserContext, so any `frameNavigated` re-emits `executionContextCreated` for the main frame's V8 context under the child's frameId and churns the id. Opt-in workaround (`LP.configureLoading {subFrame: false}`, formerly `LP.setSubframeLoading` until PR #2426) NOT applicable to this gem — would break `switch_to_frame` / `within_frame`. **In-flight upstream fix**: PR #2431 (OPEN, opened 2026-05-12) removes the duplicate `Page.frameNavigated` emission and reuses the child frame's V8 context for `inspector.contextCreated` during iframe navigations, so the root frame's id stops churning. **Locally validated 2026-05-13** by building from the PR branch (HEAD `806497c0`, binary `1.0.0-dev.6157+806497c0`): the original `NoExecutionContextError` is cured — every previously-failing frame test passes when run individually. **But batch-mode runs against the PR build surface 8–14 *different* failures** (`Capybara::ElementNotFound`, seed-dependent: 14/11/8 across three seeds), so test-ordering pollution exists separately from the contextId bug. Pollution is either gem-side (state leak between specs) or a regression introduced by #2431 — not yet narrowed. **Gem-side mitigation** (already in place): `Browser#find_in_frame` rescues `NoExecutionContextError` and re-resolves the iframe stack from locators captured at `push_frame` time via `refresh_frame_stack!` before retrying (`browser.rb:792-816`, helper at 845-861). Mitigation only rescues `NoExecutionContextError`, so it doesn't help the new batch failures. **Keep the mitigation** until the batch pollution is understood — even after #2431 merges, dropping the rescue would be premature. |
| #2407 | Stability | V8 fatal `AllowHeapAllocation::IsAllowed()` during GC weak callback under CDP load (debug builds only). Trigger: Worker `importScripts` + iframe-heavy page + repeated CDP connect/disconnect cycles. Currently not gem-relevant — gem tests don't load Worker-heavy pages. Keep on watchlist. |

**Gem-side defenses we keep regardless of upstream**: `Browser#with_default_context_wait` retries on `Runtime.executionContextCreated`, and `Driver#invalid_element_errors` includes `NoExecutionContextError` so Capybara's `automatic_reload` keeps working. Cheap defense-in-depth.

### General Limitations

- Many Web APIs not yet implemented (hundreds remain)
- Complex JS frameworks may not work (React SSR hydration, heavy SPA)
- `window.getComputedStyle()` works via CSSOM for many properties; `checkVisibility` matches all active stylesheets
- No `window.scrollTo()`, `element.scrollIntoView()` (no layout)
- `MutationObserver` available; `window.postMessage` across frames works
- No CORS enforcement (acknowledged in upstream README)
- In-page `WebSocket` API implemented
- `window.open` partial support: no `target=window_name`/`_blank`, sub-pages share the parent's lifetime, no CDP-side validation. Useful for sites that call `window.open` defensively for login popups.
- Web Workers: partial support — `URL`, `AbortController`, `AbortSignal`, `OffscreenCanvas`. Many Worker APIs still missing (#2017). Workers run in the same thread as the page and have a separate context.
- No Service Workers, SharedArrayBuffer
- No `localStorage`/`sessionStorage` persistence across sessions
- File upload not supported (`input[type=file]` operations will fail; Node#set raises `NotImplementedError`)

## CLI Reference

```bash
# Single-page fetch (stdout output)
lightpanda fetch [--obey_robots] [--log_format pretty|json] [--log_level info|debug] <url>

# CDP server mode
lightpanda serve --host 127.0.0.1 --port 9222 [--log_format json]

# Flags
--obey_robots                              # Respect robots.txt
--insecure_disable_tls_host_verification   # Skip TLS verification (dev only)
--disable-subframes                        # Skip child iframe document loading (NOT useful for this gem)
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
- Latest release: 0.2.9. Tags drop the `v` prefix (`0.2.9`); pre-2026-04 tags use `v` (`v0.2.6`). Asset matrix per release: `lightpanda-{aarch64,x86_64}-{linux,macos}` plus `lightpanda-0.2.9-1-{aarch64,x86_64}.pkg.tar.zst` (Arch).

## Differences from Chrome/Chromium CDP

When writing CDP interactions, be aware of these divergences:

1. **Event timing**: CDP events may arrive in different order than Chrome
2. **Error responses**: Error messages/codes differ from Chrome's (e.g., `InvalidParams` instead of specific error codes)
3. **Missing methods**: Not all methods within a domain are implemented; unsupported methods return errors
4. **Parameter rejection**: `Network.deleteCookies` silently ignores `partitionKey`
5. **Accessibility**: ARIA snapshots are more verbose than Chrome's (#1813)

## Development Tips

- Always test against Lightpanda nightly — behavior changes frequently
- When a CDP command fails, check if it's a known limitation before debugging
- Wrap CDP calls that might crash the connection in error handlers
- Prefer `Runtime.evaluate` for operations where direct CDP methods are unreliable
- Use `returnByValue: true` in `Runtime.evaluate` to get serialized values (avoids objectId lifetime issues)
- When adding new CDP interactions, verify the method exists in the corresponding domain .zig file upstream
