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
| **Page** | page.zig | Navigation, events, screenshots (1920x1080 PNG), reload (PR #1992), addScriptToEvaluateOnNewDocument (PR #1993), `handleJavaScriptDialog` exists but always errors with `-32000 No dialog is showing` and points clients at `LP.handleJavaScriptDialog` (commit 8cc82d1d, 2026-04-29), `javascriptDialogOpening` event emitted (commit 95f80c96 2026-04-03), `getNavigationHistory` / `navigateToHistoryEntry` (PR #2289 merged 2026-05-11, in nightly ≥6106 once next nightly cuts) |
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
(none currently — Page.getNavigationHistory / Page.navigateToHistoryEntry landed
in PR #2289 merged 2026-05-11. Gem still calls history.back()/history.forward()
JS at lib/capybara/lightpanda/browser.rb:220,224 until the cleanup PR switches
to native CDP and bumps MINIMUM_NIGHTLY_BUILD past the merge.)
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

3. ~~**`XPathResult` not implemented**~~ — RESOLVED upstream by PR #2305 (merged 2026-05-11 08:01 UTC). Native `Document.evaluate`, `XPathResult`, `XPathEvaluator`, `XPathExpression`, and XPath routing in `DOM.performSearch` all landed (~3,470 LOC Zig port of our polyfill; 91-case conformance battery passes upstream). **Not in published nightly yet** — current nightly (6105, built 2026-05-10 03:25 UTC) predates the merge; ships in next nightly cut.
   - Gem cleanup pending: the `XPathEval` IIFE (~700 LOC) + `document.evaluate` shim + `XPathResult` polyfill in `lib/capybara/lightpanda/javascripts/index.js:72-808,979-1010` can be removed once `MINIMUM_NIGHTLY_BUILD` is bumped past the merge.
   - The polyfill at `index.js:790-808` already self-detects native `XPathResult` (`if (typeof contextNode.evaluate === 'function' && typeof XPathResult !== 'undefined' && !XPathResult._polyfilled)`) and short-circuits to native, so callers transparently use native XPath the moment a binary with PR #2305 loads — even before the gem-side removal lands. Cleanup is purely deadcode deletion.
   - Side benefit: native XPath works in iframes (the polyfill only registers in the top frame). Removes the iframe-XPath limitation noted in the previous polyfill regime.

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

11. ~~**Textarea field values not normalized to CRLF on form submission**~~ — RESOLVED upstream by PR #2308 (merged 2026-04-29, closes #2307). `KeyValueList.urlEncode` normalizes LF→CRLF per the HTML form-data set algorithm. Gem cleanup landed 2026-04-29 — textarea skip patterns removed from `spec/spec_helper.rb`.

### Open Fix PRs (not yet merged)

- **PR #2157**: **Feat: add full SVG DOM support** — could affect tests that interact with SVG elements (icons, charts).
- **PR #2077**: **fix: Target.attachToTarget returns unique session id per call** — fixes bug where multiple `attachToTarget` calls return the same session ID. Our gem only calls `attachToTarget` once per page, but improves CDP spec compliance.
- **PR #2405** (by us, opened 2026-05-09): **Bound CDP macrotask drains so commands aren't queued behind page work**. **NOW REDUNDANT.** Targets issue #2402; the reporter (zaiddabaeen) confirmed 2026-05-11 04:41 UTC that PR #2393 (`Add timeslice to scheduler`, merged 2026-05-06, in nightly 6105) already fixes the underlying stall — same `cdp-probe.mjs` against `opswat.com/docs/mdmft/metadefender-mft` now shows `Runtime.evaluate 1+1` returning in 627 ms vs. 14.7 s pre-fix. Issue #2402 closed as fixed. PR #2405 still OPEN with no review; can be closed by us. Sub-second per-command latency on JS-heavy SPAs is already restored without it.
- **PR #2406** (by us, opened 2026-05-09): **parser: defer raw-text merge to bound memory growth**. Targets issue #2397 (some pages spike to 3+GB memory under `--obey-robots`). HTML parser would merge consecutive raw-text fragments into one giant allocation; PR defers the merge so memory growth is bounded. Affects gem if specs hit similar pages — currently not, but defense-in-depth for users who do.

### Recently Merged Upstream PRs

Public nightly **NOT refreshed since 2026-05-10 03:25 UTC** — assets still tagged `1.0.0-nightly.6105+520d9688`, built from HEAD `520d9688` (PR #2398 worker-importscripts-segfault merge). Upstream `main` has moved to `cfcfe4ee` since: two of our PRs landed today, **PR #2289 (`Page.getNavigationHistory` + `Page.navigateToHistoryEntry`) merged 2026-05-11 01:29 UTC** as commit `1bfefa3d`, closing issue #2288, and **PR #2305 (XPath 1.0 evaluator — `Document.evaluate`, `XPathResult`, `DOM.performSearch` XPath routing) merged 2026-05-11 08:01 UTC** as commit `d2151b6f`. Both are gem-relevant workaround removals (history-back JS and ~700 LOC XPath polyfill respectively). Tomorrow's nightly should be ≥6106 and roll up both, along with the small Performance/HTMLLinkElement merges (#2415/#2416/#2417). Local upstream worktree at `/Users/navid/code/browser` is fast-forwarded to `cfcfe4ee` (`Merge pull request #2417`) on `main` branch, with untracked AGENTS.md/CLAUDE.md only (PR #2396 in flight, not merged) — i.e. the worktree already has both #2289 and #2305 available for local-build validation. Note: `zig-out/bin/lightpanda` is not present in the worktree; a `zig build` is required before `LIGHTPANDA_BIN` validation. `Process::MINIMUM_NIGHTLY_BUILD = 6065` still validates today's published nightly (6105 ≥ 6065). The gem cleanup PRs that drop the history-back JS and XPath polyfill will need to bump it past whatever build number rolls up #2289 and #2305 (expected ≥6106 in tomorrow's nightly).

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
| #2286 | HTML constraint validation API (by us, merged 2026-05-01, in nightly ≥5948) | **Gem cleanup landed** — `#has_field with valid` skip patterns dropped. The trailing `:html_validation` capybara_skip flag was dropped in `59c5718` once PR #2352 closed the residual `pattern` gap (see below). |
| #2342 | `<summary>` click toggles parent `<details>.open` (by swaroski, closes #2325, merged 2026-05-04, in nightly ≥6005) | Gem cleanup landed in `638ede6` — summary arm dropped from `CLICK_JS`. Note: our parallel PR #2326 (navidemad) was closed unmerged because the maintainer landed #2342 first (`Sorry, I saw the other PR about this first and merged it`). |
| #2346 | libidn2 `strchrnul` shim for macOS (by us, merged 2026-05-04, in nightly ≥6005) | No direct gem change — fixes the upstream nightly CI build job that had been failing macOS asset uploads since `9fe628dd` vendored libidn2. macOS nightly assets resumed publishing 2026-05-04 03:40 UTC. |
| #2352 | `HTMLInputElement.pattern` + `patternMismatch` validity (by us, merged 2026-05-04, in nightly ≥6051) | **Closes the residual gap on PR #2286.** `Input.suffersPatternMismatch` now routes through the V8 RegExp engine and `el.pattern` IDL accessor returns the attribute value. `validity.patternMismatch === true` and `validationMessage === "Please match the requested format."` fire correctly for `<input pattern>`. Gem cleanup landed in `59c5718` (2026-05-05) — `MINIMUM_NIGHTLY_BUILD` bumped to 6051 and the `:html_validation` capybara_skip flag removed from `spec/features/session_spec.rb`. |
| #2297 | Page-lifecycle refactor: pending-pages model (`replacePage` → `Session.initiateRootNavigation`, merged 2026-05-04, in nightly ≥6051) | **One upstream regression — issue [#2363](https://github.com/lightpanda-io/browser/issues/2363) filed 2026-05-05.** `Page.navigate("about:blank")` against a non-blank tab fires the full event sequence (`frameStartedNavigating`, `executionContextsCleared`, `frameNavigated` x2, `executionContextCreated`, `domContentEventFired`, `loadEventFired`, `frameStoppedLoading`) but doesn't replace the document — `window.location.href`, `document.URL`, and the frame tree all still report the previous URL. Plain http→http navigation is unaffected. Self-contained Node CDP repro attached to the issue (75 lines, no npm deps). **Gem sidesteps it**: `Browser#reset` now disposes the BrowserContext via `Target.disposeBrowserContext` (ferrum/cuprite parity, see `ruby-cdp-peers.md`) instead of navigating to `about:blank`. Other "regressions" initially attributed to #2297 turned out to be gem-side — see CLICK_JS notes in the gem's NodeJS workaround section. |
| #2356 | `cdp: rename Audit into Audits` (merged 2026-05-04) | No direct gem change — we don't use the Audit(s) domain. |
| #2359 | Reorganize Server, Client, CDP and HttpClient (merged 2026-05-04) | No direct gem change — internal refactor. |
| #2361 | Fix potential use-after-free by clearing worker AFTER frame context (merged 2026-05-04) | No direct gem change — stability win for any session that touches Web Workers. |
| #2365 | Track DOM version per node's owning frame; protect cloned scripts from double-execution (merged 2026-05-05, in nightly ≥`b573e44f`) | No direct gem change — internal caching/correctness fix surfaced by the WPT `dom/ranges/Range-insertNode.html` test. |
| #2368 | `events: report listener exceptions instead of halting dispatch` (by us, merged 2026-05-06 02:17 UTC, in nightly ≥6065) | **Gem cleanup landed 2026-05-06.** `patchDispatch` IIFE deleted from `polyfills.js` (~30 LOC); `CLICK_JS` simplified — the `try { … } catch (e) { /* patchDispatch … */ }` wrapper around `dispatchEvent` collapsed to a plain assignment. `MINIMUM_NIGHTLY_BUILD` bumped to 6065 (today's published nightly tagged `61364437`, the PR #2368 merge). Validated against `LIGHTPANDA_BIN=/tmp/lp-nightly-aarch64-macos`: `bundle exec rake test:unit` (83/83), `bundle exec rake test` (140/140), `bundle exec rake spec:shared` (1399 examples, 94 pending, 1 known iframe-context flake unrelated to dispatch). |
| #2358 | `net: multipart-encode FormData bodies in fetch and XMLHttpRequest` (by us, merged 2026-05-06 04:50 UTC, in nightly ≥2026-05-07) | No direct gem change — wires the existing multipart encoder into `fetch()` and `XMLHttpRequest.send()` body paths so `FormData` no longer serializes as the literal 17 bytes `[object FormData]`. Foundation for in-page file submissions over `fetch(url, {body: formData})`; does NOT unblock `<input type=file>` uploads (still needs `Page.setFileInputFiles` — issue #2175). Closes #2357. |
| #2371 | `On an unloaded-page, fast-path navigation` (merged 2026-05-06 22:47 UTC, in nightly ≥2026-05-07) | No direct gem change — re-introduces a CDP-side perf path that was removed for PR #2297 (page-lifecycle refactor). Only fires when the page is in `_waiting` state (no navigation event yet) so it has nothing to preserve, and reuses the existing bare v8 context. Does NOT fix issue #2363 (`Page.navigate("about:blank")` on a non-blank tab still doesn't replace the document) — that's a different code path; gem keeps its `Target.disposeBrowserContext` workaround in `Browser#reset`. |
| #2374 | `Abort http_client before destroying context` (merged 2026-05-06 22:47 UTC, in nightly ≥2026-05-07) | No direct gem change — internal `Frame.zig` teardown ordering fix. XHR shutdown now runs before V8 context destruction so cleanup callbacks don't dereference a freed context. Eliminates a class of WPT crashes; defense-in-depth for sessions that have inflight HTTP at navigation/close time. |
| #2404 | `Fix double-free in fetch when http_client.request fails synchronously` (by us, merged 2026-05-10 04:03 UTC, in nightly ≥6106 once next nightly publishes) | No direct gem change — the bug only triggers under `--obey-robots` and the gem doesn't pass that flag. Stability win for upstream WPT runs and `lightpanda fetch --obey-robots` CLI users; no exposure for `serve` consumers. |
| #2289 | **`Page.getNavigationHistory` + `Page.navigateToHistoryEntry`** (by us, closes #2288, merged 2026-05-11 01:29 UTC, in nightly ≥6106 once next nightly publishes) | **Gem cleanup pending.** Once `MINIMUM_NIGHTLY_BUILD` is bumped past the merge, `Browser#back` / `Browser#forward` at `lib/capybara/lightpanda/browser.rb:220,224` can drop the `wait_for_navigation { execute("history.back()") }` / `("history.forward()")` JS calls and route through native `Page.navigateToHistoryEntry` instead. `Page.getNavigationHistory` returns `currentIndex` + per-entry `id` so the gem can pick the previous/next entry deterministically without relying on `window.history.length`. Removes the JS-only workaround documented in `CLAUDE.md` "Architecture Rules". |
| #2305 | **XPath 1.0 evaluator: `Document.evaluate`, `XPathResult`, `XPathEvaluator`, `XPathExpression`, `DOM.performSearch` XPath routing** (by us, merged 2026-05-11 08:01 UTC, in nightly ≥6106 once next nightly publishes) | **Gem cleanup pending — large win.** ~700 LOC of `XPathEval` IIFE + `document.evaluate` shim + `XPathResult` polyfill in `lib/capybara/lightpanda/javascripts/index.js:72-808,979-1010` becomes deadcode. The polyfill at `index.js:790-808` already self-detects native via `if (typeof contextNode.evaluate === 'function' && typeof XPathResult !== 'undefined' && !XPathResult._polyfilled)`, so callers transparently use native XPath the moment a binary with PR #2305 loads — even before the polyfill is removed. Cleanup also fixes XPath-in-iframes (the polyfill only registered in the top frame). Suggested gem changes: bump `MINIMUM_NIGHTLY_BUILD`; delete the IIFE; simplify `FIND_WITHIN_JS` / `FIND_IN_FRAME_JS` / `find_in_document` xpath branches in `browser.rb:642,658,674` to call native `document.evaluate(...)` directly; drop the `XPathPolyfill::JS` registration at `browser.rb:727`. |

Skip-pattern audit run 2026-04-29 against build 5918 found 6 obsolete patterns (5 `#attach_file` cases that don't actually upload, plus form-submit Referer). All narrowed in the same pass — `/#attach_file/` was split into 17 explicit patterns matching only the cases that hit the missing `Page.setFileInputFiles` CDP method. The PR #2322 prompt-default and PR #2324 label-branch cleanups went in optimistically with commit `5e10ce10` ahead of nightly 5945; against Linux nightly 5948 and macOS nightly 6005 those drops are validated. PR #2342 (summary/details click) cleanup landed in `638ede6` against build 6005. PR #2352 (pattern validity, merged 2026-05-04, in nightly ≥6051) cleanup landed in `59c5718` (2026-05-05) — `MINIMUM_NIGHTLY_BUILD` bumped to 6051 and the `:html_validation` capybara_skip flag dropped, completing the constraint-validation cleanup line.

### Upstream Open Issues That Affect This Gem

| Issue | Impact | Description |
|---|---|---|
| #2175 | JS/CDP | **Implement `<input type="file">` support**. Aligned with our existing `NotImplementedError` in `Node#set` for file inputs. |
| #2173 | Crash | `TargetClosedError` navigating to React apps via CDP — browser crashes. Our `handle_navigation_crash` reconnect logic covers this, but would appear as `DeadBrowserError` after retry. |
| #2043 | CDP | Roadmap discussion for CDP automation features (setFileInputFiles, Input events, dialog, history, window.open); directly relevant to our workarounds. |
| #1890 | Navigation | Multi-step form POST does not update page content (SAP SAML login). |
| #1801 | Navigation | `Page.navigate` never completes for Wikipedia. Drives our readyState polling fallback. |
| #2017 | JS | Implement Worker and SharedWorker. Partial Worker support landed (PR #2078 merged 2026-04-14, more APIs in PR #2208/#2218); SharedWorker still missing and many Worker APIs still unimplemented, so issue stays open. |
| #2363 | Navigation | `Page.navigate("about:blank")` against a non-blank tab fires the full event sequence but does NOT replace the document — `window.location.href`, `document.URL`, and the frame tree all still report the previous URL. Filed by us 2026-05-05. **Gem sidesteps it**: `Browser#reset` disposes the BrowserContext via `Target.disposeBrowserContext` (ferrum/cuprite parity) instead of navigating to `about:blank`. PR #2371 (fast-path navigation, merged 2026-05-06) does NOT fix this — different code path. |
| #2400 | Runtime | Child iframe navigation invalidates main frame's `executionContextId` for CDP drivers. Filed by us 2026-05-08. Root cause: shared V8 inspector `CONTEXT_GROUP_ID` + single `IsolatedWorld` per BrowserContext, so any `frameNavigated` re-emits `executionContextCreated` for the main frame's V8 context under the child's frameId and churns the id. Symptom in other drivers: Playwright `evaluate` raises "Execution context was destroyed" even when only a child iframe navigated. **NOT mitigated for us under load** — observed 2026-05-11 against local build dev.6109 (HEAD `cfcfe4ee`): `spec:shared` produced **10 `NoExecutionContextError` failures** in `#switch_to_frame` / `#within_frame` via `Browser#find_in_frame` (`call_function_on(iframe_node.remote_object_id, …)`), where published nightly 6105 produced only 1 in the same run. Suspected amplification source: one of the 16 merges between 6105 and 6109 — most likely the `0bbddb31` / `efbf1db8` "Try to fix a bad merge" between PR #2289 and PR #2297 in `src/cdp/domains/page.zig`, since neither PR #2289 (history CDP) nor PR #2305 (XPath) touched frame execution-context lifecycle directly. `Browser#with_default_context_wait` + `Driver#invalid_element_errors` catch some recurrences but `find_in_frame` does not wrap in `with_default_context_wait`. Worth filing as a separate regression issue against the bad-merge fix if the failure count stays high in tomorrow's nightly. |
| #2407 | Stability | V8 fatal `AllowHeapAllocation::IsAllowed()` during GC weak callback under CDP load (debug builds only — release builds will not abort but the underlying inspector lifecycle bug is the same). Filed by us 2026-05-09 against debug build of `main`. Trigger: Worker `importScripts` + iframe-heavy page + repeated CDP connect/disconnect cycles. **Currently not gem-relevant** — repro uses puppeteer-core against allbirds.com; gem tests don't load Worker-heavy pages. Keep on watchlist; if a user's specs hit Worker+iframe pages this becomes load-bearing. |

**Gem-side defenses we keep regardless of upstream**: `Browser#with_default_context_wait` retries on `Runtime.executionContextCreated`, and `Driver#invalid_element_errors` includes `NoExecutionContextError` so Capybara's `automatic_reload` keeps working. Issue #2187 ("Runtime.evaluate after click-driven navigation") closed 2026-05-04 — keep these defenses anyway, they're cheap defense-in-depth.

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
