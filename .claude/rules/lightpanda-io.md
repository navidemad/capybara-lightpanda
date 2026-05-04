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
| **LP** | lp.zig | Lightpanda-specific extensions; full enum: `getMarkdown`, `getSemanticTree`, `getInteractiveElements`, `getNodeDetails`, `getStructuredData`, `detectForms`, `clickNode`, `fillNode`, `scrollNode`, `waitForSelector`, `handleJavaScriptDialog` (PR #2261, merged 2026-04-29 — pre-arm dialog response, see Recently Merged below) |
| **Network** | network.zig | Cookies, request/response interception |
| **Page** | page.zig | Navigation, events, screenshots (1920x1080 PNG), reload (PR #1992), addScriptToEvaluateOnNewDocument (PR #1993), `handleJavaScriptDialog` exists but always errors with `-32000 No dialog is showing` and points clients at `LP.handleJavaScriptDialog` (commit 8cc82d1d, 2026-04-29), `javascriptDialogOpening` event emitted (commit 95f80c96 2026-04-03); NO history methods (PR #2289 OPEN) |
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
Page.addScriptToEvaluateOnNewDocument                    Page.getLayoutMetrics
Page.captureScreenshot       Page.javascriptDialogOpening (event)
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
LP.handleJavaScriptDialog    (planned — pre-arm modal responses; gem cleanup pending)
```

### CDP Methods NOT Available (gem uses JS workarounds)

```
Page.getNavigationHistory    → gem uses history.back()/history.forward() JS instead
                                (PR #2289 OPEN — when merged, switch to native CDP)
Page.navigateToHistoryEntry  → gem uses history.back()/history.forward() JS instead
                                (PR #2289 OPEN — when merged, switch to native CDP)
```

### CDP Methods Partially Implemented (event but no handler)

```
Page.handleJavaScriptDialog  → DISPATCH HANDLER EXISTS but DELIBERATELY ALWAYS ERRORS
                                with "-32000 No dialog is showing" (commit 8cc82d1d,
                                2026-04-29). Lightpanda-aware clients pre-arm the
                                accept/promptText response via LP.handleJavaScriptDialog
                                BEFORE the action that triggers the dialog (see Recently
                                Implemented below). The Page.javascriptDialogOpening
                                event is emitted (commit 95f80c96, 2026-04-03) and the
                                gem still captures the message text from there.
```

### CDP Methods Recently Implemented

```
Network.setUserAgentOverride   → IMPLEMENTED (PR #2139, merged ~2026-04-11)
Emulation.setUserAgentOverride → IMPLEMENTED (PR #2153, merged 2026-04-14)
Page.createIsolatedWorld       → NOW WORKING (PR #2164, merged 2026-04-16). Previously returned
                                  wrong executeContextId; fix pulls correct value from v8 inspector.
Network.getAllCookies          → IMPLEMENTED (PR #2255, merged 2026-04-27, in nightly ≥5817).
                                  Gem now calls this in Cookies#all.
Network.clearBrowserCookies    → ACCEPTS empty params (PR #2255, merged 2026-04-27, in nightly ≥5817).
                                  Gem now calls this in Cookies#clear.
LP.handleJavaScriptDialog      → IMPLEMENTED (PR #2261, merged 2026-04-29, in nightly ≥5900,
                                  closes #2260). Pre-arm model: client sends
                                  `LP.handleJavaScriptDialog {accept, promptText}` BEFORE
                                  triggering the action that opens a dialog; the response
                                  is stashed in `BrowserContext.pending_dialog_response`
                                  and consumed when the dialog opens. Bypasses the
                                  dispatch-thread deadlock that prevented the gem from
                                  calling `Page.handleJavaScriptDialog` synchronously.
                                  Gem cleanup pending — see "Recently Merged Upstream PRs".
LP.handleJavaScriptDialog      → defaultText fallback (PR #2322, merged 2026-04-30, in Linux
  defaultText fallback            nightly ≥5944, closes #2321). When the gem pre-arms
                                  `LP.handleJavaScriptDialog {accept: true}` with no
                                  `promptText` and the page calls `prompt(msg, defaultText)`,
                                  Lightpanda now returns `defaultText` (Chrome parity)
                                  instead of "". Lets `accept_modal(:prompt)` without
                                  `with:` surface the dialog's prebuilt default value.
HTMLElement.isContentEditable  → MERGED, BUT NOT USABLE (PR #2310, merged 2026-04-30, in
                                  Linux nightly ≥5944, closes #2309). The maintainer overrode
                                  the spec-correct walk in commit `2af95af6`: native getter
                                  always returns false; only logs `.not_implemented` when the
                                  spec walk would have said true. Rationale: no caret/keyboard
                                  editing pipeline → returning true would silently noop
                                  Puppeteer-style dispatchKeyEvent. Gem polyfill at
                                  `javascripts/index.js:910-921` MUST stay; replacing it with
                                  a native read would regress every `Node#content_editable?`
                                  call to false.
KeyboardEvent.keyCode/charCode → IMPLEMENTED (PR #2292, merged 2026-04-28, in nightly ≥5900).
                                  Gated on `isTrusted`; Enter sets charCode.
Browser sends Referer          → IMPLEMENTED (PR #2283, merged 2026-04-28, in nightly ≥5900).
                                  Cross-page navigation requests now carry the originating
                                  page's URL as Referer.
HTMLFrameSetElement stub       → IMPLEMENTED (PR #2306, merged 2026-04-28, in nightly ≥5900,
                                  closes #2249). Older Angular 9 SPAs no longer fail
                                  completely on document construction.
<input type=image> click       → SUBMITS THE FORM (PR #2312, merged 2026-04-29, in nightly ≥5900,
                                  closes #2311). Native `imageBtn.click()` now schedules
                                  navigation through `Frame.submitForm`.
<label> click activation       → IMPLEMENTED (PR #2324, merged 2026-04-30, in Linux nightly
                                  ≥5944, closes #2323). `Frame.handleClick` now resolves
                                  the labeled control via `Label.getControl` and dispatches
                                  a synthetic `.click()`. Gem cleanup landed in `5e10ce10`
                                  (label arm dropped from `CLICK_JS`).
```

### Available CDP Methods (not yet used by this gem)

```
Page.createIsolatedWorld     Page.getFrameTree
Page.removeScriptToEvaluateOnNewDocument
Page.setLifecycleEventsEnabled  Page.stopLoading (stub)    Page.close
Page.printToPDF (fake PDF — PR #2197 merged 2026-04-20)
DOM.resolveNode              DOM.getBoxModel (now returns real getBoundingClientRect geometry)
DOM.scrollIntoViewIfNeeded
DOM.performSearch            DOM.getSearchResults        DOM.discardSearchResults
DOM.getContentQuads          DOM.requestChildNodes
DOM.getFrameOwner            DOM.getOuterHTML            DOM.requestNode
Input.dispatchMouseEvent     Input.dispatchKeyEvent      Input.insertText
Network.setCookies (batch)   Network.getResponseBody
Network.setCacheDisabled (stub)
Network.setUserAgentOverride
Runtime.addBinding           Runtime.runIfWaitingForDebugger (stub)
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
LP.getMarkdown               LP.getNodeDetails
LP.detectForms               LP.clickNode
LP.fillNode                  LP.scrollNode
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

2. ~~**`Network.clearBrowserCookies` + `Network.getAllCookies`**~~ — RESOLVED both upstream (PR #2255 merged 2026-04-27) and gem-side (cookies.rb cleanup landed; `MINIMUM_NIGHTLY_BUILD = 5817`). Current `Cookies#all` calls `Network.getAllCookies`; `Cookies#clear` calls bulk `Network.clearBrowserCookies`; `Browser#visited_origins` / `record_visited_origin` / `sweep_visited_origins` no longer exist. Verified empirically against `1.0.0-dev.5839+2bbf23b3`. Historical context retained for `Network.deleteCookies(name:, url:)` per-origin behavior, which still works as expected.

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
   - **History**: `document.body = newBody` setter was missing → fixed by PR #2215 (merged 2026-04-23). After that landed, the CSS selector engine still had a bug where `querySelector('#id')` returned null after `innerHTML` mutation + `replaceWith` (Turbo Drive's snapshot-then-swap). Fixed by PR #2244 (merged 2026-04-27 00:46 UTC, by us): `Frame.getElementByIdFromNode` walks `_removed_ids` + scope root on `lookup` miss.
   - **Confirmed in nightly ≥5816**, gem-side cleanup landed (`MINIMUM_NIGHTLY_BUILD` = 5817, querySelector rewriter IIFE removed from `index.js`, polyfill regression test removed from `driver_spec.rb`).
   - **Turbo Frames (GET navigation)**: work natively via Turbo's fetch + frame-element innerHTML replacement.

8. ~~**`textContent` whitespace differs from Chrome**~~ — RETRACTED 2026-04-28 (misdiagnosis, see wishlist A13)
   - **Empirical retraction against `1.0.0-dev.5817+716b6f33`**: `Element.textContent` for the `with_html.erb` nested-div fixture matches the [HTML Living Standard descendant-text-content concatenation](https://dom.spec.whatwg.org/#concept-descendant-text-content) byte-for-byte. The Capybara `#ancestor` test (`el.ancestor('//div', text: "Ancestor\nAncestor\nAncestor")`) **passes** on current build. Probe at `/tmp/a13-probe/`.
   - **What was wrong with the original entry**: the failure routes through `node.text(:visible)` → `Node#visible_text` → the gem's `_lightpanda.visibleText` JS polyfill, NOT through `textContent`. With CSSOM merged, `getComputedStyle(div).display === 'block'` works and the polyfill emits block-level newlines correctly.
   - **Real residual upstream gap (separate, not in scope today)**: native `Element.innerText` (`src/browser/webapi/element/Html.zig:226-268`, `_getInnerText`) doesn't insert required line breaks at block-level boundaries per the [innerText algorithm](https://html.spec.whatwg.org/multipage/dom.html#the-innertext-idl-attribute) — it recurses through children and only emits `\n` for `<br>`. Empirically returns `"Ancestor Ancestor Ancestor Child  ASibling  "`. Gem polyfill hides this; no test surfaces the native gap. Future PR opportunity (~150 LOC gem polyfill drop on fix; multi-day Zig project).
   - **Real residual gem-side gap (separate)**: `node #shadow_root should get visible text` still fails because `_lightpanda.visibleText` (`lib/capybara/lightpanda/javascripts/index.js:953`) wraps every `display:block` element with `\n…\n` even when empty — phantom line break between siblings. File as gem-side TODO.

9. ~~**`form.submit()` does NOT navigate** and **`document.write()` is a no-op**~~ — RETRACTED 2026-04-27 (gem misdiagnosis, both work natively); gem-side cleanup completed 2026-04-28
   - **Empirical retraction**: native `form.submit()` (POST + GET), `submit_button.click()`, `form.requestSubmit()`, and Enter-in-text-input implicit submission **all navigate correctly**. `document.open(); document.write(html); document.close()` correctly replaces `document.body.innerHTML`.
   - **Gem-side cleanup landed 2026-04-28**: `CLICK_JS` simplified to `this.click()` (with label-click + summary/details + image-button special cases — see Known Bugs #10, #11 below), `IMPLICIT_SUBMIT_JS` rewritten to click default submit button or fall back to `form.requestSubmit()`, "plain form submission (Lightpanda fetch+swap)" describe block removed from `driver_spec.rb`. ~160 LOC dropped from `node.rb`. `bundle exec rake spec:incremental` → 1396 examples, 0 failures, 97 pending against nightly 5839.
   - **Origin of the misdiagnosis**: the 2026-04-26 gem commit `35ee402` added a fetch+swap workaround in `CLICK_JS` based on the assumption that `submitForm` doesn't navigate. But `git blame src/browser/Frame.zig` shows `submitForm` has called `scheduleNavigationWithArena` since at least 2026-03-24 — the upstream fix predated the gem workaround by a month. Likely related to the `#id` selector regression (Known Bug #7) attributed to the wrong root cause.

10. ~~**`<input type=image>` click does not submit the form**~~ — RESOLVED upstream by PR #2312 (merged 2026-04-29, closes #2311, in nightly ≥5900). Native `imageBtn.click()` routes through `Frame.submitForm`. Gem cleanup landed 2026-04-29 — image-button branch removed from `CLICK_JS` (`lib/capybara/lightpanda/node.rb`).

11. ~~**Textarea field values not normalized to CRLF on form submission**~~ — RESOLVED upstream by PR #2308 (merged 2026-04-29, closes #2307). `KeyValueList.urlEncode` normalizes LF→CRLF per the HTML form-data set algorithm. Gem cleanup landed 2026-04-29 — textarea skip patterns removed from `spec/spec_helper.rb`. **Distribution caveat (verified 2026-05-01)**: gem currently sets `MINIMUM_NIGHTLY_BUILD = 5940`. Linux nightly 5948 (05-01 cut at HEAD `9a9e79eb`) clears the floor, but **macOS nightly assets are still 04-29 cut at build 5900** (HEAD `78babf40`) — the macOS GHA build jobs have now missed two consecutive nightly cycles. macOS end-users hit `BinaryError "build 5900 < required 5940"` on `Capybara::Lightpanda::Binary.ensure_nightly` until the macOS nightly catches up.

### Open Fix PRs (not yet merged)

- **PR #2157**: **Feat: add full SVG DOM support** — could affect tests that interact with SVG elements (icons, charts).
- **PR #2077**: **fix: Target.attachToTarget returns unique session id per call** — fixes bug where multiple `attachToTarget` calls return the same session ID. Our gem only calls `attachToTarget` once per page, but improves CDP spec compliance.
- **PR #2289** (by us, opened 2026-04-28, **CHANGES_REQUESTED**): **Page.getNavigationHistory + Page.navigateToHistoryEntry**. Maintainer left review; needs revision before merge. When merged: `Browser#back` / `#forward` can switch from `history.back()` / `history.forward()` JS to native CDP commands, removing the JS workaround documented in CLAUDE.md.
- **PR #2305** (by us, opened 2026-04-28): **XPath 1.0 evaluator** (`Document.evaluate`, `XPathResult`/`XPathEvaluator`/`XPathExpression`, `DOM.performSearch` XPath routing). ~3,470 LOC Zig port of the gem polyfill; 91-case conformance battery passes. When merged: drop the entire `XPathEval` IIFE and `document.evaluate` polyfill from `index.js` (~700 LOC); also fixes XPath-in-iframes.

### Recently Merged Upstream PRs

Public nightly refreshed **2026-05-04 03:44 UTC** for all four platforms (Linux/macOS × x86_64/aarch64) at main HEAD `0420802f`, build **6005**. macOS nightly is **caught up** — PR #2346 (libidn2 `strchrnul` shim, merged 2026-05-04) restored the macOS GHA build job after a two-cycle stall. Verified by downloading `lightpanda-aarch64-macos`: reports `1.0.0-nightly.6005+b8144d3e`. With `Process::MINIMUM_NIGHTLY_BUILD = 5940`, all distributed nightly platforms now pass the version-check.

| PR | Description | Gem cleanup landed |
|---|---|---|
| #2261 | `LP.handleJavaScriptDialog` pre-arm (closes #2260) | `Browser#accept_modal`/`#dismiss_modal` rewired to send LP command before the action; 4 modal skip patterns dropped |
| #2283 | `Referer` on cross-page navigation | 4 referer skip patterns dropped (form-submit Referer ALSO works — no skip needed) |
| #2292 | `KeyboardEvent.keyCode`/`charCode` | `node #send_keys should generate key events` skip dropped |
| #2306 | `HTMLFrameSetElement` stub (closes #2249) | No direct gem change |
| #2312 | `<input type=image>` click submits form (closes #2311) | Image-button branch dropped from `CLICK_JS` |
| #2294 | UA stylesheet `display:none` defaults | `_lightpanda.isVisible` collapsed to ~Cuprite shape (~20 LOC saved) |
| #2308 | Textarea LF→CRLF in `KeyValueList.urlEncode` (closes #2307) | 2 textarea skip patterns dropped |
| #2315 | `:disabled` honors fieldset/optgroup ancestors (closes #2314) | `_lightpanda.isDisabled` polyfill dropped (~28 LOC); `DISABLED_JS` now inlines `el.matches(':disabled')` |
| #2237 | `window.open` partial support | No direct gem change |
| #2319 | `Window.close` drops queued navigation | No direct gem change |
| #2320 | Fix segfault on `Frame` deinit | No direct gem change (stability win for long sessions) |
| #2282 | `<input type=file>` foundation (FormData entries can hold `*File`, multipart encoding) | **No direct gem change yet** — the PR explicitly does NOT enable file uploads; both new code paths assert `entry.value == file` is `unreachable`. Track for follow-up that wires `Page.setFileInputFiles`. |
| #2322 | LP dialog `defaultText` fallback when `promptText` is null (closes #2321) | Gem cleanup landed in `5e10ce10` — `#accept_prompt should accept the prompt with no message when there is a default` skip pattern dropped from `spec/spec_helper.rb`. |
| #2324 | `<label>` click runs activation behavior (closes #2323) | Gem cleanup landed in `5e10ce10` — label arm dropped from `CLICK_JS` (`lib/capybara/lightpanda/node.rb`). Comment in `node.rb:357-364` now says "Native works as of build ≥5940". |
| #2327 | Cookie: don't allow JS to mutate `HttpOnly` cookies | No direct gem change (security alignment with Chrome). |
| #2310 | `HTMLElement.isContentEditable` IDL attribute (closes #2309) | **Gotcha — no gem cleanup possible.** PR landed but the maintainer added commit `2af95af6` immediately before merge that overrides the spec walk: `getIsContentEditable` now ALWAYS returns `false` and emits `log.info(.not_implemented, "IsContentEditable", ...)` when the spec walk would have returned true. Rationale (per commit message): Lightpanda has no caret/keyboard editing pipeline, so a spec-correct `true` would route Puppeteer's `dispatchKeyEvent` into a silently-noop input pipeline. Net effect for us: `_lightpanda.isContentEditable` polyfill in `javascripts/index.js:910-921` MUST stay; native `el.isContentEditable` is unusable. The polyfill walks ancestors itself, so it still works correctly. |
| #2335 | Defer `Window.close()` until next `Page.deinit` tick | No direct gem change (stability win — `Frame.deinit` no longer runs inside JS runtime). |
| #2331 | `Element.getElementsByTagName` filters by `tag_name` not `lower` (WPT alignment) | No direct gem change. |
| #2299 | IDN URL handling | No direct gem change. |
| #2285 | Form submitter override only for `submit` inputs | No direct gem change (tightens semantics for non-submit input types — our gem already targets explicit submits). |
| #2296 | `crypto.generateKey` raises typed errors instead of crashing | No direct gem change. |
| #2286 | HTML constraint validation API (by us, merged 2026-05-01, in nightly ≥5948) | **Partial gem cleanup landed** — `#has_field with valid` skip patterns dropped from `spec/spec_helper.rb`; `:html_validation` capybara_skip flag stays. **Residual upstream gap**: `Input.suffersPatternMismatch` is a TODO stub (`Input.zig:298-305`) and `el.pattern` IDL accessor returns null, so `validity.patternMismatch` never fires and `validationMessage` is empty for `<input pattern>`. `valueMissing` / `required` flow works correctly (`validationMessage => "Please fill out this field."`). Capybara's `#has_field with validation message` specs target a `pattern` field, so they remain pending. Future upstream PR opportunity: route `pattern` through V8 RegExp evaluation from Zig. |
| #2342 | `<summary>` click toggles parent `<details>.open` (by swaroski, closes #2325, merged 2026-05-04, in nightly ≥6005) | **Gem cleanup pending** — drop the summary arm from `CLICK_JS` (`lib/capybara/lightpanda/node.rb:366-381`, ~12 LOC). Once dropped, `CLICK_JS` collapses to a one-liner `function() { this.click() }`. Note: our parallel PR #2326 (navidemad) was closed unmerged because the maintainer landed #2342 first (`Sorry, I saw the other PR about this first and merged it`). |
| #2346 | libidn2 `strchrnul` shim for macOS (by us, merged 2026-05-04, in nightly ≥6005) | No direct gem change — fixes the upstream nightly CI build job that had been failing macOS asset uploads since `9fe628dd` vendored libidn2. macOS nightly assets resumed publishing 2026-05-04 03:40 UTC. |

Skip-pattern audit run 2026-04-29 against build 5918 found 6 obsolete patterns (5 `#attach_file` cases that don't actually upload, plus form-submit Referer). All narrowed in the same pass — `/#attach_file/` was split into 17 explicit patterns matching only the cases that hit the missing `Page.setFileInputFiles` CDP method. The PR #2322 prompt-default and PR #2324 label-branch cleanups went in optimistically with commit `5e10ce10` ahead of nightly 5945; against Linux nightly 5948 and macOS nightly 6005 those drops are validated. **macOS nightly caught up 2026-05-04** (≥6005) so the next skip-pattern audit can run reproducibly across both platforms. PR #2286 (constraint validation, merged 2026-05-01) and PR #2342 (summary/details click, merged 2026-05-04) are next in line for skip-pattern + JS cleanup.

### Upstream Open Issues That Affect This Gem

| Issue | Impact | Description |
|---|---|---|
| #2187 | CDP | **`Runtime.evaluate` after click-driven navigation fails with "Cannot find default execution context"**. DIRECTLY RELEVANT: `Node#call` wraps every CDP call in `Browser#with_default_context_wait`, which does a single event-driven retry (waits for `Runtime.executionContextCreated` with `auxData.isDefault: true`, then yields again). The driver's `invalid_element_errors` also includes `NoExecutionContextError` so Capybara's `automatic_reload` can re-find the node. Keep both layers until this is fixed. |
| #2175 | JS/CDP | **Implement `<input type="file">` support**. Aligned with our existing `NotImplementedError` in `Node#set` for file inputs. |
| #2173 | Crash | `TargetClosedError` navigating to React apps via CDP — browser crashes. Our `handle_navigation_crash` reconnect logic covers this, but would appear as `DeadBrowserError` after retry. |
| #2043 | CDP | Roadmap discussion for CDP automation features (setFileInputFiles, Input events, dialog, history, window.open); directly relevant to our workarounds. |
| #1890 | Navigation | Multi-step form POST does not update page content (SAP SAML login). |
| #1801 | Navigation | `Page.navigate` never completes for Wikipedia. Drives our readyState polling fallback. |
| #2017 | JS | Implement Worker and SharedWorker. Partial Worker support landed (PR #2078 merged 2026-04-14, more APIs in PR #2208/#2218); SharedWorker still missing and many Worker APIs still unimplemented, so issue stays open. |
| #2288 | CDP | `Page.getNavigationHistory` / `Page.navigateToHistoryEntry` not implemented. Our PR #2289 OPEN proposes the full pair. Gem currently uses `history.back()` / `history.forward()` JS workaround. |

### General Limitations

- Many Web APIs not yet implemented (hundreds remain)
- Complex JS frameworks may not work (React SSR hydration, heavy SPA)
- `window.getComputedStyle()` significantly improved — CSSOM merged (PR #1797, 2026-03-23); `checkVisibility` matches all active stylesheets
- No `window.scrollTo()`, `element.scrollIntoView()` (no layout)
- `MutationObserver` now available (PR #1870, reference counting; weak refs disabled by PR #1887)
- `window.postMessage` across frames now works (PR #1817)
- No CORS enforcement (acknowledged in upstream README as of 2026-03-27)
- In-page `WebSocket` API now implemented (PR #2179 merged 2026-04-18, closes #1952)
- `window.open` partial support landed (PR #2237 merged 2026-04-29, in nightly ≥5900): no `target=window_name`/`_blank`, sub-pages share the parent's lifetime, no CDP-side validation. Useful for sites that call `window.open` defensively for login popups.
- `Window.close` now drops any queued navigation (PR #2319 merged 2026-04-29, in nightly ≥5900) AND defers `Frame.deinit` to the next `Page.deinit` tick (PR #2335 merged 2026-04-30, in Linux nightly ≥5948), so popup-close flows can't race a queued navigation against the close and don't crash if `window.close()` runs from inside the JS runtime.
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
