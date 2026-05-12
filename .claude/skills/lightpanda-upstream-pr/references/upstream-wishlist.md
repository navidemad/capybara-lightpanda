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

> Items A1–A9, A13–A21, A24–A33 have all been resolved (or retracted as gem misdiagnoses) — see section D for the historical record. Numbering preserved to keep cross-references stable.

### A10. `Page.loadEventFired` unreliable on complex JS pages (#1801, #1832)

- **Today**: may never fire on Wikipedia, certain SPAs, French real estate sites. Even after PR #2032 reordered events.
- **Want**: fire reliably at end of navigation.
- **Gem workaround**: `lib/capybara/lightpanda/browser.rb` — `wait_for_page_load` / `wait_for_navigation` use a 2-second `Page.loadEventFired` window then fall back to `document.readyState` polling. Critical for Wikipedia-style sites.
- **Drop-on-fix**: keep readyState fallback as a safety net (cheap), but remove the 2-second cap and trust `loadEventFired` as primary.

### A11. `Runtime.evaluate` after click-driven navigation: "Cannot find default execution context" (#2187)

- **Today**: race window after navigation where the V8 default context is destroyed but not yet recreated. Calls fail with `-32000 Cannot find default execution context`.
- **Want**: queue the evaluate until the new context is ready, or block until ready.
- **Gem workaround**: `lib/capybara/lightpanda/browser.rb` — `with_default_context_wait` retries once after waiting for `Runtime.executionContextCreated`. `Node#call`, `find_in_document`, `Node#shadow_root` all wrap in this pattern.
- **Drop-on-fix**: remove `with_default_context_wait` and unwrap the retry calls. ~15 LOC + 4 call-site simplifications.

### A12. WebSocket dies on complex page navigation (#1849)

- **Today**: PR #1850 (2026-03-16) was supposed to fix this; still happens occasionally on certain sites.
- **Want**: stable WebSocket through any navigation lifecycle.
- **Gem workaround**: `lib/capybara/lightpanda/browser.rb` — `handle_navigation_crash` reconnects on `@client.closed?` and retries the navigation once. Without this, full-app crashes ripple as `DeadBrowserError` on the next CDP call.
- **Drop-on-fix**: remove `handle_navigation_crash` and the reconnect/retry logic. ~30 LOC.

### A22. `Element.isContentEditable` — IDL attribute landed but always returns false (cannot drop polyfill)

- **Today (verified 2026-05-01 against `main` HEAD `9a9e79eb`, build 5948)**: `HTMLElement.isContentEditable` IDL accessor exists (`src/browser/webapi/element/Html.zig:398-407`), but the implementation always returns `false`. PR #2310 (by us) originally implemented the spec-correct walk, but the maintainer added commit `2af95af6` immediately before merge that strips the return path: it walks ancestors per HTML §7.7.5.2, but only to emit `log.info(.not_implemented, "IsContentEditable", ...)` when the spec answer would be `true` — the function unconditionally returns `false`. Rationale (from the commit body): Lightpanda has no caret/keyboard editing pipeline, so a spec-correct `true` would route Puppeteer's `dispatchKeyEvent` into a silently-noop input pipeline; routing to `false` and logging the unsupported case surfaces the gap in telemetry rather than masquerading as a working state.
- **Upstream issue/PR**: #2309 CLOSED 2026-04-30, PR #2310 MERGED 2026-04-30 (with the maintainer override).
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js:910-921` — `_lightpanda.isContentEditable` falls back to walking the ancestor chain looking for a non-`false` `contenteditable` attribute when `el.isContentEditable` is falsy/missing (~12 LOC). Called from `EDITABLE_HOST_JS` in `lib/capybara/lightpanda/node.rb:503`, which backs `Node#content_editable?`. **Polyfill MUST stay** — replacing it with the native read would force every `Node#content_editable?` call to return false.
- **Drop-on-fix**: blocked indefinitely, contingent on Lightpanda implementing a real keyboard-editing pipeline. Until then, the gem polyfill is load-bearing.

### A23. `Element.innerText` doesn't insert block-level line breaks

- **Today**: `_getInnerText` at `src/browser/webapi/element/Html.zig:226-268` recurses through children and emits `\n` only for `<br>`. No display:block / display:list-item line breaks; no hidden-descendant filtering (source even has a `// TODO check if elt is hidden` comment at line 241); no line-collapsing pass. Empirically, nested-block fixtures return `"Ancestor Ancestor Ancestor Child  ASibling  "` (no newlines) where Chrome returns the same content with `\n` inserted around block boundaries.
- **Want**: implement [the HTML innerText algorithm](https://html.spec.whatwg.org/multipage/dom.html#the-innertext-idl-attribute) — required line breaks around block-level boxes, hidden-descendant filtering via `getComputedStyle().display`, the line-collapsing pass that drops required line breaks adjacent to empty blocks. Multi-day Zig project; needs `getComputedStyle` access from inside the writer-driven walker.
- **Upstream issue/PR**: not filed.
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js` — `_lightpanda.visibleText` (~50 LOC) walks descendants in JS, dispatches on tag-name + `getComputedStyle().display`, wraps block-level descendants in `\n…\n` only when they actually contribute visible text. Called from `VISIBLE_TEXT_JS` in `lib/capybara/lightpanda/node.rb`, which backs `Node#visible_text` (and hence `text(:visible)`). Also: `node #shadow_root should get visible text` still fails because the polyfill emits a phantom `\n` around empty `display:block` elements between inline siblings — Chrome's innerText collapses these via the line-collapse pass. Gem-side TODO to add `/\S/.test(out)` guard or wait for upstream native impl.
- **Drop-on-fix**: replace the polyfill with `el.innerText` and inline the read at the `VISIBLE_TEXT_JS` constant. Drops `_lightpanda.visibleText` (~50 LOC). The phantom-newline gem-side bug goes away too if upstream collapses required line breaks around empty blocks.

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

- **Today (observed 2026-05-04 against public nightly `1.0.0-nightly.6005+b8144d3e`; full repro in `spec/features/upstream_bugs_spec.rb` "Bug #4 — HTMLDialogElement polyfill" + `UPSTREAM_BUGS.md` Bug #4)**: the `HTMLDialogElement` constructor exists (`typeof HTMLDialogElement === 'function'`) but `prototype.showModal`, `prototype.show`, `prototype.close`, and `prototype.returnValue` are all `undefined`. Calling any of them throws `TypeError: d.showModal is not a function`. Blocks any UI built on the native `<dialog>` element (very common in Rails 8 + DaisyUI / Tailwind UI / shadcn).
- **Want**: per [HTML §4.11.4 "The dialog element"](https://html.spec.whatwg.org/multipage/interactive-elements.html#the-dialog-element), implement on `HTMLDialogElement.prototype`:
  - `show()` — adds the `open` content attribute if not already set; non-modal display.
  - `showModal()` — throws `InvalidStateError` if `[open]` is already present; otherwise sets `[open]` and (in Chrome) adds the dialog to the top layer + sets a backdrop. Lightpanda has no rendering so the focus-trap / backdrop / top-layer can be no-ops, but `[open]` MUST flip and the dialog MUST become visible to selectors.
  - `close([returnValue])` — removes `[open]`, sets `returnValue` if argument given, queues a `close` event.
  - `returnValue` getter/setter, `cancel` event on Esc (Esc handling is out of scope without input events).
- **Upstream issue/PR**: not filed. Mirrors the shape of `HTMLFormElement.prototype.requestSubmit` (PR #2253, merged 2026-04-27) — single Zig file under `src/browser/webapi/element/html/`, ~3 prototype methods, no V8/CDP-runtime entanglement. Probably the smallest discrete missing-API gap in the gem.
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/polyfills.js:8-36` (~30 LOC) — adds `showModal` (with `InvalidStateError` parity), `show`, `close([returnValue])` on the prototype. Toggles `[open]` and dispatches a `'close'` event. No focus trap, no backdrop, no top-layer (Lightpanda has no layout anyway).
- **Drop-on-fix**: remove the dialog block from `polyfills.js`. ~30 LOC. The spec test in `spec/features/upstream_bugs_spec.rb` becomes a regression check for the upstream implementation.

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

---

## D. Drop-on-fix LOC tally

If the remaining open / unfiled items in section A + B land upstream, the gem can shed roughly:

| Item | LOC saved | Reason |
|---|---|---|
| **A23 — `Element.innerText` block-level newlines** | ~50 | `_lightpanda.visibleText` polyfill |
| **B12 — `HTMLDialogElement` methods** | ~30 | Dialog block in `polyfills.js` |
| **A12 — WebSocket nav crash** | ~30 | `handle_navigation_crash` reconnect |
| **A10 — Page.loadEventFired fallback** | ~20 | Simplify (keep readyState as safety net) |
| **A11 — NoExecutionContextError race** | ~15 + 4 call-sites | `with_default_context_wait` |
| **B4 — file uploads** | adds ~30, removes 26 skips | Net positive: enables a feature |
| **B5#1, B5#2 — keyCode/charCode + caret keys** | 2 skip patterns | Synthetic CDP keyboard events need keyCode populated; ArrowLeft/Home/End need to move the input caret |
| **B8, B9, B10 — datalist + frame-closed + getComputedStyle cascade** | ~10 skip patterns | Removes spec_helper entries |

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

**Total remaining drop-on-fix surface**: roughly **~145 LOC of gem-side code** plus ~14 spec_helper skip patterns. Down from ~1,030 LOC pre-2026-05-11. Of what remains, A23 (`innerText` block-level newlines, ~50 LOC) is the single largest item. **Pending wishlist additions** (Bug #6 / #7 / #8 / #9 / #10 in `UPSTREAM_BUGS.md` — Turbo-driven discoveries from 2026-05-04 → 2026-05-06) are not yet folded into this tally; their gem-side polyfills add another ~120 LOC in `polyfills.js` waiting on upstream fixes.

---

## Quick wins (for upstream contributors)

### Open PRs awaiting upstream review (filed by us)

None — the 10 PRs that were open at the time of the prior tally (A18 #2283, A21 #2315, A24 #2294, A25 #2312, A26 #2308, A30 #2352, B1 #2305, B2 #2289, B6 #2286, plus our closed-then-superseded A29 #2326) all landed between 2026-04-28 and 2026-05-11. The big-bang gem cleanup ride along that wave was the ~700-LOC XPath polyfill removal in commit `94a4120`.

### Unfiled items most worth claiming (need authors)

Listed by drop-on-fix impact / spec-compliance importance:

1. **B12 — `HTMLDialogElement.{showModal, show, close}`** — ~30 LOC drop-on-fix; smallest, cleanest scope. Pure missing-API addition; mirrors `HTMLFormElement.prototype.requestSubmit` shape exactly (PR #2253). Good first-PR candidate.
2. **A23 — `Element.innerText` block-level line breaks** — ~50 LOC drop-on-fix; multi-day Zig project (writer needs `getComputedStyle` access from inside the walker, plus the line-collapsing pass). Highest single-item LOC saving among open items.
3. **A12 — WebSocket dies on complex page navigation (#1849)** — ~30 LOC drop-on-fix; partial fix from PR #1850 in 2026-03 didn't fully close the issue.
4. **A11 — `Runtime.evaluate` "Cannot find default execution context" race (#2187)** — ~15 LOC + 4 call-sites; needs queue-or-await around `executionContextCreated`. Note: the gem now also wraps `find_in_frame` in `with_default_context_wait` (commit `ac95ad5`, 2026-05) to handle iframe context churn from upstream #2400; landing #2187 wouldn't fully retire the helper.
5. **A10 — `Page.loadEventFired` reliability (#1801)** — ~20 LOC drop-on-fix; long-standing.
6. **B4 — `<input type=file>` / `Page.setFileInputFiles` (#2175)** — adds ~30 gem LOC, removes 26 skip patterns. Net positive: enables a feature.
7. **B5#1 — `KeyboardEvent.keyCode` gated on `isTrusted`** — PR #2292 implemented `keyCode`/`charCode` but gates on trusted events. Single skip pattern (`node #send_keys should generate key events`); needs the gate loosened for synthetic `Input.dispatchKeyEvent` per Chrome's CDP behavior.
8. **B5#2 — Caret-movement keys (`ArrowLeft`/`Home`/`End`) don't move input caret** — single skip pattern; not yet filed as an issue.

### New bugs not yet folded into this wishlist (discovered 2026-05-04 → 2026-05-06 via Turbo Drive probes)

Tracked in `UPSTREAM_BUGS.md` at gem root. Each has a gem-side polyfill in `polyfills.js` waiting on upstream fix. Need wishlist entries (suggest A34–A38):

- **Bug #6 — `fetch(url, { body: new FormData(...) })` doesn't encode multipart** — bloquant for all Turbo Drive form submits (422 systematic on server). Lightpanda coerces `FormData` to `"[object FormData]"` via `String()` instead of running Fetch §6.5 "extract a body". Same bug also affects `XMLHttpRequest.send(formData)`. **No gem-side workaround possible** — encoding lives in Lightpanda's Zig fetch layer.
- **Bug #7 — Form IDL accessors return `undefined` (`enctype`/`method`/`action`/`target` on `HTMLFormElement`; `formEnctype`/`formMethod`/`formAction`/`formTarget`/`formNoValidate` on submitters)** — blocks Turbo Drive's `FormSubmission` constructor with `TypeError: Cannot read properties of undefined (reading 'toLowerCase')`. Gem polyfills via `patchFormIDL` IIFE (~70 LOC) in `polyfills.js`.
- **Bug #8 — `addEventListener` during capture-phase invisible to in-flight bubble-phase** — WHATWG DOM §2.9 step 5.4 violation. Breaks Turbo's `submitBubbled` interception; form submits become full-page navigations instead of Turbo fetches. Gem polyfills via `patchListenerLifecycle` IIFE (~50 LOC) which defers `removeEventListener` to a microtask.
- **Bug #9 — `requestSubmit()` throws when a listener cancels the SubmitEvent** — HTML §4.10.21.5 step 5 says it must return silently when cancelled. Lightpanda throws `JsException`. Gem workaround: `try { this.form.requestSubmit(this); } catch (e) {}` around `CLICK_JS`'s submit path.
- **Bug #10 — `Runtime.evaluate` retains `const`/`let` top-level bindings between CDP calls** — V8 spec says each `Runtime.evaluate` runs in a fresh script; Lightpanda shares the scope so a second `const x = ...` throws `SyntaxError: Identifier 'x' has already been declared`. Gem workaround: wrap every no-args `evaluate(expr)` / `execute(expr)` in an IIFE on the Ruby side + surface `exceptionDetails`.

## What this gem won't ever fix (run cuprite)

- Real screenshots / pixel diffs / visual regression
- Layout-dependent tests (scroll, resize, real geometry)
- Service Workers, WebAuthn, SharedArrayBuffer
- Anything requiring a compositor

The dual-driver pattern (`BROWSER=lightpanda` env gate + cuprite fallback) documented in the gem's README is the answer for these.
