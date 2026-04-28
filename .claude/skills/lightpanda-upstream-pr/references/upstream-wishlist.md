# Lightpanda Upstream Wishlist

What `capybara-lightpanda` patches around because of upstream gaps in
[lightpanda-io/browser](https://github.com/lightpanda-io/browser).

Each entry has:
- **Today** — actual behavior on `1.0.0-nightly.5816+a578f4d6` (verified 2026-04-27)
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

- **Today (nightly 5816)**: command still responds `-31998 InvalidParams` because the fix is not yet in the nightly. PR #1821 (>= v0.2.6) added the missing `clearRetainingCapacity()` call but didn't fix the inverted-logic guard.
- **Want**: clear ALL cookies in the in-memory jar regardless of current page origin (Chrome behavior); silently accept an empty params object per JSON-RPC convention.
- **Upstream issue**: #2254, **Upstream PR**: **#2255 MERGED 2026-04-27 04:15 UTC, by us — NOT in nightly 5816** (built 03:18 UTC, ~57 min before merge). Will ship in next nightly.
- **Gem workaround**: `lib/capybara/lightpanda/cookies.rb` — `Cookies#clear` ignores the response and falls through to a per-origin sweep using `Browser#visited_origins`.
- **Drop-on-fix**: bump `MINIMUM_NIGHTLY_BUILD` past the post-merge build, then remove `sweep_visited_origins`, the `@visited_origins` tracking in `Browser#initialize`, the `record_visited_origin` helper. ~50 LOC.

### A2. `Network.getCookies` (no `urls`) scoped to current origin

- **Today (nightly 5816)**: returns only cookies for the current page's origin. Cookies set on previously-visited domains are invisible. On `about:blank`, raises `InvalidDomain`. (This actually matches Chrome's CDP spec for `Network.getCookies`, but Chrome also implements `Network.getAllCookies` for cross-origin enumeration — see B3.)
- **Want**: cross-origin enumeration via `Network.getAllCookies` (B3); the origin-scoped `Network.getCookies` itself can keep its current semantics.
- **Upstream issue**: #2254, **Upstream PR**: **#2255 MERGED 2026-04-27, NOT in nightly 5816** — bundled with A1 + B3.
- **Gem workaround**: pass explicit `urls: [...]` parameter for cross-origin enumeration. Track visited origins in Browser. (Same workaround as A1.)
- **Drop-on-fix**: alongside A1.

### A3. `Page.handleJavaScriptDialog` always errors

- **Today**: returns `-32000 No dialog is showing`. Dialogs auto-dismiss in headless mode (alert→OK, confirm→false, prompt→null) before a handler can intervene. The CDP method exists since commit 7208934b (2026-04-06) but has no effect.
- **Want**: support deferred dialog handling — `accept`/`promptText` should override the auto-dismiss return value.
- **Upstream issue**: #2260, **Upstream PR**: #2261 (open as of 2026-04-27, by us — pre-arm model).
- **Gem workaround**: `lib/capybara/lightpanda/browser.rb` — `prepare_modals` / `accept_modal` / `dismiss_modal` / `find_modal` capture messages via `Page.javascriptDialogOpening` for matching, but never call `handleJavaScriptDialog`. Result: `accept_modal(:confirm|:prompt)` cannot influence the JS return value.
- **Drop-on-fix**: rewire modal handlers to actually call `Page.handleJavaScriptDialog` (must be off the dispatch thread to avoid the synchronous-CDP-from-event-handler deadlock). Removes 4 skip-list patterns in `spec/spec_helper.rb` (`#accept_confirm`, `#accept_prompt`, `#accept_alert if text doesn't match`, `#accept_alert nested modals`). ~30 LOC + skip patterns.

### A4. ~~`form.submit()` does not navigate~~ — NOT A BUG (gem misdiagnosis, retracted 2026-04-27)

- **Resolution**: Lightpanda's native `form.submit()`, `submit_button.click()`, `form.requestSubmit()`, and Enter-in-text-input implicit submission **all navigate correctly** on current nightly. Verified empirically against `1.0.0-nightly.5816+a578f4d6` with a pure-CDP probe at `/tmp/a4-probe/probe-button-click.js` (POST + GET + redirect chain all PASS).
- **What was actually wrong**: the gem's `CLICK_JS` fetch+swap workaround was added 2026-04-26 in commit `35ee402` based on the assumption that `Frame.submitForm` doesn't call into navigation. But `git blame` of `src/browser/Frame.zig` shows `submitForm` has been calling `scheduleNavigationWithArena` since 2026-03-24 (commit `^afb0c292`). The workaround was either a misdiagnosis of a different symptom or stale empirical evidence.
- **Gem-side action (TODO)**: simplify `CLICK_JS` to just call `this.click()` for submit buttons; remove `IMPLICIT_SUBMIT_JS` and the `\n`-routing branch in `Node#fill_text_input`. ~150 LOC. Verify with `bundle exec rake spec:incremental`. Keep label-click forwarding and `<summary>`/`<details>` toggle (those are real upstream gaps).
- **Drop-on-fix**: N/A upstream — gem cleanup only.

### A5. ~~`document.write()` is a no-op~~ — NOT A BUG (retracted 2026-04-27 alongside A4)

- **Resolution**: Lightpanda's `document.open(); document.write(html); document.close()` correctly replaces the document body on current nightly. Verified empirically: probe writes `<h1>WRITTEN_PAGE</h1>` and `document.body.innerHTML` reflects it, `document.body.innerText.includes("WRITTEN_PAGE") === true`. Probe at `/tmp/a4-probe/probe-doc-write.js`.
- **What was wrong**: the same 2026-04-26 commit (`35ee402`) that added the `form.submit()` workaround also asserted `document.write()` was a no-op. Both claims are contradicted by today's nightly.
- **Gem-side action**: not directly used in the gem (CLICK_JS uses `body.innerHTML = ...`, not `document.write`), so removing the A5 entry is informational only. Drops alongside the A4 cleanup.
- **Drop-on-fix**: N/A.

### A6. `Page.reload` does not replay POST

- **Today**: a refresh after a POST navigation does a GET to the same URL, not a re-POST. Form action handlers don't re-run.
- **Want**: replay the POST as Chrome does (with confirmation prompt that headless can auto-accept).
- **Upstream issue**: #2258, **Upstream PR**: #2259 (open as of 2026-04-27, by us).
- **Gem workaround**: none. Skip-listed in `spec/spec_helper.rb` (`#refresh it reposts`).
- **Drop-on-fix**: remove the skip pattern.

### A7. `<select>` without `<option>` serialized as `""` in FormData

- **Today**: `new FormData(form)` includes a `<select>` with zero options as an empty-string entry.
- **Want**: per HTML spec, omit the entry.
- **Upstream issue**: #2262, **Upstream PR**: #2264 (open as of 2026-04-27, by us).
- **Gem workaround**: none. Skip-listed (`#click_button on HTML4 form should not serialize a select tag without options`).
- **Drop-on-fix**: remove the skip pattern.

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

### A14. `requestSubmit()` not implemented on `HTMLFormElement`

- **Today (nightly 5816)**: native `HTMLFormElement.prototype.requestSubmit` exists (PR #1891 merged 2026-03-17, follow-up PR #1984 merged 2026-03-24 — both shipped in nightly.5812+). Functional behavior is correct: dispatches a `SubmitEvent`, validates submitter button, throws TypeError / NotFoundError per spec. The gem polyfill's `if (!HTMLFormElement.prototype.requestSubmit)` guard means it is a no-op on current nightly.
- **Residual spec bug (still in 5816)**: `requestSubmit()` with no submitter argument sets `event.submitter` to the form element; per HTML spec it should be `null`. **Upstream issue**: #2252, **Upstream PR**: **#2253 MERGED 2026-04-27 04:20 UTC, by us, NOT in nightly 5816** (built 03:18 UTC, ~1h before merge). Will ship in next nightly.
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js` polyfill at end of file (~20 LOC). Now superseded by native impl (already a no-op via the existence guard).
- **Drop-on-fix**: remove the polyfill IIFE. Safe to do today even before #2253 ships — the gem isn't asserting `event.submitter === null` anywhere, and the polyfill is already inactive on current nightly. Defer until next gem release for safety.

### A15. `window.location.pathname =` doesn't trigger navigation

- **Today**: only `.href =` triggers navigation. Setting `.pathname`, `.search`, `.hash` updates the URL string but doesn't navigate.
- **Want**: any `location` part assignment triggers navigation, like Chrome.
- **Upstream PR**: #2257 (open as of 2026-04-27, by us — covers `.pathname` and `.search`; `.hash` is in-page anchor and doesn't navigate cross-page).
- **Gem workaround**: none. Skip-listed: `#assert_current_path should wait for current_path` (the underlying fixture uses `window.location.pathname =`).
- **Drop-on-fix**: remove 5 skip patterns related to `assert_current_path` / `has_current_path`.

### A16. URL fragments dropped through redirects

- **Today**: visiting `/redirect#fragment` lands on `/landed`, dropping `#fragment`.
- **Want**: preserve fragment through redirect (RFC 7231 §7.1.2 — fragment carries forward unless Location header has its own).
- **Upstream issue**: #2263, **Upstream PR**: #2265 (open as of 2026-04-27, by us).
- **Gem workaround**: none. Skip-listed: `#current_url maintains fragment`.
- **Drop-on-fix**: remove skip pattern.

### A17. `<input type=range>` constraints not enforced

- **Today**: `set` writes the value but Lightpanda doesn't clamp/validate against `min`/`max`.
- **Want**: enforce min/max on value assignment per WHATWG `type=range` value sanitization (step matching is a separate follow-up).
- **Upstream issue**: #2266, **Upstream PR**: #2267 (open as of 2026-04-27, by us — covers min/max clamp; step matching deferred).
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

### A20. `formaction` / `formmethod` / `formenctype` on submit button not honored

- **Today (nightly 5816)**: native click on a `<button type=submit formaction="/X">` (or `formmethod=`, `formenctype=`) navigates to the form's `action` with the form's `method`/`enctype`, ignoring the submitter's overrides. Only `formtarget` is honored. Empirically verified with a CDP probe at `/tmp/a4-probe/probe-formaction.js` (3 of 4 cases FAIL on default nightly — `formaction`, `formmethod`, and combined override). `Frame.submitForm` reads `action`/`method`/`enctype` only from the form element (`Frame.zig:3735, 3752, 3753`); the symmetrical submitter-first lookup that already exists for `formtarget` (lines 3684-3691) is missing for the other three attributes.
- **Want**: per [HTML Living Standard form submission algorithm](https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#concept-form-submit), when a submit button is the submitter, `formaction` / `formmethod` / `formenctype` on the submitter override the form's corresponding attributes (mirroring how `formtarget` already works upstream).
- **Surfaced**: 2026-04-27 while verifying A4 was a misdiagnosis. The gem's `CLICK_JS` workaround (originally added for the wrong reason) coincidentally hides this real bug — see `node.rb` `CLICK_JS` reads `this.getAttribute('formaction') || form.getAttribute('action') || ...`, so the gem-side fetch+swap path uses the right URL while native CDP-driven Capybara wouldn't.
- **Gem workaround**: implicit. The fetch+swap in `CLICK_JS` reads `formaction`/`formmethod`/`formenctype` directly off the submitter button before issuing the fetch.
- **Drop-on-fix**: trim the formaction/formmethod/formenctype handling out of `CLICK_JS` once the fix ships in nightly. Combined with the now-stale A4 cleanup, the entire `CLICK_JS` fetch+swap path becomes deletable (~150 LOC). The text-content fallback for `<button name>` without explicit `value` may need a separate small probe before deletion.

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

- **Today (verified 2026-04-28 against `main` HEAD via source inspection)**: `StyleManager.hasDisplayNone` at `src/browser/StyleManager.zig:239-243` honors only the `[hidden]` attribute as a UA-stylesheet rule. Grepping `src/browser/{StyleManager.zig,css/}` and `src/browser/webapi/Element.zig` for tag-name UA defaults (`script`/`style`/`head`/`title`/`noscript`/`template`/`details`/`input[type=hidden]`) turns up nothing. Empirically, `getComputedStyle(scriptEl).display` returns the inherited default (e.g. `'block'` from `<body>`) instead of `'none'`, and `el.checkVisibility()` returns `true` for `<head>`, `<script>`, `<style>`, `<noscript>`, `<template>`, `<title>`, `<input type="hidden">`, and the collapsed children of `<details>:not([open])>*:not(summary)`.
- **Want**: per the [HTML Rendering spec §15.3.1 "Hidden elements"](https://html.spec.whatwg.org/multipage/rendering.html#hidden-elements), the UA stylesheet maps these tags and selector patterns to `display: none`:
  - `area, base, basefont, datalist, head, link, meta, noembed, noframes, param, rp, script, source, style, template, track, title { display: none; }`
  - `input[type="hidden" i] { display: none; }`
  - `details:not([open]) > *:not(summary) { display: none; }`
  
  With these baked into `hasDisplayNone` (or a built-in UA stylesheet pass that runs before user CSS), `el.checkVisibility()` matches Chrome for all of the above without per-call special cases.
- **Upstream issue**: #2293, **Upstream PR**: #2294 (open as of 2026-04-28, by us).
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js` — `_lightpanda.isVisible` (~30 LOC) walks ancestors itself: rejects HEAD/TEMPLATE/NOSCRIPT/SCRIPT/STYLE/TITLE tags and `<input type="hidden">`, walks ancestors looking for `[hidden]` and closed `<details>`, special-cases `<summary>` as visible inside a closed `<details>`, then falls back to `el.checkVisibility()` and `getComputedStyle()` for the rest. The comparable Cuprite helper at `lib/capybara/cuprite/javascripts/index.js#isVisible` (~25 LOC) only checks `display`/`visibility`/`opacity` at each ancestor — Chrome's UA stylesheet handles every other case implicitly.
- **Drop-on-fix**: simplify `_lightpanda.isVisible` down to roughly Cuprite's shape — drop the tag-name allowlist, the `[hidden]` ancestor walk, the `<details>` open/`<summary>` carve-out. Keep the `offsetParent === null` fallback for ancestor `display:none` since that still requires real layout. ~20 LOC saved + the polyfill becomes substantially less surprising.

---

## B. Missing CDP / DOM methods

### B1. `XPathResult` interface and `document.evaluate` not implemented

- **Today**: `document.evaluate` is undefined; `XPathResult` constants don't exist.
- **Want**: native XPath 1.0 evaluator on Document.
- **Gem workaround**: `lib/capybara/lightpanda/javascripts/index.js` — full XPath 1.0 evaluator (~700 LOC) covering tokenizer, parser, AST evaluation, all 13 axes, 27 functions. Exposed as `window._lightpanda.xpathFind` and as `document.evaluate` polyfill.
- **Drop-on-fix**: remove the entire `XPathEval` IIFE and the `XPathResult`/`document.evaluate` polyfill. ~700 LOC.

### B2. `Page.getNavigationHistory` / `Page.navigateToHistoryEntry` not implemented

- **Want**: standard CDP history APIs.
- **Upstream issue**: #2288, **Upstream PR**: #2289 (open as of 2026-04-28, by us).
- **Gem workaround**: `lib/capybara/lightpanda/browser.rb` — `back` and `forward` use JS `history.back()` / `history.forward()` instead.
- **Drop-on-fix**: switch to the CDP methods (more reliable than JS for cross-origin history).

### B3. `Network.getAllCookies` not implemented

- **Today (nightly 5816)**: `Network.getAllCookies` is still missing from the dispatch enum — calling it returns `-31998 UnknownMethod`. Empirically verified.
- **Want**: a way to enumerate all cookies in the jar regardless of origin.
- **Upstream issue**: #2254, **Upstream PR**: **#2255 MERGED 2026-04-27, NOT in nightly 5816** — bundled with A1 + A2.
- **Gem workaround**: pass explicit `urls:` to `Network.getCookies` (see A2).
- **Drop-on-fix**: simplify `Cookies#all` to one `Network.getAllCookies` call (currently uses origin-scoped `Network.getCookies`).

### B4. `<input type=file>` / `Page.setFileInputFiles` not implemented (#2175)

- **Want**: file upload support.
- **Gem workaround**: `Node#set` raises `NotImplementedError` for file inputs. Skip-listed: 26 `#attach_file` specs.
- **Drop-on-fix**: implement `Node#set_file` using `Page.setFileInputFiles`. Removes 26 skip patterns.

### B5. `Input.dispatchKeyEvent` modifier flags incomplete

- **Today (verified 2026-04-28 against `main` HEAD `2bbf23b3`)**: probed via `/tmp/b5-probe/`. Three independent issues surface in the three skip-listed specs:
  1. `KeyboardEvent.keyCode` and `charCode` are hardcoded stubs returning `0` (`KeyboardEvent.zig:273-282`). Fails `should generate key events` (test expects `keyCode=84` for 't'-key keydown, observes `0`). **Upstream issue**: #2291, **Upstream PR**: #2292 (open as of 2026-04-28, by us).
  2. `Input.dispatchKeyEvent` for `ArrowLeft`/`ArrowRight`/`Home`/`End` doesn't move the input caret. Fails `should send special characters` (which uses `:left` to position the cursor mid-string before inserting a char). **Not yet filed.**
  3. **Gem-side**: `Capybara::Lightpanda::Keyboard#type` doesn't track standalone modifier symbols as sticky modifiers — `'ocean', :shift, 'side'` types `oceanside` instead of `oceanSIDE`. Modifier flags themselves DO propagate (probe 1 confirmed `shiftKey: true` on the resulting KeyboardEvent), so this is a Ruby-side state-tracking bug, not Lightpanda's responsibility.
- **Want**: see the three sub-items above. PR #2292 only addresses (1).
- **Gem workaround**: none useful. Skip-listed: `node #send_keys should send special characters`, `should hold modifiers at top level`, `should generate key events`.
- **Drop-on-fix**: when #2292 ships in nightly, remove the `should generate key events` skip pattern. The other two skip patterns need (2) and (3) to be addressed independently.

### B6. `validity` API not implemented

- **Want**: `el.validity.valid`, `el.validity.valueMissing`, `el.validationMessage`.
- **Upstream issue**: #2284, **Upstream PR**: #2286 (open as of 2026-04-28, by us).
- **Gem workaround**: none. Skip-listed: `#has_field with valid should be true if field is valid`, `should be false if field is invalid`.
- **Drop-on-fix**: remove skip patterns.

### B7. CSS escape sequences inside quoted attribute values not decoded

- **Today (verified 2026-04-27 against nightly.5812+b3257754)**: numeric Unicode escapes in `#id` and `.class` (e.g. `#\31 escape\.me`, `.\32 escape`) **work** — PR #1350 (merged 2026-01-09) wired `parseEscape` into identifier parsing. The remaining broken case is escape sequences inside **quoted attribute values**: `p[data-random="abc\\def"]` does not match an element with `data-random="abc\def"` because `Parser.attributeValue` (`src/browser/webapi/selector/Parser.zig:1005`) reads the quoted string via `std.mem.indexOfScalarPos` without decoding CSS escapes, so `\\` survives as two literal bytes instead of one.
- **Want**: per CSS Syntax Level 3 §4.3.7, decode escape sequences inside quoted strings — `\\` → `\`, `\"` → `"`, `\'` → `'`, hex escapes, line continuations.
- **Upstream issue**: #2268, **Upstream PR**: #2269 (open as of 2026-04-27, by us).
- **Gem workaround**: none. Of the two skip-listed Capybara specs, `#find with css selectors should support escaping characters` (cases `#\31 escape\.me`, `.\32 escape`) **passes against current nightly** — likely flipping to passing once the `find_spec.rb:91` skip pattern is removed. Only `#has_css? should allow escapes in the CSS selector` (the `p[data-random="abc\\def"]` case from `has_css_spec.rb:256-259`) genuinely needs the upstream fix.
- **Drop-on-fix**: remove the `#has_css?` skip pattern (needs PR #2269 in nightly). The `#find` pattern can probably be removed today after re-running the spec against nightly.
- **Probe**: `/tmp/b7-probe/` has a 3-case CDP probe that demonstrates which forms work / fail. Reuse for the upstream reproducer.

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

If all of section A + B land upstream, the gem can shed roughly:

| Item | LOC saved | Reason |
|---|---|---|
| **B1 — XPath evaluator** | ~700 | Whole `XPathEval` IIFE in index.js |
| ~~**A4 + A5 — form.submit / document.write**~~ | ~~~150~~ | RETRACTED 2026-04-27 — never actually broken upstream; gem cleanup tracked under A4 |
| ~~**A8 — `#id` rewriter**~~ | ~~~60~~ | DONE 2026-04-27 — PR #2244 merged + shipped + gem polyfill removed |
| **A1 + A2 + B3 — cookie clearing** | ~50 | `sweep_visited_origins`, `visited_origins` tracking |
| **A3 — handleJavaScriptDialog** | ~30 + 4 skips | Modal handlers + 4 spec_helper skip patterns |
| **A12 — WebSocket nav crash** | ~30 | `handle_navigation_crash` reconnect |
| **A14 — requestSubmit polyfill** | ~20 | Polyfill IIFE in index.js |
| **A11 — NoExecutionContextError race** | ~15 + 4 call-sites | `with_default_context_wait` |
| **A10 — Page.loadEventFired fallback** | ~20 | Simplify (don't fully remove — keep readyState as safety net) |
| **A21 — `:disabled` inheritance** | ~28 | `_lightpanda.isDisabled` polyfill |
| **A22 — `Element.isContentEditable`** | ~12 | `_lightpanda.isContentEditable` polyfill |
| **A23 — `Element.innerText` block-level newlines** | ~50 | `_lightpanda.visibleText` polyfill |
| **A24 — UA stylesheet display:none defaults** | ~20 | Slim `_lightpanda.isVisible` to Cuprite-shape |
| **B4 — file uploads** | adds ~30, removes 26 skips | Net positive: enables a feature |
| **A15, A16, A17, A18, B5–B11 — assorted** | 30+ skip patterns | Removes spec_helper skip list entries |

**Total drop-on-fix surface**: roughly **~1220 LOC of gem-side code becomes deletable**, plus ~50 spec_helper skip patterns become removable. The XPath polyfill alone is ~700 LOC. Removing the JS-side hacks would also let us delete most of the `_lightpanda` namespace IIFE in `index.js`.

---

## Quick wins (for upstream contributors)

If filing one PR, these are the highest-impact:

1. **A8 (`#id` rewriter)** — already filed (#2244). Small, targeted patch in `Frame.getElementByIdFromNode`. Fixes Turbo Drive interaction.
2. **A1/A2 (cookie clearing)** — make `Network.clearBrowserCookies` actually clear the in-memory jar, OR implement `Network.getAllCookies`. Fixes `reset_session!` semantics across multi-domain tests.
3. **B1 (`XPathResult` / `document.evaluate`)** — biggest LOC savings (~700 LOC). Native implementation would also fix XPath-in-iframes, edge cases in our evaluator.
4. **A3 (`handleJavaScriptDialog`)** — fixes confirm/prompt return-value override; small upstream change.

(A4 was previously listed here but has since been retracted as not-a-bug — see Section A.)

## What this gem won't ever fix (run cuprite)

- Real screenshots / pixel diffs / visual regression
- Layout-dependent tests (scroll, resize, real geometry)
- Service Workers, WebAuthn, SharedArrayBuffer
- Anything requiring a compositor

The dual-driver pattern (`BROWSER=lightpanda` env gate + cuprite fallback) documented in the gem's README is the answer for these.
