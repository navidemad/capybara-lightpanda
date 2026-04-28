# Lightpanda Upstream Wishlist

What `capybara-lightpanda` patches around because of upstream gaps in
[lightpanda-io/browser](https://github.com/lightpanda-io/browser).

Each entry has:
- **Today** — actual behavior on the current public nightly (`1.0.0-dev.5839+2bbf23b3`, asset published 2026-04-28 03:33 UTC). Where verified against a different build, the entry calls it out.
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

### A1. `Network.clearBrowserCookies` returns `InvalidParams` — FIXED + SHIPPED + GEM CLEANED UP

- **Today (nightly 5839)**: FIXED. `Network.clearBrowserCookies` accepts an empty params object and clears the jar. Empirically verified.
- **Upstream PR**: **#2255 MERGED 2026-04-27 04:15 UTC, by us**, in nightly ≥5817.
- **Gem workaround**: removed. `Cookies#clear` (`lib/capybara/lightpanda/cookies.rb`) calls `Network.clearBrowserCookies` directly; `Browser#visited_origins` / `record_visited_origin` / `sweep_visited_origins` deleted; `MINIMUM_NIGHTLY_BUILD` bumped to 5817.
- **Drop-on-fix**: N/A — done.

### A2. `Network.getCookies` (no `urls`) scoped to current origin — RESOLVED via B3

- **Today (nightly 5839)**: still origin-scoped (matches Chrome's CDP spec). Cross-origin enumeration now flows through `Network.getAllCookies` (see B3).
- **Gem workaround**: removed alongside A1 — `Cookies#all` uses `Network.getAllCookies` for the cross-origin case.
- **Drop-on-fix**: N/A — done alongside A1.

### A3. `Page.handleJavaScriptDialog` always errors

- **Today**: returns `-32000 No dialog is showing`. Dialogs auto-dismiss in headless mode (alert→OK, confirm→false, prompt→null) before a handler can intervene. The CDP method exists since commit 7208934b (2026-04-06) but has no effect.
- **Want**: support deferred dialog handling — `accept`/`promptText` should override the auto-dismiss return value.
- **Upstream issue**: #2260, **Upstream PR**: #2261 (open as of 2026-04-27, by us — pre-arm model).
- **Gem workaround**: `lib/capybara/lightpanda/browser.rb` — `prepare_modals` / `accept_modal` / `dismiss_modal` / `find_modal` capture messages via `Page.javascriptDialogOpening` for matching, but never call `handleJavaScriptDialog`. Result: `accept_modal(:confirm|:prompt)` cannot influence the JS return value.
- **Drop-on-fix**: rewire modal handlers to actually call `Page.handleJavaScriptDialog` (must be off the dispatch thread to avoid the synchronous-CDP-from-event-handler deadlock). Removes 4 skip-list patterns in `spec/spec_helper.rb` (`#accept_confirm`, `#accept_prompt`, `#accept_alert if text doesn't match`, `#accept_alert nested modals`). ~30 LOC + skip patterns.

### A4. ~~`form.submit()` does not navigate~~ — NOT A BUG (gem misdiagnosis, retracted 2026-04-27); GEM CLEANUP DONE 2026-04-28

- **Resolution**: native `form.submit()`, `submit_button.click()`, `form.requestSubmit()`, and Enter-in-text-input implicit submission all navigate correctly on current nightly. Verified empirically against `1.0.0-nightly.5816+a578f4d6` via probes at `/tmp/a4-probe/`.
- **What was actually wrong**: gem commit `35ee402` (2026-04-26) added a `CLICK_JS` fetch+swap workaround based on the assumption that `Frame.submitForm` doesn't navigate. `git blame src/browser/Frame.zig` shows `submitForm` has called `scheduleNavigationWithArena` since 2026-03-24 — the workaround was a misdiagnosis.
- **Gem cleanup landed 2026-04-28**: `CLICK_JS` collapsed to native `this.click()` (with label-click + summary/details + image-button special cases — see A25 below); `IMPLICIT_SUBMIT_JS` rewritten to click default submit button or fall back to `form.requestSubmit()`; `\n`-routing branch in `Node#fill_text_input` retained but routes through the new minimal path; "plain form submission (Lightpanda fetch+swap)" describe block removed from `driver_spec.rb`. ~167 LOC dropped from `node.rb`. `bundle exec rake spec:incremental` → 1396 examples, 0 failures, 97 pending.
- **Drop-on-fix**: N/A — done.

### A5. ~~`document.write()` is a no-op~~ — NOT A BUG (retracted 2026-04-27)

- **Resolution**: Lightpanda's `document.open(); document.write(html); document.close()` correctly replaces the document body on current nightly. Verified empirically. Probe at `/tmp/a4-probe/probe-doc-write.js`.
- **Drop-on-fix**: N/A — informational only, gem doesn't use `document.write`.

### A6. `Page.reload` does not replay POST — FIXED + SHIPPED + GEM CLEANED UP

- **Today (nightly 5839)**: FIXED. `Page.reload` replays the POST method/body/headers from the prior navigation. Empirically verified by spec re-run — the previously-skipped `#refresh it reposts` test now passes.
- **Upstream issue**: #2258, **Upstream PR**: **#2259 MERGED 2026-04-27 23:16 UTC, by us**, in nightly ≥5839.
- **Gem cleanup**: `/#refresh it reposts/` skip pattern removed from `spec/spec_helper.rb` 2026-04-28.
- **Drop-on-fix**: N/A — done.

### A7. `<select>` without `<option>` serialized as `""` in FormData — FIXED + SHIPPED

- **Today (nightly 5839)**: FIXED. PR #2264 merged 2026-04-27 23:30 UTC. No spec was previously skipped under this exact pattern (the gem's old fetch+swap path included its own FormData fixup), so no gem-side cleanup needed beyond the now-removed `CLICK_JS` workaround.
- **Drop-on-fix**: N/A — done.

### A8. `#id` selector returns null after body innerHTML+replaceWith — FIXED + SHIPPED + GEM CLEANED UP

- **Today (nightly 5816)**: FIXED. `document.querySelector('#id')` after the modify-then-replace pattern returns truthy on `1.0.0-nightly.5816+a578f4d6`. Empirically verified.
- **Upstream PR**: **#2244 MERGED 2026-04-27 00:46 UTC, by us, commit `e1e9a0d7`**, included in nightly 5816.
- **Gem workaround**: removed 2026-04-27. `MINIMUM_NIGHTLY_BUILD` bumped to 5816, the `querySelector{,All}` rewriter IIFE deleted from `index.js`, the polyfill regression test deleted from `driver_spec.rb`, and the polyfill mention dropped from `CLAUDE.md`. `bundle exec rake spec:incremental` confirmed 1396 examples passing (1 pre-existing #2187 flake).
- **Drop-on-fix**: N/A — done.

### A9. ~~Cookies set on 302 redirect not sent on follow-up request~~ — NOT A BUG (gem fixture mismatch, fixed 2026-04-27)

- **Resolution**: Lightpanda has always sent the redirect-set cookie correctly on the follow-up GET. Verified empirically against nightly 5816 with a Python+CDP reproducer (302 with `Set-Cookie: redirect_test=survived` → `Location: /echo` → `/echo` receives `Cookie: redirect_test=survived`).
- **What was actually broken**: the gem fixture at `spec/support/test_app.rb`. `/lightpanda/set_cookie_and_redirect` set a cookie named `redirect_test` and redirected to `/lightpanda/get_test_cookie`, but that route reads `request.cookies["lightpanda_test"]` (a different cookie set by an unrelated route). The assertion target always returned `"No cookie"` regardless of Lightpanda's actual behavior; the `pending` annotation hid the fixture mismatch.
- **Gem-side fix (2026-04-27)**: added `/lightpanda/echo_redirect_cookie` route that reads `request.cookies["redirect_test"]`, repointed the redirect target, dropped the `pending` line in `driver_spec.rb:212`. Spec now passes against current nightly.
- **Drop-on-fix**: N/A — done.

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

### A13. ~~`textContent` whitespace differs from Chrome~~ — NOT A BUG (misdiagnosed, retracted 2026-04-28)

- **Resolution**: Lightpanda's `Element.textContent` is spec-compliant. Verified empirically against `1.0.0-dev.5817+716b6f33` with a CDP probe at `/tmp/a13-probe/repro.sh`: for the `with_html.erb` nested-div fixture, `el.textContent` byte-exactly matches the [HTML Living Standard descendant-text-content concatenation](https://dom.spec.whatwg.org/#concept-descendant-text-content). The wishlist's primary failing-test example (`#ancestor` with `text: "Ancestor\nAncestor\nAncestor"`) **passes** on current build.
- **What was wrong with the original entry**: the wishlist diagnosed the bug as living in "Lightpanda's html5ever / DOM text-node coalescing path", but `textContent` was never broken — the surfacing failure routes through `node.text(:visible)` → `Node#visible_text` → the gem's `_lightpanda.visibleText` JS polyfill, NOT through `textContent`. With CSSOM merged (PR #1797, 2026-03-23), `getComputedStyle(div).display === 'block'` works, the polyfill emits block-level newlines correctly, and the test passes.
- **Real residual upstream gap (separate, not pursued here)**: Lightpanda's native `Element.innerText` (`src/browser/webapi/element/Html.zig:226-268`) recurses through children and only emits `\n` for `<br>` — it doesn't insert required line breaks at block-level boundaries per the [innerText algorithm](https://html.spec.whatwg.org/multipage/dom.html#the-innertext-idl-attribute). Empirically: probe2 returns `"Ancestor Ancestor Ancestor Child  ASibling  "` (no newlines) for the same fixture. The gem polyfills around this with `_lightpanda.visibleText`, so no test surfaces the native gap. A future upstream PR could fix native `innerText` and obsolete ~150 LOC of gem polyfill — not in scope today (multi-day Zig project; needs `getComputedStyle` access from inside the writer-driven walker + line-break collapsing rules).
- **Real residual gem-side gap (separate)**: `node #shadow_root should get visible text` still fails because `_lightpanda.visibleText` (`lib/capybara/lightpanda/javascripts/index.js:953`) wraps every `display:block` element with `\n…\n` even when the element has no visible content — an empty `<div id="nested_shadow_host">` between two inline siblings introduces a phantom line break, so `"some text scroll.html"` becomes `"some text\nscroll.html"`. Chrome's innerText collapses required line breaks around empty blocks. File as gem-side TODO.
- **Drop-on-fix**: N/A.

### A14. `requestSubmit()` not implemented on `HTMLFormElement` — FIXED + SHIPPED + GEM CLEANED UP

- **Today (nightly 5839)**: FIXED. Native `HTMLFormElement.prototype.requestSubmit` exists (PR #1891 / PR #1984, shipped in nightly.5812+); `requestSubmit()` with no submitter argument now correctly sets `event.submitter === null` (PR #2253 merged 2026-04-27 04:20 UTC, by us, in nightly ≥5817).
- **Gem cleanup**: the `requestSubmit` polyfill IIFE was already removed from `index.js` before today's session. No outstanding gem-side work.
- **Drop-on-fix**: N/A — done.

### A15. `window.location.pathname =` doesn't trigger navigation — FIXED + SHIPPED + GEM CLEANED UP

- **Today (nightly 5839)**: FIXED. Setting `.pathname` or `.search` triggers a navigation (PR #2257 merged 2026-04-27 10:31 UTC, by us, in nightly ≥5817). `.hash` is in-page anchor and doesn't navigate cross-page (matches Chrome).
- **Gem cleanup**: 5 `assert_current_path` / `has_current_path` skip patterns removed from `spec/spec_helper.rb`.
- **Drop-on-fix**: N/A — done.

### A16. URL fragments dropped through redirects — FIXED + SHIPPED + GEM CLEANED UP

- **Today (nightly 5839)**: FIXED. Fragment is inherited across fragment-less redirect (PR #2265 merged 2026-04-27 10:15 UTC, by us, in nightly ≥5817).
- **Gem cleanup**: `#current_url maintains fragment` skip pattern removed from `spec/spec_helper.rb`.
- **Drop-on-fix**: N/A — done.

### A17. `<input type=range>` constraints not enforced — FIXED + SHIPPED + GEM CLEANED UP

- **Today (nightly 5839)**: FIXED. PR #2267 (clamp to min/max, by us, merged 2026-04-27 23:27 UTC) and PR #2280 (round to nearest step on the step ladder, by us, merged 2026-04-28 02:55 UTC) both in nightly ≥5839.
- **Gem cleanup**: `#fill_in with input[type="range"] should set the range slider to valid values` skip pattern removed from `spec/spec_helper.rb` 2026-04-28. AUDIT_SKIPS run confirmed test now passes.
- **Drop-on-fix**: N/A — done.

### A18. `Referer` header not propagated reliably — FIXED UPSTREAM, AWAITING NEXT NIGHTLY

- **Today (nightly 5839)**: still broken. Native form submission and link-click navigation send no `Referer` header. Empirically: `#visit should send a referer when submitting a form` started failing 2026-04-28 once the gem dropped its `CLICK_JS` fetch+swap pipeline (the old workaround sent the form via `fetch()`, which set `Referer` automatically).
- **Want**: spec-compliant Referer policy on cross-page navigations.
- **Upstream PR**: **#2283 MERGED 2026-04-28 08:01 UTC, by us, NOT in current nightly** (built 03:33 UTC, ~4½ h before merge). Will ship in next nightly.
- **Gem workaround**: none. Skip-listed in `spec/spec_helper.rb`: `should send a referer when following a link`, `preserve original referer through redirect`, `should send a referer when submitting a form`, `click_link follow redirects back to itself`.
- **Drop-on-fix**: remove the 4 referer skip patterns when the next nightly publishes and `MINIMUM_NIGHTLY_BUILD` is bumped past the post-merge build.

### A19. `Network.deleteCookies` previously rejected `partitionKey`

- **Today**: PR #1821 made this silently ignore unknown params (was rejection).
- **Want**: confirmed working as of >= v0.2.6.
- **Gem workaround**: none. (Already fixed upstream.)
- **Drop-on-fix**: N/A.

### A20. `formaction` / `formmethod` / `formenctype` on submit button not honored — FIXED + SHIPPED + GEM CLEANED UP

- **Today (nightly 5839)**: FIXED. Submitter overrides (`formaction` / `formmethod` / `formenctype`) are honored natively (PR #2279 merged 2026-04-28 01:49 UTC, by us, in nightly ≥5839). The `formtarget` parity that already existed is now matched for the other three.
- **Gem cleanup**: dropped alongside the A4 `CLICK_JS` cleanup (2026-04-28). The gem's old fetch+swap path used to read these off the submitter explicitly; native form submission now does it.
- **Drop-on-fix**: N/A — done.

### A21. `:disabled` selector / "actually disabled" doesn't inherit through `<fieldset>` / `<select>` / `<optgroup>`

- **Today (verified 2026-04-28 against `main` HEAD via source inspection)**: `el.matches(':disabled')` only checks the element's own `disabled` content attribute. `src/browser/webapi/selector/List.zig:537-541` reads `el.getAttributeSafe("disabled") != null` directly — no ancestor walk. So `<fieldset disabled><input></fieldset>` reports `input.matches(':disabled') === false`, and similarly for `<select disabled>` / `<optgroup disabled>` containing `<option>`. The `disabled` IDL attribute on form controls is also own-attribute only (which is spec-compliant for the IDL — the inheritance is supposed to surface through `:disabled`, form submission filtering, and event-target dispatch).
- **Want**: per [HTML §4.10.18.3 "Enabling and disabling form controls"](https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#enabling-and-disabling-form-controls), a form control is "actually disabled" when its own `disabled` attribute is set OR a disabled ancestor `<fieldset>` contains it (with the first-`<legend>` exception — descendants of the first legend stay enabled). `<option>` should also be `:disabled` when an ancestor `<optgroup disabled>` or `<select disabled>` contains it. `:disabled` and the `:enabled` complement need to walk ancestors accordingly.
- **Upstream issue/PR**: not filed.
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js` — `_lightpanda.isDisabled` walks ancestor `<fieldset>` / `<optgroup>` / `<select>` to honor the inherited cases, with the fieldset-first-legend exception (~28 LOC). Called from `DISABLED_JS` in `lib/capybara/lightpanda/node.rb:678`, which backs `Node#disabled?`.
- **Drop-on-fix**: replace the polyfill with `el.matches(':disabled')` and inline the call at the `DISABLED_JS` constant. Drops `_lightpanda.isDisabled` (~28 LOC).

### A22. `Element.isContentEditable` not implemented

- **Today (verified 2026-04-28 against `main` HEAD via source inspection)**: `Element.isContentEditable` is not exposed as an IDL attribute. The only `contenteditable` reference in the Zig source is `src/browser/interactive.zig:258` (semantic-tree categorization for `LP.getInteractiveElements`); no accessor on `Element` or `HtmlElement`. Reading `el.isContentEditable` returns `undefined`.
- **Want**: per [HTML §7.7.5.2 "The isContentEditable IDL attribute"](https://html.spec.whatwg.org/multipage/interaction.html#dom-iscontenteditable), `Element.isContentEditable` returns `true` when the element's effective content editable state is "true" — own `contenteditable` attribute non-`false`, OR closest ancestor with non-`false` `contenteditable` attribute (the inheritance walk).
- **Upstream issue/PR**: not filed.
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js` — `_lightpanda.isContentEditable` falls back to walking the ancestor chain looking for a non-`false` `contenteditable` attribute when `el.isContentEditable` is falsy/missing (~12 LOC). Called from `EDITABLE_HOST_JS` in `lib/capybara/lightpanda/node.rb:676`, which backs `Node#content_editable?`.
- **Drop-on-fix**: replace the polyfill with native `el.isContentEditable` and inline the read at the `EDITABLE_HOST_JS` constant. ~12 LOC.

### A23. `Element.innerText` doesn't insert block-level line breaks

- **Today (verified 2026-04-28 against `main` HEAD via source inspection — restates the residual gap noted under A13's retraction)**: `_getInnerText` at `src/browser/webapi/element/Html.zig:226-268` recurses through children and emits `\n` only for `<br>`. No display:block / display:list-item line breaks; no hidden-descendant filtering (source even has a `// TODO check if elt is hidden` comment at line 241); no line-collapsing pass. Empirically, nested-block fixtures return `"Ancestor Ancestor Ancestor Child  ASibling  "` (no newlines) where Chrome returns the same content with `\n` inserted around block boundaries.
- **Want**: implement [the HTML innerText algorithm](https://html.spec.whatwg.org/multipage/dom.html#the-innertext-idl-attribute) — required line breaks around block-level boxes, hidden-descendant filtering via `getComputedStyle().display`, the line-collapsing pass that drops required line breaks adjacent to empty blocks. Multi-day Zig project (per A13 notes); needs `getComputedStyle` access from inside the writer-driven walker.
- **Upstream issue/PR**: not filed.
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js` — `_lightpanda.visibleText` (~50 LOC) walks descendants in JS, dispatches on tag-name + `getComputedStyle().display`, wraps block-level descendants in `\n…\n` only when they actually contribute visible text. Called from `VISIBLE_TEXT_JS` in `lib/capybara/lightpanda/node.rb:505`, which backs `Node#visible_text` (and hence `text(:visible)`).
- **Drop-on-fix**: replace the polyfill with `el.innerText` and inline the read at the `VISIBLE_TEXT_JS` constant. Drops `_lightpanda.visibleText` (~50 LOC). The "phantom newline around empty block" gem-side gap noted in A13 (the `/\S/.test(out)` guard) also goes away if the upstream impl properly collapses required line breaks around empty blocks.

### A24. User-agent stylesheet only honors `[hidden]` — missing default `display:none` for unrendered elements

- **Today (nightly 5839)**: still broken. `StyleManager.hasDisplayNone` (`src/browser/StyleManager.zig:239-243`) honors only the `[hidden]` attribute as a UA-stylesheet rule. Empirically, `getComputedStyle(scriptEl).display` returns `'block'` instead of `'none'`, and `el.checkVisibility()` returns `true` for `<head>`/`<script>`/`<style>`/`<noscript>`/`<template>`/`<title>`/`<input type="hidden">` and for collapsed children of `<details>:not([open])>*:not(summary)`.
- **Want**: per the [HTML Rendering spec §15.3.1 "Hidden elements"](https://html.spec.whatwg.org/multipage/rendering.html#hidden-elements), the UA stylesheet maps these tags and selector patterns to `display: none`:
  - `area, base, basefont, datalist, head, link, meta, noembed, noframes, param, rp, script, source, style, template, track, title { display: none; }`
  - `input[type="hidden" i] { display: none; }`
  - `details:not([open]) > *:not(summary) { display: none; }`
- **Upstream issue**: #2293, **Upstream PR**: #2294 (OPEN as of 2026-04-28, by us).
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js` — `_lightpanda.isVisible` (~30 LOC) walks ancestors itself: rejects HEAD/TEMPLATE/NOSCRIPT/SCRIPT/STYLE/TITLE tags and `<input type="hidden">`, walks ancestors looking for `[hidden]` and closed `<details>`, special-cases `<summary>` as visible inside a closed `<details>`, then falls back to `el.checkVisibility()` and `getComputedStyle()` for the rest. Cuprite's `isVisible` (~25 LOC) only checks `display`/`visibility`/`opacity` at each ancestor — Chrome's UA stylesheet handles every other case implicitly.
- **Drop-on-fix**: simplify `_lightpanda.isVisible` to roughly Cuprite's shape — drop the tag-name allowlist, the `[hidden]` ancestor walk, the `<details>` open/`<summary>` carve-out. Keep the `offsetParent === null` fallback. ~20 LOC saved + the polyfill becomes less surprising.

### A25. `<input type=image>` click does not submit the associated form

- **Today (nightly 5839)**: native `imageBtn.click()` fires the click event but never schedules a navigation, even though the button's `form` is set and the default `type` is `submit`. Surfaced 2026-04-28 when the gem dropped the `CLICK_JS` fetch+swap pipeline — 7 image-button submit specs in `session_spec.rb` started failing because Lightpanda doesn't route image-button clicks into `Frame.submitForm`.
- **Want**: per [HTML §4.10.18.6.4 "Submit buttons"](https://html.spec.whatwg.org/multipage/input.html#image-button-state-(type=image)), clicking an `<input type=image>` should submit the form with `name.x` / `name.y` coordinate fields appended to the form data set. The submission path should mirror `<input type=submit>` (which already works after PR #2244).
- **Upstream issue/PR**: not filed.
- **Gem workaround**: `CLICK_JS` (`lib/capybara/lightpanda/node.rb`) special-cases `<input type=image>` and calls `form.requestSubmit()` after the click (~5 LOC). Coordinate fields (`name.x` / `name.y`) are NOT appended; Capybara tests don't assert on them, but a real-app spec that read those server-side would fail.
- **Drop-on-fix**: remove the image-button branch in `CLICK_JS`. ~5 LOC.

### A26. Textarea field values not normalized to CRLF on form submission

- **Today (nightly 5839)**: native form submission sends raw `\n` for `<textarea>` field values; should be `\r\n` per HTML's [form-data set algorithm](https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#constructing-the-form-data-set) (step "If entry's value is a string, replace every occurrence of U+000D (CR) not followed by U+000A (LF), and every occurrence of U+000A (LF) not preceded by U+000D (CR), in entry's value, by a string consisting of U+000D (CR) and U+000A (LF)"). Affects both `application/x-www-form-urlencoded` and likely `multipart/form-data`. Surfaced 2026-04-28 when the gem dropped its fetch+swap path (the JS `formEncode` did the CRLF conversion).
- **Want**: normalize textarea field values to CRLF in `Frame.submitForm` (or wherever the form-data set is constructed). The same normalization applies during the per-entry value processing for both encodings.
- **Upstream issue/PR**: not filed.
- **Gem workaround**: none. Pre-normalizing in `Node#set` would over-normalize (textarea would display `\r\n` chars). The fix has to live in Lightpanda's HTTP layer. Skip-listed: `#click_button.*should convert lf to cr/lf in submitted textareas`, `#fill_in should handle newlines in a textarea`.
- **Drop-on-fix**: remove the 2 skip patterns.

---

## B. Missing CDP / DOM methods

### B1. `XPathResult` interface and `document.evaluate` not implemented

- **Today**: `document.evaluate` is undefined; `XPathResult` constants don't exist.
- **Want**: native XPath 1.0 evaluator on Document.
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js` — full XPath 1.0 evaluator (~700 LOC) covering tokenizer, parser, AST evaluation, all 13 axes, 27 functions. Exposed as `window._lightpanda.xpathFind` and as `document.evaluate` polyfill.
- **Drop-on-fix**: remove the entire `XPathEval` IIFE and the `XPathResult`/`document.evaluate` polyfill. ~700 LOC.

### B2. `Page.getNavigationHistory` / `Page.navigateToHistoryEntry` not implemented

- **Today (nightly 5839)**: still missing from dispatch — both methods return `UnknownMethod`.
- **Want**: standard CDP history APIs (Chrome-compatible).
- **Upstream issue**: #2288, **Upstream PR**: #2289 (OPEN as of 2026-04-28, by us).
- **Gem workaround**: `lib/capybara/lightpanda/browser.rb` — `back` and `forward` use JS `history.back()` / `history.forward()` instead.
- **Drop-on-fix**: switch `Browser#back` / `#forward` to `Page.navigateToHistoryEntry` (more reliable than JS for cross-origin history). Update CLAUDE.md to drop the history-method workaround note.

### B3. `Network.getAllCookies` not implemented — FIXED + SHIPPED + GEM CLEANED UP

- **Today (nightly 5839)**: FIXED. `Network.getAllCookies` is in the dispatch enum and returns all cookies in the jar (PR #2255 merged 2026-04-27 04:15 UTC, by us, in nightly ≥5817).
- **Gem cleanup**: `Cookies#all` calls `Network.getAllCookies` directly. Cross-origin enumeration via the previous `Network.getCookies(urls: visited_origins)` sweep removed (alongside A1).
- **Drop-on-fix**: N/A — done.

### B4. `<input type=file>` / `Page.setFileInputFiles` not implemented (#2175)

- **Want**: file upload support.
- **Gem workaround**: `Node#set` raises `NotImplementedError` for file inputs. Skip-listed: 26 `#attach_file` specs.
- **Drop-on-fix**: implement `Node#set_file` using `Page.setFileInputFiles`. Removes 26 skip patterns.

### B5. `Input.dispatchKeyEvent` modifier flags / keyCode / caret movement

Three independent issues:

  1. **`KeyboardEvent.keyCode` and `charCode` legacy attributes hardcoded to 0** — FIXED UPSTREAM, AWAITING NEXT NIGHTLY. **Upstream issue**: #2291, **Upstream PR**: **#2292 MERGED 2026-04-28 07:46 UTC, by us, NOT in current nightly** (built 03:33 UTC, ~4h before merge). Implementation gates on `isTrusted` (CDP-driven events get correct keyCode), and adds Enter charCode. Skip pattern `node #send_keys should generate key events` remains until next nightly publishes.
  2. **`Input.dispatchKeyEvent` for `ArrowLeft`/`ArrowRight`/`Home`/`End` doesn't move the input caret**. Fails `should send special characters` (which uses `:left` to position the cursor mid-string before inserting a char). **Not yet filed.**
  3. **Gem-side bug** (separate — handled in 2b623164): `Capybara::Lightpanda::Keyboard#type` tracks standalone modifier symbols as sticky modifiers. Modifier flags propagate via CDP correctly; this was a Ruby-side state-tracking issue.
- **Gem workaround**: none. Skip-listed: `node #send_keys should send special characters` (#2), `should generate key events` (#1).
- **Drop-on-fix**: remove the `should generate key events` skip pattern when #2292 ships in nightly. `should send special characters` requires sub-item (2) to be filed and fixed.

### B6. `validity` API not implemented

- **Today (nightly 5839)**: `el.validity` is undefined; `el.validationMessage` empty. Empirically `TypeError: Cannot read properties of undefined (reading 'valid')` when accessed.
- **Want**: `el.validity.valid`, `el.validity.valueMissing`, etc., and `el.validationMessage` per the [HTML constraint validation API](https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#the-constraint-validation-api).
- **Upstream issue**: #2284, **Upstream PR**: #2286 (OPEN as of 2026-04-28, by us).
- **Gem workaround**: none. Skip-listed: `#has_field with valid should be true if field is valid`, `should be false if field is invalid`.
- **Drop-on-fix**: remove the 2 `#has_field with valid` skip patterns.

### B7. CSS escape sequences inside quoted attribute values not decoded — FIXED + SHIPPED

- **Today (nightly 5839)**: FIXED. Escape sequences inside quoted attribute values (e.g. `p[data-random="abc\\def"]`) decode correctly (PR #2269 merged 2026-04-27 23:27 UTC, by us, in nightly ≥5839).
- **Gem cleanup (TODO)**: re-run AUDIT_SKIPS to confirm which `#find with css selectors should support escaping characters` and `#has_css? should allow escapes in the CSS selector` skip patterns can drop. Today's full-suite run didn't fail any escape-related spec, suggesting the gem may not have an active blanket skip; verify with `git grep -nE 'escape.*selector|selector.*escape' spec/spec_helper.rb`.
- **Drop-on-fix**: remove any escape-related skip patterns once the AUDIT confirms they pass.
- **Probe**: `/tmp/b7-probe/` had the original 3-case CDP probe. No longer needed.

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
| **B1 — XPath evaluator** | ~700 | Whole `XPathEval` IIFE in index.js |
| **A23 — `Element.innerText` block-level newlines** | ~50 | `_lightpanda.visibleText` polyfill |
| **A3 — handleJavaScriptDialog** | ~30 + 4 skips | Modal handlers + 4 spec_helper skip patterns |
| **A12 — WebSocket nav crash** | ~30 | `handle_navigation_crash` reconnect |
| **A21 — `:disabled` inheritance** | ~28 | `_lightpanda.isDisabled` polyfill |
| **A24 — UA stylesheet display:none defaults** | ~20 | Slim `_lightpanda.isVisible` to Cuprite-shape (PR #2294 OPEN) |
| **A10 — Page.loadEventFired fallback** | ~20 | Simplify (keep readyState as safety net) |
| **A11 — NoExecutionContextError race** | ~15 + 4 call-sites | `with_default_context_wait` |
| **A22 — `Element.isContentEditable`** | ~12 | `_lightpanda.isContentEditable` polyfill |
| **A25 — `<input type=image>` submit** | ~5 | Image-button branch in `CLICK_JS` |
| **B4 — file uploads** | adds ~30, removes 26 skips | Net positive: enables a feature |
| **B2 — Page.getNavigationHistory** | ~5 + CLAUDE.md note | Switch `Browser#back`/`#forward` to CDP (PR #2289 OPEN) |
| **A18, A26, B5#1, B6 — assorted skip patterns** | 8+ skip patterns | Removes spec_helper entries (PR #2283/#2292/#2286 + A26 unfiled) |

**Resolved since prior tally** (no longer counts toward future drop-on-fix):

| Item | LOC saved | When |
|---|---|---|
| **A1 + A2 + B3 — cookie clearing** | ~50 | DONE 2026-04-27 (PR #2255 + gem cleanup) |
| **A8 — `#id` rewriter** | ~60 | DONE 2026-04-27 (PR #2244 + gem polyfill removed) |
| **A4 + A5 — form.submit / document.write** (gem-side cleanup) | ~167 | DONE 2026-04-28 (`CLICK_JS` slim, `IMPLICIT_SUBMIT_JS` slim, regression block dropped) |
| **A14 — requestSubmit polyfill** | ~20 | DONE pre-2026-04-28 |
| **A20 — formaction/formmethod/formenctype** | bundled with A4 | DONE 2026-04-28 (PR #2279 + gem cleanup) |
| **A6, A7, A15, A16, A17, B7 — assorted skip patterns** | 9 patterns | DONE 2026-04-28 (PRs all merged + spec_helper cleaned) |

**Total remaining drop-on-fix surface**: roughly **~915 LOC of gem-side code** plus ~12 spec_helper skip patterns. The XPath polyfill alone is ~700 LOC.

---

## Quick wins (for upstream contributors)

Highest-impact open / unfiled items:

1. **B1 (`XPathResult` / `document.evaluate`)** — biggest LOC savings (~700 LOC). Native implementation would also fix XPath-in-iframes and edge cases in the gem's evaluator.
2. **A24 (UA stylesheet display:none)** — PR #2294 already filed. Fixes `el.checkVisibility()` for HEAD/SCRIPT/STYLE/etc. without per-call special cases. Lets the gem collapse `_lightpanda.isVisible` to Cuprite shape.
3. **B2 (`Page.getNavigationHistory` / `navigateToHistoryEntry`)** — PR #2289 already filed. Replaces JS `history.back()` / `history.forward()` with the spec-compliant CDP path; better cross-origin behavior.
4. **A3 (`handleJavaScriptDialog`)** — PR #2261 already filed. Fixes confirm/prompt return-value override; small upstream change.
5. **A25 (`<input type=image>` submit)** — not yet filed. Small targeted fix in the click-handling path; should mirror `<input type=submit>` post-PR-#2244.
6. **A26 (textarea LF→CRLF normalization)** — not yet filed. Single-spot fix in `Frame.submitForm` (or the form-data-set construction).

## What this gem won't ever fix (run cuprite)

- Real screenshots / pixel diffs / visual regression
- Layout-dependent tests (scroll, resize, real geometry)
- Service Workers, WebAuthn, SharedArrayBuffer
- Anything requiring a compositor

The dual-driver pattern (`BROWSER=lightpanda` env gate + cuprite fallback) documented in the gem's README is the answer for these.
