# Lightpanda Browser Reference

Upstream repo: https://github.com/lightpanda-io/browser
License: AGPL-3.0 | Status: Beta (stability and coverage improving)

Current floors enforced by the gem: `Process::MINIMUM_NIGHTLY_BUILD = 9994` **or** `Process::MINIMUM_RELEASE = 1.0.0` — the same commit on both channels (9994 = `git rev-list --count 1.0.0`). The release-channel lockstep caps the nightly floor at the newest tagged release, so the floor cannot pass 9994 until upstream tags again. The 2026-10-03 bump 9058 → 9994 retired the #3375 `sel.value =` detour, ungated the #3378 matchMedia pin and folded in our #3414/#3420/#3422/#3424 editing fixes. `lib/capybara/lightpanda/process.rb` carries the per-PR rationale of every bump; "Binary Distribution" below explains why two floors exist.

**Upstream behavior changes the gem compensates for** (users run the rolling nightly, so these are not gated by the floor; each pinned by `test/features/pointer_focus_test.rb` + `test/js/pointer-focus.test.ts`):
- #3702 (9968) dropped `focus()` from `handleClick`, and an *untrusted* `mousedown` never runs the focus default → `CLICK_JS` focuses `_lightpanda.pointerFocusTarget(hit)` itself after an uncancelled mousedown (label → its control, contenteditable → outermost editing host, disabled skipped), or blurs the active element when the press hits nothing focusable. Without it `click` then `page.send_keys` typed into `<body>`.
- #3424 (9234) made `Input.insertText` insert *at the caret*, and an attribute-seeded `value=` leaves the caret at 0 → `SEND_KEYS_FOCUS_JS` moves the caret to the end of a field that did not already have focus (WebDriver Element Send Keys / chromedriver). A field that already has focus keeps its caret — tests placing a caret must `focus()` first.
- #3592 (9646) made `focus()` a no-op on non-focusable elements → `SEND_KEYS_FOCUS_JS` blurs the previous field so keys go to the body instead of landing there.
- #3502 (9424) stopped the `value` getter from skipping disabled options, exposing that both `sel.value =` and `option.selected = true` select a disabled option (per spec) → `SELECT_OPTION_JS` returns early on `_lightpanda.isDisabled(this)`.
- #3379 (9083) applies `tooShort`/`tooLong` only to *user-edited* values (HTML spec) → `#has_field … valid` is skipped in `spec_helper.rb` as spec-correct (`Node#set` writes `.value` from JS).

## Architecture

- Written in **Zig 0.17** (since #3760, 10077 — a local `main` build needs Zig 0.17), JS execution via **V8**
- HTML parsing: **html5ever** (standards-compliant, handles malformed HTML)
- HTTP: **libcurl** (custom headers, proxies, TLS control)
- CSS: **CSSOM** — `insertRule`/`deleteRule`/`replace`/`replaceSync`, `checkVisibility` matches all active stylesheets. `@layer` support came in two halves — rules inside an `@layer` block *participate* in the cascade from #2719 (build ≥8160), and their *layer rank* is honored from #2983 (build ≥8281). Both are in the floor; don't cite 8160 alone as "`@layer` works". No full layout/paint/compositing
- Platforms: Linux x86_64, macOS aarch64, Windows via WSL2

## CDP Server

Launched with `lightpanda serve --host 127.0.0.1 --port 9222`. Clients connect via WebSocket at `ws://127.0.0.1:9222`. Compatible with Puppeteer, Playwright (partial), and chromedp.

**WS handshake (#3173/#3256, in the floor)**: an upgrade request carrying any `Origin` header is 403'd, and `Host` must be an IP literal, the exact lowercase `localhost:<port>`, or (#3803, 10133) the name passed to an explicit `--advertise-host` — bare `localhost`, `LOCALHOST:<port>` and `localhost.evil.com:<port>` still 403. The gem's spawn path is immune (it connects to the `address=` the server logs, and websocket-driver 0.8.1 sends no `Origin`); a user-supplied `ws_url:` may say `localhost:<port>` — pinned by `test/features/ws_url_host_test.rb`.

### Implemented CDP Domains (21 total)

| Domain | File | Notes |
|---|---|---|
| **Accessibility** | accessibility.zig | AXNode support. Not used by this gem. |
| **Audits** | audits.zig | `enable` / `disable` stubs only. Not used by this gem. |
| **Browser** | browser.zig | Basic browser-level commands |
| **Console** | console.zig | `Console.messageAdded` event available; `console.*` also mirrored to `Runtime.consoleAPICalled` when `Runtime.enable` is on (the gem's Turbo tracker uses the latter). |
| **CSS** | css.zig | CSSOM: `insertRule`/`deleteRule`/`replace`/`replaceSync`; `checkVisibility` matches all stylesheets; CDP `CSS.getComputedStyleForNode` not yet implemented |
| **DOM** | dom.zig | 16 methods: `getDocument`, `querySelector`, `querySelectorAll`, `performSearch`, `resolveNode`, `describeNode`, `getBoxModel`, `getOuterHTML`, etc. |
| **Emulation** | emulation.zig | `setUserAgentOverride` works (rejects `Mozilla`-containing UAs by design — go-rod workaround, #2704 closed as intended). `setDeviceMetricsOverride` drives `window.innerWidth`/`innerHeight`, `matchMedia`/`@media` evaluation, and `Page.getLayoutMetrics` — a JS-visible viewport, still no real layout. `mobile`/`scale` accepted-and-warned; `deviceScaleFactor` honored since #3231 (≥8815, 0 = don't override — feeds the screenshot renderer's scale). Both override setters re-evaluate every page's `MediaQueryList` and fire a real `change` only where `matches` flipped (#3378, in the floor; `addListener`/`removeListener` map to `change`), so `Driver#resize_window_to` makes breakpoint-listening JS run mid-test. **JS side only** — the loaded document's `@media` cascade does not re-resolve until the next navigation (resize-then-`visit` is the documented shape; verified 2026-09-06 on 9213). Pinned (both halves) by `viewport_test.rb`. Also `setEmulatedMedia`, `setFocusEmulationEnabled`, `setTouchEmulationEnabled`, `setGeolocationOverride`/`clearGeolocationOverride` + `navigator.geolocation` (#3233, ≥8755) |
| **Fetch** | fetch.zig | Network interception: `enable`, `disable`, `continueRequest`, `failRequest`, `fulfillRequest`, `continueWithAuth`; events: `requestPaused`, `authRequired` |
| **Input** | input.zig | `dispatchMouseEvent`, `dispatchKeyEvent`, `insertText` |
| **Inspector** | inspector.zig | Inspector lifecycle |
| **Log** | log.zig | Console/log message forwarding |
| **LP** | lp.zig | Lightpanda-specific extensions: `getMarkdown`, `getSemanticTree`, `getInteractiveElements`, `getNodeDetails`, `getStructuredData`, `getContentSignal`, `detectForms`, `clickNode`, `fillNode`, `scrollNode`, `waitForSelector`, `handleJavaScriptDialog` (pre-arm), `configureLoading` (per-session loading toggles; params `{subFrame, worker, externalStylesheets, images}` — `images` since #3230, ≥8834. **Load-bearing from #3305, ≥8946**: `{subFrame: true}` is how the gem must re-enable iframes, see limitation #6), `configureCDP`, `version` |
| **Network** | network.zig | Cookies (`getAllCookies`, `clearBrowserCookies` bulk both work), request/response interception, `setUserAgentOverride`, `setBlockedURLs`, `getRequestPostData` + `postData` on Request (#3150, ≥8572, bodies ≤64 KB). Header precedence since #3200/#3203 (≥8671): `fixed` (`Sec-Ch-Ua*`, never overridable) > `cli` (`--http-header`, `--user-agent`) > `cdp` (`setExtraHTTPHeaders`, the gem's `Network#headers=`) > script-set > default — so a CDP-set `User-Agent` is honored unless it contains `Mozilla` (`validateUserAgent`, every path). Cache-control surface (`clearBrowserCache`, `setCacheDisabled`, `requestServedFromCache`) unused — `Driver#reset!` disposes the BrowserContext. `Network#build_response_handler` matches the navigation response by the remembered document `requestId` (`response.type` is also readable since #3037). Worker requests ride the page session, so a worker's in-flight fetch counts toward `pending_connections`. **Redirects (#3175, in the floor)**: every followed hop emits its own `requestWillBeSent` with the same `requestId` and a `redirectResponse` payload; the 3xx never gets a `responseReceived` (Chrome semantics). `Network#build_request_handler` closes the previous entry from `redirectResponse` (Ferrum's `subscribe_request_will_be_sent` shape) without feeding `last_navigation_response` (so `status_code` stays the final hop's), and responses resolve onto the *last open* entry for the id — keep both, or one redirect strands a `response: nil` entry and every `wait_for_network_idle` burns its full timeout (probed 2026-08-18 on nightly 8688). Since #3267 (≥8880) a cross-origin redirect hop drops the `Authorization` header (Chrome/fetch semantics; other custom headers, including the gem's `Network#headers=`, still follow) — a suite that authenticates by header and redirects across origins loses the credential on the hop. **Since 1.0.0-era builds**: response header *names* are lowercased (#3624, 9734 — `Browser#response_headers`'s `Headers` downcases, so `['Content-Type']` still works; raw `traffic[..][:response][:headers]` keys are lowercase); `Origin` sent on form/fetch POSTs (#3460, 9302 — Rails origin check now actually runs); `Sec-Fetch-Site/Mode/Dest` sent to trustworthy URLs only (#3564, 9600 — measured `none`/`same-origin` correctly for navigate, form POST, `location.href`, fetch); a 301/302/303 that switches to GET drops body headers (#3526, 9478); `X-Frame-Options` enforced on iframes (#3605, 9704 — Rails' default `SAMEORIGIN` blocks cross-origin `within_frame`, Chrome parity). |
| **Page** | page.zig | Navigation, events, screenshots (real text-render PNG since #3231, ≥8815; hardcoded 1920x1080 placeholder below), `reload`, `addScriptToEvaluateOnNewDocument`, `getNavigationHistory`/`navigateToHistoryEntry`, `javascriptDialogOpening` + `lifecycleEvent` + `navigatedWithinDocument` events. `handleJavaScriptDialog` deliberately errors — use `LP.handleJavaScriptDialog`. **Failed navigations commit an error document since #3843 (10261)**: a root navigation that fails before a response (refused, DNS, TLS) used to leave the old document in place; it now commits "Navigation failed\n\nReason: CouldntConnect" at the *failed* URL (opaque origin), so `current_url` is the unreachable URL afterwards — `click_navigation_wait_test.rb`'s refused case asserts the old path and fails on ≥10261. Cancelled navigations (`window.stop()`, `Fetch.failRequest`) still keep the old document. |
| **Performance** | performance.zig | Performance metrics |
| **Runtime** | runtime.zig | JS evaluation, object inspection. Only Nodes carry `subtype: "node"` since #3831 (10255); below it every Zig-backed object did, so `evaluate_script` of `location`/`window`/a `DOMRect` came back as a bogus `Capybara::Node::Element`. From 10255 `location`/`DOMRect` serialize to Hashes and `window` raises `BrowserError: Object reference chain is too long` (`runtime.rb#unwrap_call_result` → `returnByValue`); thrown `DOMException`s carry their `Name: message` description. Verified 2026-10-10 on nightly 10379. |
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
Page.frameStartedNavigating (event)                      Page.frameStoppedLoading (event)
Runtime.enable               Runtime.evaluate
Runtime.callFunctionOn       Runtime.getProperties       Runtime.releaseObject
Runtime.executionContextCreated (event)                  Runtime.executionContextsCleared (event)
Runtime.consoleAPICalled (event)
DOM.describeNode             DOM.setFileInputFiles
Input.dispatchKeyEvent       Input.insertText
Network.getAllCookies        Network.setCookie
Network.deleteCookies        Network.clearBrowserCookies
Network.enable               Network.disable
Network.setExtraHTTPHeaders  Network.requestWillBeSent (event)
Network.responseReceived (event)                         Network.loadingFailed (event)
Browser.setDownloadBehavior  Browser.downloadWillBegin (event)
Browser.downloadProgress (event)
Emulation.setDeviceMetricsOverride
LP.handleJavaScriptDialog    LP.configureLoading (limitation #6)    LP.version
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
Page.getNavigationHistory    Page.navigateToHistoryEntry (reloads even a pushState entry — Browser#back uses history.back())
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
Input.dispatchMouseEvent
Network.setCookies (batch)   Network.getResponseBody     Network.setBlockedURLs
Network.setCacheDisabled     Network.clearBrowserCache    Network.canClearBrowserCache
Network.requestServedFromCache (event)                    Network.getRequestPostData (#3150, ≥8572)
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
Emulation.clearDeviceMetricsOverride  Emulation.setEmulatedMedia
Emulation.setFocusEmulationEnabled    Emulation.setTouchEmulationEnabled
Emulation.setGeolocationOverride      Emulation.clearGeolocationOverride (#3233, ≥8755)
LP.getSemanticTree           LP.getInteractiveElements
LP.getStructuredData         LP.waitForSelector
LP.getMarkdown               LP.getNodeDetails
LP.detectForms               LP.clickNode
LP.fillNode                  LP.scrollNode
LP.configureCDP              LP.getContentSignal
```

## Known Bugs and Limitations

### Critical for This Gem

1. **`Page.loadEventFired` unreliable** (#1801 — closed 2026-09-17 on "seems fixed on main", no PR or repro; treat as unproven)
   - May never fire on complex JS pages, Wikipedia, certain French real estate sites
   - This gem works around it with `document.readyState` polling fallback in `Browser#go_to`
   - DO NOT remove the readyState fallback — `Page.loadEventFired` itself is still unreliable
   - One family member fixed: readyState stuck at `"loading"` after a synchronous external-stylesheet fetch (forem homepage) — PR #2843, build ≥7692, in the floor

2. **No rendering engine (CSS much improved)**
   - Screenshots: since #3231 (≥8815) `Page.captureScreenshot` renders a real PNG — a text-layout rendering of the document (Rust-side renderer, bundled DejaVu fonts; honors `clip` + `deviceScaleFactor`; `format` png only; `printToPDF` still fake). Below 8815: hardcoded 1920×1080 placeholder. Not pixel-accurate compositor output — visual regression stays out of scope
   - `getComputedStyle` resolves inline `style=` declarations, cascade-aware `display`/`visibility` (via StyleManager, so author stylesheets and `@layer` count; `!important` honored since #3653, 9845), `width`/`height` matching `getBoundingClientRect` (which since #3612, 9772, honors stylesheet-declared sizes), custom properties `--*` (#3461, 9319), and CSS **initial** values for `color`/`opacity`/`background-color`. Every other property returns `""`; results are read-only since #3516 (9471).
   - **Closed `[popover]` reads as VISIBLE below 10052** (1.0.0, so the floor): no UA `[popover]:not(:popover-open) { display: none }`, so `checkVisibility()` is true and `display` `block` for a never-shown popover — Capybara matches its content. Fixed by our #3757 (10052; verified 2026-10-05 on nightly 10071: `checkVisibility()` false, `display` `none`). No gem-side mitigation. Inline keyword comparisons are case-insensitive since #3270 (≥8857). `checkVisibility` matches all active stylesheets
   - No scroll/resize, no visual regression testing
   - `getBoundingClientRect` and screenshots have no real layout: rects are synthesized from document/sibling position and return all-zero for non-visible elements
   - **Viewport IS emulatable**: `Emulation.setDeviceMetricsOverride` drives `window.innerWidth`/`innerHeight`, `matchMedia`/`@media` evaluation, AND `Page.getLayoutMetrics` (no longer hardcoded 1920×1080). This is a JS-visible viewport only — element geometry stays synthetic, so `obscured?`-outside-viewport still can't work. The gem wires its `window_size` option to it in `Browser#set_viewport` (called from `create_page`); `Options::DEFAULT_WINDOW_SIZE` mirrors the browser's native 1920×1080 so the default is a no-op.

3. **JavaScript context lost between navigations**
   - JS execution context is reset on every page load: globals, polyfills, and any custom functions evaluated in a previous document are gone.
   - Polyfills are auto-injected on every navigation via `Page.addScriptToEvaluateOnNewDocument`, registered once at session creation in `Browser#create_page`. Ad-hoc `Runtime.evaluate` calls still need to be re-run after each `visit`.
   - Node references (objectIds) become invalid after navigation

4. **`HTMLElement.isContentEditable` IDL attribute always returns false**
   - Native getter ALWAYS returns `false` and logs `.not_implemented` when the spec walk would have returned true. Rationale: Lightpanda has no caret/keyboard editing pipeline.
   - Gem polyfill at `javascripts/predicates.js` (`_lightpanda.isContentEditable`) MUST stay — it walks ancestors itself.
   - **#3372 (≥9097) does NOT change this** — audited 2026-09-04, don't re-audit. It reflected the *`contentEditable`* IDL attribute (getter returns `true`/`false`/`plaintext-only`/`inherit`, setter validates), so `el.contentEditable = 'true'` finally sets the attribute instead of creating an expando. `isContentEditable` is explicitly untouched: upstream's own `tests/element/html/contenteditable.html` asserts `false` for all nine cases including `ancestor-true`.

5. **External `<link rel="stylesheet">` fetch — ON by default in the gem** (build ≥6353)
   - The gem passes `--load-resources stylesheet` unconditionally (`Process#build_args`; `image` is appended to the same comma-separated value under `load_images:`), so `<link rel="stylesheet" href="…">` is fetched synchronously, parsed via `replaceSync`, added to `document.styleSheets`, and contributes to the cascade (`checkVisibility`/`getComputedStyle`). Author-vs-UA `[hidden]` ordering is correct. Cost: one synchronous CSS fetch per `<link>`. A sheet over **2 MiB** (4 MiB from #3889, 10375) is dropped whole — `error` event, none of its rules apply — so an unminified dev-mode bundle past the cap leaves `display: none` menus/tabs visible.
   - Per-session `LP.configureLoading {externalStylesheets: true}` also exists; the gem uses the CLI flag.
   - `@media` + `matchMedia` evaluate against the current viewport, which defaults to 1920×1080 but honors `Emulation.setDeviceMetricsOverride` (see limitation #2).
   - **Capybara impact**: responsive CTA variants gated by an external stylesheet now resolve to a single variant (no more `Capybara::Ambiguous`); externally-loaded responsive specs that previously needed cuprite/Selenium work on lightpanda.

6. **Iframes and workers are OFF by default from #3305 (build ≥8946) — LIVE, and handled by the gem**
   - `Config.LoadResources` became a `packed struct(u4)` (`iframe`, `worker`, `stylesheet`, `image`) with **every field defaulting false**, and `Frame.iframeAddedCallback` returns early on `load_resources.iframe == false`. The parser still puts the `<iframe>` in the DOM; no child frame is ever created, so `switch_to_frame` / `within_frame` find nothing.
   - **The gem's fix is in**: `Browser#configure_loading` sends `LP.configureLoading {subFrame: true, worker: true}` from `create_page` — per-BrowserContext, so it re-runs after every `Driver#reset!`. Kept on CDP rather than adding `iframe,worker` to the CLI `--load-resources` value even now that the floor allows it: the CDP path is already pinned end-to-end by `test/features/frame_loading_test.rb`, and a unit test guards that `build_args` never names iframes/workers so the two mechanisms can't drift apart.
   - `--load-resources` takes a comma-separated value (`cli.zig` sets each named field of the `LoadResources` packed struct; `full` sets all). The gem sends `stylesheet` or `stylesheet,image`.
   - Because the gem opts workers back in, worker requests still count toward `wait_for_idle`.

7. **SIGTERM after a live CDP connection — hangs fixed upstream (#2509 telemetry, #2511 live-WS, both ≤ floor), gem keeps both teardown layers regardless** (crash / GC-abandon paths still need them):
   1. **Primary** — `Browser.track`/`quit_all` closes the CDP WS from a single `at_exit`
      *before* SIGTERM, so teardown is instant. Regression-tested by
      `test/features/teardown_test.rb` (at-exit < 2s = clean SIGTERM, not the 3s SIGKILL fallback).
   2. **Backstop** — `Process#stop` + the `weak_kill` finalizer escalate `TERM` → 3s grace →
      `SIGKILL` → reap, for the crash / GC-abandon paths the `at_exit` can't reach.

### Upstream Open Issues That Affect This Gem

| Issue | Impact | Description |
|---|---|---|
| #1890 | Navigation | Multi-step form POST does not update page content (SAP SAML login). |
| #3770 | Navigation | `location.hash = '#x'` fires `hashchange` but not `popstate`. |
| #3764 | Text | `innerText` ignores `text-transform`, so Capybara `text` sees the source case (our PR #3765, open). |
| not filed | Navigation | `location.href = 'javascript:…'` requests `http://javascript:…` (`UrlMalformat`). Harmless through 10260; from #3843 (10261) the failed navigation emits `executionContextsCleared` and never creates a context, so every later call raises `NoExecutionContextError` until the next `visit`. `CLICK_JS` assigns every `<a href>`, so clicking `href="javascript:void(0)"` (select2, Bootstrap toggles) kills the page — `driver_test.rb` "descends a wrapper click" fails 5/5 on nightly 10379, passes on 1.0.0 (verified 2026-10-10). |
| #3852 | Binary | The 1.0.0 `aarch64-linux` binary needs glibc 2.38 (built on `ubuntu-24.04-arm`; x86_64 needs 2.35), so Debian 12 / Ubuntu 22.04 arm64 can't start it. |

**Gem-side defenses we keep regardless of upstream**: the `readyState` fallback in `Browser#go_to` (#1801 closed 2026-09-17 on "seems fixed on main", no PR/repro), `handle_navigation_crash` (#2173 closed as usage error), `Browser#with_default_context_wait` + `NoExecutionContextError` in `invalid_element_errors` (#2400 fixed by #3397, 9238 — still cheap defense-in-depth).

**Known flake** (seen 1× in ~25 runs on nightly 10033, 2026-10-03): Capybara's `#switch_to_frame works if the frame is closed` — after `Close Window Now` (the child frame's `onClick` removes its own `<iframe>` from the parent), `#childFrame` was still present for the whole wait. Not caused by `CLICK_JS`'s focus step (0/10 with and without it). If it recurs on main CI, capture `console_logs` and suspect the child frame's `closeWin` not being defined yet when the click lands.

**Audited immune, do not re-audit**: `Network.enable` double-registered its listener before 8298 (under the floor, moot). The gem enables exactly once per BrowserContext anyway — `Network#enable`'s `@enabled` guard, and `Network#reset` clears the flag only *after* `Target.disposeBrowserContext`. Keep that ordering. #3179 closed "can't reproduce"; `CLICK_JS` assigns `location.href` itself regardless. CDP-layer audit 2026-10-03 (9058 → 10038): every method the gem uses still exists (domains moved to `src/server/cdp/domains/`); #3595 (`sessionId` echoed in replies — gem routes by id), #3600 (detach/destroy events on `disposeBrowserContext` — gem doesn't subscribe), #3598 (about:blank lifecycle — only with `setLifecycleEventsEnabled`), #3521 (returnByValue shape unchanged) are all inert. The gem's `/No node with given id found/` match (`client.rb`) is a Chrome string Lightpanda never emits (it sends `-31998 NodeNotFound`/`UnwrapFailed`, `-32000 Invalid remote object id`) — dead, not a regression.

### General Limitations

- Many Web APIs not yet implemented (hundreds remain)
- Complex JS frameworks may not work (React SSR hydration, heavy SPA)
- Same-document navigations: `Page.navigatedWithinDocument` IS emitted for `history.pushState`/`replaceState` (#2964, build ≥8143, `navigationType: historyApi`); fragment navigation and history traversal still emit nothing (#2829, open). The gem is immune either way — `Browser#current_url`/`frame_url` read `window.location.href` via `Runtime.evaluate`, not CDP frame-URL tracking — so keep it that way (don't switch `current_url` to an event-tracked frame URL).
- `window.getComputedStyle()`: see limitation #2 (cascade-aware `display`/`visibility`, `--*` custom properties, stylesheet-aware `width`/`height`; everything else `""`). `checkVisibility` matches all active stylesheets including `@layer`
- `window.scrollTo()`/`scrollBy()` track a scroll position (`window._scroll_pos`, fire `scroll`/`scrollend`) and `Element` exposes `scrollTop`/`scrollLeft`/`scrollIntoView` — BUT element scroll is decoupled from window scroll and no layout means `getBoundingClientRect` isn't scroll-aware. So position scroll is readable but `:bottom`/`:center` and element-relative alignment are meaningless; the gem keeps `Node#scroll_to`/`scroll_by` as no-ops and `:scroll` stays in `capybara_skip`. Since #3048 (build ≥8305, in the floor) an inner element's `scrollWidth`/`scrollHeight` is `max(clientSize, sum of direct *element* children)` instead of aliasing `clientSize` — enough that measure-then-mutate loops (the infinite-marquee idiom) terminate. Layout mode is not detected, so the numbers bound content extent rather than describe a layout. **Since #3614/#3588 (9899/9659)** `<html>`/`<body>` `scrollHeight`/`offsetHeight` are a synthetic document extent (not 1e8) and `window.scrollTo/By` clamp to `scrollSize − viewport` — on a short page `scrollTo(0, scrollHeight)` doesn't move or fire `scroll`, so an infinite-scroll trigger may never fire. `documentElement.clientHeight` is the viewport in standards mode.
- `<option>`s inside an `<optgroup>` are visible to `HTMLSelectElement` (`options`, `value`, `selectedIndex`, `selectedOptions`, submission) — our #3058, in the floor. No gem-side workaround exists below it, so don't lower the floor past 8328.
- `option.selected = true` deselects its siblings in a single `<select>` (#3375, 9071, in the floor), so `SELECT_OPTION_JS` sets it directly — the old `sel.value =` detour picked the *first* option sharing a value. The `_lightpanda.isDisabled(this)` guard stays: both IDL routes select a disabled option per spec.
- Timers: `MAX_CALLBACKS` (shared by timeouts + intervals + rAF) 8192, repeating 2048 (#3445, 9274). Delays are clamped to `i32` ≥ 0 since #3719 (10027). Non-standard `window.setImmediate` removed in #3784 (10100, Chrome has none).
- **Uncaught exceptions from timers, rAF and inline `on*` handlers reach `window`'s `error` event only from 10049** (our #3755; verified 2026-10-05 on nightly 10071). Below it — 1.0.0, so the floor — only `addEventListener` listeners and top-level scripts do, so `errors.js` / `Browser#page_errors` miss the rest. `queueMicrotask` and observer-callback exceptions reach it from #3849 (10310, isolate message listener; verified 2026-10-10 on nightly 10379). No gem-side workaround possible below either build.
- `Runtime.consoleAPICalled` object args carry no `value` since #3504 (9414) — only primitives do — so `console_logs[:text]` renders `console.log({a:1})` as `Object`, DOM nodes/`undefined` as `""`. Gem's sentinels are primitives (unaffected); `console.rb#console_arg_text` falls back `value → unserializableValue → description → className → type` for both `console_logs[:text]` and the IO logger.
- Cookies (#3529, 9877; #3514, 9446): `Network.setCookie` with `sameSite: "None"` and no `secure` returns `{success: false}` and drops the cookie — `Cookies#set` returns that boolean (ferrum parity), and `Cookies#load` strips `None` from insecure entries (pre-9877 stores reported every unspecified cookie as `None`) and warns on any refusal. Cookies without SameSite are Lax-by-default (Chrome's 2-min POST exception) and `getAllCookies` omits the field (`Cookie#same_site` → nil). Secure cookies are now sent on `http://127.0.0.1`/`localhost` (loopback is a secure context; `isSecureContext` true there since #3565). **Chrome's cookie validation from #3791 (10212)**: a control char or `;` in the name or value, `=` in the name, or surrounding whitespace now answers `-32602 Sanitizing cookie failed`, so `Cookies#set` *raises* `BrowserError` instead of returning `false` (verified 2026-10-10 on nightly 10379; below 10212 such a cookie was silently stored); a `domain` without a leading dot is host-only (it used to reach subdomains); an `https` `url` forces Secure. #3793 (10214) accepts Chrome-exported `priority`/`sourceScheme`/`sourcePort`/`sameParty` fields.
- `<template>` custom elements are no longer upgraded before import (#3587/#3409/#3519) — Turbo Streams rely on `importNode(el, true)` of template content; real-apps CI passed on a ≥9719 nightly (2026-09-28), so treat as watched, not broken. #3830 (10241) moved fragment-parsed custom-element constructors after insertion — re-check on the next real-apps run.
- Audited through **10424** (main HEAD 2026-10-10; nightly 10379, release 1.0.0 = 9994, 0.4.1 = 9463). Everything ≤9994 is in the floor and lives in the bullet it belongs to. In-floor one-liners kept so they aren't re-derived: `Authorization` dropped on cross-origin redirect hops (#3267); immediate `<meta http-equiv=refresh>` (#3283); runaway `MutationObserver`/`IntersectionObserver` auto-disconnect (#3316/#3383); unknown CDP methods answer `-32601` (#3324 — inert, gem matches message text); `target=_blank` opens a popup `Frame` (#3327 — gem insulated, `CLICK_JS` assigns `location.href`); BiDi alongside CDP (#3209 — gem stays on CDP). In the floor, not covered elsewhere: `<fieldset disabled>` gates descendant `.click()`/`willValidate` (#3376, 9074); `contentEditable` IDL reflected but `isContentEditable` still hardwired false (#3372, limitation #4); `--locale`/`--timezone` CLI (#3466, 9309 — defaults unchanged: `Accept-Language: en-US,en;q=0.9`); `--http-timeout` default 15 s (#3432, 9258); `DOM.setFileInputFiles` fires `change` in the owning iframe (#3566, 9602 — `attach_file` inside `within_frame` now reaches iframe listeners); `Driver#html` includes `<template>` content (#3717, 10022); innerHTML parsed with correct context (#3430, 9256). Above the floor (nightly/main only, gate any test on `browser.nightly_build`): nested inline `<script>` no longer drains microtasks/timers mid-`appendChild` (#3750, 10046); `form.<name>` named field access (#3778, 10060); `Page.navigate` honors `referrer`/`referrerPolicy` (#3738, 10062 — gem passes neither); type selectors match XML/camelCase SVG and `*-of-type` tells custom elements apart (#3761/#3762, 10064/10068); a materialized `Attr` follows later `setAttribute` (our #3766, 10071 — Stimulus `data-*-param` via `element.attributes`, XPath `@attr` re-reads); `input.value =` reflects to the attribute in default modes (`hidden`, `submit`, `button`, … — our #3776, 10080 — `input[value='x']` finders); a descendant's own `visibility`/`pointer-events` overrides the inherited value (#3739, 10094 — `_lightpanda.isVisible` follows, Chrome parity); `history.back()` between path-differing `pushState` entries restores in place with `popstate` (our #3763, 10239 — closes #3726, verified on 10379); a form submitted from `/x#frag` to `/x` sends its request (our #3771, 10164); per-Window `History` and caller-relative `Location` URLs (our #3773/#3775, 10130/10136 — iframe pages); `:checked` matches selected `<option>`s (#3811, 10148); `innerText` of a not-rendered element returns its raw text (#3876, 10357); `abort()` cancels an in-flight fetch with `AbortError` (#3837, 10308 — closes #3725, so aborted Turbo fetches stop holding `wait_for_idle`); `setAttribute('src')` on a connected iframe navigates it (#3806, 10225); pseudo-element selectors parse and match nothing instead of throwing (#3891, 10419); `<option>` text collapses markup whitespace (#3896, 10422); aarch64-linux regexp-JIT SIGILL fixed (#3844, 10274 — closes #3672; 1.0.0 still has it, workaround `LIGHTPANDA_EXTRA_ARGS="--v8-flags-unsafe --regexp-interpret-all"`). Service workers / WebDriver / adblock / agent-MCP / Web Locks / CompressionStream / `Target.targetInfoChanged` (#3850, unsubscribed) PRs are opt-in or inert for the gem.
- **Keyboard activation via CDP since #3264 (≥8842, in the floor)**: `Input.dispatchKeyEvent` builds a *trusted* `KeyboardEvent` routed through `frame/user_input.zig`: a printable-or-Enter keydown without ctrl/meta fires `keypress` (cancelling it suppresses Enter's implicit submit), and Enter on `<button>`/`<a href>`/`input[type=button|submit|reset|image]` or Space-keyup on buttons/checkbox/radio synthesizes a trusted activation `click` — so `send_keys(:enter)` submits and `send_keys(:space)` toggles. No double-fire: `Keyboard#send_key_event` sends only `keyDown`/`keyUp` (chars via `Input.insertText`), and `CLICK_JS`'s events are untrusted. **Send `keyDown`, never `rawKeyDown`** — `input.zig` dropped `rawKeyDown` outright below #3716 (10020, not in 1.0.0), which is why every text-less key silently no-oped until the gem's 2026-09-06 fix. Since #3542 (9580) typing follows the `text` param, not `key`, and `keypress` also fires under Ctrl — so `Keyboard#dispatch_modified_char` omits `text` while Ctrl/Meta is held (a chord is a command; `[:ctrl, "a"]` used to type a stray `a`). Pinned by `test/features/keyboard_activation_test.rb`. Above the floor: Enter in a text field now *clicks* the form's default button instead of submitting directly (#3783, 10154 — its click handlers run, per spec), and Ctrl+A runs `select()` in an `<input>`/`<textarea>` (#3874, 10366 — `send_keys([:control, "a"], :backspace)` clears the field, verified 2026-10-10 on nightly 10379; Meta+A doesn't, Linux parity).
- **Keyboard editing via CDP since #3298 (≥8937, in the floor)**: a trusted Backspace/Delete keydown on `<input>`/`<textarea>` runs `user_input.zig#editKey` → trusted `beforeinput` → one-character delete (or the selection) → `input`, inputType `deleteContentBackward`/`deleteContentForward`. Pinned by `test/features/keyboard_editing_test.rb`. Our upstream fixes, all in the floor and pinned in the same file: `beforeinput` cancelable so `preventDefault()` vetoes the edit (#3414, 9217 — masked-input libs); `.value =` moves the caret to the end when the value changes (#3420, 9223 — below it `set` then `send_keys(:backspace)` no-ops); `<textarea>` `select()`/`setSelectionRange()` read the child-text default (#3422, 9229); arrows/Home/End move the caret and Shift extends the selection, and `Input.insertText` inserts *at the caret* (#3424, 9234 — the attribute-seeded `value` case is handled by `SEND_KEYS_FOCUS_JS`, see the top). Below 10057 (1.0.0, so the floor) `send_keys` inside an iframe types nothing: `Input.*` targets the top frame's `activeElement`, which never becomes the `<iframe>`. Fixed by our #3759 (10057, in nightly ≥10071).
- `<form method="dialog">` closes its nearest ancestor `<dialog>` (`returnValue` from the submitter, `close` event) without navigating (our #3054), and a closed `<dialog>` with its whole subtree reads as non-visible (#3269). Both in the floor and with no gem-side fallback — the floor is the only defense for Spree 5's `<dialog>`+Turbo-confirm destroy flow. Pinned by `test/features/upstream_bugs_test.rb` (Bug #4).
- `MutationObserver` available; `window.postMessage` across frames works
- CORS: **enforced by default since #3654 (9883, in 1.0.0)**. Checked (`request_mode .cors`): `fetch()`, XHR, EventSource, module scripts / `import()`, classic scripts with `crossorigin`. Not checked: classic `<script>`, stylesheets, images, WebSocket. Same-origin = scheme + exact host + port, so `127.0.0.1` vs `localhost` or another port is cross-origin (Chrome parity). Opt-out `--disable-features cors` (fatal `UnknownOption` below 9883; `--experimental-features cors` still parses but is ignored); no per-session CDP switch. The gem passes no flag — keep Chrome parity (Cuprite/Selenium suites already satisfy CORS; opting out gives false greens). A blocked request emits `Network.loadingFailed {errorText:"CorsBlocked"}` (no response); `Network` closes the entry from it and keeps `errorText` as `traffic[..][:error]`, so `wait_for_idle` isn't held hostage (pinned by `test/features/network_failure_test.rb`). Blocks are logged only at debug level — nothing in `console_logs`. Preflight cache is process-wide (survives `Driver#reset!`).
- In-page `WebSocket` API implemented; sends `Origin` on upgrade since build 6736 (PR #2710), so ActionCable's request-forgery check passes and `turbo_stream_for` / solid_cable streams connect without `disable_request_forgery_protection`
- `window.open` partial support: no `target=window_name`/`_blank`, sub-pages share the parent's lifetime, no CDP-side validation. Useful for sites that call `window.open` defensively for login popups.
- Workers: dedicated + **SharedWorker** implemented (#2017). Workers run in the same thread as the page with a separate context; individual Worker-scope APIs may still be missing. **Off by default from #3305 (≥8946)** — `--load-resources worker` / `LP.configureLoading {worker: true}` opts back in; the old `--disable-workers` opt-out is now inert. `WorkerNavigator` added #3288 (≥8892).
- Landed between builds 7776 and 8300: **IndexedDB** (#2732; in-memory unless `--storage-engine sqlite`), **EventSource/SSE** (#2879), `CookieStore`, `ResizeObserver`, the Navigation API, `BroadcastChannel`, `StorageEvent`, `BeforeUnloadEvent`, `TouchEvent`, SVG geometry/animated-value interfaces, `DOMMatrix`/`DOMPoint`.
- No Service Workers, SharedArrayBuffer
- No `localStorage`/`sessionStorage` persistence across sessions (in-memory only; `--storage-engine` backs IndexedDB, not Web Storage)
- File upload — **SUPPORTED since build 6672** (no longer a limitation). `DOM.setFileInputFiles` (PR #2635) populates `input.files` + fires `change`; PR #2654 wires multipart `.file` submission (filename + Content-Type + bytes, RFC 7578). Both halves are guaranteed by the floor. `Node#fill_input` routes `<input type=file>` through `Browser#set_file_input_files`. Paths are read off the machine running Lightpanda (fine for the locally-spawned process). Validated by the Capybara `#attach_file` shared specs (29 examples, 0 failures).
- File **download** — **SUPPORTED since build 7545** (PR #2722, in the floor). `Browser.setDownloadBehavior {behavior:"allow", downloadPath, eventsEnabled}` streams a navigation response carrying `Content-Disposition: attachment` to disk (on the Lightpanda host) and emits `Browser.downloadWillBegin`/`downloadProgress`. The gem's `Downloads` tracker (`downloads.rb`) wires this in `Browser#create_page` whenever a destination exists (`:save_path` option, else `Capybara.save_path`); `Driver#downloads` / `#wait_for_download` expose the completed-file list. **Trigger is `Content-Disposition: attachment`, NOT MIME type** — a `text/csv` (or any) response WITHOUT that header is rendered as a normal (empty) navigation, not downloaded. That's why Capybara's `:download` shared spec (its `/download.csv` fixture is MIME-triggered, no Content-Disposition) stays in `capybara_skip`; the real attachment path is covered by `test/features/download_test.rb`. `<a download>` clicks navigate to the attachment URL (Lightpanda commits an empty doc afterward) rather than staying on the page.
- Drag-and-drop (HTML5 file/data drop) — **SUPPORTED since build 6699** (PR #2671: `DataTransfer`/`DataTransferItem`/`DataTransferItemList` + `DragEvent`). `Node#drop` (Capybara's `Element#drop`) attaches a hidden `<input type=file>` to the dropzone's document, loads it via `DOM.setFileInputFiles` (bytes read off disk on the Lightpanda host, `file.type` sniffed by the browser), moves `input.files` into a `DataTransfer` alongside `{mime => data}` typed items, then fires `dragenter`→`dragover`→`drop` (`DROP_JS`). Geometry-free; no payload-size ceiling in the driver (`--cdp-max-message-size 100 MiB` stays for large `execute_script` bundles). `Node#drag_to` (2026-08-24) runs Capybara's own Selenium HTML5 drag script via `evaluate_async` (`HTML5_DRAG_JS` in `node.rb`) — 12/13 of the `#drag_to HTML5` shared specs pass (our #3259 floors MouseEvent coordinate getters Chrome-style; our #3257 ships `HTMLElement.draggable`, read verbatim by the drag scripts); the one remaining skip is SortableJS (mouse-fallback path — Selenium can drive a real mouse, we cannot). Coordinate-based `drag_by` and non-HTML5 `drag_to` raise `NotImplementedError` (no layout).

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
--load-resources <a,b,…>                   # Comma-separated value from
                                           # iframe|image|stylesheet|worker (or `full`); repeats
                                           # OR together. ALL FOUR DEFAULT OFF since #3305 (≥8946).
                                           # Gem passes `stylesheet` (+`,image` under load_images).
--enable-external-stylesheets              # DEPRECATED alias of `--load-resources stylesheet`
                                           # since #3305 (≥8946); still parses, warns. Gem no
                                           # longer passes it (floor ≥ 9058).
--cdp-max-message-size <BYTES>             # Inbound CDP WS cap, default 1 MiB (gem: 100 MiB)
--disable-subframes                        # DEPRECATED by #3305 (≥8946): iframes are now OFF by
                                           # default, so this opt-OUT is inert. Re-enable with
                                           # `--load-resources iframe`.
--disable-workers                          # DEPRECATED by #3305 (≥8946), same flip.
--disable-features cors                    # CORS is ON by default since #3654 (≥9883); this opts
                                           # out (fatal UnknownOption below 9883). The gem passes
                                           # nothing (Chrome parity). `--experimental-features
                                           # cors` still parses but is ignored;
                                           # `--experimental-features serviceworker` gates SWs.
--locale <tag> / --timezone <tz>           # #3466, ≥9309 (fatal below). Gem passes neither.
--http-timeout <ms>                        # Default 15 s since #3432 (≥9258).
--storage-engine none|sqlite               # IndexedDB persistence backend
--storage-sqlite-path <PATH>               # SQLite file (":memory:" allowed)
--user-agent / --user-agent-suffix         # UA control (Mozilla-containing values still rejected)
--http-header "Name: value"                # Sent on every HTTP request (#3187, ≥8717); outranks
                                           # CDP setExtraHTTPHeaders for the same name
--block-urls / --block-cidrs / --block-private-networks
--ca-cert <PATH> / --ca-path <PATH>        # TLS roots from a PEM file / directory;
                                           # either one REPLACES the system trust store
--http-cache-dir <PATH>                    # On-disk HTTP cache
--inject-script / --inject-script-file     # CLI-side equivalent of addScriptToEvaluateOnNewDocument
--log-format pretty|json                   # Log output format
--log-level info|debug                     # Verbosity
--log-filter <SCOPE>                       # Renamed from --log-filter-scopes by #3305 (≥8946);
                                           # the old name still parses with a warning. The gem
                                           # passes neither — only `LIGHTPANDA_EXTRA_ARGS` can.

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
- **All four arch/OS pairs are published on every channel** (verified 2026-07-25
  against `nightly` and 0.3.5): `lightpanda-x86_64-linux`,
  `lightpanda-aarch64-linux`, `lightpanda-x86_64-macos`,
  `lightpanda-aarch64-macos`. `Binary::PLATFORMS` maps all four — it used to list
  only x86_64-linux and aarch64-macos, which raised `UnsupportedPlatformError` on
  Intel Macs and arm64/Graviton runners that upstream ships a binary for. Don't
  re-narrow it.
- Latest release: **1.0.0 (2026-10-02) = build 9994**; 0.4.1 (2026-09-15) = 9463; 0.4.0 (2026-08-31) = 9058. Main's `build.zig.zon` is now `1.1.0-dev`, so nightlies print `1.1.0-nightly.N+hash` (the gem's `(?:nightly|dev)\.(\d+)` regex handles it). Tags drop the `v` prefix since 2026-04. Per release: `lightpanda-{aarch64,x86_64}-{linux,macos}` + `.deb` packages.

**Two version-string shapes, two gem floors** (verified 2026-07-24): `build.zig`'s
`resolveVersion` enriches a version with `git rev-list --count HEAD` + short hash
*only* when it carries a pre-release tag. The release workflow passes
`-Dversion=<tag>`, which parses as a full semver with no pre-release — so a
tagged release prints a bare `0.3.5` with **no build counter**, while nightlies
print `1.0.0-nightly.8285+de85a51d`. `Process#check_minimum_version` therefore
gates two channels: `MINIMUM_NIGHTLY_BUILD` (build counter) and
`MINIMUM_RELEASE` (semver). Keep them in lockstep — a release is acceptable
exactly when its own commit count clears the nightly floor
(`git rev-list --count <tag>`; 1.0.0 = 9994, 0.4.1 = 9463, 0.4.0 = 9058, 0.3.7 = 8671, 0.3.6 = 8318, 0.3.5 = 8165, 0.3.4 = 7708, 0.3.3 = 7562).
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
