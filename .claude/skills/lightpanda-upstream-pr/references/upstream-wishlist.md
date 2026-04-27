# Lightpanda Upstream Wishlist

What `capybara-lightpanda` patches around because of upstream gaps in
[lightpanda-io/browser](https://github.com/lightpanda-io/browser).

Each entry has:
- **Today** — actual behavior on `1.0.0-nightly.5812+b3257754` (verified 2026-04-26)
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

### A1. `Network.clearBrowserCookies` returns `InvalidParams`

- **Today**: command responds `-31998 InvalidParams` whenever the caller includes `params: {}`. Root cause: inverted-logic guard in `clearBrowserCookies` returns `InvalidParams` if `cmd.params(struct{})` is non-null, which it always is when the caller sends an empty params object. PR #1821 (>= v0.2.6) added the missing `clearRetainingCapacity()` call but didn't fix this guard.
- **Want**: clear ALL cookies in the in-memory jar regardless of current page origin (Chrome behavior); silently accept an empty params object per JSON-RPC convention.
- **Upstream issue**: #2254, **Upstream PR**: #2255 (open as of 2026-04-27, by us).
- **Gem workaround**: `lib/capybara/lightpanda/cookies.rb` — `Cookies#clear` ignores the response and falls through to a per-origin sweep using `Browser#visited_origins`.
- **Drop-on-fix**: remove `sweep_visited_origins`, the `@visited_origins` tracking in `Browser#initialize`, the `record_visited_origin` helper. ~50 LOC.

### A2. `Network.getCookies` (no `urls`) scoped to current origin

- **Today**: returns only cookies for the current page's origin. Cookies set on previously-visited domains are invisible. On `about:blank`, raises `InvalidDomain`. (This actually matches Chrome's CDP spec for `Network.getCookies`, but Chrome also implements `Network.getAllCookies` for cross-origin enumeration — see B3.)
- **Want**: cross-origin enumeration via `Network.getAllCookies` (B3); the origin-scoped `Network.getCookies` itself can keep its current semantics.
- **Upstream issue**: #2254, **Upstream PR**: #2255 (open as of 2026-04-27, by us — bundled with A1 + B3 since the gem workaround is shared).
- **Gem workaround**: pass explicit `urls: [...]` parameter for cross-origin enumeration. Track visited origins in Browser. (Same workaround as A1.)
- **Drop-on-fix**: alongside A1.

### A3. `Page.handleJavaScriptDialog` always errors

- **Today**: returns `-32000 No dialog is showing`. Dialogs auto-dismiss in headless mode (alert→OK, confirm→false, prompt→null) before a handler can intervene. The CDP method exists since commit 7208934b (2026-04-06) but has no effect.
- **Want**: support deferred dialog handling — `accept`/`promptText` should override the auto-dismiss return value.
- **Gem workaround**: `lib/capybara/lightpanda/browser.rb` — `prepare_modals` / `accept_modal` / `dismiss_modal` / `find_modal` capture messages via `Page.javascriptDialogOpening` for matching, but never call `handleJavaScriptDialog`. Result: `accept_modal(:confirm|:prompt)` cannot influence the JS return value.
- **Drop-on-fix**: rewire modal handlers to actually call `Page.handleJavaScriptDialog` (must be off the dispatch thread to avoid the synchronous-CDP-from-event-handler deadlock). Removes 4 skip-list patterns in `spec/spec_helper.rb` (`#accept_confirm`, `#accept_prompt`, `#accept_alert if text doesn't match`, `#accept_alert nested modals`). ~30 LOC + skip patterns.

### A4. `form.submit()` does not navigate

- **Today**: parses and validates but never issues an HTTP request. Page stays on original URL with form still rendered. Verified 2026-04-26.
- **Want**: spec-compliant form submission — issue the request, navigate, fire submit event.
- **Gem workaround**: `lib/capybara/lightpanda/node.rb` — `CLICK_JS` (submit-button click path) and `IMPLICIT_SUBMIT_JS` (Enter-in-text-input) do `fetch(action) → DOMParser → swap document.body.innerHTML → history.replaceState`. Bypasses Lightpanda's form pipeline entirely.
- **Drop-on-fix**: simplify `CLICK_JS` to just `this.click()` for submit buttons; remove `IMPLICIT_SUBMIT_JS`. ~150 LOC.

### A5. `document.write()` is a no-op

- **Today**: `document.open(); document.write(html); document.close()` leaves `body.innerHTML.length` unchanged. Verified 2026-04-26.
- **Want**: spec-compliant document.write — replace document content.
- **Gem workaround**: implicit. The original CLICK_JS used `document.write` to swap content; replaced with `body.innerHTML = ...` as part of A4's workaround.
- **Drop-on-fix**: alongside A4 if we ever want to use `document.write` again.

### A6. `Page.reload` does not replay POST

- **Today**: a refresh after a POST navigation does a GET to the same URL, not a re-POST. Form action handlers don't re-run.
- **Want**: replay the POST as Chrome does (with confirmation prompt that headless can auto-accept).
- **Gem workaround**: none. Skip-listed in `spec/spec_helper.rb` (`#refresh it reposts`).
- **Drop-on-fix**: remove the skip pattern.

### A7. `<select>` without `<option>` serialized as `""` in FormData

- **Today**: `new FormData(form)` includes a `<select>` with zero options as an empty-string entry.
- **Want**: per HTML spec, omit the entry.
- **Gem workaround**: none. Skip-listed (`#click_button on HTML4 form should not serialize a select tag without options`).
- **Drop-on-fix**: remove the skip pattern.

### A8. `#id` selector returns null after body innerHTML+replaceWith

- **Today**: `Frame.getElementByIdFromNode` (CSS selector engine fast path for `#id`) only checks the `lookup` map. After a body removal the original element lives in `_removed_ids` and the new element isn't re-registered, so `lookup.get(id)` misses. `getElementById` works (has recovery), `[id="..."]` works, but `#id` shorthand doesn't. Triggers in Turbo Drive's snapshot-then-swap pattern.
- **Want**: `#id` fast path should mirror `Document.getElementById` recovery (walk `removed_ids` + scope root).
- **Upstream PR**: **#2244 (filed by us, OPEN as of 2026-04-26)**.
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js` patches `Document.prototype.querySelector{,All}` and `Element.prototype.querySelector{,All}` to rewrite `#id` → `[id="id"]` before delegating to native engine. Walks selector char-by-char, tracks bracket depth and quoted strings, supports compound selectors, pseudo-class arguments, commas, escapes.
- **Drop-on-fix**: remove the `querySelector` rewriter IIFE in `index.js` (~60 LOC) and the polyfill regression test in `spec/features/driver_spec.rb`.

### A9. Cookies set on 302 redirect not sent on follow-up request

- **Today**: `Set-Cookie` on a 302 response is stored in the cookie jar but the immediate follow-up GET to the redirect target doesn't include it. Verified on v0.2.7 and current nightly.
- **Want**: include the just-set cookie on the redirect-target request.
- **Gem workaround**: none. Pending test in `spec/features/driver_spec.rb` (`sends redirect-set cookies on the follow-up request`).
- **Drop-on-fix**: remove the `pending` annotation.

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

### A13. `textContent` whitespace differs from Chrome (surfaced 2026-04-26)

- **Today**: Lightpanda preserves source-template whitespace differently. Multi-level nested fixtures normalize to different whitespace patterns than Chrome — surfaces in Capybara's `#ancestor` shared spec where `text: "Ancestor\nAncestor\nAncestor"` matches in Chrome but not in Lightpanda.
- **Want**: spec-compliant text node coalescing matching Chrome's html5ever output.
- **Gem workaround**: tests use regex `text:` instead of literal `\n`-containing strings. No code-side workaround possible — lives in Lightpanda's html5ever / DOM text-node coalescing path.
- **Drop-on-fix**: simplify Capybara test fixtures that currently use regexes.

### A14. `requestSubmit()` not implemented on `HTMLFormElement`

- **Today (2026-04-27)**: native `HTMLFormElement.prototype.requestSubmit` exists (PR #1891 merged 2026-03-17, follow-up PR #1984 merged 2026-03-24 — both shipped in nightly.5812+). Functional behavior is correct: dispatches a `SubmitEvent`, validates submitter button, throws TypeError / NotFoundError per spec. The gem polyfill's `if (!HTMLFormElement.prototype.requestSubmit)` guard means it is a no-op on current nightly.
- **Residual spec bug**: `requestSubmit()` with no submitter argument sets `event.submitter` to the form element; per HTML spec it should be `null`. **Upstream issue**: #2252, **Upstream PR**: #2253 (open as of 2026-04-27, by us).
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js` polyfill at end of file (~20 LOC). Now superseded by native impl (already a no-op via the existence guard).
- **Drop-on-fix**: remove the polyfill IIFE. Safe to do today even before #2253 lands — the gem isn't asserting `event.submitter === null` anywhere, and the polyfill is already inactive on current nightly. Defer until next gem release for safety.

### A15. `window.location.pathname =` doesn't trigger navigation

- **Today**: only `.href =` triggers navigation. Setting `.pathname`, `.search`, `.hash` updates the URL string but doesn't navigate.
- **Want**: any `location` part assignment triggers navigation, like Chrome.
- **Gem workaround**: none. Skip-listed: `#assert_current_path should wait for current_path` (the underlying fixture uses `window.location.pathname =`).
- **Drop-on-fix**: remove 5 skip patterns related to `assert_current_path` / `has_current_path`.

### A16. URL fragments dropped through redirects

- **Today**: visiting `/redirect#fragment` lands on `/landed`, dropping `#fragment`.
- **Want**: preserve fragment through redirect (Chrome behavior — fragment carries forward unless target sets its own).
- **Gem workaround**: none. Skip-listed: `#current_url maintains fragment`.
- **Drop-on-fix**: remove skip pattern.

### A17. `<input type=range>` constraints not enforced

- **Today**: `set` writes the value but Lightpanda doesn't clamp/validate against `min`/`max`.
- **Want**: enforce min/max on value assignment.
- **Gem workaround**: none. Skip-listed: `#fill_in with input[type="range"] should set the range slider to valid values`, `should respect the range slider limits`.
- **Drop-on-fix**: remove skip patterns.

### A18. `Referer` header not propagated reliably

- **Today**: missing or incorrect `Referer` on cross-link navigation.
- **Want**: spec-compliant Referer policy.
- **Gem workaround**: none. Skip-listed: `should send a referer when following a link`, `preserve original referer through redirect`, `click_link follow redirects back to itself`.
- **Drop-on-fix**: remove skip patterns.

### A19. `Network.deleteCookies` previously rejected `partitionKey`

- **Today**: PR #1821 made this silently ignore unknown params (was rejection).
- **Want**: confirmed working as of >= v0.2.6.
- **Gem workaround**: none. (Already fixed upstream.)
- **Drop-on-fix**: N/A.

---

## B. Missing CDP / DOM methods

### B1. `XPathResult` interface and `document.evaluate` not implemented

- **Today**: `document.evaluate` is undefined; `XPathResult` constants don't exist.
- **Want**: native XPath 1.0 evaluator on Document.
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js` — full XPath 1.0 evaluator (~700 LOC) covering tokenizer, parser, AST evaluation, all 13 axes, 27 functions. Exposed as `window._lightpanda.xpathFind` and as `document.evaluate` polyfill.
- **Drop-on-fix**: remove the entire `XPathEval` IIFE and the `XPathResult`/`document.evaluate` polyfill. ~700 LOC.

### B2. `Page.getNavigationHistory` / `Page.navigateToHistoryEntry` not implemented

- **Want**: standard CDP history APIs.
- **Gem workaround**: `lib/capybara/lightpanda/browser.rb` — `back` and `forward` use JS `history.back()` / `history.forward()` instead.
- **Drop-on-fix**: switch to the CDP methods (more reliable than JS for cross-origin history).

### B3. `Network.getAllCookies` not implemented

- **Today**: `Network.getAllCookies` is missing from the dispatch enum — calling it returns `-31998 UnknownMethod`.
- **Want**: a way to enumerate all cookies in the jar regardless of origin.
- **Upstream issue**: #2254, **Upstream PR**: #2255 (open as of 2026-04-27, by us — bundled with A1 + A2).
- **Gem workaround**: pass explicit `urls:` to `Network.getCookies` (see A2).
- **Drop-on-fix**: simplify `sweep_visited_origins` to one `Network.getAllCookies` call.

### B4. `<input type=file>` / `Page.setFileInputFiles` not implemented (#2175)

- **Want**: file upload support.
- **Gem workaround**: `Node#set` raises `NotImplementedError` for file inputs. Skip-listed: 26 `#attach_file` specs.
- **Drop-on-fix**: implement `Node#set_file` using `Page.setFileInputFiles`. Removes 26 skip patterns.

### B5. `Input.dispatchKeyEvent` modifier flags incomplete

- **Want**: correct propagation of shift/ctrl/alt/meta modifier state across key events; correct keyCode/code attributes on KeyboardEvent.
- **Gem workaround**: none useful. Skip-listed: `node #send_keys should send special characters`, `should hold modifiers at top level`, `should generate key events`.
- **Drop-on-fix**: remove skip patterns.

### B6. `validity` API not implemented

- **Want**: `el.validity.valid`, `el.validity.valueMissing`, `el.validationMessage`.
- **Gem workaround**: none. Skip-listed: `#has_field with valid should be true if field is valid`, `should be false if field is invalid`.
- **Drop-on-fix**: remove skip patterns.

### B7. CSS escape syntax (`\31`, `\.` etc.) not supported in selectors

- **Want**: handle CSS escape grammar in the selector parser.
- **Gem workaround**: none. Skip-listed: `#find with css selectors should support escaping characters`, `#has_css? should allow escapes in the CSS selector`.
- **Drop-on-fix**: remove skip patterns.

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

- **Today**: Lightpanda's DOM serialization differs from Chrome's expected XPath path output.
- **Want**: XPath path matching Chrome's format (e.g. `/html/body/div[2]/p[1]`).
- **Gem workaround**: gem uses CSS-like path generation in `GET_PATH_JS`. Skip-listed: `node #path returns xpath which points to itself`.
- **Drop-on-fix**: remove skip pattern.

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

If all of section A + B land upstream, the gem can shed roughly:

| Item | LOC saved | Reason |
|---|---|---|
| **B1 — XPath evaluator** | ~700 | Whole `XPathEval` IIFE in index.js |
| **A4 + A5 — form.submit / document.write** | ~150 | `CLICK_JS` fetch+swap + `IMPLICIT_SUBMIT_JS` |
| **A8 — `#id` rewriter** | ~60 | querySelector polyfill + regression test (PR #2244 OPEN) |
| **A1 + A2 + B3 — cookie clearing** | ~50 | `sweep_visited_origins`, `visited_origins` tracking |
| **A3 — handleJavaScriptDialog** | ~30 + 4 skips | Modal handlers + 4 spec_helper skip patterns |
| **A12 — WebSocket nav crash** | ~30 | `handle_navigation_crash` reconnect |
| **A14 — requestSubmit polyfill** | ~20 | Polyfill IIFE in index.js |
| **A11 — NoExecutionContextError race** | ~15 + 4 call-sites | `with_default_context_wait` |
| **A10 — Page.loadEventFired fallback** | ~20 | Simplify (don't fully remove — keep readyState as safety net) |
| **B4 — file uploads** | adds ~30, removes 26 skips | Net positive: enables a feature |
| **A15, A16, A17, A18, B5–B11 — assorted** | 30+ skip patterns | Removes spec_helper skip list entries |

**Total drop-on-fix surface**: roughly **~1100 LOC of gem-side code becomes deletable**, plus ~50 spec_helper skip patterns become removable. The XPath polyfill alone is ~700 LOC. Removing the JS-side hacks would also let us delete most of the `_lightpanda` namespace IIFE in `index.js`.

---

## Quick wins (for upstream contributors)

If filing one PR, these are the highest-impact:

1. **A8 (`#id` rewriter)** — already filed (#2244). Small, targeted patch in `Frame.getElementByIdFromNode`. Fixes Turbo Drive interaction.
2. **A1/A2 (cookie clearing)** — make `Network.clearBrowserCookies` actually clear the in-memory jar, OR implement `Network.getAllCookies`. Fixes `reset_session!` semantics across multi-domain tests.
3. **A4 (`form.submit()` navigates)** — fixes a huge swath of plain-form tests; lets us delete the gem's most invasive workaround (~150 LOC).
4. **B1 (`XPathResult` / `document.evaluate`)** — biggest LOC savings (~700 LOC). Native implementation would also fix XPath-in-iframes, edge cases in our evaluator.
5. **A3 (`handleJavaScriptDialog`)** — fixes confirm/prompt return-value override; small upstream change.

## What this gem won't ever fix (run cuprite)

- Real screenshots / pixel diffs / visual regression
- Layout-dependent tests (scroll, resize, real geometry)
- Service Workers, WebAuthn, SharedArrayBuffer
- Anything requiring a compositor

The dual-driver pattern (`BROWSER=lightpanda` env gate + cuprite fallback) documented in the gem's README is the answer for these.
