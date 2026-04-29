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
Page.addScriptToEvaluateOnNewDocument                    Page.getLayoutMetrics
Page.captureScreenshot       Page.javascriptDialogOpening (event)
Runtime.enable               Runtime.evaluate
Runtime.callFunctionOn       Runtime.getProperties       Runtime.releaseObject
Runtime.executionContextCreated (event)                  Runtime.executionContextsCleared (event)
DOM.getDocument              DOM.querySelector           DOM.querySelectorAll
DOM.describeNode
Network.getAllCookies        Network.setCookie
Network.deleteCookies        Network.clearBrowserCookies
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
Network.setUserAgentOverride   → IMPLEMENTED (PR #2139, merged ~2026-04-11)
Emulation.setUserAgentOverride → IMPLEMENTED (PR #2153, merged 2026-04-14)
Page.createIsolatedWorld       → NOW WORKING (PR #2164, merged 2026-04-16). Previously returned
                                  wrong executeContextId; fix pulls correct value from v8 inspector.
Network.getAllCookies          → IMPLEMENTED (PR #2255, merged 2026-04-27, in nightly ≥5817).
                                  Gem now calls this in Cookies#all.
Network.clearBrowserCookies    → ACCEPTS empty params (PR #2255, merged 2026-04-27, in nightly ≥5817).
                                  Gem now calls this in Cookies#clear.
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
Network.setExtraHTTPHeaders  Network.setCacheDisabled (stub)
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

10. **`<input type=image>` click does not submit the form** (real Lightpanda gap, surfaced by 2026-04-28 cleanup)
    - Native `imageBtn.click()` fires the click event but never schedules a navigation, even though the button has an associated `<form>` and a default `submit` type. Image buttons are HTML4-era — the spec requires the form to be submitted with `name.x` / `name.y` coordinate fields appended.
    - **Gem workaround**: `CLICK_JS` (`lib/capybara/lightpanda/node.rb`) special-cases `<input type=image>` and calls `form.requestSubmit()` after the click. Coordinate fields are NOT appended (Capybara tests don't assert on them), but the form submits. ~5 LOC.
    - **Wishlist**: file upstream — `Frame.submitForm` should be reachable from the `<input type=image>` click path (probably needs `Element.click()` for image inputs to call into the same submission machinery as `<input type=submit>`).

11. **Textarea field values not normalized to CRLF on form submission** (real Lightpanda gap, surfaced by 2026-04-28 cleanup)
    - Per HTML's [form-data set algorithm](https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#constructing-the-form-data-set), `<textarea>` field values must have line endings normalized to `\r\n` before serialization. Native form submission on Lightpanda sends raw `\n`. Affects both `application/x-www-form-urlencoded` and likely `multipart/form-data`.
    - **No gem workaround**: pre-normalizing in `Node#set` would over-normalize (textarea would display `\r\n` in the DOM). The previous fetch+swap pipeline did the conversion in JS during form encoding, but native form submission lives in Lightpanda's HTTP layer.
    - **Spec impact**: 2 skip patterns added in `spec/spec_helper.rb` (`#click_button.*should convert lf to cr/lf in submitted textareas` + `#fill_in should handle newlines in a textarea`).
    - **Wishlist**: file upstream — `Frame.submitForm` (or wherever the form-data set is constructed) should normalize textarea values per the spec.

### Open Fix PRs (not yet merged)

- **PR #2237**: **window.open** — limited support: no `target=window_name`/`_blank`, sub-pages share the parent's lifetime, no CDP-side validation. Useful for sites that call `window.open` defensively (login popups). Capybara tests that open popups would previously have errored — they'd now work for the duration of the parent page.
- **PR #2157**: **Feat: add full SVG DOM support** — could affect tests that interact with SVG elements (icons, charts).
- **PR #2077**: **fix: Target.attachToTarget returns unique session id per call** — fixes bug where multiple `attachToTarget` calls return the same session ID. Our gem only calls `attachToTarget` once per page, but improves CDP spec compliance.
- **PR #2261** (by us, opened 2026-04-27): **handleJavaScriptDialog drives confirm/prompt return values**. Fixes #2260 — currently `accept_modal(:confirm|:prompt)` cannot influence the JS return value (Lightpanda auto-dismisses). When merged: rewires `Browser#prepare_modals` to call `Page.handleJavaScriptDialog` (off the dispatch thread); removes 4 modal skip patterns in `spec/spec_helper.rb`.
- **PR #2289** (by us, opened 2026-04-28): **Page.getNavigationHistory + Page.navigateToHistoryEntry**. When merged: `Browser#back` / `#forward` can switch from `history.back()` / `history.forward()` JS to native CDP commands, removing the JS workaround documented in CLAUDE.md.
- **PR #2286** (by us, opened 2026-04-28): **HTML constraint validation API**. When merged: removes the `#has_field with valid` skip patterns (lines 141-142 of `spec/spec_helper.rb`).
- **PR #2294** (by us, opened 2026-04-28): **CSS UA stylesheet display:none defaults for unrendered elements** (HEAD/SCRIPT/STYLE/NOSCRIPT/TEMPLATE/TITLE + `[type=hidden]`). When merged: lets `_lightpanda.isVisible` (`javascripts/index.js:834-865`) collapse to roughly Cuprite's shape (~20 LOC saved); see Cuprite "Diverged on purpose" entry in `ruby-cdp-peers.md`.
- **PR #2305** (by us, opened 2026-04-28): **XPath 1.0 evaluator** (`Document.evaluate`, `XPathResult`/`XPathEvaluator`/`XPathExpression`, `DOM.performSearch` XPath routing). ~3,470 LOC Zig port of the gem polyfill; 91-case conformance battery passes. When merged: drop the entire `XPathEval` IIFE and `document.evaluate` polyfill from `index.js` (~700 LOC); also fixes XPath-in-iframes.
- **PR #2308** (by us, opened 2026-04-28): **textarea LF→CRLF normalization** in `KeyValueList.urlEncode` (form-data set encoding). Closes #2307. When merged: remove `#click_button.*should convert lf to cr/lf in submitted textareas`, `#fill_in should handle newlines in a textarea` skip patterns from `spec/spec_helper.rb`.
- **PR #2310** (by us, opened 2026-04-29): **`HTMLElement.isContentEditable` IDL attribute** with ancestor inheritance walk. Closes #2309. When merged: replace `_lightpanda.isContentEditable` polyfill with native read at `EDITABLE_HOST_JS` constant in `lib/capybara/lightpanda/node.rb` (~12 LOC saved).
- **PR #2312** (by us, opened 2026-04-29): **`<input type=image>` click routes into form submission**. Closes #2311. When merged: drop the image-button branch in `CLICK_JS` (`lib/capybara/lightpanda/node.rb`) — ~5 LOC saved.
- **PR #2315** (by us, opened 2026-04-29): **`:disabled` / `:enabled` selector matchers honor ancestor `<fieldset disabled>` and `<optgroup disabled>` (HTML "concept-fe-disabled" + "concept-option-disabled")**. Closes #2314. When merged: drop the `_lightpanda.isDisabled` polyfill (`lib/capybara/lightpanda/javascripts/index.js:901-928`) and inline `el.matches(':disabled')` at `DISABLED_JS` in `lib/capybara/lightpanda/node.rb:526` — ~28 LOC saved.

### Recently Merged Upstream PRs Awaiting a Public Nightly

The public nightly tag last refreshed **2026-04-28 03:33 UTC**, snapshotting commit `2bbf23b3` (PR #2280 merge), build **5839**. PRs merged after that timestamp are in `main` but NOT in the publicly-distributed nightly. When the next nightly ships, bump `Process::MINIMUM_NIGHTLY_BUILD` and apply the gem-side cleanups below.

- **PR #2283** (by us, merged 2026-04-28 08:01 UTC): `Referer` header sent on cross-page navigations. Gem cleanup: remove `#visit should send a referer when following a link`, `#visit should preserve the original referer URL when following a redirect`, `#click_link should follow redirects back to itself` skip patterns (`spec/spec_helper.rb:122-126`).
- **PR #2292** (by us, merged 2026-04-28 07:46 UTC): `KeyboardEvent.keyCode` and `charCode` legacy attributes implemented (gated on `isTrusted`, plus Enter charCode). Gem cleanup: remove the `node #send_keys should generate key events` skip pattern (`spec/spec_helper.rb:119`).

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
