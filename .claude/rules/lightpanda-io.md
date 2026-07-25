# Lightpanda Browser Reference

Upstream repo: https://github.com/lightpanda-io/browser
License: AGPL-3.0 | Status: Beta (stability and coverage improving)

Current floors enforced by the gem: `Process::MINIMUM_NIGHTLY_BUILD = 8160` (PR #2719 `@layer` block rules in the cascade; subsumes #2795 innerText at 7571 and #2722 download streaming at 7545) **or** `Process::MINIMUM_RELEASE = 0.3.5` for tagged releases, which is build 8165. See `lib/capybara/lightpanda/process.rb` for the per-PR rationale of every bump in this floor, and "Binary Distribution" below for why the two floors exist.

## Architecture

- Written in **Zig 0.16.0**, JS execution via **V8**
- HTML parsing: **html5ever** (standards-compliant, handles malformed HTML)
- HTTP: **libcurl** (custom headers, proxies, TLS control)
- CSS: **CSSOM** — `insertRule`/`deleteRule`/`replace`/`replaceSync`, `checkVisibility` matches all active stylesheets, `@layer` priority respected in the cascade (#2719, build ≥8160); no full layout/paint/compositing
- Platforms: Linux x86_64, macOS aarch64, Windows via WSL2

## CDP Server

Launched with `lightpanda serve --host 127.0.0.1 --port 9222`. Clients connect via WebSocket at `ws://127.0.0.1:9222`. Compatible with Puppeteer, Playwright (partial), and chromedp.

### Implemented CDP Domains (21 total)

| Domain | File | Notes |
|---|---|---|
| **Accessibility** | accessibility.zig | AXNode support. Not used by this gem. |
| **Audits** | audits.zig | `enable` / `disable` stubs only. Not used by this gem. |
| **Browser** | browser.zig | Basic browser-level commands |
| **Console** | console.zig | `Console.messageAdded` event available; `console.*` also mirrored to `Runtime.consoleAPICalled` when `Runtime.enable` is on (the gem's Turbo tracker uses the latter). |
| **CSS** | css.zig | CSSOM: `insertRule`/`deleteRule`/`replace`/`replaceSync`; `checkVisibility` matches all stylesheets; CDP `CSS.getComputedStyleForNode` not yet implemented |
| **DOM** | dom.zig | 16 methods: `getDocument`, `querySelector`, `querySelectorAll`, `performSearch`, `resolveNode`, `describeNode`, `getBoxModel`, `getOuterHTML`, etc. |
| **Emulation** | emulation.zig | `setUserAgentOverride` works (rejects `Mozilla`-containing UAs by design — go-rod workaround, #2704 closed as intended). `setDeviceMetricsOverride` drives `window.innerWidth`/`innerHeight`, `matchMedia`/`@media` evaluation, and `Page.getLayoutMetrics` — a JS-visible viewport, still no real layout. `deviceScaleFactor`/`mobile`/`scale` accepted-and-warned. Also `setEmulatedMedia`, `setFocusEmulationEnabled`, `setTouchEmulationEnabled` |
| **Fetch** | fetch.zig | Network interception: `enable`, `disable`, `continueRequest`, `failRequest`, `fulfillRequest`, `continueWithAuth`; events: `requestPaused`, `authRequired` |
| **Input** | input.zig | `dispatchMouseEvent`, `dispatchKeyEvent`, `insertText` |
| **Inspector** | inspector.zig | Inspector lifecycle |
| **Log** | log.zig | Console/log message forwarding |
| **LP** | lp.zig | Lightpanda-specific extensions: `getMarkdown`, `getSemanticTree`, `getInteractiveElements`, `getNodeDetails`, `getStructuredData`, `getContentSignal`, `detectForms`, `clickNode`, `fillNode`, `scrollNode`, `waitForSelector`, `handleJavaScriptDialog` (pre-arm), `configureLoading` (per-session opt-out for iframe and/or worker loading; params `{subFrame, worker}`), `configureCDP`, `version` |
| **Network** | network.zig | Cookies (`getAllCookies`, `clearBrowserCookies` bulk both work), request/response interception, `setUserAgentOverride`, `setBlockedURLs` (url-pattern request blocking). A custom `User-Agent` set via `setExtraHTTPHeaders` (the gem's `Network#headers=` path) is honored since PR #2735 — but `validateUserAgent` still rejects `Mozilla`-containing UAs, so realistic browser-UA spoofing stays blocked on every path. Cache-control surface (`clearBrowserCache`, `setCacheDisabled`, `requestServedFromCache` event, `fromDiskCache` on Response) is implemented but not used by the gem — `Driver#reset!` disposes the BrowserContext, wiping cache implicitly. Event payloads completed in #3037 (build ≥8318): `responseReceived` now carries `type` (`"Document"` for the main document), and `loadingFinished`/`loadingFailed` carry `timestamp`. Both **above the floor** — `Network#build_response_handler` still identifies the navigation response by matching the remembered document `requestId`, which works on every build. |
| **Page** | page.zig | Navigation, events, screenshots (1920x1080 PNG), `reload`, `addScriptToEvaluateOnNewDocument`, `getNavigationHistory`/`navigateToHistoryEntry`, `javascriptDialogOpening` + `lifecycleEvent` + `navigatedWithinDocument` events. `handleJavaScriptDialog` deliberately errors — use `LP.handleJavaScriptDialog`. |
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
DOM.describeNode             DOM.setFileInputFiles
Network.getAllCookies        Network.setCookie
Network.deleteCookies        Network.clearBrowserCookies
Network.enable               Network.disable
Network.setExtraHTTPHeaders  Network.requestWillBeSent (event)
Network.responseReceived (event)
Browser.setDownloadBehavior  Browser.downloadWillBegin (event)
Browser.downloadProgress (event)
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
DOM.querySelector            DOM.querySelectorAll (finds go through JS in Runtime.callFunctionOn)
Page.setLifecycleEventsEnabled  Page.stopLoading (stub)    Page.close
Page.printToPDF (fake PDF)
DOM.getDocument              DOM.resolveNode
DOM.getBoxModel (returns real getBoundingClientRect geometry)
DOM.scrollIntoViewIfNeeded
DOM.performSearch            DOM.getSearchResults        DOM.discardSearchResults
DOM.getContentQuads          DOM.requestChildNodes
DOM.getFrameOwner            DOM.getOuterHTML            DOM.requestNode
Input.dispatchMouseEvent     Input.dispatchKeyEvent      Input.insertText
Network.setCookies (batch)   Network.getResponseBody     Network.setBlockedURLs
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
Browser.grantPermissions / setPermission / resetPermissions (#2727)
Browser.setWindowBounds (noop)  Browser.getWindowForTarget (fixed windowId)
Emulation.setDeviceMetricsOverride (window.innerWidth/innerHeight + matchMedia +
                              Page.getLayoutMetrics, #2664)
Emulation.clearDeviceMetricsOverride  Emulation.setEmulatedMedia
Emulation.setFocusEmulationEnabled    Emulation.setTouchEmulationEnabled
LP.getSemanticTree           LP.getInteractiveElements
LP.getStructuredData         LP.waitForSelector
LP.getMarkdown               LP.getNodeDetails
LP.detectForms               LP.clickNode
LP.fillNode                  LP.scrollNode
LP.configureLoading          (per-session opt-out for iframe and/or worker loading,
                              params {subFrame, worker}; NOT applicable to this gem —
                              disabling subframes breaks switch_to_frame/within_frame.)
LP.configureCDP              LP.getContentSignal         LP.version
```

## Known Bugs and Limitations

### Critical for This Gem

1. **`Page.loadEventFired` unreliable** (#1801)
   - May never fire on complex JS pages, Wikipedia, certain French real estate sites
   - This gem works around it with `document.readyState` polling fallback in `Browser#go_to`
   - DO NOT remove the readyState fallback — `Page.loadEventFired` itself is still unreliable
   - One family member fixed: readyState stuck at `"loading"` after a synchronous external-stylesheet fetch (forem homepage, wishlist A10) — PR #2843, build ≥7692 (above the floor, so not guaranteed for gem users)

2. **No rendering engine (CSS much improved)**
   - Screenshots return a 1920x1080 PNG (hardcoded dimensions, no actual rendering)
   - `getComputedStyle` resolves inline `style=` declarations, cascade-aware `display`/`visibility` (via StyleManager, so author stylesheets and `@layer` count), synthetic `width`/`height` matching `getBoundingClientRect`, and CSS **initial** values for `color`/`opacity`/`background-color`. Every other property returns `""` — there is still no cascade resolution for arbitrary properties. `checkVisibility` matches all active stylesheets
   - No scroll/resize, no visual regression testing
   - `getBoundingClientRect` and screenshots have no real layout: rects are synthesized from document/sibling position and return all-zero for non-visible elements
   - **Viewport IS emulatable**: `Emulation.setDeviceMetricsOverride` drives `window.innerWidth`/`innerHeight`, `matchMedia`/`@media` evaluation, AND `Page.getLayoutMetrics` (no longer hardcoded 1920×1080). This is a JS-visible viewport only — element geometry stays synthetic, so `obscured?`-outside-viewport still can't work. The gem wires its `window_size` option to it in `Browser#set_viewport` (called from `create_page`); `Options::DEFAULT_WINDOW_SIZE` mirrors the browser's native 1920×1080 so the default is a no-op.

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
   - Gem polyfill at `javascripts/predicates.js` (`_lightpanda.isContentEditable`) MUST stay — it walks ancestors itself.

6. **External `<link rel="stylesheet">` fetch — ON by default in the gem** (build ≥6353)
   - The gem passes `--enable-external-stylesheets` unconditionally (`Process#build_args`), so `<link rel="stylesheet" href="…">` is fetched synchronously, parsed via `replaceSync`, added to `document.styleSheets`, and contributes to the cascade (`checkVisibility`/`getComputedStyle`). Author-vs-UA `[hidden]` ordering is correct. Cost: one synchronous CSS fetch per `<link>`.
   - The flag is a fatal `UnknownOption` on builds <6353. (Per-session `LP.configureLoading {externalStylesheets: true}` also exists; the gem uses the CLI flag.)
   - `@media` + `matchMedia` evaluate against the current viewport, which defaults to 1920×1080 but honors `Emulation.setDeviceMetricsOverride` (see limitation #2).
   - **Capybara impact**: responsive CTA variants gated by an external stylesheet now resolve to a single variant (no more `Capybara::Ambiguous`); externally-loaded responsive specs that previously needed cuprite/Selenium work on lightpanda.

7. **SIGTERM after a live CDP connection — hangs fixed upstream (#2509 telemetry, #2511 live-WS, both ≤ floor), gem keeps both teardown layers regardless** (crash / GC-abandon paths still need them):
   1. **Primary** — `Browser.track`/`quit_all` closes the CDP WS from a single `at_exit`
      *before* SIGTERM, so teardown is instant. Regression-tested by
      `test/features/teardown_test.rb` (at-exit < 2s = clean SIGTERM, not the 3s SIGKILL fallback).
   2. **Backstop** — `Process#stop` + the `weak_kill` finalizer escalate `TERM` → 3s grace →
      `SIGKILL` → reap, for the crash / GC-abandon paths the `at_exit` can't reach.

### Upstream Open Issues That Affect This Gem

| Issue | Impact | Description |
|---|---|---|
| #2173 | Crash | `TargetClosedError` navigating to React apps via CDP — browser crashes. Our `handle_navigation_crash` reconnect logic covers this, but would appear as `DeadBrowserError` after retry. |
| #1890 | Navigation | Multi-step form POST does not update page content (SAP SAML login). |
| #1801 | Navigation | `Page.navigate` never completes for Wikipedia. Drives our readyState polling fallback. |
| #2400 | JS context | Child iframe navigation invalidates the main frame's `executionContextId`. Covered by `with_default_context_wait` + `NoExecutionContextError` in `invalid_element_errors`. |
| #2460 | Memory | `Frame.removeNode` unlinks but never frees `Node`/`Element` memory. Not gem-relevant — `Driver#reset!` disposes the BrowserContext per spec. A very long single-session spec doing heavy DOM churn could accumulate RSS. Watch only. |
| #3057 | Forms | `<option>`s inside `<optgroup>` are invisible to `HTMLSelectElement` (`options`, `value`, `selectedIndex`, `selectedOptions`, submission) — Capybara's `select` can't reach grouped options. PR #3058 open. |

**Gem-side defenses we keep regardless of upstream**: `Browser#with_default_context_wait` retries on `Runtime.executionContextCreated`, and `Driver#invalid_element_errors` includes `NoExecutionContextError` so Capybara's `automatic_reload` keeps working. Cheap defense-in-depth.

### General Limitations

- Many Web APIs not yet implemented (hundreds remain)
- Complex JS frameworks may not work (React SSR hydration, heavy SPA)
- Same-document navigations: `Page.navigatedWithinDocument` IS emitted for `history.pushState`/`replaceState` (#2964, build ≥8143, `navigationType: historyApi`); fragment navigation and history traversal still emit nothing (#2829, open). The gem is immune either way — `Browser#current_url`/`frame_url` read `window.location.href` via `Runtime.evaluate`, not CDP frame-URL tracking — so keep it that way (don't switch `current_url` to an event-tracked frame URL).
- `window.getComputedStyle()`: cascade-aware for `display`/`visibility` only; synthetic `width`/`height`; CSS initial values for `color`/`opacity`/`background-color`; every other property returns `""` (see limitation #2). `checkVisibility` matches all active stylesheets including `@layer`
- `window.scrollTo()`/`scrollBy()` track a scroll position (`window._scroll_pos`, fire `scroll`/`scrollend`) and `Element` exposes `scrollTop`/`scrollLeft`/`scrollIntoView` — BUT element scroll is decoupled from window scroll and no layout means `getBoundingClientRect` isn't scroll-aware. So position scroll is readable but `:bottom`/`:center` and element-relative alignment are meaningless; the gem keeps `Node#scroll_to`/`scroll_by` as no-ops and `:scroll` stays in `capybara_skip`. Since #3048 (build ≥8305, **above the floor**) an inner element's `scrollWidth`/`scrollHeight` is `max(clientSize, sum of direct *element* children)` instead of aliasing `clientSize` — enough that measure-then-mutate loops (the infinite-marquee idiom) terminate. Text children are not measured and layout mode is not detected, so the numbers bound content extent rather than describe a layout; `<html>`/`<body>` keep the synthetic 1920/1e8 defaults, so page-level overflow and infinite-scroll checks read the same as before.
- `<form method="dialog">` closes its nearest ancestor `<dialog>` (sets `returnValue` from the submitter's IDL `value`, fires `close`) and performs no navigation — #3053/PR #3054, build ≥8311, **above the floor**. Below 8311 it falls through to a GET navigation, leaving the dialog open forever; that is the `<dialog>`+Turbo-confirm idiom Spree 5's admin uses for every destroy confirmation. No gem-side workaround was ever shipped — nothing to remove, but real-apps runs on a sub-8311 binary still fail this cluster.
- `MutationObserver` available; `window.postMessage` across frames works
- No CORS enforcement (acknowledged in upstream README)
- In-page `WebSocket` API implemented; sends `Origin` on upgrade since build 6736 (PR #2710), so ActionCable's request-forgery check passes and `turbo_stream_for` / solid_cable streams connect without `disable_request_forgery_protection`
- `window.open` partial support: no `target=window_name`/`_blank`, sub-pages share the parent's lifetime, no CDP-side validation. Useful for sites that call `window.open` defensively for login popups.
- Workers: dedicated + **SharedWorker** implemented (#2017). Workers run in the same thread as the page with a separate context; individual Worker-scope APIs may still be missing. `--disable-workers` opts out.
- Landed between builds 7776 and 8300: **IndexedDB** (#2732; in-memory unless `--storage-engine sqlite`), **EventSource/SSE** (#2879), `CookieStore`, `ResizeObserver`, the Navigation API, `BroadcastChannel`, `StorageEvent`, `BeforeUnloadEvent`, `TouchEvent`, SVG geometry/animated-value interfaces, `DOMMatrix`/`DOMPoint`.
- No Service Workers, SharedArrayBuffer
- No `localStorage`/`sessionStorage` persistence across sessions (in-memory only; `--storage-engine` backs IndexedDB, not Web Storage)
- File upload — **SUPPORTED since build 6672** (no longer a limitation). `DOM.setFileInputFiles` (PR #2635) populates `input.files` + fires `change`; PR #2654 wires multipart `.file` submission (filename + Content-Type + bytes, RFC 7578). Both halves are required — on builds 6625–6671 the file attaches but the form submits empty — and the gem floor guarantees them. `Node#fill_input` routes `<input type=file>` through `Browser#set_file_input_files`. Paths are read off the machine running Lightpanda (fine for the locally-spawned process). Validated by the Capybara `#attach_file` shared specs (29 examples, 0 failures).
- File **download** — **SUPPORTED since build 7545** (PR #2722, in the floor). `Browser.setDownloadBehavior {behavior:"allow", downloadPath, eventsEnabled}` streams a navigation response carrying `Content-Disposition: attachment` to disk (on the Lightpanda host) and emits `Browser.downloadWillBegin`/`downloadProgress`. The gem's `Downloads` tracker (`downloads.rb`) wires this in `Browser#create_page` whenever a destination exists (`:save_path` option, else `Capybara.save_path`); `Driver#downloads` / `#wait_for_download` expose the completed-file list. **Trigger is `Content-Disposition: attachment`, NOT MIME type** — a `text/csv` (or any) response WITHOUT that header is rendered as a normal (empty) navigation, not downloaded. That's why Capybara's `:download` shared spec (its `/download.csv` fixture is MIME-triggered, no Content-Disposition) stays in `capybara_skip`; the real attachment path is covered by `test/features/download_test.rb`. `<a download>` clicks navigate to the attachment URL (Lightpanda commits an empty doc afterward) rather than staying on the page.
- Drag-and-drop (HTML5 file/data drop) — **SUPPORTED since build 6699** (PR #2671: `DataTransfer`/`DataTransferItem`/`DataTransferItemList` + `DragEvent`). `Node#drop` (Capybara's `Element#drop`) assembles a `DataTransfer` — file paths base64'd over CDP, `{mime => data}` hashes as typed items — then fires `dragenter`→`dragover`→`drop` (`DROP_JS` in `node.rb`). Geometry-free, so it needs no layout; the 6699 floor guarantees the APIs (on builds <6699 the drop JS raises "DataTransfer is not defined"). The drop payload rides one `Runtime.callFunctionOn` over the CDP WebSocket, whose inbound cap the gem raises to 100 MiB via `--cdp-max-message-size` (`Process#build_args`; flag from PR #2760, build 7441 ≤ floor, default 1 MiB) — so a dropped file's base64 must stay under ~70 MB (was ~700 KB at the 1 MiB default). Coordinate-based `drag_to`/`drag_by` remain unsupported (no layout).

## CLI Reference

```bash
# Single-page fetch (stdout output)
lightpanda fetch [--obey_robots] [--log_format pretty|json] [--log_level info|debug] <url>

# CDP server mode
lightpanda serve --host 127.0.0.1 --port 9222 [--log_format json]

# Flags — canonical spelling is kebab-case; the parser also accepts the
# snake_case form of every name (cli.zig toKebabCase), so the gem's
# `--log_level` keeps working.
--obey-robots                              # Respect robots.txt
--insecure-disable-tls-host-verification   # Skip TLS verification (dev only)
--enable-external-stylesheets              # Fetch <link rel=stylesheet> (gem passes this)
--cdp-max-message-size <BYTES>             # Inbound CDP WS cap, default 1 MiB (gem: 100 MiB)
--disable-subframes                        # Skip child iframe loading (NOT useful for this gem)
--disable-workers                          # Skip worker loading
--storage-engine none|sqlite               # IndexedDB persistence backend
--storage-sqlite-path <PATH>               # SQLite file (":memory:" allowed)
--user-agent / --user-agent-suffix         # UA control (Mozilla-containing values still rejected)
--block-urls / --block-cidrs / --block-private-networks
--http-cache-dir <PATH>                    # On-disk HTTP cache
--inject-script / --inject-script-file     # CLI-side equivalent of addScriptToEvaluateOnNewDocument
--log-format pretty|json                   # Log output format
--log-level info|debug                     # Verbosity

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
- Latest release: 0.3.5 (2026-07-17). Tags drop the `v` prefix since 2026-04. Per release: `lightpanda-{aarch64,x86_64}-{linux,macos}` + `.deb` packages.

**Two version-string shapes, two gem floors** (verified 2026-07-24): `build.zig`'s
`resolveVersion` enriches a version with `git rev-list --count HEAD` + short hash
*only* when it carries a pre-release tag. The release workflow passes
`-Dversion=<tag>`, which parses as a full semver with no pre-release — so a
tagged release prints a bare `0.3.5` with **no build counter**, while nightlies
print `1.0.0-nightly.8285+de85a51d`. `Process#check_minimum_version` therefore
gates two channels: `MINIMUM_NIGHTLY_BUILD` (build counter) and
`MINIMUM_RELEASE` (semver). Keep them in lockstep — a release is acceptable
exactly when its own commit count clears the nightly floor
(`git rev-list --count <tag>`; 0.3.5 = 8165, 0.3.4 = 7708, 0.3.3 = 7562).
Only the rolling `nightly` tag is re-published, so **releases are the only
reproducible pin** — nightlies are not archived.

## Differences from Chrome/Chromium CDP

When writing CDP interactions, be aware of these divergences:

1. **Event timing**: CDP events may arrive in different order than Chrome
2. **Error responses**: Error messages/codes differ from Chrome's (e.g., `InvalidParams` instead of specific error codes)
3. **Missing methods**: Not all methods within a domain are implemented; unsupported methods return errors
4. **Parameter rejection**: `Network.deleteCookies` silently ignores `partitionKey`

## Development Tips

- Always test against Lightpanda nightly — behavior changes frequently
- When a CDP command fails, check if it's a known limitation before debugging
- Wrap CDP calls that might crash the connection in error handlers
- Prefer `Runtime.evaluate` for operations where direct CDP methods are unreliable
- Use `returnByValue: true` in `Runtime.evaluate` to get serialized values (avoids objectId lifetime issues)
- When adding new CDP interactions, verify the method exists in the corresponding domain .zig file upstream
