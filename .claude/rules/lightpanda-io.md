# Lightpanda Browser Reference

Upstream: https://github.com/lightpanda-io/browser (AGPL-3.0). Source audit verified 2026-10-29 at `8f2c8185c97e3cc98de07f164e7eb3d9e2dd9020` (build 11280).

## Version and transport constraints

- Floors: `Process::MINIMUM_NIGHTLY_BUILD = 10965`, `MINIMUM_RELEASE = 1.0.2`, the same commit. `process.rb` owns the floor rationale. Release binaries have no `nightly_build`; only gate behavior above the floor and remove gates when raising it.
- A release prints bare semver; a nightly includes `git rev-list --count` and a hash. Keep both floors aligned. Only releases are reproducible pins: the rolling nightly tag is overwritten.
- Four binary targets: `{aarch64,x86_64}-{linux,macos}`. Keep all four in `Binary::PLATFORMS`; two-entry maps broke Intel Macs and Graviton runners. Latest release checked: 1.0.2 (2026-10-23).
- Zig 0.17 + V8, html5ever, libcurl and CSSOM; geometry and screenshots remain approximate, without a full layout/paint engine.
- WebSocket upgrade rejects `Origin` unless `--remote-allow-origins` permits it. `Host` accepts IP literals, exact lowercase `localhost:<port>`, or explicit `--advertise-host`; bare/uppercase localhost and suffix attacks fail. Spawned clients use the logged address and send no Origin.

## CDP commands used by the gem

All **32 distinct literal commands** below are admitted by the dispatch enums both at the audited SHA and at release `1.0.2`; the current handlers/routes were inspected. Call sites are under `lib/capybara/lightpanda/`; internal command/page_command wrappers were inspected, including multiline calls. Runtime's enum admits evaluate/callFunctionOn/getProperties/releaseObject and forwards them through `sendInspector` → `BrowserContext.callInspector` → V8, rather than separate Zig handlers.

| Domain | Commands |
|---|---|
| Browser | `setDownloadBehavior` |
| DOM | `describeNode`, `setFileInputFiles` |
| Emulation | `setDeviceMetricsOverride` |
| Input | `dispatchKeyEvent`, `insertText` |
| LP | `configureLoading`, `getMarkdown`, `handleJavaScriptDialog`, `version` |
| Network | `clearBrowserCookies`, `deleteCookies`, `disable`, `enable`, `getAllCookies`, `setCookie`, `setExtraHTTPHeaders` |
| Page | `addScriptToEvaluateOnNewDocument`, `captureScreenshot`, `enable`, `getLayoutMetrics`, `navigate`, `reload` |
| Runtime | `callFunctionOn`, `enable`, `evaluate`, `getProperties`, `releaseObject` |
| Target | `attachToTarget`, `createBrowserContext`, `createTarget`, `disposeBrowserContext` |

`LP.getMarkdown` is used by `driver.rb#markdown`. Caller-controlled `command`, `page_command` and `execute_cdp` accept arbitrary names; these escape hatches are not a finite inventory. The `Network.setBlockedURLs` string in selenium_compat.rb is a documentation example, not a built-in call.

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
Page.createIsolatedWorld     Page.getFrameTree
Page.getNavigationHistory    Page.navigateToHistoryEntry (same-document traversal fixed by #3903, 11113; below it reloads — keep history.back() until the floor covers it)
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
Network.setCookies (batch)   Network.getResponseBody     Network.setBlockedURLs
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

- **Navigation:** `Page.loadEventFired` can be absent; keep `go_to`'s readyState polling. A refused/DNS/TLS root navigation commits an error document at the failed URL; cancelled navigation keeps the old document. Click waits must follow main-frame navigation start and document readiness, not just context clearing or Turbo idle.
- **History:** same-document `Page.navigateToHistoryEntry` was fixed by #3903 (11113), above the floor; keep history.back/forward until covered and validated. Read URLs from location rather than tracking them from frame events.
- **Frames:** `callFunctionOn` executes in the top context even with an iframe node as `this`; use `this.ownerDocument/defaultView`. Frame scripts compile through the frame's own eval while accepting top-context handles. #4192's listener-world fix does not establish that this constraint changed or resolve issue #3833.
- **Node handles:** old-document `this` can raise NoExecutionContextError; old nodes passed as arguments can raise a cross-world error mapped to NodeNotFoundError. Only actual nodes have subtype node; ordinary objects serialize by value and cyclic values can be refused.
- **Modals:** form method=dialog closes the ancestor dialog without navigation; a closed dialog subtree is invisible, which the Spree/Turbo confirm flow depends on. Use LP.handleJavaScriptDialog before the action. Page.handleJavaScriptDialog deliberately errors. One pre-arm slot is consumed once; do not raise from the event-dispatch thread.
- **Resources:** CLI resource loading defaults off. Process passes `--load-resources stylesheet` (+ image when requested); create_page sends LP.configureLoading with subFrame/worker true. Keep iframe/worker configuration on the existing per-context CDP path; the frame-loading/build-args tests prevent CLI/CDP drift.
- **External CSS:** loaded synchronously into the cascade; oversized sheets are dropped whole (2 MiB below #3889/10375, 4 MiB above). A large development sheet can expose normally hidden menus.
- **Viewport:** Emulation changes innerWidth/Height, matchMedia and layout metrics; rects remain approximate. Resizing fires MediaQueryList changes, but stylesheet @media cascade was only re-resolved after navigation in the verified viewport tests. Default 1920×1080 mirrors the browser; changing it shifts existing media branches.
- **Hit testing:** retain owning-frame and outer-to-inner shadow checks. ShadowRoot hit testing needs #4184 (11071); 1.0.2 uses the host fallback. Native shadow visibility excludes unslotted light DOM/replaced slot fallback above #4190 (11082).
- **Styles/text:** checkVisibility uses active stylesheets and UA rules, including hidden inputs, closed details and popovers. getComputedStyle does not resolve arbitrary cascade properties; do not replace native visibility with a JS cascade walk. Position/offsetParent obey stylesheet position only above #4142 (11006). Screenshots are text-layout PNGs, not visual-regression output; printToPDF remains fake.
- **Scrolling:** positions exist and rects follow window scroll, but element/window scrolling and alignment do not model a real layout. Keep scroll_to/scroll_by no-ops and the scroll skip. Short pages clamp at zero, so scrolling to the bottom may emit no event.
- **Pointer focus:** untrusted mousedown does not focus; CLICK_JS must focus the enabled target (labels resolve to controls, contenteditable to the editing host), or blur when appropriate. A non-focusable send_keys target must blur the previous field.
- **Text caret:** Input.insertText inserts at the caret; SEND_KEYS_FOCUS_JS moves it to the end only for a newly focused field. Preserve an already-focused caret. Ctrl/Meta chords omit text to avoid inserting stray characters; use keyDown, not rawKeyDown.
- **Keyboard:** trusted Enter/Space can activate controls; cancelled keypress suppresses Enter submit. Backspace/Delete emit beforeinput/input; blur/Enter commits change. Keys within frames target the frame's active field. JS-written values do not satisfy user-edited tooShort/tooLong validation. Selecting a disabled option is legal in native IDL, so SELECT_OPTION_JS must reject it.
- **Contenteditable:** native getter fixed by #4210 (11229), above the floor; keep the helper for older binaries. Invalid values inherit and SVG attributes do not enable editing upstream, but our helper accepts any non-false attribute: investigate these cases. Trusted text insertion needs #4182 (11101); Node#set still writes innerHTML.
- **Errors:** page_errors stays separate from console_logs. Runtime.exceptionThrown is absent when page error is cancelled, for handled same-tick rejections and for driver Runtime failures. No stackTrace; line/column are zero-based; rejections have 0/0 and no URL. Console object arguments have descriptions but no value; keep primitive sentinels and console_arg_text fallback.
- **Network:** redirects repeat requestId with redirectResponse and no intermediate responseReceived. Close each previous hop and resolve responses onto the last open entry, or idle waits strand pending traffic. Cross-origin hops drop Authorization; response names are lowercase. Worker fetches count in page traffic.
- **Headers/CORS:** fixed Sec-Ch-Ua outranks CLI, then CDP, script and defaults. Mozilla-containing UA overrides are rejected. CORS is on by default; keep it. Blocked requests emit loadingFailed/CorsBlocked without a response; the traffic entry must close. Preflight cache survives context reset.
- **Cookies:** insecure SameSite=None is refused with success:false; invalid names/values raise -32602. Unspecified SameSite is Lax and omitted from output; legacy stores may need None stripped from insecure cookies. Domain without a leading dot is host-only; HTTPS URL forces Secure. deleteCookies ignores partitionKey.
- **Reset/teardown:** dispose the context before clearing Network enabled state; replies route by command id, not sessionId. Keep quit_all's socket close before SIGTERM and TERM→3s→KILL escalation for crash/GC paths. A readiness fallback and navigation-crash recovery remain useful even after upstream issue closure.
- **Files/downloads:** upload/drop paths read files on the browser host via DOM.setFileInputFiles. Downloads retain browser-level events and on-disk tracking. Native anchor download (#4124, 11097) requires skipping manual navigation at the existing version gate; older builds need attachment navigation. MIME-only navigation still does not download.
- **Drag:** hidden upload input belongs in the dropzone's document; fire dragenter→dragover→drop. HTML5 drag_to ends with drop OR dragleave, never both; coordinate drag_by/non-HTML5 fallback remains unsupported. Input.dispatchDragEvent (#4228, 11246) does not yet support files/native dragstart and does not replace this path.

## Above-floor behavior to keep distinct from 1.0.2

- CSS nesting: #3962 (10976); nested display:none is lost below it.
- Initial about:blank timers: #4148 (11012); awaiting a timer before visit hangs below it.
- Dialog conformance: #4164 (11050); showModal on an already-modal dialog is a no-op and close is queued. Do not expect the old InvalidStateError.
- Cookie eviction: #4138 (11017); Chrome-style limits replace the old 1024-cookie failure. Non-loopback HTTP cannot overwrite Secure cookies above #4125 (10973).
- stepMismatch validation: #4157 (11032). sendBeacon only sends when beacon resources are enabled (#4144, 11020).
- onmouseenter/onmouseleave handlers: #4248 (11237); dispatching mouseenter alone did not make property/attribute handlers run on older browsers.

## Upstream open issues that affect this gem

| Issue | Impact | Description |
|---|---|---|
| #4263 | Hit testing | Fixed inset overlays retain synthetic bounds; #4264 is open. |
| #4251 | Keyboard | Ctrl deletion/arrows do not perform word editing. |
| #3852 | Binary | Release 1.0.0/1.0.1 aarch64-linux needs glibc 2.38, excluding Debian 12/Ubuntu 22.04 arm64. |
| (wishlist A63) | Drag | scrollIntoView ignores alignment options; HTML5_DRAG_JS centers manually to avoid pushing neighbours offscreen. |

## CLI details that affect the gem

- Canonical flags are kebab-case, but snake_case aliases still parse; the gem's log_level remains valid.
- --cdp-max-message-size is an inbound WS byte cap (browser default 1 MiB, gem 100 MiB).
- --http-header outranks CDP extra headers; --ca-cert/--ca-path replace the system trust store.
- --storage-engine sqlite backs IndexedDB, not localStorage/sessionStorage. Web Storage is session-local.
- LIGHTPANDA_DISABLE_TELEMETRY=true disables telemetry. Other optional flags belong in upstream CLI help, not this reference.
