# Lightpanda Browser Reference

Upstream: https://github.com/lightpanda-io/browser (AGPL-3.0). Source audit verified 2026-11-11 at `e2593a0cc` (build 12019). The published nightly is 12013 (`cae5d41fa`, 2026-11-11); pre-release 1.0.4-rc1 is 12015 (`44d096b9a`, a CI-only delta on top).

## Version and transport constraints

- Floors: `Process::MINIMUM_NIGHTLY_BUILD = 11647`, `MINIMUM_RELEASE = 1.0.3`, the same commit (raised 2026-11-05). `process.rb` owns the floor rationale. Release binaries have no `nightly_build`; only gate behavior above the floor and remove gates when raising it.
- A release prints bare semver; a nightly includes `git rev-list --count` and a hash. Keep both floors aligned. Only releases are reproducible pins: the rolling nightly tag is overwritten. A release candidate (#4480) prints `<semver>-rcN.<count>+<hash>` (`build.zig#resolveVersion`) and `Process::RC_VERSION` checks its counter against the nightly floor, so 1.0.4-rc1 (2026-11-11, GitHub pre-release) reads as build 12015 and takes the nightly-gated paths; `Binary.required_version = "1.0.4-rc1"` downloads it. Format derived from source, the binary was not run.
- Four binary targets: `{aarch64,x86_64}-{linux,macos}`. Keep all four in `Binary::PLATFORMS`; two-entry maps broke Intel Macs and Graviton runners. Latest release: 1.0.3 (2026-11-05) = the floor, build 11647 (`b8e234a77`); #4430, #4242 and #4450 (11651/11663/11672) ship only in nightlies and 1.0.4-rc1. Release aarch64-linux binaries (1.0.2 included) need glibc 2.38, x86_64 2.35, so Debian 12/Ubuntu 22.04 arm64 can't run them; #3852 closed as documented (#4333), not rebuilt. x86_64-macos binaries built before #4450 (11672), releases 1.0.2 and 1.0.3 included, have no CPU baseline and crash with SIGILL on the first HTTPS request on CPUs without ADX (#4433, closed by #4450; 1.0.4-rc1 carries the fix, no final release does). From #4533 (11915) the aarch64-macos build pins `-Dcpu=apple_m1` on macos-15 runners: nightly 11745, built native on a newer chip, SIGILLed at startup on M1 (#4519, closed); 1.0.3 runs.
- Zig 0.17 + V8, html5ever, libcurl and CSSOM; geometry and screenshots remain approximate, without a full layout/paint engine.
- WebSocket upgrade rejects `Origin` unless `--remote-allow-origins` permits it. `Host` accepts IP literals, exact lowercase `localhost:<port>`, or explicit `--advertise-host`; bare/uppercase localhost and suffix attacks fail. Spawned clients use the logged address and send no Origin. From #4553 (11986) the same Host check guards every HTTP route (`/json/*`), not only upgrades.

## CDP commands used by the gem

All **31 distinct literal commands** below are admitted by the dispatch enums at 12013 and at the audited SHA (12019). Call sites are under `lib/capybara/lightpanda/`, including multiline command/page_command calls. Runtime's evaluate/callFunctionOn/getProperties/releaseObject go through `sendInspector` → `Target.callInspector` → V8, not separate Zig handlers.

**Multi-target CDP (#3945, 11844, nightly-only):** per-page state moved from BrowserContext to a `Target` (up to 16 per context; `disposeBrowserContext` closes them all). A command reaches the target of its session; each target is its own inspector context group. Source-checked against the gem's single-target model: `target_id` still equals the root frame id (`target.zig` sets it from `id.toFrameId`), which `browser.rb#subscribe_to_navigation` relies on; console messages and exceptions now carry the frame they ran in (iframe `executionContextId`), and the gem reads neither. Validated 2026-11-08 on a local `d2f387cae` (11912) build: `test:all` 690 runs and `spec:shared:parallel` 0 failures.

| Domain | Commands |
|---|---|
| Browser | `setDownloadBehavior` |
| DOM | `describeNode`, `setFileInputFiles` |
| Emulation | `setDeviceMetricsOverride` |
| Input | `dispatchKeyEvent`, `insertText` |
| LP | `configureLoading`, `handleJavaScriptDialog`, `version` |
| Network | `clearBrowserCookies`, `deleteCookies`, `disable`, `enable`, `getAllCookies`, `setCookie`, `setExtraHTTPHeaders` |
| Page | `addScriptToEvaluateOnNewDocument`, `captureScreenshot`, `enable`, `getLayoutMetrics`, `navigate`, `reload` |
| Runtime | `callFunctionOn`, `enable`, `evaluate`, `getProperties`, `releaseObject` |
| Target | `attachToTarget`, `createBrowserContext`, `createTarget`, `disposeBrowserContext` |

Caller-controlled `command`, `page_command` and `execute_cdp` accept arbitrary names; these escape hatches are not a finite inventory. The `LP.getMarkdown` (driver.rb) and `Network.setBlockedURLs` (selenium_compat.rb) strings are doc-comment examples, not built-in calls.

### Subscribed events (14 distinct names)

```
Browser.downloadProgress Browser.downloadWillBegin
Network.loadingFailed Network.requestWillBeSent Network.responseReceived
Page.domContentEventFired Page.frameStartedNavigating Page.frameStoppedLoading Page.javascriptDialogOpening Page.loadEventFired
Runtime.consoleAPICalled Runtime.exceptionThrown Runtime.executionContextCreated Runtime.executionContextsCleared
```

Emission sites: `domains/browser.zig` (downloads), `network.zig` (requests/responses/failures), `page.zig` (navigation/dialogs/context clearing), `runtime.zig` (console/exceptions). `Runtime.executionContextCreated` comes from V8's inspector via `Inspector.contextCreated`; a missing literal emitter in Zig is not missing support. Presence is a source check, not a guarantee of event timing: keep the readyState fallback.

### Available CDP methods (not yet used by this gem)

```
Page.setDocumentContent (#4304, 11433)                    Performance.getMetrics (#4305, 11426)
CSS.getComputedStyleForNode (#4377, 11626)
LP.waitUntil {until: load|domcontentloaded|networkalmostidle|networkidle|settled|done, timeout} (#4422, 11698; main frame only, also emits a `settled` Page.lifecycleEvent; `settled` ignores intervals, timers >100 ms and IntersectionObserver work)
Page.createIsolatedWorld     Page.getFrameTree
Page.getNavigationHistory    Page.navigateToHistoryEntry (same-document traversal fixed by #3903, 11113, in the floor; Browser#back keeps history.back())
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
Input.dispatchMouseEvent     Input.dispatchTouchEvent (#3816, 10479)
Input.setInterceptDrags      Input.dispatchDragEvent (#4228, 11246; external text drag only, no files or native dragstart)
Page.frameDetached (event, #3939, 10544 — removed iframes)
Network.setBlockedURLs (`urlPatterns: [{urlPattern, block}]` only, no legacy `urls`; sets the browser-wide HttpClient list, which disposeBrowserContext does not clear)
LP.getMarkdown               LP.configureLoading {beacon} (#4504, 11869)
Network.setCookies (batch)   Network.getResponseBody
Network.setCacheDisabled     Network.clearBrowserCache    Network.canClearBrowserCache
Network.requestServedFromCache (event)                    Network.getRequestPostData
Runtime.addBinding           Runtime.runIfWaitingForDebugger (stub)
DOM.enable                   CSS.enable
Fetch.enable                 Fetch.disable
Fetch.continueRequest        Fetch.failRequest
Fetch.fulfillRequest         Fetch.continueWithAuth
Target.closeTarget           Target.getBrowserContexts
Target.getTargets            Target.getTargetInfo        Target.setAutoAttach
Target.setDiscoverTargets (stub)  Target.activateTarget (stub)
Target.attachToBrowserTarget Target.detachFromTarget     Target.sendMessageToTarget
Browser.grantPermissions / setPermission / resetPermissions
Browser.setWindowBounds (noop)  Browser.getWindowForTarget (fixed windowId)
Emulation.clearDeviceMetricsOverride  Emulation.setEmulatedMedia
Emulation.setFocusEmulationEnabled    Emulation.setTouchEmulationEnabled
Emulation.setGeolocationOverride      Emulation.clearGeolocationOverride
LP.getSemanticTree           LP.getInteractiveElements
LP.getStructuredData         LP.waitForSelector
LP.getNodeDetails
LP.detectForms               LP.clickNode
LP.fillNode                  LP.scrollNode
LP.configureCDP              LP.getContentSignal
```

## Constraints the driver must preserve

- **Navigation:** `Page.loadEventFired` can be absent; keep `go_to`'s readyState polling. A refused/DNS/TLS root navigation commits an error document at the failed URL; from #4430 (11651) a Fetch bad-list port (1, 22, 25, 6000…) fails the same way with `net::ERR_UNSAFE_PORT`, before any connection; cancelled navigation keeps the old document. Click waits must follow main-frame navigation start and document readiness, not just context clearing or Turbo idle. From #4554 (11988) readyState turns `interactive` when the parser ends, before deferred and module scripts run (DOMContentLoaded still waits for them), as in Chrome; below it `interactive` came just before DOMContentLoaded. So `interactive` no longer means the page's JS ran: `wait_for_document_ready` requires `complete`, and `navigation.rb#page_ready?` (go_to's fallback after 2 s without `loadEventFired`) accepts `interactive` only once the navigation timing entry shows DOMContentLoaded (`visit_readiness_test.rb`).
- **History:** same-document `Page.navigateToHistoryEntry` is fixed in the floor (#3903, 11113); history.back/forward works and stays unless a switch is validated. Read URLs from location rather than tracking them from frame events.
- **Frames:** `callFunctionOn` executes in the top context even with an iframe node as `this`; use `this.ownerDocument/defaultView`. Frame scripts compile through the frame's own eval while accepting top-context handles. #4192's listener-world fix does not establish that this constraint changed or resolve issue #3833.
- **Node handles:** old-document `this` can raise NoExecutionContextError; old nodes passed as arguments can raise a cross-world error mapped to NodeNotFoundError. Only actual nodes have subtype node; ordinary objects serialize by value and cyclic values can be refused.
- **Modals:** form method=dialog closes the ancestor dialog without navigation; a closed dialog subtree is invisible, which the Spree/Turbo confirm flow depends on. Use LP.handleJavaScriptDialog before the action. Page.handleJavaScriptDialog deliberately errors. One pre-arm slot is consumed once; do not raise from the event-dispatch thread.
- **Resources:** CLI resource loading defaults off. Process passes `--load-resources stylesheet` (+ image when requested); create_page sends LP.configureLoading with subFrame/worker true. Keep iframe/worker configuration on the existing per-context CDP path; the frame-loading/build-args tests prevent CLI/CDP drift. `subFrame: false` is not a cheap middle ground: from #4515 (11917) such an iframe gets an about:blank window whose HTTP and WebSocket requests are all refused.
- **External CSS:** loaded synchronously into the cascade; a sheet over 4 MiB is dropped whole. A large development sheet can expose normally hidden menus.
- **Viewport:** Emulation changes innerWidth/Height, matchMedia and layout metrics; rects remain approximate. Resizing fires MediaQueryList changes, but stylesheet @media cascade was only re-resolved after navigation in the verified viewport tests. Default 1920×1080 mirrors the browser; changing it shifts existing media branches.
- **Hit testing:** retain owning-frame and outer-to-inner shadow checks. ShadowRoot hit testing (#4184, 11071) is in the floor; predicates.js still feature-detects it. Native shadow visibility excludes unslotted light DOM/replaced slot fallback (#4190). Hit testing ignores stacking/positioning. On recent nightlies (#4371: reported on 11500, not 1.0.1; not bisected, block boxes start at the parent's left edge since #4342, 11478) an empty following block can cover an absolutely positioned sibling's overflow, and isObscured then reports true. CLICK_JS never hit-tests, so clicks are unaffected.
- **Styles/text:** checkVisibility uses active stylesheets and UA rules, including hidden inputs, closed details and popovers. getComputedStyle does not resolve arbitrary cascade properties; do not replace native visibility with a JS cascade walk. Position/offsetParent obey stylesheet position (#4142). Screenshots are text-layout PNGs, not visual-regression output; printToPDF remains fake.
- **Scrolling:** positions exist and rects follow window scroll, but element/window scrolling and alignment do not model a real layout. Keep scroll_to/scroll_by no-ops and the scroll skip. Short pages clamp at zero, so scrolling to the bottom may emit no event.
- **Pointer focus:** untrusted mousedown does not focus; CLICK_JS must focus the enabled target (labels resolve to controls, contenteditable to the editing host), or blur when appropriate. A non-focusable send_keys target must blur the previous field.
- **Text caret:** Input.insertText inserts at the caret; SEND_KEYS_FOCUS_JS moves it to the end only for a newly focused field. Preserve an already-focused caret. Ctrl/Meta chords omit text to avoid inserting stray characters; use keyDown, not rawKeyDown.
- **Keyboard:** trusted Enter/Space can activate controls; cancelled keypress suppresses Enter submit. Backspace/Delete emit beforeinput/input; blur/Enter commits change. Keys within frames target the frame's active field. JS-written values do not satisfy user-edited tooShort/tooLong validation. Selecting a disabled option is legal in native IDL, so SELECT_OPTION_JS must reject it.
- **Contenteditable:** native getter correct from #4210 (11229, in the floor), but keep the helper: SVG elements have no getter and pointerFocusTarget needs each element's own state. `predicates.js#contentEditableState` mirrors upstream `Element.contentEditableState`: HTML elements only, invalid values inherit, then `document.designMode` decides (its body is the editing host, #4285/#4286, 11345/11347). On 1.0.3 the native getter matches the helper for every HTML value and designMode; on SVG it is `undefined`, the helper `false` (verified 2026-11-05). Trusted text insertion needs #4182 (11101), Backspace/Delete and Ctrl+A in an editing host #4415 (11610); from #4438 (11682) Enter inserts a paragraph and Shift+Enter a line break through cancellable beforeinput (below it Enter did not edit a host). From #4538 (11966) `focus()` collapses the caret at the host's first position unless the selection is already inside, and `beforeinput` carries `getTargetRanges()`; text typed without a selection already landed there, so send_keys output is unchanged. Node#set still writes innerHTML.
- **Errors:** page_errors stays separate from console_logs. Runtime.exceptionThrown is absent when page error is cancelled, for handled same-tick rejections and for driver Runtime failures. No stackTrace; line/column are zero-based; rejections have 0/0 and no URL. Console object arguments have descriptions but no value; keep primitive sentinels and console_arg_text fallback.
- **Network:** redirects repeat requestId with redirectResponse and no intermediate responseReceived. Close each previous hop and resolve responses onto the last open entry, or idle waits strand pending traffic. Cross-origin hops drop Authorization; response names are lowercase. Worker fetches count in page traffic.
- **Headers/CORS:** fixed Sec-Ch-Ua outranks CLI, then CDP, script and defaults. Mozilla-containing UA overrides are rejected. CORS is on by default; keep it. Blocked requests emit loadingFailed/CorsBlocked without a response; the traffic entry must close. From #4242 (11663) fetch/XHR hide cross-origin response headers not listed in Access-Control-Expose-Headers. Preflight cache survives context reset.
- **Cookies:** insecure SameSite=None is refused with success:false; invalid names/values raise -32602. Unspecified SameSite is Lax and omitted from output; legacy stores may need None stripped from insecure cookies. Domain without a leading dot is host-only; HTTPS URL forces Secure. deleteCookies ignores partitionKey. From #4442 (11688) a cross-site subrequest's response can only set SameSite=None cookies; Lax/Strict need a same-site request or a top-level navigation (Chrome parity).
- **Reset/teardown:** dispose the context before clearing Network enabled state; replies route by command id, not sessionId. Keep quit_all's socket close before SIGTERM and TERM→3s→KILL escalation for crash/GC paths. A readiness fallback and navigation-crash recovery remain useful even after upstream issue closure.
- **Files/downloads:** upload/drop paths read files on the browser host via DOM.setFileInputFiles. Downloads retain browser-level events and on-disk tracking. Native anchor download (#4124, 11097) is in the floor: CLICK_JS skips its own navigation for a `download` link, since navigating again cancels the download. MIME-only navigation still does not download.
- **Drag:** hidden upload input belongs in the dropzone's document; fire dragenter→dragover→drop. HTML5 drag_to ends with drop OR dragleave, never both; coordinate drag_by/non-HTML5 fallback remains unsupported. Input.dispatchDragEvent (#4228, 11246) does not yet support files/native dragstart and does not replace this path.

## Floor behavior that surprises Chrome-trained readers

- `showModal()` on an already-modal dialog is a no-op (no InvalidStateError) and `close` is queued (#4164).
- `navigator.sendBeacon` sends nothing: the gem enables no `beacon` resource loading (#4144).
- An unsized iframe is 300×150 and is its own viewport (#4344), so isObscured reports content below 150px as obscured, as Chrome does.
- Runtime.exceptionThrown lines are document-relative for parser-inserted inline scripts (#4340); dynamic, document.write and `sourceURL` scripts stay script-relative.

## Nightly-only behavior (above 11647)

Published (≤12013; 1.0.4-rc1 carries all of it):

- `postMessage` honors `targetOrigin` (#4382, 11676; an opaque origin may still post to itself, #4466, 11704): a mismatched target drops the message, as Chrome does.
- Custom elements: `createElement`/`createElementNS` run CE reactions (#4459, 11702) and `:defined` follows the element's upgrade state (#4448, 11715). Turbo/Stimulus elements ride this path; recheck on the next real-apps run.
- Multi-target CDP (#3945, 11844); see "CDP commands used by the gem".
- Disposing a context resets its viewport override (#4191, 11853); `create_page` resends the viewport anyway.
- innerText follows CSS `white-space: pre|pre-wrap|break-spaces` (#4510, 11912) and breaks lines between table row groups (#4509, 11897), so `visible_text` changes for styled code blocks and `<thead>`/`<tbody>` tables (Chrome parity).
- `history.pushState(undefined, '')` stores no state instead of the string `"undefined"`, and a non-cloneable state throws DataCloneError (#4499, 11887).
- In-page WebSocket reassembles fragmented messages (#4492, 11847) and fails a handshake whose server subprotocol wasn't offered (#4462, 11793).
- `ClipboardEvent` exists (#4527, 11923).
- CSS animation events (#4496, 11948: trusted, bubbling `animationstart`/`animationend`/`animationcancel` after delay + duration × iterations, never for `infinite`) are opt-in from #4559 (11991) behind `--experimental-features animation`, for load cost. The gem doesn't pass it, so pages waiting on `animationend` stall as on the floor; `LIGHTPANDA_EXTRA_ARGS="--experimental-features animation"` opts a suite in. Only 11948–11990 fired them by default.
- Trusted mouse events stop at the first disabled form control in the path (#4507, 11930). CLICK_JS dispatches untrusted events, so it is unaffected.
- `import()` of an already-available module settles in a later task, after an earlier `setTimeout(fn, 0)` (#4531, 11969), as in Chrome.

Main only (12014–12019):

- `elementFromPoint` and trusted mouse input skip `inert` subtrees (#4548, 12019), so isObscured stops reporting an inert overlay as covering what is beneath it (Chrome parity).

## Upstream open issues that affect this gem

| Issue | Impact | Description |
|---|---|---|
| #4263 | Hit testing | Fixed inset overlays retain synthetic bounds; fixes #4264/#4293 closed unmerged, maintainer wants the design settled in issues. |
| #4371 | Hit testing | Nightly regression: an empty block after a positioned element spans the viewport and wins elementFromPoint (1.0.1 OK). |
| #4298 | Text | innerText line breaks follow the tag, not computed display, so visible_text newlines can differ from Chrome. |
| #4251 | Keyboard | Ctrl deletion/arrows do not perform word editing. |
| (wishlist A63) | Drag | scrollIntoView ignores alignment options; HTML5_DRAG_JS centers manually to avoid pushing neighbours offscreen. |

## CLI details that affect the gem

- Canonical flags are kebab-case, but snake_case aliases still parse; the gem's log_level remains valid.
- --cdp-max-message-size is an inbound WS byte cap (browser default 1 MiB, gem 100 MiB).
- --http-header outranks CDP extra headers; --ca-cert/--ca-path replace the system trust store.
- --storage-engine sqlite backs IndexedDB, not localStorage/sessionStorage. Web Storage is session-local.
- LIGHTPANDA_DISABLE_TELEMETRY=true disables telemetry. Other optional flags belong in upstream CLI help, not this reference.
