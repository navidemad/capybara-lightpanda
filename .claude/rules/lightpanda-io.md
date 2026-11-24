# Lightpanda Browser Reference

Upstream: https://github.com/lightpanda-io/browser (AGPL-3.0). Source audit verified 2026-11-24 at `a6efe7f89` (build 12425). The published nightly is 12421 (`8bc75b49b`, 2026-11-24); main moved to `1.1.0-dev`, so nightlies print `1.1.0-nightly.<count>+<hash>`, which `Process.check_version!` already parses. Latest release 1.0.5 (2026-11-20) is 12297 (`8f220d5b4`, the 1.0.5-rc2 commit), and `Binary::DEFAULT_VERSION` pins it (#304).

## Version and transport constraints

- Floors: `Process::MINIMUM_NIGHTLY_BUILD = 12015`, `MINIMUM_RELEASE = 1.0.4`, the same commit (raised 2026-11-16; suites green on the 1.0.4 aarch64-macos binary). `process.rb` owns the floor rationale. Release binaries have no `nightly_build`; only gate behavior above the floor and remove gates when raising it.
- A release prints bare semver; a nightly includes `git rev-list --count` and a hash. Keep both floors aligned. Only releases are reproducible pins: the rolling nightly tag is overwritten. A release candidate (#4480) prints `<semver>-rcN.<count>+<hash>` (`build.zig#resolveVersion`); `Process::RC_VERSION` checks its counter against the nightly floor, so an RC takes the nightly-gated paths (format derived from source, no RC binary run).
- Four binary targets: `{aarch64,x86_64}-{linux,macos}`. Keep all four in `Binary::PLATFORMS`; two-entry maps broke Intel Macs and Graviton runners. Release aarch64-linux binaries need glibc 2.38, x86_64 2.35, so Debian 12/Ubuntu 22.04 arm64 can't run them (#3852, documented in #4333, not rebuilt). 1.0.4 is the first release whose x86_64-macos binary doesn't SIGILL on CPUs without ADX (#4450).
- Zig 0.17 + V8, html5ever, libcurl and CSSOM; geometry and screenshots remain approximate, without a full layout/paint engine.
- WebSocket upgrade rejects `Origin` unless `--remote-allow-origins` permits it. `Host` accepts IP literals, exact lowercase `localhost:<port>`, or explicit `--advertise-host`; bare/uppercase localhost and suffix attacks fail. Spawned clients use the logged address and send no Origin. From #4553 (11986) the same Host check guards every HTTP route (`/json/*`), not only upgrades.

## CDP commands used by the gem

All **36 distinct literal commands** below are admitted by the dispatch enums at 1.0.5 (12297) and at the audited SHA (12425), and the 14 Zig-emitted events below are still emitted there. Call sites are under `lib/capybara/lightpanda/`, including multiline command/page_command calls and the `execute_cdp` calls of `selenium_compat.rb`'s document-scoped cookie helpers (`Network.getCookies`/`setCookies`). Runtime's evaluate/callFunctionOn/getProperties/releaseObject go through `sendInspector` → `Target.callInspector` → V8, not separate Zig handlers.

**Multi-target CDP (#3945, 11844, in the floor):** per-page state moved from BrowserContext to a `Target` (up to 16 per context; `disposeBrowserContext` closes them all). A command reaches the target of its session; each target is its own inspector context group. Source-checked against the gem's single-target model: `target_id` still equals the root frame id (`target.zig` sets it from `id.toFrameId`), which `browser.rb#subscribe_to_navigation` relies on; console messages and exceptions now carry the frame they ran in (iframe `executionContextId`), and the gem reads neither.

| Domain | Commands |
|---|---|
| Browser | `setDownloadBehavior` |
| DOM | `describeNode`, `setFileInputFiles` |
| Emulation | `setDeviceMetricsOverride`, `setUserAgentOverride` |
| Input | `dispatchKeyEvent`, `insertText` |
| LP | `configureLoading`, `handleJavaScriptDialog`, `version` |
| Network | `clearBrowserCache`, `clearBrowserCookies`, `deleteCookies`, `disable`, `enable`, `getAllCookies`, `getCookies`, `setCookie`, `setCookies`, `setExtraHTTPHeaders` |
| Page | `addScriptToEvaluateOnNewDocument`, `captureScreenshot`, `enable`, `getLayoutMetrics`, `navigate`, `reload`, `setLifecycleEventsEnabled` |
| Runtime | `callFunctionOn`, `enable`, `evaluate`, `getProperties`, `releaseObject` |
| Target | `attachToTarget`, `createBrowserContext`, `createTarget`, `disposeBrowserContext` |

Caller-controlled `command`, `page_command` and `execute_cdp` accept arbitrary names; these escape hatches are not a finite inventory. The opt-in Cuprite page's `cuprite_page.rb#command` forwards one of them, `Emulation.setTimezoneOverride`, then checks `Intl`'s zone and raises `NotSupportedByDriverError` when the browser ignored it: every release up to 1.0.5. `process.rb#build_args` passes `--cdp-allow-timezone-override` (see Emulation stubs) to a nightly/RC from 12374 only. The `LP.getMarkdown` (driver.rb) and `Network.setBlockedURLs` (selenium_compat.rb) strings are doc-comment examples, not built-in calls.

### Subscribed events (15 distinct names)

```
Browser.downloadProgress Browser.downloadWillBegin
Network.loadingFailed Network.loadingFinished Network.requestWillBeSent Network.responseReceived
Page.frameStartedNavigating Page.frameStoppedLoading Page.javascriptDialogOpening Page.lifecycleEvent Page.navigatedWithinDocument
Runtime.consoleAPICalled Runtime.exceptionThrown Runtime.executionContextCreated Runtime.executionContextsCleared
```

Emission sites: `domains/browser.zig` (downloads), `network.zig` (requests/responses/finishes/failures), `page.zig` (navigation incl. same-document/dialogs/context clearing), `runtime.zig` (console/exceptions). `Runtime.executionContextCreated` comes from V8's inspector via `Inspector.contextCreated`; a missing literal emitter in Zig is not missing support. Presence is a source check, not a guarantee of event timing: keep the readyState fallback.

### Available CDP methods (not yet used by this gem)

```
Page.setDocumentContent (#4304, 11433)                    Performance.getMetrics (#4305, 11426)
CSS.getComputedStyleForNode (#4377, 11626)
LP.waitUntil {until: load|domcontentloaded|networkalmostidle|networkidle|settled|done, timeout} (#4422, 11698; main frame only, also emits a `settled` Page.lifecycleEvent; `settled` ignores intervals, timers >100 ms and IntersectionObserver work)
Page.createIsolatedWorld     Page.getFrameTree
Page.getNavigationHistory    Page.navigateToHistoryEntry (same-document traversal fixed by #3903, 11113, in the floor; Browser#back keeps history.back())
Page.removeScriptToEvaluateOnNewDocument
DOM.querySelector            DOM.querySelectorAll (finds go through JS in Runtime.callFunctionOn)
Page.stopLoading (stub)    Page.close
Page.printToPDF (fake PDF)
DOM.getDocument              DOM.resolveNode
DOM.getBoxModel (real getBoundingClientRect geometry; Chrome's error under display:none from #4684, 12280)
DOM.scrollIntoViewIfNeeded
DOM.performSearch            DOM.getSearchResults        DOM.discardSearchResults
DOM.getContentQuads          DOM.requestChildNodes
DOM.getFrameOwner            DOM.getOuterHTML            DOM.requestNode
Input.dispatchMouseEvent     Input.dispatchTouchEvent
Input.setInterceptDrags      Input.dispatchDragEvent (#4228, 11246; external text drag only, no files or native dragstart)
Page.frameDetached (event, removed iframes)
Network.setBlockedURLs (`urlPatterns: [{urlPattern, block}]` only, no legacy `urls`; sets the browser-wide HttpClient list, which disposeBrowserContext does not clear)
LP.getMarkdown               LP.configureLoading {beacon} (#4504, 11869)
LP.dump {format, withFrames} (withFrames #4657, 12166: html only, inlines each iframe's document, nested ones too)
Network.getResponseBody      Network.setCacheDisabled     Network.canClearBrowserCache
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

- **Navigation:** `Page.loadEventFired` can be absent; keep `go_to`'s readyState polling. It and `Page.domContentEventFired` carry no frameId and fire for every frame (`frameLoaded`/`frameDOMContentLoaded` in page.zig, 1.0.3 and later), so an iframe that loads first reads as the page: wait on the main frame's `Page.frameStoppedLoading` or `Page.lifecycleEvent` (frameId == target id) instead. A refused/DNS/TLS root navigation commits an error document at the failed URL; from #4430 (11651) a Fetch bad-list port (1, 22, 25, 6000…) fails the same way with `net::ERR_UNSAFE_PORT`, before any connection; cancelled navigation keeps the old document. Click waits must follow main-frame navigation start and document readiness, not just context clearing or Turbo idle. readyState turns `interactive` when the parser ends, before deferred and module scripts run (#4554; DOMContentLoaded still waits for them), as in Chrome. So `interactive` no longer means the page's JS ran: `wait_for_document_ready` requires `complete`, and `browser/navigation.rb#page_ready?` (go_to's fallback after 2 s without `loadEventFired`) accepts `interactive` only once the navigation timing entry shows DOMContentLoaded (`visit_readiness_test.rb`).
- **History:** same-document `Page.navigateToHistoryEntry` is fixed in the floor (#3903, 11113); history.back/forward works and stays unless a switch is validated. Read URLs from location rather than tracking them from frame events.
- **Frames:** `callFunctionOn` executes in the top context even with an iframe node as `this`; use `this.ownerDocument/defaultView`. Frame scripts compile through the frame's own eval while accepting top-context handles. #4192's listener-world fix does not establish that this constraint changed or resolve issue #3833.
- **Node handles:** old-document `this` can raise NoExecutionContextError; old nodes passed as arguments can raise a cross-world error mapped to NodeNotFoundError. Only actual nodes have subtype node; ordinary objects serialize by value and cyclic values can be refused.
- **Modals:** form method=dialog closes the ancestor dialog without navigation; a closed dialog subtree is invisible, which the Spree/Turbo confirm flow depends on. Use LP.handleJavaScriptDialog before the action. Page.handleJavaScriptDialog deliberately errors. One pre-arm slot is consumed once; do not raise from the event-dispatch thread.
- **Resources:** CLI resource loading defaults off. Process passes `--load-resources stylesheet` (+ image when requested); create_page sends LP.configureLoading with subFrame/worker true. Keep iframe/worker configuration on the existing per-context CDP path; the frame-loading/build-args tests prevent CLI/CDP drift. `subFrame: false` is not a cheap middle ground: from #4515 (11917) such an iframe gets an about:blank window whose HTTP and WebSocket requests are all refused.
- **External CSS:** loaded synchronously into the cascade; a sheet over 4 MiB is dropped whole. A large development sheet can expose normally hidden menus.
- **Viewport:** Emulation changes innerWidth/Height, matchMedia and layout metrics; rects remain approximate. Resizing fires MediaQueryList changes, but stylesheet @media cascade was only re-resolved after navigation in the verified viewport tests. Default 1920×1080 mirrors the browser; changing it shifts existing media branches.
- **Hit testing:** retain owning-frame and outer-to-inner shadow checks. ShadowRoot hit testing (#4184, 11071) is in the floor; predicates.js still feature-detects it. Native shadow visibility excludes unslotted light DOM/replaced slot fallback (#4190). On 1.0.4 hit testing ignores stacking/positioning (layered from 12260, see below). In the floor (#4371, not in 1.0.1; block boxes start at the parent's left edge since #4342, 11478) an empty following block can cover an absolutely positioned sibling's overflow, and isObscured then reports true. CLICK_JS never hit-tests, so clicks are unaffected.
- **Styles/text:** checkVisibility uses active stylesheets and UA rules, including hidden inputs, closed details and popovers. getComputedStyle does not resolve arbitrary cascade properties; do not replace native visibility with a JS cascade walk. Position/offsetParent obey stylesheet position (#4142). Screenshots are text-layout PNGs up to 1.0.5; from 12387 (#4734) `Page.captureScreenshot` and `Page.getLayoutMetrics` draw from the layout engine (PDF stays reader-mode). Neither is visual-regression output; printToPDF remains fake. Cascade gaps on 1.0.4 (verified 2026-11-18): rules inside `@supports` are dropped (applied from 12324, #4708), a `var()` value is not resolved (`display: var(--d)` does not hide, `text-transform: var(--tt)` does not apply), and `text-transform: capitalize` and `::first-letter` leave innerText as written (uppercase/lowercase apply), so `text` casing can differ from Chrome.
- **Emulation stubs:** `Emulation.setTimezoneOverride` answers `{}` and does nothing up to 1.0.5. From 12374 (our #4701; first published in nightly 12421) it moves the target's `Date`/`Intl` zone, an empty id or the context's disposal restores the process zone, and an unknown id answers -32602, but only under `serve --cdp-allow-timezone-override` (off by default: ICU's zone is process-wide); without the flag it is still ignored, with a warning. An older binary exits on the unknown flag, so `process.rb#runtime_timezone_override?` gates it on the build counter (no release yet). The `timezone` option sets `TZ` on the spawned process instead (per process). `Emulation.setUserAgentOverride` answers `{}` even when it refuses a `Mozilla` value; a Mozilla-less value moves the header and `navigator.userAgent` until the context is disposed, and `Network#user_agent=` raises on a refused one (verified 2026-11-18 on 1.0.4, `emulation_test.rb`).
- **Scrolling:** positions exist and rects follow window scroll, but element/window scrolling and alignment do not model a real layout. Keep scroll_to/scroll_by no-ops and the scroll skip. Short pages clamp at zero, so scrolling to the bottom may emit no event.
- **Pointer focus:** untrusted mousedown does not focus; CLICK_JS must focus the enabled target (labels resolve to controls, contenteditable to the editing host), or blur when appropriate. A non-focusable send_keys target must blur the previous field.
- **Typing:** a US-layout character goes out as keyDown (with `text`) + keyUp so keydown/keypress/keyup fire; Lightpanda inserts the keyDown's text itself. Other characters and newlines stay on Input.insertText (`input` only; a newline keyDown would be Enter). Keys follow the chain of focused `<iframe>` elements (`user_input.zig#focusedFrame`): `focus()` on a `<body>` editing host does not focus its iframe, so SEND_KEYS_FOCUS_JS focuses each owning iframe itself (`key_listeners_test.rb`).
- **Text caret:** Input.insertText inserts at the caret; SEND_KEYS_FOCUS_JS moves it to the end only for a newly focused field. Preserve an already-focused caret. Ctrl/Meta chords omit text to avoid inserting stray characters; use keyDown, not rawKeyDown.
- **Keyboard:** trusted Enter/Space can activate controls; cancelled keypress suppresses Enter submit. Backspace/Delete emit beforeinput/input; blur/Enter commits change. Keys within frames target the frame's active field. JS-written values do not satisfy user-edited tooShort/tooLong validation. Selecting a disabled option is legal in native IDL, so SELECT_OPTION_JS must reject it.
- **Contenteditable:** keep `predicates.js#contentEditableState` although the native getter is correct (#4210): SVG elements have none (`undefined`, the helper `false`) and pointerFocusTarget needs each element's own state. It mirrors upstream `Element.contentEditableState`: HTML elements only, invalid values inherit, then `document.designMode` decides (its body is the editing host, #4285/#4286). An editing host takes trusted text (#4182), Backspace/Delete and Ctrl+A (#4415), and Enter as a paragraph, Shift+Enter as a line break, through cancellable beforeinput (#4438). `focus()` collapses the caret at the host's first position unless the selection is already inside (#4538), where text typed without a selection always landed, so send_keys output is unchanged. Node#set still writes innerHTML.
- **Errors:** page_errors stays separate from console_logs. `consoleAPICalled`/`exceptionThrown` `timestamp` is whole seconds since the host booted, not Chrome's epoch ms (verified 2026-11-18 on 1.0.4), so both buffers also record `received_at` (wall-clock epoch ms), which Selenium `LogEntry` uses. Runtime.exceptionThrown is absent when page error is cancelled, for handled same-tick rejections and for driver Runtime failures. No stackTrace; line/column are zero-based; rejections have 0/0 and no URL. Console object arguments have descriptions but no value; keep primitive sentinels and console_arg_text fallback.
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
- `postMessage` honors `targetOrigin` (#4382, 11676; an opaque origin may still post to itself, #4466, 11704): a mismatched target drops the message, as Chrome does.
- Custom elements: `createElement`/`createElementNS` run CE reactions (#4459, 11702) and `:defined` follows the element's upgrade state (#4448, 11715). Turbo/Stimulus elements ride this path.
- innerText follows CSS `white-space: pre|pre-wrap|break-spaces` (#4510, 11912) and breaks lines between table row groups (#4509, 11897), so `visible_text` changes for styled code blocks and `<thead>`/`<tbody>` tables (Chrome parity).
- `history.pushState(undefined, '')` stores no state instead of the string `"undefined"`, and a non-cloneable state throws DataCloneError (#4499, 11887).
- In-page WebSocket reassembles fragmented messages (#4492, 11847) and fails a handshake whose server subprotocol wasn't offered (#4462, 11793).
- `ClipboardEvent` exists (#4527, 11923).
- CSS animation events (#4496, 11948: trusted, bubbling `animationstart`/`animationend`/`animationcancel` after delay + duration × iterations, never for `infinite`) are opt-in from #4559 (11991) behind `--experimental-features animation`, for load cost. The gem doesn't pass it, so pages waiting on `animationend` stall; `LIGHTPANDA_EXTRA_ARGS="--experimental-features animation"` opts a suite in.
- Trusted mouse events stop at the first disabled form control in the path (#4507, 11930). CLICK_JS dispatches untrusted events, so it is unaffected.
- `import()` of an already-available module settles in a later task, after an earlier `setTimeout(fn, 0)` (#4531, 11969), as in Chrome.

## Behavior above the floor (12015)

In release 1.0.5 (12297, the pin) and the nightly, not in the 1.0.4 floor. Validated 2026-11-20 on the 1.0.5 aarch64-macos binary: `test:all` 810 runs and `spec:shared:parallel` green; the skip audit passed none of its 43 examples, so no skip pattern is obsolete.

- `elementFromPoint` and trusted mouse input skip `inert` subtrees (#4548, 12019), so isObscured stops reporting an inert overlay as covering what is beneath it (Chrome parity).
- `xhr.upload` dispatches `loadstart`/`progress`/`load`/`loadend` (or `error`/`abort`/`timeout`) (#4529, ours, 12116); below it a page waiting on upload progress never saw the upload finish.
- Style invalidation is selective (#4583, 12029, then #4610–#4641, extended to layout caches by #4651, 12226): an attribute write clears the style cache only when a stylesheet selector names that attribute, and DOM insertion/removal invalidates the parent's subtree unless `:has`/`:empty`/form pseudo-classes reach further. An `isVisible` that stays stale after a DOM mutation on a nightly but not on 1.0.4 is an upstream invalidation bug, not a predicate bug.
- Navigation API `NavigateEvent.intercept()` (#4243, 12199) keeps an intercepted cross-document navigation in the document: a same-document commit that emits only `Page.navigatedWithinDocument`, never `frameStartedNavigating`, so the click sniff sees no navigation, as for `pushState`.
- Layout rewrite (#4650, 12212; it supersedes the closed #4549/#4561): box tops follow block flow and `position: absolute/relative`, heights follow content (a text line is 20px; an empty block keeps a fallback height, #4679 open) instead of the 5px-per-element stack, and widths are text-aware. isObscured, `wait_for_stop_moving`, HTML5_DRAG_JS and `DOM.getBoxModel` see other rects than on 1.0.4.
- `display: grid` layout, and text wraps at the computed width rather than only an explicit one (#4673, 12238); `em`/`rem`/basic `calc()` lengths (#4692, 12263) and `min-height`/`max-height` (#4693, 12266). Rects shift again.
- Hit testing layers paint order (#4689, 12260): a positioned box and its subtree win over the normal flow even earlier in the tree, a negative `z-index` loses to it; other `z-index` values count as `auto`. Within a layer the last element in tree order still wins. It clears #4371's symptom: on the issue's page the empty `#out` block still overlaps `#knob` on 1.0.5, but `elementFromPoint` returns the knob and `#knob.obscured?` is false (true on 1.0.4; verified 2026-11-20).

Nightly only (12298–12421). Validated 2026-11-23 on nightly 12369 (aarch64-macos): `test:all` 810 runs and `spec:shared:parallel` green; the skip audit passed none of its 43 examples. Same on nightly 12421 (2026-11-24): `test:all` 813 runs and `spec:shared:parallel` green, skip audit 0/43.

- Rules inside `@supports` apply (#4708, ours, 12324); 1.0.5 still drops them.
- `navigator.clipboard.readText`/`writeText` exist (#4728, 12347), on a text buffer per CDP connection, never the system clipboard, kept across navigations. `writeText` succeeds unless `clipboard-write` is denied; `readText` rejects with NotAllowedError unless `Browser.grantPermissions` granted `clipboard-read`, which the gem never sends. Below it a copy button calling `writeText` threw.
- Layout adds padding and `box-sizing` (#4725/#4726, 12342–12344), sizes `html`/`body` from a declared height (#4724, 12354; `html`'s percentage is of the viewport), counts text between flex items as an item (#4735, 12358), moves boxes by `margin-left`/`margin-right` (`margin: 0 auto` centers, #4744, 12414) and separates flex items by `gap` (#4746, 12419). The root box now takes the viewport width instead of a hard-coded 1920 (#4746), so `window_size` moves layout as well as `innerWidth`. Rects shift again.
- `Emulation.setTimezoneOverride` works behind `--cdp-allow-timezone-override` (#4701, ours, 12374; see Emulation stubs). On nightly 12421 the gem passes the flag and `cuprite_contract.rb`'s per-test zone example takes the supported path (verified 2026-11-24).
- `Access-Control-Allow-Headers: *` also covers `Authorization` (#4729, 12377), as every browser does against the spec.

## Upstream open issues that affect this gem

| Issue | Impact | Description |
|---|---|---|
| #4263 | Hit testing | Fixed inset overlays retain synthetic bounds; fixes #4264/#4293 closed unmerged, maintainer wants the design settled in issues. |
| #4371 | Hit testing | Regression in the floor (1.0.1 OK): an empty block after a positioned element spans the viewport and wins elementFromPoint. Symptom cleared from 12260 by layered hit testing (#4689, verified on 1.0.5); still open, still hits the 1.0.4 floor. |
| #4298 | Text | innerText line breaks follow the tag, not computed display, so visible_text newlines can differ from Chrome. |
| #4251 | Keyboard | Ctrl deletion/arrows do not perform word editing. |
| (wishlist A63) | Drag | scrollIntoView ignores alignment options; HTML5_DRAG_JS centers manually to avoid pushing neighbours offscreen. |

## CLI details that affect the gem

- Canonical flags are kebab-case, but snake_case aliases still parse; the gem's log_level remains valid.
- --cdp-max-message-size is an inbound WS byte cap (browser default 1 MiB, gem 100 MiB).
- --http-header outranks CDP extra headers; --ca-cert/--ca-path replace the system trust store.
- --storage-engine sqlite backs IndexedDB, not localStorage/sessionStorage. Web Storage is session-local.
- LIGHTPANDA_DISABLE_TELEMETRY=true disables telemetry. Other optional flags belong in upstream CLI help, not this reference.
