# Lightpanda Browser Reference

Upstream repo: https://github.com/lightpanda-io/browser
License: AGPL-3.0 | Status: Beta (stability and coverage improving)

Current nightly floor enforced by the gem: `Process::MINIMUM_NIGHTLY_BUILD = 6353`. See `lib/capybara/lightpanda/process.rb` for the per-PR rationale of every bump in this floor.

## Architecture

- Written in **Zig 0.15.2**, JS execution via **V8**
- HTML parsing: **html5ever** (standards-compliant, handles malformed HTML)
- HTTP: **libcurl** (custom headers, proxies, TLS control)
- CSS: **CSSOM** — `insertRule`/`deleteRule`/`replace`/`replaceSync`, `checkVisibility` matches all active stylesheets; no full layout/paint/compositing
- Platforms: Linux x86_64, macOS aarch64, Windows via WSL2

## CDP Server

Launched with `lightpanda serve --host 127.0.0.1 --port 9222`. Clients connect via WebSocket at `ws://127.0.0.1:9222`. Compatible with Puppeteer, Playwright (partial), and chromedp.

### Implemented CDP Domains (21 total)

| Domain | File | Notes |
|---|---|---|
| **Accessibility** | accessibility.zig | AXNode support; aria snapshots noisier than Chrome (#1813) |
| **Audits** | audits.zig | `enable` / `disable` stubs only. Not used by this gem. |
| **Browser** | browser.zig | Basic browser-level commands |
| **Console** | console.zig | `Console.messageAdded` event available; `console.*` also mirrored to `Runtime.consoleAPICalled` when `Runtime.enable` is on (the gem's Turbo tracker uses the latter). |
| **CSS** | css.zig | CSSOM: `insertRule`/`deleteRule`/`replace`/`replaceSync`; `checkVisibility` matches all stylesheets; CDP `CSS.getComputedStyleForNode` not yet implemented |
| **DOM** | dom.zig | 16 methods: `getDocument`, `querySelector`, `querySelectorAll`, `performSearch`, `resolveNode`, `describeNode`, `getBoxModel`, `getOuterHTML`, etc. |
| **Emulation** | emulation.zig | Viewport/device emulation stubs; `setUserAgentOverride` works |
| **Fetch** | fetch.zig | Network interception: `enable`, `disable`, `continueRequest`, `failRequest`, `fulfillRequest`, `continueWithAuth`; events: `requestPaused`, `authRequired` |
| **Input** | input.zig | `dispatchMouseEvent`, `dispatchKeyEvent`, `insertText` |
| **Inspector** | inspector.zig | Inspector lifecycle |
| **Log** | log.zig | Console/log message forwarding |
| **LP** | lp.zig | Lightpanda-specific extensions: `getMarkdown`, `getSemanticTree`, `getInteractiveElements`, `getNodeDetails`, `getStructuredData`, `detectForms`, `clickNode`, `fillNode`, `scrollNode`, `waitForSelector`, `handleJavaScriptDialog` (pre-arm), `configureLoading` (per-session opt-out for iframe and/or worker loading; params `{subFrame, worker}`) |
| **Network** | network.zig | Cookies (`getAllCookies`, `clearBrowserCookies` bulk both work), request/response interception, `setUserAgentOverride`. Cache-control surface (`clearBrowserCache`, `setCacheDisabled`, `requestServedFromCache` event, `fromDiskCache` on Response) is implemented but not used by the gem — `Driver#reset!` disposes the BrowserContext, wiping cache implicitly. |
| **Page** | page.zig | Navigation, events, screenshots (1920x1080 PNG), `reload`, `addScriptToEvaluateOnNewDocument`, `getNavigationHistory`/`navigateToHistoryEntry`, `javascriptDialogOpening` event. `handleJavaScriptDialog` deliberately errors — use `LP.handleJavaScriptDialog`. |
| **Performance** | performance.zig | Performance metrics |
| **Runtime** | runtime.zig | JS evaluation, object inspection |
| **Security** | security.zig | Security state |
| **Storage** | storage.zig | Storage state; `createContext` with storage state fails (#1550) |
| **Target** | target.zig | Target/session management. Frame IDs scoped to the connection-lifetime `Browser`; not gem-relevant since we don't keep targetId-keyed state across `Driver#reset!`. |
| **webMCP** | webmcp.zig | Lightpanda Model Context Protocol surface. Not used by this gem. |

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
Runtime.consoleAPICalled (event)
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
Network.setCacheDisabled     Network.clearBrowserCache    Network.canClearBrowserCache
Network.requestServedFromCache (event)
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
LP.configureLoading          (per-session opt-out for iframe and/or worker loading,
                              params {subFrame, worker}; NOT applicable to this gem —
                              disabling subframes breaks switch_to_frame/within_frame.)
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

5. **`HTMLElement.isContentEditable` IDL attribute always returns false**
   - Native getter ALWAYS returns `false` and logs `.not_implemented` when the spec walk would have returned true. Rationale: Lightpanda has no caret/keyboard editing pipeline.
   - Gem polyfill at `javascripts/index.js` (`_lightpanda.isContentEditable`) MUST stay — it walks ancestors itself.

6. **External `<link rel="stylesheet">` fetch — ON by default in the gem** (PR #2487, build ≥6353)
   - The gem passes `--enable-external-stylesheets` unconditionally (`Process#build_args`), so `<link rel="stylesheet" href="…">` is fetched synchronously, parsed via `replaceSync`, added to `document.styleSheets`, and contributes to the cascade (`checkVisibility`/`getComputedStyle`). Author-vs-UA `[hidden]` ordering is correct (PR #2498). Cost: one synchronous CSS fetch per `<link>`.
   - The flag is a fatal `UnknownOption` on builds <6353 — this is the reason the gem floor is 6353. (Per-session `LP.configureLoading {externalStylesheets: true}` also exists; the gem uses the CLI flag.)
   - Inline `<style>` `@media` + `matchMedia` evaluate against the hardcoded 1920×1080 viewport.
   - **Capybara impact**: responsive CTA variants gated by an external stylesheet now resolve to a single variant (no more `Capybara::Ambiguous`); externally-loaded responsive specs that previously needed cuprite/Selenium work on lightpanda.

7. **SIGTERM can be ignored after a CDP connection — handled gem-side**

   There are **two distinct** SIGTERM hangs here; don't conflate them.

   - **(A) Telemetry/curl-multi hang** (upstream #2507, fixed by #2509). On a build that
     owns a curl `multi` handle, the Network loop drops the CDP fds from its poll set and
     `poll(timeout=-1)` starves, so SIGTERM is ignored *even if the CDP socket was already
     closed*. The `multi` is created **only by telemetry** (`telemetry/lightpanda.zig`
     `submitRequest`). **The gem never hits this** — it spawns with
     `LIGHTPANDA_DISABLE_TELEMETRY=true`, so no `multi` is ever created. Verified: a broken
     6353 ReleaseFast build hangs 8/8 with telemetry on, 0/8 with telemetry off. #2509 fixes
     it (8/8 → 0/8) for telemetry-on CDP clients (Puppeteer/Playwright/chromedp).

   - **(B) Live-CDP-connection hang — this is the gem's actual 45-min teardown hang.**
     Lightpanda absorbs a **single** SIGTERM whenever a CDP connection is **still live**.
     `Sighandler.zig` runs the graceful-shutdown listeners on the 1st/2nd signal and only
     `process.exit(1)`s on the **3rd**; the graceful path (`Server.deinit`) spins
     `while active_threads > 0` waiting for the per-connection worker, which doesn't unwind
     while the CDP socket is open. **Telemetry-independent and NOT fixed by #2509** — verified:
     with the CDP WS left open at SIGTERM, *both* the broken 6353 and the #2509 fix 6354
     ReleaseFast builds hang identically (telemetry off); closing the WS first → clean exit
     on the next SIGTERM. A bare WS connect with zero CDP commands is enough to trigger it.
     (Untested whether pre-#2495 6323 also had variant B.)

   - **Why the gem hit (B):** `Browser#quit` closes the CDP client (WS) *before* `Process#stop`
     (SIGTERM), so explicit quit is clean (~0.05s). But `Driver#reset!` keeps the process +
     open client alive between tests, nothing called `quit` at suite exit, and Capybara 3.40
     doesn't quit drivers — so cleanup fell to the **Process GC finalizer** (`weak_kill` →
     `terminate(pid)`), which only has the pid and never closes the WS → SIGTERM on a live-CDP
     process → pre-escalation `Process.wait` deadlocked the finalizer pass = the 45-min hang.

   - **Gem handling (two layers):**
     1. **Primary** — `Browser` tracks live instances and `#quit`s them (closing the CDP WS
        first) from a single `at_exit` (`Browser.track`/`quit_all`). So at process exit the
        socket is closed before any SIGTERM and teardown is instant. Regression-tested by
        `test/features/teardown_test.rb` (asserts at-exit teardown < 2s, i.e. clean SIGTERM,
        not the 3s SIGKILL fallback).
     2. **Backstop** — `Process#stop` and the `weak_kill` finalizer still escalate `TERM` →
        wait `STOP_GRACE_SECONDS` (3s) → `SIGKILL` → reap, covering crash/GC-abandon paths the
        `at_exit` can't reach. Keep both regardless of any floor bump — variant (B) is not what
        #2509 fixes.

   - **Open upstream (separate from #2509):** a single SIGTERM should terminate lightpanda even
     with a live CDP connection (graceful shutdown shouldn't block forever on the connection
     worker). Minimal repro (Lightpanda + raw CDP only): open a CDP WebSocket, leave it open,
     send one SIGTERM (no navigation needed) → process hangs; close the WS first → clean exit.
     Filed upstream as #2510; fix proposed in navidemad's PR #2511 (`network: terminate live
     CDP connections on shutdown`, OPEN). #2511 only fixes the browser side — keep both gem
     layers (`at_exit` primary + finalizer escalation backstop) regardless, since crash and
     GC-abandon paths still need the gem's teardown.

### Open Fix PRs (not yet merged)

- **PR #2077**: `Target.attachToTarget` returns unique session id per call. Gem only calls `attachToTarget` once per page, so spec-compliance win only.

### Upstream Open Issues That Affect This Gem

| Issue | Impact | Description |
|---|---|---|
| #2175 | JS/CDP | **Implement `<input type="file">` support**. Aligned with our existing `NotImplementedError` in `Node#set` for file inputs. |
| #2173 | Crash | `TargetClosedError` navigating to React apps via CDP — browser crashes. Our `handle_navigation_crash` reconnect logic covers this, but would appear as `DeadBrowserError` after retry. |
| #2043 | CDP | Roadmap discussion for CDP automation features (setFileInputFiles, Input events, dialog, history, window.open); directly relevant to our workarounds. |
| #1890 | Navigation | Multi-step form POST does not update page content (SAP SAML login). |
| #1801 | Navigation | `Page.navigate` never completes for Wikipedia. Drives our readyState polling fallback. |
| #2017 | JS | Implement Worker and SharedWorker. Partial Worker support landed; SharedWorker still missing and many Worker APIs still unimplemented. |
| #2363 | Navigation | `Page.navigate("about:blank")` against a non-blank tab fires the full event sequence but does NOT replace the document. **Gem sidesteps it** by disposing the BrowserContext in `Browser#reset` instead of navigating to `about:blank`. |
| #2407 | Stability | V8 fatal `AllowHeapAllocation::IsAllowed()` during GC weak callback under CDP load (debug builds only; trigger: Worker `importScripts` + iframe-heavy page + repeated CDP connect/disconnect). Not gem-relevant — gem tests don't load Worker-heavy pages. Watch only. |
| #2460 | Memory | `Frame.removeNode` unlinks but never frees `Node`/`Element` memory. Not gem-relevant — `Driver#reset!` disposes the BrowserContext per spec. A very long single-session spec doing heavy DOM churn could accumulate RSS. Watch only. |

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
- Latest release: 0.3.0 (2026-05-13). Tags drop the `v` prefix since 2026-04. Per release: `lightpanda-{aarch64,x86_64}-{linux,macos}` + `.deb` packages.

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
