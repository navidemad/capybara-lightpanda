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

### A3. `Page.handleJavaScriptDialog` always errors — FIXED + SHIPPED + GEM CLEANED UP (one residual)

- **Resolution**: `Page.handleJavaScriptDialog` deliberately stays as `-32000 No dialog is showing` (commit `8cc82d1d`, 2026-04-29) and points clients at the new `LP.handleJavaScriptDialog` pre-arm method. **PR #2261 MERGED 2026-04-29**, in nightly ≥5900. Pre-arm model: client sends `LP.handleJavaScriptDialog {accept, promptText}` BEFORE the action that triggers the dialog; Lightpanda's BC stashes the response in `pending_dialog_response` (single slot) and consumes it when the dialog opens.
- **Gem cleanup landed 2026-04-29**: `Browser#accept_modal` / `#dismiss_modal` (`lib/capybara/lightpanda/browser.rb`) send the LP command immediately on call (which lands before the `Driver#accept_modal { block.call }` runs). `prepare_modals` keeps the `Page.javascriptDialogOpening` handler for message capture (drives `find_modal`). `@modal_responses` queue dropped. 4 skip patterns removed in `spec/spec_helper.rb` (`#accept_confirm`, `#accept_prompt should accept the prompt`, `#accept_prompt should allow special characters`, `#accept_alert nested modals`).
- **Residual gap (A27)**: when `promptText` is null/missing, Lightpanda returns null/empty rather than falling back to the JS prompt's `defaultText` argument. Skip pattern `#accept_prompt should accept the prompt with no message when there is a default` retained. See A27 below.
- **Drop-on-fix**: N/A — done. (A27 covers the residual.)

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

### A21. `:disabled` selector / "actually disabled" doesn't inherit through `<fieldset>` / `<optgroup>`

- **Today (verified 2026-04-29 against `main` HEAD + nightly 5839 via CDP probe)**: `el.matches(':disabled')` only checks the element's own `disabled` content attribute. `src/browser/webapi/selector/List.zig:537-541` reads `el.getAttributeSafe("disabled") != null` directly — no ancestor walk. So `<fieldset disabled><input></fieldset>` reports `input.matches(':disabled') === false`, and `<optgroup disabled><option></optgroup>` reports `option.matches(':disabled') === false`. Empirical 8-case CDP probe at `repro/a21-disabled-inheritance/` confirms 3 of 8 cases mismatch the spec.
- **Want**: per [HTML §4.10.18.3 "Enabling and disabling form controls"](https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#enabling-and-disabling-form-controls), a form control (button/input/select/textarea/form-associated custom) is "actually disabled" when its own `disabled` attribute is set OR a disabled ancestor `<fieldset>` contains it (with the first-`<legend>` exception). `<option>` is `:disabled` per [HTML §4.10.10 "concept-option-disabled"](https://html.spec.whatwg.org/multipage/form-elements.html#concept-option-disabled) when its own attribute is set OR its parent is an `<optgroup disabled>`. Note `<option>` does NOT inherit from `<select disabled>` or `<fieldset disabled>` — only `<optgroup disabled>` parent contributes (verified against Chrome 130).
- **Upstream issue**: #2314, **Upstream PR**: #2315 (open as of 2026-04-29, by us — routes `:disabled`/`:enabled` matchers through `Element.isDisabled`; extends `isDisabled` to recognize the `<option>` + `<optgroup disabled>` case while keeping the fieldset walk).
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js` — `_lightpanda.isDisabled` walks ancestor `<fieldset>` / `<optgroup>` / `<select>` to honor the inherited cases, with the fieldset-first-legend exception (~28 LOC). Called from `DISABLED_JS` in `lib/capybara/lightpanda/node.rb:678`, which backs `Node#disabled?`. Note the polyfill overreaches slightly vs. spec by treating `<option>` inside `<select disabled>` as disabled (line 910); the upstream fix targets spec-correct behavior.
- **Drop-on-fix**: replace the polyfill with `el.matches(':disabled')` and inline the call at the `DISABLED_JS` constant. Drops `_lightpanda.isDisabled` (~28 LOC).

### A22. `Element.isContentEditable` — IDL attribute landed but always returns false (cannot drop polyfill)

- **Today (verified 2026-05-01 against `main` HEAD `9a9e79eb`, build 5948)**: `HTMLElement.isContentEditable` IDL accessor exists (`src/browser/webapi/element/Html.zig:398-407`), but the implementation always returns `false`. PR #2310 (by us) originally implemented the spec-correct walk, but the maintainer added commit `2af95af6` immediately before merge that strips the return path: it walks ancestors per HTML §7.7.5.2, but only to emit `log.info(.not_implemented, "IsContentEditable", ...)` when the spec answer would be `true` — the function unconditionally returns `false`. Rationale (from the commit body): Lightpanda has no caret/keyboard editing pipeline, so a spec-correct `true` would route Puppeteer's `dispatchKeyEvent` into a silently-noop input pipeline; routing to `false` and logging the unsupported case surfaces the gap in telemetry rather than masquerading as a working state.
- **Upstream issue/PR**: #2309 CLOSED 2026-04-30, PR #2310 MERGED 2026-04-30 (with the maintainer override).
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js:910-921` — `_lightpanda.isContentEditable` falls back to walking the ancestor chain looking for a non-`false` `contenteditable` attribute when `el.isContentEditable` is falsy/missing (~12 LOC). Called from `EDITABLE_HOST_JS` in `lib/capybara/lightpanda/node.rb:503`, which backs `Node#content_editable?`. **Polyfill MUST stay** — replacing it with the native read would force every `Node#content_editable?` call to return false.
- **Drop-on-fix**: blocked indefinitely, contingent on Lightpanda implementing a real keyboard-editing pipeline. Until then, the gem polyfill is load-bearing.

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
- **Upstream issue**: #2311, **Upstream PR**: #2312 (open as of 2026-04-29, by us — extends `Frame.handleClick`'s `.input` arm to match `.image`; FormData.collectForm's image-submitter branch already emits `name.x`/`name.y` correctly so only the routing is changed).
- **Gem workaround**: `CLICK_JS` (`lib/capybara/lightpanda/node.rb`) special-cases `<input type=image>` and calls `form.requestSubmit()` after the click (~5 LOC). Coordinate fields (`name.x` / `name.y`) are NOT appended; Capybara tests don't assert on them, but a real-app spec that read those server-side would fail.
- **Drop-on-fix**: remove the image-button branch in `CLICK_JS`. ~5 LOC.

### A26. Textarea field values not normalized to CRLF on form submission

- **Today (nightly 5839)**: native form submission sends raw `\n` for `<textarea>` field values; should be `\r\n` per HTML's [form-data set algorithm](https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#constructing-the-form-data-set) (step "If entry's value is a string, replace every occurrence of U+000D (CR) not followed by U+000A (LF), and every occurrence of U+000A (LF) not preceded by U+000D (CR), in entry's value, by a string consisting of U+000D (CR) and U+000A (LF)"). Affects `application/x-www-form-urlencoded` POST bodies and the GET query-string path. Surfaced 2026-04-28 when the gem dropped its fetch+swap path (the JS `formEncode` did the CRLF conversion).
- **Want**: normalize textarea field values to CRLF in the form-data set encoder. The same normalization applies during the per-entry value processing for both encodings.
- **Upstream issue**: #2307, **Upstream PR**: #2308 (open as of 2026-04-28, by us — adds `writeFormLineEnd` helper to `KeyValueList.urlEncodeValueUtf8` / `urlEncodeValueLegacy`, gated on `mode == .form`; `URLSearchParams.toString()` (`mode == .query`) intentionally untouched per the URL standard).
- **Gem workaround**: none. Pre-normalizing in `Node#set` would over-normalize (textarea would display `\r\n` chars). The fix has to live in Lightpanda's HTTP layer. Skip-listed: `#click_button.*should convert lf to cr/lf in submitted textareas`, `#fill_in should handle newlines in a textarea`.
- **Drop-on-fix**: remove the 2 skip patterns.

### A27. `LP.handleJavaScriptDialog` doesn't fall back to dialog `defaultText` when `promptText` is null — FIXED + SHIPPED + GEM CLEANED UP

- **Today (verified 2026-05-01 against `main` HEAD `9a9e79eb`, build 5948)**: PR #2322 (by us, MERGED 2026-04-30) lets `Window.zig`'s `prompt` keep its second argument as `default_text` and returns `response.prompt_text orelse default_text orelse ""` on accept, matching Chrome.
- **Upstream issue**: #2321 CLOSED 2026-04-30. **Upstream PR**: #2322 MERGED 2026-04-30, in Linux nightly ≥5944.
- **Gem cleanup landed in commit `5e10ce10`** (2026-04-30): `#accept_prompt should accept the prompt with no message when there is a default` skip pattern dropped from `spec/spec_helper.rb`.

### A28. `<label>` click does not run activation behavior on associated form control — FIXED + SHIPPED + GEM CLEANED UP

- **Today (verified 2026-05-01 against `main` HEAD `9a9e79eb`, build 5948)**: PR #2324 (by us, MERGED 2026-04-30) adds a `.label` arm to `Frame.handleClick` that resolves the labeled control via `Label.getControl` and dispatches a synthetic click. Capybara's `automatic_label_click` flow now works natively.
- **Upstream issue**: #2323 CLOSED 2026-04-30. **Upstream PR**: #2324 MERGED 2026-04-30, in Linux nightly ≥5944.
- **Gem cleanup landed in commit `5e10ce10`** (2026-04-30): label arm dropped from `CLICK_JS` in `lib/capybara/lightpanda/node.rb`.

### A29. `<summary>` click does not toggle parent `<details>.open`

- **Today (verified 2026-04-29 against `main` HEAD `e981ec75`, build 5918)**: clicking a `<summary>` element fires the click event but does not toggle the parent `<details>`'s `open` attribute. Empirical probe: `<details><summary>` + `sum.click()` → `{ before: false, after: false }`. `Details.zig` exposes `getOpen`/`setOpen` but does not register a click activation handler on `<summary>` children. Per [HTML §4.11.1.2 "Activation behavior of `<summary>`"](https://html.spec.whatwg.org/multipage/interactive-elements.html#the-summary-element), the activation behavior is "if the element is a summary element that is a child of a details element, toggle the parent's `open` attribute".
- **Want**: register an activation behavior on `<summary>` that toggles `parentElement.open` when the parent is a `<details>` and the summary is the first such child. Should also fire the `toggle` event on the details, per spec, but Capybara tests only assert on the `open` attribute.
- **Upstream issue**: #2325, **Upstream PR**: #2326 (open as of 2026-04-29, by us — `.generic` arm in `Frame.handleClick` that gates on `_tag == .summary`, walks parent siblings to confirm first-summary, toggles via existing `Details.setOpen`. Fires neither `ToggleEvent` (Lightpanda lacks the type) nor activation on descendant clicks (same gap as `<a>`/`<label>` today, broader scope).
- **Gem workaround**: `CLICK_JS` (`lib/capybara/lightpanda/node.rb`) detects `<summary>`, walks to parent `<details>`, and flips `open` after dispatching the click (~6 LOC).
- **Drop-on-fix**: remove the summary/details branch from `CLICK_JS`. ~6 LOC.

### A30. `HTMLInputElement.pattern` IDL accessor + `validity.patternMismatch` not implemented

- **Today (verified 2026-05-04 against public nightly `1.0.0-nightly.6005+b8144d3e`, `main` HEAD `0420802f`)**: `HTMLInputElement.prototype.pattern` is not registered on the JS prototype — `inp.pattern` returns `undefined` even when `getAttribute('pattern')` returns the regex. `Input.suffersPatternMismatch` is a TODO stub returning `false`, so `validity.patternMismatch` never fires for `<input pattern="…">` and `validationMessage` is empty for any pattern-violating value. This is the explicit deferral from PR #2286 ("`patternMismatch` — needs JS RegExp evaluation from Zig […]; no clean Zig-side path yet"). `valueMissing` / `typeMismatch` / range / length paths from PR #2286 all work correctly.
- **Want**: per [HTML §4.10.5.3.5](https://html.spec.whatwg.org/multipage/input.html#the-pattern-attribute), reflect `pattern` as an IDL accessor on `HTMLInputElement` and implement `suffersPatternMismatch` by evaluating `new RegExp("^(?:" + pattern + ")$", "v").test(value)` via V8 on the owner frame. Apply only to text-like input types; treat empty value and unparseable regex as no constraint.
- **Upstream issue**: #2351, **Upstream PR**: #2352 (open as of 2026-05-04, by us — `getPattern`/`setPattern` mirror `getMin`/`setMin`, `pattern = bridge.accessor(...)` registered, `suffersPatternMismatch` rewritten to `frame.js.localScope` + `ls.local.exec` with JSON-encoded interpolation; `ValidityState.getPatternMismatch` plumbs `*Frame`).
- **Gem workaround**: `:html_validation` flag in `capybara_skip` list (`spec/features/session_spec.rb`) — pends Capybara's `#has_field with validation message` specs which target a `<input pattern>` field.
- **Drop-on-fix**: remove `:html_validation` from the `capybara_skip` list. 1 line in `spec/features/session_spec.rb` + the skip comment above it.

### A31. ~~`HTMLElement.click()` throws via `Runtime.callFunctionOn`~~ — NOT A BUG (gem misdiagnosis, retracted 2026-05-04)

- **Resolution**: native `el.click()` invoked via `Runtime.callFunctionOn` with an `objectId`-bound `this` works correctly on current public nightly (`1.0.0-nightly.6005+b8144d3e`, build 6005). Verified empirically via probe at `/Users/navid/code/browser/repro/a31-a32-a33-verify/probe.js` + `probe2.js`: returned `OK`, no `exceptionDetails`, all 4 ancestor listeners fire (leaf → mid → body → doc) with `event.target` preserved.
- **What was actually wrong**: gem commit `2fdcf32` (2026-05-04) added the `CLICK_JS` workaround based on `UPSTREAM_BUGS.md` Bug #1, which described `el.click()` as throwing `JsException` via `callFunctionOn`. The gem author's repro was likely run against an earlier nightly that had since been fixed, OR the symptom misattributed a different bug (the throwing-listener case — see A33 below — produces an identical `JsException` at the gem's call site).
- **Gem cleanup landed 2026-05-04**: `SET_CHECKBOX_JS` collapsed to `function(value) { if (this.checked !== value) this.click(); }` (was ~12 LOC). `CLICK_JS` itself **stays in its prior form** because it's still load-bearing for A33 (see below) — the JS-level dispatch is what allows `polyfills.js`'s `patchDispatch` IIFE to rescue throwing-listener bubble propagation. Comment block above `CLICK_JS` rewritten to point at A33 / DOM §2.9 instead of the retracted A31.
- **Drop-on-fix**: N/A — done.

### A32. ~~`dispatchEvent(new MouseEvent(...))` throws via `Runtime.callFunctionOn`~~ — NOT A BUG (gem misdiagnosis, retracted 2026-05-04)

- **Resolution**: `this.dispatchEvent(new MouseEvent('click', { bubbles: true }))` invoked via `Runtime.callFunctionOn` returns `OK` with no `exceptionDetails` on current public nightly. Same probe as A31. The plain `Event` constructor also works — both are spec-compliant.
- **What was actually wrong**: same root cause as A31. `UPSTREAM_BUGS.md` Bug #2 was described as a sibling of Bug #1; both are retracted together.
- **Gem cleanup**: none needed. `CLICK_JS` already uses plain `Event` (cheaper construction); switching to `MouseEvent` for `click(x:, y:, modifiers:)` fidelity is a future ergonomics improvement, not a bug fix. File as gem-side TODO if real-app users start asking for coordinate/modifier-aware clicks.
- **Drop-on-fix**: N/A — done.

### A33. `dispatchEvent` halts on listener throw instead of reporting exception (DOM §2.9 step 4 violation)

- **Today (verified 2026-05-04 against public nightly `1.0.0-nightly.6005+b8144d3e`, build 6005, via empirical spec re-run with `polyfills.js`'s `patchDispatch` IIFE removed)**: bubble propagation works correctly on the happy path (verified in probe2 — leaf → mid → body → doc with `event.target` preserved). **But** if any listener invoked during dispatch throws an exception, Lightpanda halts the entire dispatch path: subsequent listeners on the same node are skipped AND ancestor propagation never runs. The exception bubbles out of `dispatchEvent` to the caller. Per `spec/features/upstream_bugs_spec.rb` "invokes the document handler even when the local handler throws" — running this case without the polyfill produces a `JavaScriptError: Error: JsException` at the gem's `call_function_on` boundary, with `window.__hits` containing only the leaf phase. Real-world impact: a buggy Stimulus controller or a Turbo Drive edge-case throw silently disables document-level delegation across the whole page until the next navigation.
- **Want**: per [DOM §2.9 "Dispatching events"](https://dom.spec.whatwg.org/#concept-event-dispatch), the inner-invoke step says "If an exception is thrown by listener's callback, then ... If exception is non-null, then report exception." "Report" means surface to the global error handler / `window.onerror`, NOT halt the dispatch loop. Each listener's callback is wrapped in its own catch; the dispatch algorithm must continue invoking the remaining listeners and the bubble/capture walk regardless.
- **Upstream issue/PR**: not filed. Likely fix is a `try/catch` around each callback invocation inside the dispatch loop in `src/browser/webapi/event/EventTarget.zig` (or wherever Lightpanda calls back into V8 for each listener), with the caught exception forwarded to the inspector / global error handler instead of propagating up the call stack.
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/polyfills.js` — `patchDispatch` IIFE (~45 LOC) monkey-patches `EventTarget.prototype.dispatchEvent` to catch the surfaced `JsException`, then re-walks `parentNode` manually, calling `orig.call(node, event)` on each ancestor and spoofing `event.target` / `event.currentTarget` via `Object.defineProperty`. Pairs with `CLICK_JS` (`lib/capybara/lightpanda/node.rb`, ~22 LOC) which dispatches click events via JS-level `dispatchEvent` (so the patch can rescue them) and falls back to manual default-action (`form.submit()` / `location.href`). Suffices for Stimulus / Turbo (which don't inspect `eventPhase` or `composedPath`) but breaks the spec on `eventPhase` (always 0 for spoofed targets), `CAPTURING_PHASE` (skipped entirely), and `composedPath` (not polyfilled).
- **Drop-on-fix**: remove the `patchDispatch` IIFE from `polyfills.js` (~45 LOC) AND collapse `CLICK_JS` to `"function() { this.click(); }"` (one-liner; ~22 LOC saved). The `SET_CHECKBOX_JS` simplification already landed. Total: ~67 LOC across two files. Restores spec-correct `eventPhase`, capture-phase listeners, and `composedPath`.

### A34. `fetch` and `XHR` send `FormData` as `[object FormData]` instead of multipart-encoding it

- **Today (verified 2026-05-04 against build `1.0.0-dev.6013+6b896ba2` via `spec/features/hotwire_zones_probe_spec.rb` Zone 1 — 4 dedicated tests)**: Body coercion at the JS→Zig bridge falls through to `toString()` for any `body` that isn't a string/Blob/Stream. URLSearchParams happens to work because its native `toString()` returns a properly URL-encoded query string — but FormData's `toString()` is `"[object FormData]"`. The server therefore receives `Content-Type: application/x-www-form-urlencoded` with body `"object%20FormData"` (17 bytes), parsed as a single bogus key `"object FormData"` with `nil` value. **Identical surface for all 4 facets covered by the probe**:

  | Probe shape | Symptom |
  |---|---|
  | `fetch(url, { body: new FormData() + .append(...) })` | `params: {"object FormData" => nil}` |
  | `fetch(url, { body: new FormData(form) })` (the Turbo Drive shape) | `params: {"object FormData" => nil}` |
  | `fetch(url, { body: fd })` Content-Type assertion | `application/x-www-form-urlencoded` instead of `multipart/form-data; boundary=…` |
  | `XMLHttpRequest.send(fd)` | `params: {"object FormData" => nil}` — **identical** to fetch |

  → fetch and XHR share the same broken body-coercion path. **One upstream fix covers both.**

- **Want**: per [Fetch §6.5 "extract a body"](https://fetch.spec.whatwg.org/#concept-bodyinit-extract) step 8, when the body is a `FormData` instance, generate a random boundary, multipart-encode the entries (`Content-Disposition: form-data; name="<key>"` per part), and set `Content-Type: multipart/form-data; boundary=<boundary>`. Per [XHR §4.7.6 "send()"](https://xhr.spec.whatwg.org/#dom-xmlhttprequest-send), same algorithm.

- **Upstream issue/PR**: not filed. **Pinpoint of the fix** (verified by reading `/Users/navid/code/browser` source):
  - **Site to patch**: `src/browser/webapi/net/Request.zig:48-55`. The `InitOpts.body` field is typed `?[]const u8` — a flat string. The JS→Zig bridge thus coerces every JSValue body argument via `toString()` before it ever reaches Zig logic. Need to widen the type to a tagged union, e.g.:
    ```zig
    pub const BodyInit = union(enum) {
        bytes: []const u8,
        form_data: *FormData,
        url_search_params: *URLSearchParams,
        blob: *Blob,
        // …
    };
    ```
    similar to `src/browser/webapi/net/Response.zig:67-72` which already exposes a (narrower) `BodyInit` union — that file is the existing model to widen.
  - **Encoder is already in place**: `src/browser/webapi/net/FormData.zig:174` exposes `pub fn write(opts: WriteOpts, writer: *std.Io.Writer) !void` with `opts.encoding = .formdata` taking a boundary. The full `multipartEncode` algorithm is at `src/browser/webapi/net/FormData.zig:198`. The PR's job is to wire this into the Request body branch and emit the matching `Content-Type` header.
  - XHR-side equivalent will share the union; verify by grepping for `.send(` handlers in `XMLHttpRequest.zig` (or equivalent file) and routing them through the same `BodyInit` extractor.

- **Gem workaround**: none possible from JS land — the bug is below the JS API surface. Apps that hit Turbo Drive form submits on Lightpanda will see 422/400s server-side. A JS-level monkey-patch of `window.fetch` to detect `body instanceof FormData`, URL-encode entries, and force `Content-Type: application/x-www-form-urlencoded` would work for fields-only forms but breaks file uploads (`<input type=file>`) which require true multipart. Not implementing this in the gem until upstream lands a fix.

- **Drop-on-fix**: nothing to remove gem-side (no workaround installed). The 4 probe tests in `spec/features/hotwire_zones_probe_spec.rb` Zone 1 turn green and become regression coverage for the upstream encoder. Unblocks: every Turbo Drive form submission + every JS-driven `XMLHttpRequest`-based form post + every `<input type=file>` upload that goes through `FormData`.

---

## B. Missing CDP / DOM methods

### B1. `XPathResult` interface and `document.evaluate` not implemented

- **Today (nightly 5839)**: `document.evaluate` is undefined; `XPathResult` constants don't exist; `DOM.performSearch` only handles CSS queries.
- **Want**: native XPath 1.0 evaluator on Document, plus the WHATWG `XPathResult` / `XPathEvaluator` / `XPathExpression` surface, plus XPath query routing in `DOM.performSearch` (gives Playwright/Puppeteer/Capybara XPath-via-CDP).
- **Upstream PR**: #2305 (open as of 2026-04-28, by us — Zig port of the gem polyfill, ~3,470 LOC: tokenizer/parser/evaluator/functions/result + WHATWG webapi types + `DOM.performSearch` heuristic; matches polyfill semantics including `lang()` → `false`, `namespace::` → `[]`, lowercased `name()`/`local-name()`). 91-case conformance battery passes; full behavior spec in [XPATH_COMPLIANCE.md](https://github.com/navidemad/capybara-lightpanda/blob/main/XPATH_COMPLIANCE.md). No associated issue — the PR is a downstream coordination move.
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js` — full XPath 1.0 evaluator (~700 LOC) covering tokenizer, parser, AST evaluation, all 13 axes, 27 functions. Exposed as `window._lightpanda.xpathFind` and as `document.evaluate` polyfill.
- **Drop-on-fix**: remove the entire `XPathEval` IIFE and the `XPathResult`/`document.evaluate` polyfill. ~700 LOC. Also fixes XPath-in-iframes (the polyfill is only registered on the top frame via `Page.addScriptToEvaluateOnNewDocument`).

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

  1. **`KeyboardEvent.keyCode` and `charCode` legacy attributes** — PARTIALLY FIXED, RESIDUAL ISSUE. **PR #2292 MERGED 2026-04-28** (in nightly ≥5900, by us) implements `keyCode`/`charCode` and adds Enter charCode, BUT gates on `isTrusted: true`. Verified empirically 2026-04-29 against build 5918: events from `Input.dispatchKeyEvent` still report `keyCode: 0` because `isTrusted` is false on synthetic CDP-dispatched events. The Capybara test `node #send_keys should generate key events` asserts on these synthetic events, so it still fails. **Want**: loosen the gate so `Input.dispatchKeyEvent` emits keyCode/charCode regardless of `isTrusted`. Browsers don't normally expose synthetic events with isTrusted=true (it's a security boundary), but CDP-driven test environments are expected to surface the values. Cross-check Chrome: `Input.dispatchKeyEvent` emits events with keyCode populated. **Upstream issue**: not yet filed (was #2291, but that's resolved by #2292 — needs a follow-up issue for the CDP path). Skip pattern `node #send_keys should generate key events` retained.
  2. **`Input.dispatchKeyEvent` for `ArrowLeft`/`ArrowRight`/`Home`/`End` doesn't move the input caret**. Fails `should send special characters` (which uses `:left` to position the cursor mid-string before inserting a char). **Not yet filed.**
  3. **Gem-side bug** (separate — handled in 2b623164): `Capybara::Lightpanda::Keyboard#type` tracks standalone modifier symbols as sticky modifiers. Modifier flags propagate via CDP correctly; this was a Ruby-side state-tracking issue.
- **Gem workaround**: none. Skip-listed: `node #send_keys should send special characters` (#2), `should generate key events` (#1).
- **Drop-on-fix**: remove the `should generate key events` skip pattern when #1 is fully resolved. `should send special characters` requires sub-item (2) to be filed and fixed.

### B6. `validity` API not implemented

- **Today (nightly 5839)**: `el.validity` is undefined; `el.validationMessage` empty. Empirically `TypeError: Cannot read properties of undefined (reading 'valid')` when accessed.
- **Want**: `el.validity.valid`, `el.validity.valueMissing`, etc., and `el.validationMessage` per the [HTML constraint validation API](https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#the-constraint-validation-api).
- **Upstream issue**: #2284, **Upstream PR**: #2286 (OPEN as of 2026-04-29, by us; rebased on `origin/main` HEAD `3b3e4e41`, mergeable).
- **Maintainer feedback (2026-04-29)**: Karl questioned the use case in a top-level comment ("the server should already enforce the constraints"). Replied with the headless-test-automation argument — CDP clients assert client-side state without round-tripping the server, the constraint logic is already in Lightpanda (only the query surface is missing), and SPA submit handlers calling `form.checkValidity()` throw `TypeError` today. Offered a smaller starting cut (Input-only, defer Select/TextArea/Button/Form) as an off-ramp. Awaiting his response. Reply: https://github.com/lightpanda-io/browser/pull/2286#issuecomment-4344400646.
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

### B12. `HTMLDialogElement.prototype.{showModal, show, close}` not implemented

- **Today (observed 2026-05-04 against public nightly `1.0.0-nightly.6005+b8144d3e`; full repro in `spec/features/upstream_bugs_spec.rb` "Bug #4 — HTMLDialogElement polyfill" + `UPSTREAM_BUGS.md` Bug #4)**: the `HTMLDialogElement` constructor exists (`typeof HTMLDialogElement === 'function'`) but `prototype.showModal`, `prototype.show`, `prototype.close`, and `prototype.returnValue` are all `undefined`. Calling any of them throws `TypeError: d.showModal is not a function`. Blocks any UI built on the native `<dialog>` element (very common in Rails 8 + DaisyUI / Tailwind UI / shadcn).
- **Want**: per [HTML §4.11.4 "The dialog element"](https://html.spec.whatwg.org/multipage/interactive-elements.html#the-dialog-element), implement on `HTMLDialogElement.prototype`:
  - `show()` — adds the `open` content attribute if not already set; non-modal display.
  - `showModal()` — throws `InvalidStateError` if `[open]` is already present; otherwise sets `[open]` and (in Chrome) adds the dialog to the top layer + sets a backdrop. Lightpanda has no rendering so the focus-trap / backdrop / top-layer can be no-ops, but `[open]` MUST flip and the dialog MUST become visible to selectors.
  - `close([returnValue])` — removes `[open]`, sets `returnValue` if argument given, queues a `close` event.
  - `returnValue` getter/setter, `cancel` event on Esc (Esc handling is out of scope without input events).
- **Upstream issue/PR**: not filed. Mirrors the shape of the recently-merged `HTMLFormElement.prototype.requestSubmit` PR (A14) — single Zig file under `src/browser/webapi/element/html/`, ~3 prototype methods, no V8/CDP-runtime entanglement. Probably the smallest discrete missing-API gap in the gem.
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
| **B1 — XPath evaluator** | ~700 | Whole `XPathEval` IIFE in index.js |
| **A33 — `dispatchEvent` listener-throw halts dispatch** | ~67 | `patchDispatch` IIFE in `polyfills.js` (~45) + `CLICK_JS` collapse (~22) |
| **A23 — `Element.innerText` block-level newlines** | ~50 | `_lightpanda.visibleText` polyfill |
| **A3 — handleJavaScriptDialog** | ~30 + 4 skips | Modal handlers + 4 spec_helper skip patterns |
| **A12 — WebSocket nav crash** | ~30 | `handle_navigation_crash` reconnect |
| **B12 — `HTMLDialogElement` methods** | ~30 | Dialog block in `polyfills.js` |
| **A21 — `:disabled` inheritance** | ~28 | `_lightpanda.isDisabled` polyfill |
| **A24 — UA stylesheet display:none defaults** | ~20 | Slim `_lightpanda.isVisible` to Cuprite-shape (PR #2294 OPEN) |
| **A10 — Page.loadEventFired fallback** | ~20 | Simplify (keep readyState as safety net) |
| **A11 — NoExecutionContextError race** | ~15 + 4 call-sites | `with_default_context_wait` |
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
| **A22 — `Element.isContentEditable`** | NOT a drop-on-fix anymore | PR #2310 MERGED 2026-04-30 but the maintainer rewrote the implementation to always return `false` (commit `2af95af6`). Polyfill remains load-bearing — see A22 above. |

**Total remaining drop-on-fix surface**: roughly **~1,030 LOC of gem-side code** plus ~12 spec_helper skip patterns. The XPath polyfill alone is ~700 LOC. A33 (the narrowed listener-throw bug) + B12 (HTMLDialogElement) account for ~97 LOC of `polyfills.js` + `node.rb` workarounds. A31 + A32 retracted as misdiagnoses (see below).

---

## Quick wins (for upstream contributors)

### Open PRs awaiting upstream review (filed by us)

Reviewer focus would unlock most of the remaining gem-side cleanup. Listed by drop-on-fix impact:

1. **B1 — `XPathResult` / `document.evaluate` (PR #2305)** — biggest LOC savings (~700 LOC). Zig port of the gem polyfill; 91-case conformance battery passes. Also fixes XPath-in-iframes (the polyfill is only registered on the top frame) and routes `DOM.performSearch` XPath queries.
2. **A24 — UA stylesheet display:none (PR #2294)** — fixes `el.checkVisibility()` for HEAD/SCRIPT/STYLE/etc. Lets the gem collapse `_lightpanda.isVisible` to Cuprite shape (~20 LOC).
3. **B2 — `Page.getNavigationHistory` / `navigateToHistoryEntry` (PR #2289)** — replaces JS `history.back()` / `history.forward()` with the spec-compliant CDP path; better cross-origin behavior.
4. **A3 — `handleJavaScriptDialog` (PR #2261)** — pre-arm model so `accept_modal(:confirm|:prompt)` can override the auto-dismiss return value. Removes ~30 LOC + 4 skip patterns.
5. **B6 — Constraint validation API (PR #2286)** — `el.validity.*` and `el.validationMessage`; removes 2 skip patterns.
6. **A25 — `<input type=image>` submit (PR #2312)** — routes image-button clicks into `Frame.submitForm`; removes ~5 LOC of `CLICK_JS` special-casing.
8. **A26 — Textarea LF→CRLF normalization (PR #2308)** — `KeyValueList.urlEncode` form-data fix; removes 2 skip patterns.
9. **A21 — `:disabled` ancestor inheritance through `<fieldset>` / `<optgroup>` (PR #2315)** — ~28 LOC drop-on-fix; routes `:disabled`/`:enabled` selector matchers through `Element.isDisabled` and extends `isDisabled` for the `<option>` + `<optgroup disabled>` case.

### Unfiled items most worth claiming (need authors)

1. **A33 — `dispatchEvent` halts on listener throw (DOM §2.9 step 4 violation)** — ~67 LOC drop-on-fix. Real-world impact: a buggy Stimulus controller or Turbo Drive edge-case throw silently disables document-level event delegation across the page. Likely fix is a `try/catch` around each callback invocation inside the dispatch loop in `src/browser/webapi/event/EventTarget.zig` with the caught exception forwarded to the global error handler instead of propagating to the dispatch caller. Small, isolated reproducer (3 listeners, 1 throwing).
2. **B12 — `HTMLDialogElement.{showModal, show, close}`** — ~30 LOC drop-on-fix; smallest, cleanest scope. Pure missing-API addition; mirrors A14 (`requestSubmit`) shape exactly. Good first-PR candidate.
3. **A23 — `Element.innerText` block-level line breaks** — ~50 LOC drop-on-fix; multi-day Zig project (writer needs `getComputedStyle` access from inside the walker, plus the line-collapsing pass). Highest single-item LOC saving.
4. **A12 — WebSocket dies on complex page navigation (#1849)** — ~30 LOC drop-on-fix; partial fix from PR #1850 in 2026-03 didn't fully close the issue.
5. **A11 — `Runtime.evaluate` "Cannot find default execution context" race (#2187)** — ~15 LOC + 4 call-sites; needs queue-or-await around `executionContextCreated`.
6. **A10 — `Page.loadEventFired` reliability (#1801)** — ~20 LOC drop-on-fix; long-standing.
7. **B4 — `<input type=file>` / `Page.setFileInputFiles` (#2175)** — adds ~30 gem LOC, removes 26 skip patterns. Net positive: enables a feature.
8. **B5#2 — Caret-movement keys (`ArrowLeft`/`Home`/`End`) don't move input caret** — single skip pattern; not yet filed as an issue.

## What this gem won't ever fix (run cuprite)

- Real screenshots / pixel diffs / visual regression
- Layout-dependent tests (scroll, resize, real geometry)
- Service Workers, WebAuthn, SharedArrayBuffer
- Anything requiring a compositor

The dual-driver pattern (`BROWSER=lightpanda` env gate + cuprite fallback) documented in the gem's README is the answer for these.
