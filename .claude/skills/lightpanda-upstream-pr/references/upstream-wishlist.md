# Lightpanda Upstream Wishlist

What `capybara-lightpanda` patches around because of upstream gaps in
[lightpanda-io/browser](https://github.com/lightpanda-io/browser).

Each entry has:
- **Today** — actual behavior on current public nightly (build ≥ 6269 as of 2026-05-17) and against the gem's enforced floor `MINIMUM_NIGHTLY_BUILD = 6269`. Where verified against a different build, the entry calls it out.
- **Want** — Chrome / spec behavior the gem assumes
- **Gem workaround** — where the workaround lives + one-liner
- **Drop-on-fix** — what gem code becomes superfluous when upstream lands the fix

Use this file when:
- Filing an issue / PR upstream against `lightpanda-io/browser`
- Auditing whether a gem-side hack is still needed after a Lightpanda update
- Communicating capability gaps to gem users

---

## Sections

- **A. Bugs to fix upstream** — Lightpanda misbehaves vs CDP / HTML spec; fixable
- **B. Missing CDP / DOM methods** — calls return errors or methods don't exist; gem routes around them
- **C. Inherent limitations** — by-design (no rendering, no compositor); out of scope upstream
- **D. Drop-on-fix LOC tally** — rough budget if section A + B all land

---

## A. Bugs to fix upstream

> Resolved/retracted A-items (A1–A9, A13–A21, A24–A35, A41) have been removed from this file; numbering is preserved (no renumbering) to keep cross-references stable. **A11 and A12 are kept as gem-side documentation only**: their tracking issues closed upstream but the gem retains the helpers as defense-in-depth (the underlying race + crash classes are inherent to the design).

### A10. `Page.loadEventFired` unreliable on complex JS pages (#1801 OPEN; #1832 CLOSED 2026-04-09)

- **Today (re-verified 2026-05-12)**: #1801 still OPEN. May never fire on Wikipedia, certain SPAs, French real estate sites. Even after PR #2032 reordered events.
- **Want**: fire reliably at end of navigation.
- **Gem workaround**: `lib/capybara/lightpanda/browser.rb` — `wait_for_page_load` / `wait_for_navigation` use a 2-second `Page.loadEventFired` window then fall back to `document.readyState` polling. Critical for Wikipedia-style sites.
- **Drop-on-fix**: keep readyState fallback as a safety net (cheap), but remove the 2-second cap and trust `loadEventFired` as primary.

### A11. `Runtime.evaluate` after click-driven navigation: "Cannot find default execution context" (#2187 CLOSED — gem keeps the helper)

- **Today**: race window after navigation where the V8 default context is destroyed but not yet recreated. Calls fail with `-32000 Cannot find default execution context`.
- **Upstream status (verified 2026-05-12)**: issue #2187 CLOSED 2026-05-04 as "completed". Maintainer confirmed Lightpanda's nav model discards the current context and emits `Runtime.executionContextsCleared` + `executionContextCreated` events around it (page.zig:518 / :540) — the race window is **inherent**, not a bug. The events ARE reliable; clients are expected to gate on them. So no further upstream filing is possible.
- **Want**: nothing further from upstream. The events are sufficient.
- **Gem workaround**: `lib/capybara/lightpanda/browser.rb` — `with_default_context_wait` retries on `NoExecutionContextError` after waiting for `Runtime.executionContextCreated`. `Node#call`, `find_in_document`, `find_in_frame`, `Node#shadow_root` all wrap in this pattern. **Load-bearing** — required because the race window is real.
- **Drop-on-fix**: NOT a drop-on-fix anymore — the helper is the correct design and stays. Cross-reference: also handles the iframe contextId churn from #2400 (see B9 / `lightpanda-io.md`).

### A12. WebSocket dies on complex page navigation (#1849 CLOSED — gem keeps defensive recovery)

- **Today**: #1849 CLOSED 2026-03-16 by PR #1850. Remaining surface: any rare crash path that drops the WS (e.g. V8 GC fatal #2407, fetch double-free #2404, http_client request failure #2381) still surfaces to the gem as a closed CDP socket.
- **Want**: nothing further upstream specific to #1849. Individual crash fixes land as they're filed (e.g. #2404 merged 2026-05-10).
- **Gem workaround**: `lib/capybara/lightpanda/browser.rb` — `handle_navigation_crash` reconnects on `@client.closed?` and retries the navigation once. Without this, any browser crash mid-navigation ripples as `DeadBrowserError` on the next CDP call.
- **Drop-on-fix**: NOT a single-fix drop-on-fix anymore. The helper guards against the entire "browser died mid-navigation" failure class, not just #1849. Keep until Lightpanda has zero crash-during-navigation paths — i.e. probably forever for a defensive driver. ~30 LOC retained as defense-in-depth.

### A22. `Element.isContentEditable` — IDL attribute landed but always returns false (cannot drop polyfill)

- **Today (re-verified 2026-05-12 against `main` HEAD `8cad175c`, nightly ≥6167)**: `HTMLElement.isContentEditable` IDL accessor exists, but `getIsContentEditable` at `src/browser/webapi/element/Html.zig:398-409` unconditionally `return false;`. PR #2310 (by us) originally implemented the spec-correct walk, but the maintainer added commit `2af95af6` immediately before merge that strips the return path: it walks ancestors per HTML §7.7.5.2, but only to emit `log.info(.not_implemented, "IsContentEditable", ...)` when the spec answer would be `true` — the function unconditionally returns `false`. Rationale (from the commit body): Lightpanda has no caret/keyboard editing pipeline, so a spec-correct `true` would route Puppeteer's `dispatchKeyEvent` into a silently-noop input pipeline; routing to `false` and logging the unsupported case surfaces the gap in telemetry rather than masquerading as a working state.
- **Upstream issue/PR**: #2309 CLOSED 2026-04-30, PR #2310 MERGED 2026-04-30 (with the maintainer override).
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js:910-921` — `_lightpanda.isContentEditable` falls back to walking the ancestor chain looking for a non-`false` `contenteditable` attribute when `el.isContentEditable` is falsy/missing (~12 LOC). Called from `EDITABLE_HOST_JS` in `lib/capybara/lightpanda/node.rb:503`, which backs `Node#content_editable?`. **Polyfill MUST stay** — replacing it with the native read would force every `Node#content_editable?` call to return false.
- **Drop-on-fix**: blocked indefinitely, contingent on Lightpanda implementing a real keyboard-editing pipeline. Until then, the gem polyfill is load-bearing.

### A23. `Element.innerText` doesn't insert block-level line breaks

- **Today (re-verified 2026-05-12 against `main` HEAD `8cad175c`)**: `_getInnerText` at `src/browser/webapi/element/Html.zig:228-268` recurses through children and emits `\n` only for `<br>`. No display:block / display:list-item line breaks; no hidden-descendant filtering (source still has the `// TODO check if elt is hidden` comment at line 243); no line-collapsing pass. Empirically, nested-block fixtures return `"Ancestor Ancestor Ancestor Child  ASibling  "` (no newlines) where Chrome returns the same content with `\n` inserted around block boundaries.
- **Want**: implement [the HTML innerText algorithm](https://html.spec.whatwg.org/multipage/dom.html#the-innertext-idl-attribute) — required line breaks around block-level boxes, hidden-descendant filtering via `getComputedStyle().display`, the line-collapsing pass that drops required line breaks adjacent to empty blocks. Multi-day Zig project; needs `getComputedStyle` access from inside the writer-driven walker.
- **Upstream issue/PR**: not filed.
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js` — `_lightpanda.visibleText` (~50 LOC) walks descendants in JS, dispatches on tag-name + `getComputedStyle().display`, wraps block-level descendants in `\n…\n` only when they actually contribute visible text. Called from `VISIBLE_TEXT_JS` in `lib/capybara/lightpanda/node.rb`, which backs `Node#visible_text` (and hence `text(:visible)`). Also: `node #shadow_root should get visible text` still fails because the polyfill emits a phantom `\n` around empty `display:block` elements between inline siblings — Chrome's innerText collapses these via the line-collapse pass. Gem-side TODO to add `/\S/.test(out)` guard or wait for upstream native impl.
- **Drop-on-fix**: replace the polyfill with `el.innerText` and inline the read at the `VISIBLE_TEXT_JS` constant. Drops `_lightpanda.visibleText` (~50 LOC). The phantom-newline gem-side bug goes away too if upstream collapses required line breaks around empty blocks.

### A36. `document` never fires `readystatechange` (breaks Turbo's `turbo:load`)

- **Today (verified 2026-06-11 against installed nightly, floor 6699)**: `document.readyState` transitions correctly (`loading` → `interactive` → `complete`) and both `DOMContentLoaded` and `window` `load` fire, but the `readystatechange` event is never dispatched at the document (Chrome fires it twice per load). Lifecycle probe log: `["script-eval:loading", "DOMContentLoaded:interactive", "window.load:complete"]` — zero `readystatechange` entries. Per [HTML "current document readiness"](https://html.spec.whatwg.org/multipage/dom.html#current-document-readiness), every readiness change must fire `readystatechange` at the `Document`.
- **Real-world impact**: Turbo 8's `PageObserver` listens ONLY for `readystatechange` to walk its stage machine to `pageLoaded()` — so `turbo:load` never fires. Found by the first external beta tester (2026-06-11): every spec failed in a `wait_for_turbo_drive` helper gated on a `data-turbo-not-loaded` html attribute that only a `turbo:load` listener removes. Reproduced with real Turbo 8.0.23 in all three loading modes (UMD, ESM, importmap) — Turbo boots fine, the event just never arrives. Also degraded the gem's own `turbo:load` listener in `index.js` (idle-reset path of the Turbo activity tracker).
- **Want**: dispatch `readystatechange` at the document whenever `document.readyState` changes (twice per load: `interactive`, `complete`). Fix shape: wherever the Zig load pipeline flips readiness, dispatch the event — mirror how `DOMContentLoaded` is emitted. No layout dependency.
- **Upstream issue**: #2707, **Upstream PR**: #2708 (open as of 2026-06-11). Fix dispatches the event at `Frame.zig`'s two readiness flips (helper `dispatchReadyStateChange`), before `DOMContentLoaded` and before `load`, matching spec ordering. Fixture: `src/browser/tests/page/readystatechange.html`.
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js` (top of the IIFE, ~7 LOC) — re-dispatches `readystatechange` from `DOMContentLoaded` (readyState=interactive) and `window` `load` (readyState=complete). Regression coverage: Zone 5 in `test/features/hotwire_zones_probe_test.rb` (event delivery) + `test/features/turbo_load_test.rb` (end-to-end against the vendored real Turbo bundle, `test/fixtures/turbo-8.0.23.umd.js`).
- **Drop-on-fix**: remove the shim block from `index.js` once `MINIMUM_NIGHTLY_BUILD` covers the fix; both tests stay as regression checks. Until the floor bump, a fixed nightly plus the shim double-fires the event — harmless for readyState-reading state machines like Turbo's PageObserver, but drop the shim promptly anyway.

### A42. WebSocket upgrade request missing `Origin` header (ActionCable rejects every connection → `turbo_stream_for` never connects)

- **Today (verified 2026-06-11 against nightly 6703)**: `new WebSocket(url)` from page JS sends `Host`, `User-Agent: Lightpanda/1.0`, `Sec-WebSocket-Key/Version/Protocol`, and cookies — but **no `Origin` header**. RFC 6455 §4.1 (and the WHATWG WebSocket connection algorithm) require browser clients to send the document origin; Chrome/Firefox always do.
- **Real-world impact**: Rails ActionCable's request-forgery protection (`ActionCable::Connection::Base#allow_request_origin?`) accepts a connection only when `Origin` matches the host (`allow_same_origin_as_host`, default ON) or `allowed_request_origins`. With the header absent it logs `Request origin not allowed: nil` and rejects the upgrade (404) before `welcome` → subscriptions never confirm → turbo-rails' `<turbo-cable-stream-source>` never sets `[connected]` → `turbo_stream_for` broadcasts (solid_cable or any adapter) never arrive. Found by the external beta tester (2026-06-11): `have_css "turbo-cable-stream-source[connected]", visible: :all` times out in every Turbo Streams spec.
- **Everything else in the chain verified WORKING on 6703** via standalone repro (real `@hotwired/turbo-rails` 8.0.16 ESM bundle + minimal ActionCable-protocol WS server): custom-element upgrade + `connectedCallback`, ActionCable's `<a>` protocol-swap URL resolution (`/cable` → `ws://…/cable`), subprotocol negotiation (`ws.protocol` echoes `actioncable-v1-json`), welcome → subscribe → confirm_subscription → attribute set, and `querySelectorAll("turbo-cable-stream-source[connected]")` matches. With the same server enforcing the Rails origin check, the failure reproduces exactly (`WS close code=1006`, infinite monitor retries, attribute never set).
- **Want**: send `Origin: <scheme://host[:port] of the executing document>` on the upgrade request — `src/browser/webapi/net/WebSocket.zig` `init` already builds extra headers for `Sec-WebSocket-Protocol` (~line 138) and pulls the document URL for the cookie-jar call (`exec.url`); serialize that origin into one more header.
- **Upstream issue**: #2709, **Upstream PR**: #2710 (open as of 2026-06-12). Fix serializes the document origin via `URL.getOrigin` (`null` for opaque origins, matching Chrome); `origin_on_upgrade` fixture in `src/browser/tests/net/websocket.html` + `get-origin` command in `TestWSServer.zig`. Branch `websocket-origin-header`, worktree `/Users/navid/code/browser-websocket-origin`, reproducer `repro/websocket-origin-header/repro.sh` (exit 1 on main, 0 with fix).
- **Gem workaround**: none possible gem-side (the header is assembled in Zig; page JS cannot set `Origin`). App-side workaround for beta testers: `config.action_cable.disable_request_forgery_protection = true` in `config/environments/test.rb`.
- **Drop-on-fix**: nothing to drop in the gem — remove the app-side workaround advice from beta docs once the floor covers the fix.

### A43. 3xx response without `Location` header aborts navigation (body never rendered, document left empty)

- **Today (verified 2026-06-12 against installed nightly 6703)**: a navigation (tested: native form POST) answered with `303 + HTML body and NO Location header` never renders — the old document is torn down and nothing replaces it, leaving the page with no `<html>` node at all (Capybara: `Unable to find xpath "/html"`). Cause in source: `src/browser/HttpClient.zig` `processOneMessage` (~line 1083) routes **every** 300–399 status into the redirect path, and `handleRedirect` (~line 1888) returns `error.LocationNotFound` when the header is absent. Per RFC 9110 §15.4 and the fetch spec, a 3xx without `Location` is a normal final response whose body must be delivered; Chrome renders it. Control case verified working: `422 + body` renders fine.
- **Real-world impact**: Rails apps render bodies with a 3xx status to satisfy Turbo's "form responses must redirect to another location" check — alonetone's signup success path does exactly `render 'thank_you', layout: 'pages', status: 303`. Found 2026-06-12 adding alonetone to the real-apps suite: `spec/features/account_requests_spec.rb` "submits the form and succeeds" never sees the thank-you page (with Turbo in front the symptom softens to "page stays on the form"). Minimal Ruby-side trigger: Rack app where `POST /submit` → `[303, {"content-type" => "text/html"}, ["<h1>Thank you</h1>"]]`, click the submit button, assert the body — fails; same with 422 passes. (Upstream reproducer must be rebuilt CDP-only per the skill's rules.)
- **Want**: enter the redirect path only when a `Location` header is present; otherwise fall through to the normal "transfer done" path so the body/status/headers are delivered as the final response. Fix shape: in `processOneMessage`, guard the `status >= 300 and status <= 399` branch with `conn.getResponseHeader("location", 0) != null`.
- **Upstream issue**: not yet filed.
- **Gem workaround**: none possible gem-side (redirect handling lives in the Zig HTTP client). The real-apps workflow pins alonetone's spec to the error-render example (`account_requests_spec.rb:4`) to keep the matrix green.
- **Drop-on-fix**: widen `spec:` for the alonetone entry in `.github/workflows/real-apps.yml` back to the whole `account_requests_spec.rb` once `MINIMUM_NIGHTLY_BUILD` covers the fix.

---

## B. Missing CDP / DOM methods

> Resolved B-items (B1–B4, B6, B7, B12) have been removed from this file; numbering is preserved (no renumbering) to keep cross-references stable.

### B5. `Input.dispatchKeyEvent` modifier flags / keyCode / caret movement

Three independent issues:

  1. **`KeyboardEvent.keyCode` and `charCode` legacy attributes** — PARTIALLY FIXED, RESIDUAL ISSUE. **PR #2292 MERGED 2026-04-28** (in nightly ≥5900, by us) implements `keyCode`/`charCode` and adds Enter charCode, BUT gates on `isTrusted: true`. Verified empirically 2026-04-29 against build 5918: events from `Input.dispatchKeyEvent` still report `keyCode: 0` because `isTrusted` is false on synthetic CDP-dispatched events. The Capybara test `node #send_keys should generate key events` asserts on these synthetic events, so it still fails. **Want**: loosen the gate so `Input.dispatchKeyEvent` emits keyCode/charCode regardless of `isTrusted`. Browsers don't normally expose synthetic events with isTrusted=true (it's a security boundary), but CDP-driven test environments are expected to surface the values. Cross-check Chrome: `Input.dispatchKeyEvent` emits events with keyCode populated. **Upstream issue**: not yet filed (was #2291, but that's resolved by #2292 — needs a follow-up issue for the CDP path). Skip pattern `node #send_keys should generate key events` retained.
  2. **`Input.dispatchKeyEvent` for `ArrowLeft`/`ArrowRight`/`Home`/`End` doesn't move the input caret**. Fails `should send special characters` (which uses `:left` to position the cursor mid-string before inserting a char). **Not yet filed.**
  3. **Gem-side bug** (separate — handled in 2b623164): `Capybara::Lightpanda::Keyboard#type` tracks standalone modifier symbols as sticky modifiers. Modifier flags propagate via CDP correctly; this was a Ruby-side state-tracking issue.
- **Gem workaround**: none. Skip-listed: `node #send_keys should send special characters` (#2), `should generate key events` (#1).
- **Drop-on-fix**: remove the `should generate key events` skip pattern when #1 is fully resolved. `should send special characters` requires sub-item (2) to be filed and fixed.

### B8. Datalist option-fill UI not implemented

- **Want**: clicking an option in a `<datalist>`-bound input fills the input.
- **Gem workaround**: none. Skip-listed: `#select input with datalist should select an option`.
- **Drop-on-fix**: remove skip pattern.

### B9. Frame-closed detection insufficient

- **Today**: can't distinguish a closed iframe from a live one within `frame_stack`. `Page.frameDetached` may fire late or not at all.
- **Want**: emit `Page.frameDetached` reliably + expose state via `DOM.describeNode` on the iframe element.
- **Gem workaround**: `lib/capybara/lightpanda/browser.rb` now subscribes to `Page.frame*` events and maintains `@frames` (Concurrent::Hash<id, Frame>). Skip-listed: `#switch_to_frame works if the frame is closed`, `#within_frame works if the frame is closed`.
- **Drop-on-fix**: surface frame-closed state in `Browser#frames` reliably and remove skip patterns.

### B10. `getComputedStyle` cascade resolution incomplete

- **Today**: CSSOM merged (PR #1797) — `checkVisibility` matches all stylesheets, `insertRule`/`deleteRule` work. But `getComputedStyle(el).textTransform` (and other cascade-resolved properties) still resolves only inline styles.
- **Want**: full cascade resolution for `getComputedStyle`.
- **Gem workaround**: none. Skip-listed: `node #style should return the computed style value`, `should return multiple style values`, `#assert_matches_style`, `#matches_style?`, `#has_css? :style option should support Hash`, `#has_css? with count for CSS processing drivers`, `#assert_text should raise if text invisible and incorrect case`.
- **Drop-on-fix**: remove ~7 skip patterns.

### B11. `Node#path` canonical XPath generation differs

- **Status (re-classified 2026-04-27)**: this is a **gem-side fix, not upstream**. Chrome doesn't expose any native `Element.path()` method either — Cuprite implements `path()` entirely in JS at `lib/capybara/cuprite/javascripts/index.js`'s `Cuprite.path(node)` using `document.evaluate('./preceding-sibling::TAG', ...)` and emits `//HTML/BODY/DIV[2]/P[1]`. The gem's current `GET_PATH_JS` (at `lib/capybara/lightpanda/node.rb:700-723`) emits a CSS-like path (`html > body > div:nth-of-type(2) > p`) which is what fails Capybara's `node #path returns xpath which points to itself` spec.
- **Fix**: rewrite `GET_PATH_JS` in the gem to mirror Cuprite's algorithm. The gem already injects an XPath polyfill (`document.evaluate` + `XPathResult`) via `addScriptToEvaluateOnNewDocument`, so the same JS works.
- **Action**: file as a gem-side TODO instead of an upstream PR. Not actionable through this skill.

### B13. `Network.emulateNetworkConditions` not implemented

- **Today (observed 2026-05-15)**: not in the implemented Network methods listed in `lightpanda-io.md`. Decidim's `decidim-dev/lib/decidim/dev/test/rspec_support/network_conditions_helpers.rb#with_browser_in_offline_mode` (lines 3-12) drives the toggle via Selenium's `execute_cdp("Network.emulateNetworkConditions", offline: true, …)`. PWA tests at `decidim-core/spec/system/pwa_features_spec.rb` depend on it.
- **Want**: standard Chrome CDP semantics — offline toggle plus optional latency / download / upload throughput throttles. Aligns with the Network domain Lightpanda already serves (cookies, headers, request lifecycle events).
- **Upstream issue/PR**: not filed. Third Chrome-only CDP method Decidim leans on after `Network.setCookie` (now native) and `Log.entryAdded` (still missing).
- **Gem workaround**: none. Decidim's helper is not callable through this gem as written (uses `execute_cdp`, a Selenium convenience). Captured here as a portability gap for any future Ruby app that wants offline / throttled assertions against Lightpanda.
- **Drop-on-fix**: nothing to remove on the gem side today. Could expose a Ruby surface (`Driver#emulate_network_conditions` mirroring ferrum's `Network#emulate_network_conditions`) once upstream ships.

### B14. Sequential focus navigation — `Tab` doesn't move `document.activeElement` (unblocks `:active_element`)

- **Today (verified 2026-06-11 against `main` HEAD `d695ce10`)**: `Document.getActiveElement` (Document.zig:487) and `HTMLElement.tabIndex` get/set (Html.zig:389-401) work, and **explicit** focus is honored — a JS `el.focus()` (or `fill_in`, which focuses before setting) updates `document.activeElement`, and the gem reads it back faithfully (locked in by `test/features/active_element_test.rb`, 5 examples). What's missing: there is no sequential focus navigation — `Input.dispatchKeyEvent` with `Tab`/`Shift+Tab` does not advance focus to the next/previous element in tabindex + document order. No `Tab` handler walks the focusable set.
- **Want**: implement HTML sequential focus navigation so a synthetic `Tab` moves `document.activeElement` to the next focusable element (firing `blur`/`focus`). No layout needed — focus order is computable from `tabindex` + document order alone.
- **Upstream issue/PR**: issue #2699, PR #2700 (open as of 2026-06-11).
- **Gem workaround**: none. The whole `:active_element` capability stays in `capybara_skip` because Capybara's `#active_element should return the active element` drives focus via `send_keys(:tab)`. The reachable (explicit-focus) slice is covered gem-side by `test/features/active_element_test.rb`.
- **Drop-on-fix**: remove `:active_element` from `capybara_skip` in `spec/features/session_spec.rb` — Capybara's 3 `#active_element` examples then run (2 already pass; the `:tab` one needs this fix). The gem test stays as a finer-grained regression check.

### B15. Multi-window lifecycle — `window.open` is v1, no independent CDP target for Capybara window specs (unblocks `:windows`)

- **Today (verified 2026-06-11 against `main` HEAD `d695ce10`)**: `window.open(url, target, features)` exists in "v1 scope" (Window.zig:507; `_blank` reserved + named-target reuse at :544-545) and `Target.createTarget` exists (target.zig:147). But per `lightpanda-io.md`, sub-pages share the parent's lifetime — there's no distinct second top-level target the CDP client can `attachToTarget` and drive independently. Capybara's `:windows` battery (`#windows`, `#open_new_window`, `#switch_to_window`, `Window#close/#size/#resize_to/#maximize/#fullscreen`, `#within_window`) needs first-class multi-target windows.
- **Want**: each `window.open` (esp. `_blank`) yields a distinct CDP target with `Target.targetCreated`/`targetDestroyed` events and an independent navigation/lifetime. Size/resize/maximize/fullscreen may be no-ops (no layout) but must not raise.
- **Upstream issue/PR**: window.open v1 landed via PR #2237, but a popup is a sibling **Frame** inside the same Page (`Window.open` → `frame.openPopup`, Window.zig:561), **not** a new CDP target. The multi-target gap is **already filed and maintainer-owned — NOT actionable as an outsider PR** (re-verified 2026-06-11 against `main` HEAD `d695ce10`):
  - **Issue #1962 (OPEN)** "Stagehand: `Target.createTarget` fails with `-31998 TargetAlreadyLoaded` on second call" is the tracking issue. Maintainer (krichprollsch) replied 2026-03-23: *"Lightpanda doesn't support multiple targets with the same CDP connection for now... It's a feature we plan to implement in the future, but it's a big task to do and it will take time to release."*
  - **PR #2039 (CLOSED unmerged 2026-03-30)** "fix(cdp): auto-close existing target on createTarget" tried a workaround; maintainer closed it: *"creating new target is on our roadmap. I'm afraid faking the creation by closing/creating new target will drive client in a wrong state since it expects with the feature the previous target is still accessible."* → no acceptable smaller slice.
  - Root cause: `BrowserContext` is 1:1:1 with Session/Page/target — single `target_id: ?[14]u8` + single `session_id` (`CDP.zig:476-510`, comments state it explicitly), `Target.createTarget` rejects a 2nd target with `TargetAlreadyLoaded` (`target.zig:164`) and asserts `!bc.session.hasPage()` (`target.zig:174`). Related symptoms: #1839 (Playwright session-mgmt assertion), #1892 (multiclient: closing one CDP connection kills the others).
- **Gem workaround**: none. The gem's `Driver` implements no window API (only `switch_to_frame`).
- **Drop-on-fix**: implement `Driver#window_handles`/`#switch_to_window`/`#open_new_window`/`#close_window` over CDP `Target`, then remove `:windows` from `capybara_skip`. Both halves (upstream multi-target + gem driver methods) required.

### B16. File downloads not implemented — `Browser.setDownloadBehavior` is a stub, no download events (unblocks `:download`)

- **Today (verified 2026-06-11 against `main` HEAD `d695ce10`)**: `Browser.setDownloadBehavior` is dispatched (browser.zig:73) but its `downloadPath` param is commented out (:77) — nothing is written to disk, and there are no `Page.downloadWillBegin`/`Browser.downloadProgress` events. An `<a download>` click or a `Content-Disposition: attachment` response produces no retrievable file.
- **Want**: honor `Browser.setDownloadBehavior {behavior: 'allow', downloadPath}` (write the response body to disk) and emit `downloadWillBegin`/`downloadProgress(state: completed)` so a client can await + locate the file. No rendering needed.
- **Upstream issue**: #2701 (open as of 2026-06-11). No PR yet — filed issue-first to settle the page-preservation design fork (preserve the current document à la Chrome vs. commit a blank document) before writing the navigation-lifecycle change. Reproducer at `repro/b16-file-downloads/` in the browser repo (exit 1 on nightly + `main` `d695ce10`).
- **Gem workaround**: none. No `Driver` download surface.
- **Drop-on-fix**: wire a `Driver` download path (await `downloadProgress` completed, read the file) + remove `:download` from `capybara_skip`.

### B17. `:has()` rejects relative selector arguments (`:has(~ .x)`, `:has(> .x)`) — valid CSS Level 4 throws SyntaxError

- **Today (verified 2026-06-12 against dev build `1.0.0-dev.6709+d695ce10`, fetch-mode probe + source)**: plain sibling combinators (`~`, `+`) and non-relative `:has()` arguments all work — `.a ~ .b`, `li:has(span)`, and even `ul:has(.a ~ .b)` match correctly. But a `:has()` argument that *starts* with a combinator throws `SyntaxError: The string did not match the expected pattern`, which the gem rewraps as `Capybara::Lightpanda::InvalidSelector`. Two halves to the gap:
  1. **Parser** — every selector (including `:has()` arguments, parsed by the full selector parser at `src/browser/webapi/selector/Parser.zig:520-545`) must begin with a compound; a leading `~`/`+`/`>` hits `error.InvalidSelector` (`Parser.zig:201-202`; `parsePart()` at :290-318 has no combinator-start arm).
  2. **Matcher** — `:has()` matching at `src/browser/webapi/selector/List.zig:685-706` only searches *descendants*, so even with the parse relaxed, sibling-anchored semantics (`:scope ~ …`) aren't implemented.
- **Real-world impact**: reported by a gem user (2026-06-12) with the Bootstrap list-group idiom `.list-group-item:not(.active):has(~ .list-group-item.active)` ("non-active items before the active one"). Chrome, Firefox, and Safari all accept relative `:has()` — any selector copied from a working Chrome/cuprite suite fails as `InvalidSelector` on lightpanda.
- **Want**: per [Selectors Level 4 §relational pseudo-class](https://drafts.csswg.org/selectors-4/#relational), `:has()` takes a `<relative-selector-list>` — each argument anchored at `:scope` (the element being matched), with an implied descendant combinator when none is given and explicit leading `>`/`~`/`+` allowed. Fix shape, both localized: parser accepts a leading combinator inside `:has()` (inject an implicit `:scope` first compound); matcher anchors evaluation at the candidate element — descendant search for the default case (current behavior), following-sibling walk for `~`, next sibling for `+`, children for `>`. No layout dependency.
- **Upstream issue**: #2711, **Upstream PR**: #2712 (open as of 2026-06-12). Fix absolutizes each `:has()` argument at parse time (`:has(~ .a)` stored as `:scope ~ .a`) and matches with `:scope` bound to the anchor element; also fixes the latent ancestor-false-positive (`div:has(span p)` matching a `span` above the anchor). Fixture: `src/browser/tests/document/query_selector_has.html`; unit test `Selector: Parser.has`.
- **Gem workaround**: none possible — selector strings come verbatim from user code through Capybara, and rewriting `:has(~ …)` gem-side would require a CSS selector parser plus semantics changes. Documented advice for affected users: rewrite to XPath (`following-sibling::`, evaluated natively since PR #2305) or filter in Ruby.
- **Drop-on-fix**: nothing gem-side to remove — purely unblocks user-written selectors that currently raise `InvalidSelector`. Add a selector regression test once `MINIMUM_NIGHTLY_BUILD` covers the fix.

---

## C. Inherent limitations (out of scope — keep cuprite for these)

These exist because Lightpanda has no rendering engine, no compositor, no real layout. They are by design — running cuprite for the visual lane is the documented answer.

### C1. No real screenshots
- `Page.captureScreenshot` returns a 1920×1080 PNG (hardcoded dimensions, no actual rendering).
- **Status**: out of scope. Use cuprite for visual specs.

### C2. No real layout / no `getBoundingClientRect` geometry
- Returns deterministic but not pixel-accurate values.
- Affects: `node #obscured?` (viewport, overlap), click coordinates, click offsets, click modifiers.
- **Skip-listed**: 9 patterns under `node #click`/`#double_click`/`#right_click` for offsets/modifiers, `node #obscured?` viewport tests, `#all with obscured filter` outside-viewport tests.
- **Status**: out of scope.

### C3. Scroll position tracked but not layout-clamped; no resize (`:scroll`)
- Updated 2026-06-11: `window.scrollTo`/`scrollBy` now track `window._scroll_pos` (and fire `scroll`/`scrollend`), and `Element` exposes `scrollTop`/`scrollLeft`/`scrollIntoView` (Window.zig:722 / Element.zig:1523) — so *position* scroll is readable. But there's no content-height clamping (`scrollHeight`/`clientHeight` are a hardcoded 1e8), element scroll is decoupled from window scroll, and `getBoundingClientRect` isn't scroll-aware (no layout). `window.resizeTo` is a no-op.
- Capybara's `#scroll_to` battery needs `:bottom`/`:center` clamping and element-relative alignment — both require real layout — so the gem keeps `Node#scroll_to`/`scroll_by` as no-ops and `:scroll` stays in `capybara_skip`. The position-scroll slice is reachable via `execute_script('window.scrollTo(...)')` if a caller truly needs it.
- **Status**: out of scope (clamping + alignment need layout).

### C11. CSS `:hover` state not tracked — reveal-on-hover doesn't work (`:hover`)
- The gem's `Node#hover` dispatches a real `mouseover` event and JS `mouseover` listeners DO fire (locked in by `test/features/hover_test.rb`). But there is no pointer-hover state, so the CSS `:hover` pseudo-class never matches — `.box:hover .hidden { display: block }` reveals stay hidden. Capybara's `#hover` example asserts exactly that reveal, so `:hover` stays in `capybara_skip`.
- **Status**: borderline-inherent — interaction-driven CSS, the same class the maintainer declined for `@media`/external stylesheets (C10). Tracking a hovered-element set on `mouseover`/`mouseout` (no coordinates needed) would be *implementable* without layout, but is low-confidence to land upstream. Filed here as a candidate, not a commitment. The event-dispatch half already has gem coverage.

### C4. `Page.getLayoutMetrics` returns hardcoded 1920×1080
- No real layout to measure.
- `window.innerWidth`/`innerHeight` may not reflect emulation settings.
- **Status**: out of scope.

### C5. `Page.printToPDF` returns fake PDF (PR #2197)
- Marked as implemented but returns a placeholder.
- **Status**: out of scope unless real layout lands.

### C6. Visual regression / pixel diffs
- Built on real screenshots. Out of scope.

### C7. Service Workers, WebAuthn, SharedArrayBuffer
- Browser-engine territory. Out of scope.

### C8. `localStorage` / `sessionStorage` persistence across sessions
- Each session starts fresh (in-process state).
- **Status**: out of scope.

### C9. CORS not enforced
- Acknowledged in upstream README. Tests can request anywhere.
- **Status**: not relevant for testing context.

### C10. External CSS not fetched, `@media` not evaluated, `matchMedia()` always false (verified 2026-05-15)
- **Confirmed by upstream maintainer (2026-05-15)** as an intentional design choice: Lightpanda is a headless agentic-AI / scraping browser, not a layout engine. Skipping external CSS fetch + media-query evaluation is a deliberate cost trade-off and an upstream PR adding them won't be accepted.
- Concrete observed behavior on installed nightly:
  - `<link rel="stylesheet" href="…">` → `link.sheet === null`, `document.styleSheets.length === 0` indefinitely (no fetch, no CSSOM entry). Selectors that live in linked stylesheets render with UA defaults only.
  - `@media` blocks inside inline `<style>` parse into `cssRules` (type code `4` = `MEDIA_RULE`) but expose as the generic `CSSRule` base — `rule.media`, `rule.cssRules`, `rule.conditionText` are all absent. The contained declarations are never applied to the cascade regardless of query.
  - `window.matchMedia(q).matches === false` for EVERY query, including `'all'`, `'screen'`, `'(min-width: 1px)'`.
- **Gem impact**: any responsive UI that hides one of two mobile/desktop CTA duplicates via `@media (min-width: …) { display: none }` will report BOTH variants as visible. Surfaces in Capybara as `Capybara::Ambiguous: found 2 elements matching "…"`. Hit hard by Decidim authentication specs and Spree confirm dialogs during the 2026-05-15 real-app smoke run.
- **No gem-side workaround.** Reimplementing the CSS cascade in JS would need a CSS parser, sync access to remote stylesheets, and a real media-query evaluator. Out of scope.
- **Status**: out of scope upstream AND in this gem. The documented answer is the dual-driver pattern — run cuprite (or Selenium-Chrome) for any spec whose visibility assertions depend on responsive CSS or external stylesheets; keep the rest on lightpanda for speed.

---

## D. Drop-on-fix LOC tally

If the remaining open / unfiled items in section A + B land upstream, the gem can shed roughly:

| Item | LOC saved | Reason |
|---|---|---|
| **A23 — `Element.innerText` block-level newlines** | ~50 | `_lightpanda.visibleText` polyfill |
| **A36 — `readystatechange` never fires** | ~7 | `index.js` shim re-dispatching from DOMContentLoaded / load |
| **A10 — Page.loadEventFired fallback** | ~20 | Simplify (keep readyState as safety net) |
| **B5#1, B5#2 — keyCode/charCode + caret keys** | 2 skip patterns | Synthetic CDP keyboard events need keyCode populated; ArrowLeft/Home/End need to move the input caret |
| **B8, B9, B10 — datalist + frame-closed + getComputedStyle cascade** | ~10 skip patterns | Removes spec_helper entries |
| **Bug #9 — `requestSubmit()` cancel throws** | ~5 | `try { … } catch` wrap in CLICK_JS |
| **Bug #10 — `Runtime.evaluate` scope leak** | ~10 | IIFE wrap + `exceptionDetails` surfacing in `Browser#evaluate`/`#execute` no-args paths |

A11 (`with_default_context_wait`) and A12 (`handle_navigation_crash`) are **NOT in this table** — both are defense-in-depth guards against inherent design constraints (V8 context churn around navigation; any browser crash mid-CDP) and stay regardless of upstream state. See their A-entries above.

**Total remaining drop-on-fix surface**: roughly **~90 LOC of gem-side code** plus ~14 spec_helper skip patterns. The largest single item is A23 (`innerText` block-level newlines, ~50 LOC); A10 (`Page.loadEventFired` fallback simplification, ~20 LOC) and A36 (`readystatechange` shim, ~7 LOC) follow.

---

## Quick wins (for upstream contributors)

### Open PRs awaiting upstream review (filed by us)

See each open A/B entry's **Upstream issue/PR** line for current filing status.

### Unfiled items most worth claiming (need authors)

Listed by drop-on-fix impact / spec-compliance importance. Items A11 and A12 (closed-issue defensive helpers) and B11 (re-classified gem-side) are intentionally excluded.

1. **A23 — `Element.innerText` block-level line breaks** — ~50 LOC drop-on-fix; multi-day Zig project (writer needs `getComputedStyle` access from inside the walker, plus the line-collapsing pass). Highest single-item LOC saving among open items, but the most expensive to implement.
2. **A10 — `Page.loadEventFired` reliability (#1801)** — ~20 LOC drop-on-fix; long-standing, still open. Keep the gem's readyState fallback as a safety net even after a fix lands (cheap), but the 2-second cap could be retired.
3. **B5#1 — `KeyboardEvent.keyCode` gated on `isTrusted`** — PR #2292 implemented `keyCode`/`charCode` but gates on `event._is_trusted == false → return 0` (verified at `src/browser/webapi/event/KeyboardEvent.zig:383`). Single skip pattern (`node #send_keys should generate key events`); needs the gate loosened for synthetic `Input.dispatchKeyEvent` per Chrome's CDP behavior.
4. **B5#2 — Caret-movement keys (`ArrowLeft`/`Home`/`End`) don't move input caret** — single skip pattern; not yet filed as an issue.
5. **B13 — `Network.emulateNetworkConditions` not implemented** — Decidim's PWA / offline test helper drives `execute_cdp("Network.emulateNetworkConditions", offline: true, …)`. Third Chrome-only CDP method Decidim leans on after `Network.setCookie` (native) and `Log.entryAdded` (still missing). Not blocking gem consumers today; documents the gap for any future portability work.
6. **B14 — Sequential focus navigation (`Tab` moves `document.activeElement`)** — unblocks `:active_element`. **Cheap + high-confidence**: no layout needed (focus order = tabindex + document order), and the explicit-focus half already works and is gem-tested. Closest in shape to a self-contained DOM-behavior PR.
7. **B16 — File downloads (`Browser.setDownloadBehavior` path + `downloadWillBegin`/`downloadProgress`)** — unblocks `:download`. The CDP method is already a dispatched stub; needs the disk write + two events. No rendering required. **Upstream issue**: #2701 (filed 2026-06-11, issue-first; awaiting maintainer's call on the page-preservation design before a PR).
8. **B15 — Independent multi-window targets for `window.open`/`_blank`** — unblocks `:windows`. Larger: upstream multi-target maturity *plus* gem-side `Driver` window methods. window.open v1 already landed (PR #2237).
9. **C11 — CSS `:hover` state (low confidence)** — would unblock `:hover`'s reveal half, but it's interaction-driven CSS in the same class the maintainer declined for `@media` (C10). The mouseover-dispatch half already works and is gem-tested.
10. **B17 — relative selectors in `:has()`** (`:has(~ .x)` / `:has(> .x)`) — **cheap + high-confidence**: parser + matcher changes both localized (`Parser.zig` / `List.zig`), no layout dependency, and the non-relative `:has()` machinery already exists to build on. Hit by a real user selector (Bootstrap list-group idiom); every evergreen browser supports it. **FILED 2026-06-12**: issue #2711 + PR #2712 (open).
11. **A36 — fire `readystatechange` at document on readiness changes** — by impact this belongs near the top (it's what kept Turbo's `turbo:load` from ever firing for the first external beta tester), though it's listed last here. Tiny, layout-free fix: dispatch the event wherever readiness flips, next to the existing `DOMContentLoaded` emit. ~7 LOC drop-on-fix in `index.js` + instant Turbo-ecosystem win. **FILED 2026-06-11**: issue #2707 + PR #2708 (open).

Each Turbo-driven bug from the 2026-05-04 → 2026-05-06 wave below (#9, #10) is also unfiled but has been deferred — their fix patterns are well-understood from the gem-side workarounds but no upstream maintainer conversation has started yet.

### New bugs not yet folded into this wishlist (discovered 2026-05-04 → 2026-05-06 via Turbo Drive probes)

Tracked in `UPSTREAM_BUGS.md` at gem root (Bug #9, #10). Each has a gem-side workaround in `node.rb` / `browser.rb` waiting on an upstream fix:

- **Bug #9 — `requestSubmit()` throws when a listener cancels the SubmitEvent** — HTML §4.10.21.5 step 5 says it must return silently when cancelled. Lightpanda throws `JsException`. Gem workaround: `try { this.form.requestSubmit(this); } catch (e) {}` around `CLICK_JS`'s submit path.
- **Bug #10 — `Runtime.evaluate` retains `const`/`let` top-level bindings between CDP calls** — V8 spec says each `Runtime.evaluate` runs in a fresh script; Lightpanda shares the scope so a second `const x = ...` throws `SyntaxError: Identifier 'x' has already been declared`. Gem workaround: wrap every no-args `evaluate(expr)` / `execute(expr)` in an IIFE on the Ruby side + surface `exceptionDetails`.

## What this gem won't ever fix (run cuprite)

- Real screenshots / pixel diffs / visual regression
- Layout-dependent tests (scroll, resize, real geometry)
- Service Workers, WebAuthn, SharedArrayBuffer
- Anything requiring a compositor

The dual-driver pattern (`BROWSER=lightpanda` env gate + cuprite fallback) documented in the gem's README is the answer for these.
