# Lightpanda Upstream Wishlist

What `capybara-lightpanda` patches around because of upstream gaps in
[lightpanda-io/browser](https://github.com/lightpanda-io/browser).

Each entry has:
- **Today** — actual behavior on current public nightly (build ≥ 6167 as of 2026-05-12) and against the gem's enforced floor `MINIMUM_NIGHTLY_BUILD = 6109`. Where verified against a different build, the entry calls it out.
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

> Items A1–A9, A13–A21, A24–A35 have all been resolved (or retracted as gem misdiagnoses) — see section D for the historical record. **A11 and A12 are kept as gem-side documentation only**: their tracking issues closed upstream but the gem retains the helpers as defense-in-depth (the underlying race + crash classes are inherent to the design). Numbering preserved to keep cross-references stable.

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

### A41. CDP wire frames embed raw `undefined` token (invalid JSON)

- **Today (observed 2026-05-15 against installed nightly during Decidim smoke run; reproducible per page load)**: a CDP reply payload near the `sessionId` field serializes a JavaScript `undefined` value as the bare token `undefined` instead of valid JSON `null` (or omitting the key). Each Decidim system spec triggers ~4 of these, surfaced by the gem's WebSocket `JSON.parse` rescue:
  ```
  Failed to parse WebSocket message: unexpected character: 'undefined}]},"sessionId":"SID-N"' at line 1 column ~800
  ```
  The 800-column hint points to a multi-target / multi-context payload — likely `Target.targetInfoChanged` or `Runtime.executionContextCreated` for the auxiliary contexts Decidim creates (it runs multi-tenant via `switch_to_host`).
- **Want**: emit `null` (or omit the key) wherever a value is `undefined`. JSON has no `undefined` literal — the current frame is unparseable by any strict CDP client (Playwright, Puppeteer would crash here; our gem rescues + drops).
- **Upstream issue/PR**: not yet filed. Capturing one offending raw frame via `LIGHTPANDA_LOG_LEVEL=debug` is the prerequisite — without the exact CDP method we can't point the maintainer at a Zig serializer site.
- **Gem workaround**: `lib/capybara/lightpanda/client/web_socket.rb#parse_message` catches `JSON::ParserError` and returns `nil`. Currently flooded with one `warn` per frame; deduped (warn once per unique error message per WebSocket instance) so a single occurrence still surfaces but doesn't drown other test output.
- **Drop-on-fix**: nothing strictly removable on the gem side — the `JSON::ParserError` rescue stays as defense-in-depth for future malformed frames. The visible win is the disappearance of the warning under normal use and parity with strict-JSON CDP clients.

---

## B. Missing CDP / DOM methods

> Items B1–B3, B6, B7 have all been resolved — see section D for the historical record. Numbering preserved to keep cross-references stable.

### B4. `<input type=file>` / `Page.setFileInputFiles` not implemented (#2175)

- **Want**: file upload support.
- **Gem workaround**: `Node#set` raises `NotImplementedError` for file inputs. Skip-listed: 26 `#attach_file` specs.
- **Drop-on-fix**: implement `Node#set_file` using `Page.setFileInputFiles`. Removes 26 skip patterns.

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

### B12. `HTMLDialogElement.prototype.{showModal, show, close}` not implemented

- **Today (re-verified 2026-05-12 against `main` HEAD `8cad175c` / nightly ≥6167; full repro in `spec/features/upstream_bugs_spec.rb` "Bug #4 — HTMLDialogElement polyfill" + `UPSTREAM_BUGS.md` Bug #4)**: the `HTMLDialogElement` constructor exists, plus `getOpen`/`setOpen` and `getReturnValue`/`setReturnValue` accessors at `src/browser/webapi/element/html/Dialog.zig:22-44`, but `prototype.showModal`, `prototype.show`, `prototype.close` are still `undefined`. Calling any of them throws `TypeError: d.showModal is not a function`. Blocks any UI built on the native `<dialog>` element (very common in Rails 8 + DaisyUI / Tailwind UI / shadcn). **Good news**: the file already exists with the right structure — just need to add the three methods + the `'close'` event dispatch.
- **Want**: per [HTML §4.11.4 "The dialog element"](https://html.spec.whatwg.org/multipage/interactive-elements.html#the-dialog-element), implement on `HTMLDialogElement.prototype`:
  - `show()` — adds the `open` content attribute if not already set; non-modal display.
  - `showModal()` — throws `InvalidStateError` if `[open]` is already present; otherwise sets `[open]` and (in Chrome) adds the dialog to the top layer + sets a backdrop. Lightpanda has no rendering so the focus-trap / backdrop / top-layer can be no-ops, but `[open]` MUST flip and the dialog MUST become visible to selectors.
  - `close([returnValue])` — removes `[open]`, sets `returnValue` if argument given, queues a `close` event.
  - `returnValue` getter/setter, `cancel` event on Esc (Esc handling is out of scope without input events).
- **Upstream issue**: #2434 (open as of 2026-05-12). **Upstream PR**: #2435 (open as of 2026-05-12). Mirrors the shape of `HTMLFormElement.prototype.requestSubmit` (PR #2253, merged 2026-04-27) — single Zig file under `src/browser/webapi/element/html/`, ~3 prototype methods, no V8/CDP-runtime entanglement. Probably the smallest discrete missing-API gap in the gem.
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/polyfills.js:8-36` (~30 LOC) — adds `showModal` (with `InvalidStateError` parity), `show`, `close([returnValue])` on the prototype. Toggles `[open]` and dispatches a `'close'` event. No focus trap, no backdrop, no top-layer (Lightpanda has no layout anyway).
- **Drop-on-fix**: remove the dialog block from `polyfills.js`. ~30 LOC. The spec test in `spec/features/upstream_bugs_spec.rb` becomes a regression check for the upstream implementation.

### B13. `Network.emulateNetworkConditions` not implemented

- **Today (observed 2026-05-15)**: not in the implemented Network methods listed in `lightpanda-io.md`. Decidim's `decidim-dev/lib/decidim/dev/test/rspec_support/network_conditions_helpers.rb#with_browser_in_offline_mode` (lines 3-12) drives the toggle via Selenium's `execute_cdp("Network.emulateNetworkConditions", offline: true, …)`. PWA tests at `decidim-core/spec/system/pwa_features_spec.rb` depend on it.
- **Want**: standard Chrome CDP semantics — offline toggle plus optional latency / download / upload throughput throttles. Aligns with the Network domain Lightpanda already serves (cookies, headers, request lifecycle events).
- **Upstream issue/PR**: not filed. Third Chrome-only CDP method Decidim leans on after `Network.setCookie` (now native) and `Log.entryAdded` (still missing).
- **Gem workaround**: none. Decidim's helper is not callable through this gem as written (uses `execute_cdp`, a Selenium convenience). Captured here as a portability gap for any future Ruby app that wants offline / throttled assertions against Lightpanda.
- **Drop-on-fix**: nothing to remove on the gem side today. Could expose a Ruby surface (`Driver#emulate_network_conditions` mirroring ferrum's `Network#emulate_network_conditions`) once upstream ships.

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

### C3. No scroll, no resize
- `window.scrollTo`, `element.scrollIntoView`, `window.resizeTo` all no-op.
- **Status**: out of scope (no layout).

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
| **B12 — `HTMLDialogElement` methods** | ~30 | Dialog block in `polyfills.js` |
| **A10 — Page.loadEventFired fallback** | ~20 | Simplify (keep readyState as safety net) |
| **Bug #7 residual — `enctype` + 5 submitter IDL overrides** | ~40 | `patchFormIDL` IIFE can be removed once `enctype` getter + submitter overrides land |
| **B4 — file uploads** | adds ~30, removes 17 skips | Net positive: enables a feature |
| **B5#1, B5#2 — keyCode/charCode + caret keys** | 2 skip patterns | Synthetic CDP keyboard events need keyCode populated; ArrowLeft/Home/End need to move the input caret |
| **B8, B9, B10 — datalist + frame-closed + getComputedStyle cascade** | ~10 skip patterns | Removes spec_helper entries |
| **Bug #9 — `requestSubmit()` cancel throws** | ~5 | `try { … } catch` wrap in CLICK_JS |
| **Bug #10 — `Runtime.evaluate` scope leak** | ~10 | IIFE wrap + `exceptionDetails` surfacing in `Browser#evaluate`/`#execute` no-args paths |

A11 (`with_default_context_wait`) and A12 (`handle_navigation_crash`) are **NOT in this table** — both are defense-in-depth guards against inherent design constraints (V8 context churn around navigation; any browser crash mid-CDP) and stay regardless of upstream state. See their A-entries above.

**Resolved since prior tally** (no longer counts toward future drop-on-fix):

| Item | LOC saved | When |
|---|---|---|
| **A1 + A2 + B3 — cookie clearing** | ~50 | DONE 2026-04-27 (PR #2255 + gem cleanup) |
| **A8 — `#id` rewriter** | ~60 | DONE 2026-04-27 (PR #2244 + gem polyfill removed) |
| **A4 + A5 — form.submit / document.write** (gem-side cleanup) | ~167 | DONE 2026-04-28 (`CLICK_JS` slim, `IMPLICIT_SUBMIT_JS` slim, regression block dropped) |
| **A14 — requestSubmit polyfill** | ~20 | DONE pre-2026-04-28 |
| **A20 — formaction/formmethod/formenctype** | bundled with A4 | DONE 2026-04-28 (PR #2279 + gem cleanup) |
| **A6, A7, A15, A16, A17, B7 — assorted skip patterns** | 9 patterns | DONE 2026-04-28 (PRs all merged + spec_helper cleaned) |
| **A18 — Referer header** | 4 skip patterns | DONE 2026-04-28 → bumped past floor (PR #2283) |
| **A21 — `:disabled` inheritance** | ~28 → ~10 (kept for `<option>` Cuprite-parity) | DONE 2026-04-29 (PR #2315 + gem cleanup) |
| **A24 — UA stylesheet display:none** | ~20 | DONE 2026-04-29 (PR #2294 + `_lightpanda.isVisible` slimmed) |
| **A25 — `<input type=image>` submit** | ~5 | DONE 2026-04-29 (PR #2312 + `CLICK_JS` branch dropped) |
| **A26 — Textarea CRLF normalization** | 2 skip patterns | DONE 2026-04-29 (PR #2308 + spec_helper cleaned) |
| **A29 — `<summary>` toggles `<details>`** | ~6 | DONE 2026-05-04 (maintainer's PR #2342/#2347 — ours #2326 closed; gem `CLICK_JS` branch dropped) |
| **B6 — Constraint validation API** | 2 skip patterns | DONE 2026-05-01 (PR #2286 + `:html_validation` flag removed) |
| **A30 — `pattern` IDL + `patternMismatch`** | 1 skip pattern | DONE 2026-05-04 (PR #2352, bundled with the B6 flag removal) |
| **A33 — `dispatchEvent` listener-throw halts dispatch** | ~45 | DONE 2026-05-06 (PR #2368 + `patchDispatch` IIFE removed; `CLICK_JS` MouseEvent dispatch retained for Turbo compat, not as A33 workaround) |
| **B1 — XPath evaluator** | ~700 | DONE 2026-05-11 (PR #2305 + `XPathEval` IIFE removed; `MINIMUM_NIGHTLY_BUILD` bumped to 6109) |
| **B2 — Page.getNavigationHistory** | ~5 + CLAUDE.md note | DONE 2026-05-11 (PR #2289 + `Browser#back`/`#forward` switched to native CDP) |
| **A22 — `Element.isContentEditable`** | NOT a drop-on-fix anymore | PR #2310 MERGED 2026-04-30 but the maintainer rewrote the implementation to always return `false` (commit `2af95af6`). Polyfill remains load-bearing — see A22 above. |
| **Bug #6 — `fetch`/`XHR` FormData multipart encoding** | 0 (no gem-side polyfill existed) | DONE 2026-05-06 (PR #2358). Turbo Drive form submits started working as soon as the nightly carrying the fix was installed. |
| **Bug #8 — listener lifecycle during dispatch** | ~50 | DONE 2026-05-11 (commit `8d5eef44` "Improve events" — dedup check in `register` now skips `removed=true` entries; `patchListenerLifecycle` IIFE removed from `polyfills.js`). First nightly carrying the fix: ≥6198. Verified 2026-05-13 on build `1.0.0-dev.6200+198c4e5a` via direct-CDP probe (no polyfill injected). |
| **A11 + A12 — defensive helpers** | NOT drop-on-fix | Issues closed (#2187 2026-05-04, #1849 2026-03-16) but helpers stay as defense-in-depth — see A-entries above. |
| **A34 — `getBoundingClientRect()` zero rect for `display:none`** | NOT A BUG | Retracted 2026-05-13 after probe verified `getBoundingClientRect()` already returns `DOMRect{0,0,0,0}` for every `display:none` case (inline, stylesheet, ancestor, `[hidden]`, descendants thereof) on installed nightly 6198 + main HEAD. Karl Seguin added the zero-rect short-circuit in `^a9b9cf14` on 2026-03-15 (`src/browser/webapi/Element.zig:1196-1207`); the gem's `_lightpanda.isObscured` comment ("Lightpanda returns a fake bounding rect…") was empirically stale by two months. Gem-side: the `style.display === 'none'` short-circuit at `javascripts/index.js:130` is dead code — `r.width === 0 \|\| r.height === 0` at line 138 already catches it. `visibility:hidden` short-circuit at line 131 stays (visibility takes a box). |
| **A35 — `getComputedStyle(el).display` cascade resolution** | NOT A BUG | Retracted 2026-05-13. Empirical verification: `getComputedStyle(descendant-of-display-none-ancestor).display === 'block'` is Chrome behavior, not a Lightpanda gap — per CSSOM the resolved value of `display` is the element's own value, not its ancestor's. Probe confirmed: descendants of `display:none` and `[hidden]` ancestors get the correct zero rect from `getBoundingClientRect()` (via `StyleManager.isHidden` ancestor walk in `src/browser/StyleManager.zig:202-235`), and `el.checkVisibility()` correctly returns false. Gem-side: the `offsetParent === null` fallback at `_lightpanda.isVisible:116-117` and the `[hidden]` ancestor walk at `_lightpanda.isObscured:132-136` are both dead defensive code now that `checkVisibility()` is correctly implemented and `getBoundingClientRect()` zeros hidden elements. |

**Total remaining drop-on-fix surface (2026-05-13 re-tally)**: roughly **~155 LOC of gem-side code** plus ~14 spec_helper skip patterns. Of what remains, A23 (`innerText` block-level newlines, ~50 LOC) is the largest single item; Bug #7's residual `enctype` + submitter overrides (~45 LOC) and B12 (`HTMLDialogElement` methods, ~30 LOC) round out the actionable top-3.

---

## Quick wins (for upstream contributors)

### Open PRs awaiting upstream review (filed by us)

None — the 10 PRs that were open at the time of the prior tally (A18 #2283, A21 #2315, A24 #2294, A25 #2312, A26 #2308, A30 #2352, B1 #2305, B2 #2289, B6 #2286, plus our closed-then-superseded A29 #2326) all landed between 2026-04-28 and 2026-05-11. The big-bang gem cleanup ride along that wave was the ~700-LOC XPath polyfill removal in commit `94a4120`.

### Unfiled items most worth claiming (need authors)

Listed by drop-on-fix impact / spec-compliance importance. Items A11 and A12 (closed-issue defensive helpers) and B11 (re-classified gem-side) are intentionally excluded.

1. **B12 — `HTMLDialogElement.{showModal, show, close}`** — ~30 LOC drop-on-fix. **TOP PICK.** The constructor + `open`/`returnValue` accessors already exist in `src/browser/webapi/element/html/Dialog.zig` (verified 2026-05-12). Just need to add the three prototype methods + `close` event dispatch. Mirrors `HTMLFormElement.prototype.requestSubmit` shape exactly (PR #2253). No layout/compositor entanglement — focus-trap and backdrop are no-ops in a headless engine.
2. **Bug #7 (residual) — `HTMLFormElement.enctype` IDL + 5 submitter overrides** — ~40 LOC drop-on-fix when bundled with the gem-side polyfill removal. Tiny upstream PR: same pattern as the existing `getMethod`/`getAction`/`getTarget` accessors at Form.zig:58-111. Submitter side (`formEnctype`/`formMethod`/`formAction`/`formTarget`/`formNoValidate`) lives in HTMLButton.zig + HTMLInput.zig and reflects the corresponding HTML attributes. Bundling all six in one PR is the right shape — Turbo's `FormSubmission` constructor reads them all together. **Upstream issue**: #2449, **Upstream PR**: #2450 (open as of 2026-05-13).
3. **A23 — `Element.innerText` block-level line breaks** — ~50 LOC drop-on-fix; multi-day Zig project (writer needs `getComputedStyle` access from inside the walker, plus the line-collapsing pass). Highest single-item LOC saving among open items, but the most expensive to implement.
4. **A10 — `Page.loadEventFired` reliability (#1801)** — ~20 LOC drop-on-fix; long-standing, still open. Keep the gem's readyState fallback as a safety net even after a fix lands (cheap), but the 2-second cap could be retired.
5. **B4 — `<input type=file>` / `Page.setFileInputFiles` (#2175)** — adds ~30 gem LOC, removes 17 `#attach_file` skip patterns. Net positive: enables a feature.
6. **B5#1 — `KeyboardEvent.keyCode` gated on `isTrusted`** — PR #2292 implemented `keyCode`/`charCode` but gates on `event._is_trusted == false → return 0` (verified at `src/browser/webapi/event/KeyboardEvent.zig:383`). Single skip pattern (`node #send_keys should generate key events`); needs the gate loosened for synthetic `Input.dispatchKeyEvent` per Chrome's CDP behavior.
7. **B5#2 — Caret-movement keys (`ArrowLeft`/`Home`/`End`) don't move input caret** — single skip pattern; not yet filed as an issue.
8. **A41 — CDP frames embed bare `undefined` token (invalid JSON)** — surfaces as ~4 `Failed to parse WebSocket message…` warnings per Decidim system spec; the gem's `JSON::ParserError` rescue drops the frame, so functionally the test passes, but a strict-JSON CDP client (Playwright, Puppeteer) would crash. Filing requires a captured raw frame via `LIGHTPANDA_LOG_LEVEL=debug` first — the column-800 hint suggests it's a multi-target / multi-context payload (`Target.targetInfoChanged` or `Runtime.executionContextCreated`).
9. **B13 — `Network.emulateNetworkConditions` not implemented** — Decidim's PWA / offline test helper drives `execute_cdp("Network.emulateNetworkConditions", offline: true, …)`. Third Chrome-only CDP method Decidim leans on after `Network.setCookie` (native) and `Log.entryAdded` (still missing). Not blocking gem consumers today; documents the gap for any future portability work.

Each Turbo-driven bug from the 2026-05-04 → 2026-05-06 wave below (#9, #10) is also unfiled but has been deferred — their fix patterns are well-understood from the gem-side polyfills but no upstream maintainer conversation has started yet. (Bug #8 was fixed upstream 2026-05-11 without us filing — see the resolved-since-prior-tally table above.)

### New bugs not yet folded into this wishlist (discovered 2026-05-04 → 2026-05-06 via Turbo Drive probes)

Tracked in `UPSTREAM_BUGS.md` at gem root. Each has a gem-side polyfill in `polyfills.js` waiting on upstream fix. Need wishlist entries (suggest A36–A40 — A34/A35 are consumed as retractions in section D):

- **~~Bug #6~~ — FormData multipart encoding — FIXED upstream 2026-05-06** by PR #2358 ("net: multipart-encode FormData bodies in fetch and XMLHttpRequest"). No gem-side polyfill existed (encoding lives in Zig), so nothing to drop on the gem side — Turbo Drive form submits started working as soon as the nightly carrying #2358 was installed. Build floor for the fix: nightly ≥ ~6090.
- **Bug #7 — Form IDL accessors — PARTIALLY FIXED upstream**. `HTMLFormElement.{method, action, target, name, acceptCharset}` accessors landed 2026-03-15 (`src/browser/webapi/element/html/Form.zig:208-211`) — predating when we filed this bug from the gem side; the polyfill's `name in proto` guard means those branches were already auto-no-op. **Still missing upstream**: `HTMLFormElement.enctype` getter (the property Turbo's `FormSubmission` constructor actually fetches first); the entire submitter side — `formEnctype`/`formMethod`/`formAction`/`formTarget`/`formNoValidate` on `HTMLButtonElement` and `HTMLInputElement`. These are what keep `patchFormIDL` IIFE (~70 LOC) load-bearing in `polyfills.js`. **Filed 2026-05-13**: issue #2449 + PR #2450 (open).
- **~~Bug #8~~ — `addEventListener` during capture-phase invisible to in-flight bubble-phase — FIXED upstream 2026-05-11** by commit `8d5eef44` ("Improve events"). The dedup check in `register` now skips `removed=true` entries, so the remove+add-during-capture idiom appends a fresh listener visible to the in-flight bubble phase. Verified 2026-05-13 on build `1.0.0-dev.6200+198c4e5a` via direct-CDP probe; `patchListenerLifecycle` IIFE (~50 LOC) removed from `polyfills.js`. First nightly carrying the fix: ≥6198.
- **Bug #9 — `requestSubmit()` throws when a listener cancels the SubmitEvent** — HTML §4.10.21.5 step 5 says it must return silently when cancelled. Lightpanda throws `JsException`. Gem workaround: `try { this.form.requestSubmit(this); } catch (e) {}` around `CLICK_JS`'s submit path.
- **Bug #10 — `Runtime.evaluate` retains `const`/`let` top-level bindings between CDP calls** — V8 spec says each `Runtime.evaluate` runs in a fresh script; Lightpanda shares the scope so a second `const x = ...` throws `SyntaxError: Identifier 'x' has already been declared`. Gem workaround: wrap every no-args `evaluate(expr)` / `execute(expr)` in an IIFE on the Ruby side + surface `exceptionDetails`.

## What this gem won't ever fix (run cuprite)

- Real screenshots / pixel diffs / visual regression
- Layout-dependent tests (scroll, resize, real geometry)
- Service Workers, WebAuthn, SharedArrayBuffer
- Anything requiring a compositor

The dual-driver pattern (`BROWSER=lightpanda` env gate + cuprite fallback) documented in the gem's README is the answer for these.
