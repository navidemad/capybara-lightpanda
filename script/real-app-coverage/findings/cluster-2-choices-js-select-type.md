# Cluster #2 — Choices.js fails to initialize (`HTMLSelectElement.type` is undefined)

**Status:** FILED UPSTREAM. Root cause confirmed AND minimally reproduced (Lightpanda browser-side). NOT gem-fixable.
**Upstream issue:** lightpanda-io/browser#2738 · **Upstream PR:** lightpanda-io/browser#2739 (open as of 2026-06-13). Implements `HTMLSelectElement.type` + `HTMLOptionElement.label` in `Select.zig` / `Option.zig` with fixture tests. Once merged + shipped in a nightly the gem floor accepts, all 23 failures clear with no gem or app change.
**Last investigated:** 2026-06-13, against browser build `1.0.0-dev.6750+ab53f92a` (= upstream `main` HEAD `ab53f92a`), gem `0.8.0`, Choices.js `11.2.3`.
**Affected tests:** 23 failures across 6 the target Rails app system test classes (second-largest cluster).

| Count | Test class |
|---|---|
| 13 | `Admin::ParkingEditSigningStateHandlerTest` |
| 3 | `Admin::SubscriptionFormTest` |
| 3 | `AdminLandingPageSectionsBlocksEditorTest` (the carousel editor) |
| 2 | `Dashboard::TerminationsTest` |
| 1 | `Checkout::PicksSidebarMultiSpotsTest::UserLoggedAsProCustomerTest` |
| 1 | `Checkout::ProCheckoutTest` |

Distinct `<select>` ids affected: `parking_signing_state` (13×), `subscription_other_fields_spot_ids` (3×), `multi_spots_desired_spots_count` (2×), `spot_other_new_spot_id` (2×).

---

## Symptom

Two phrasings of the same failure:

```
RuntimeError: Choices not fully initialized for select#parking_signing_state after 15s.
  Debug info: {hasSelect: true, hasController: true, hasStimulusController: true,
               hasChoicesInstance: false, hasChoicesStore: false, isInitialized: true, ...}
```
```
Minitest::Assertion: Expected no js errors, but these errors were found:
  [Choices ...] ❌ Failed to initialize:
  TypeError: Cannot read properties of undefined (reading 'forEach')
    at i._addPredefinedChoices (.../chunk....js)
    at i._initStore (...)
    at i.init (...)
```

The Choices instance never finishes constructing, so the gem's choices controller times out waiting for `_store`/the instance.

## Root cause (source-confirmed)

**`HTMLSelectElement.type` returns `undefined` in Lightpanda.** The HTML spec requires it to return `"select-one"` (no `multiple` attribute) or `"select-multiple"`.

Choices.js init flow:
1. `init()` → `_loadChoices()`. The branch that builds `this._presetChoices` is gated on `this._isSelectElement`.
2. `_isSelectElement` is derived from `passedElement.type`:
   `isSelectOne = (elementType === "select-one")`, `isSelectMultiple = (elementType === "select-multiple")`, `_isSelectElement = isSelectOne || isSelectMultiple`.
   With `select.type === undefined`, **both are false** → `_isSelectElement = false`.
3. So `_loadChoices()` runs neither the text nor the select branch → **`this._presetChoices` is never assigned (stays `undefined`)**.
4. `init()` later calls `_initStore()` → `withTxn(() => _addPredefinedChoices(this._presetChoices, ...))` → `choices.forEach(...)` on `undefined` → `TypeError`.

(Choices.js source refs, v11.2.3 unminified, `node_modules/choices.js/public/assets/scripts/choices.js`: element-type detection at line 3411 `var elementType = passedElement.type;` and 3419–3426; `_loadChoices` select branch at 4416–4423; `_initStore`/`_addPredefinedChoices` at 5238–5278.)

A secondary missing IDL attribute was also found: **`HTMLOptionElement.label` returns `undefined`** when the `<option>` has no `label` attribute (spec: falls back to text content). This does NOT cause the crash — Choices reads `option.label` into each choice; it would just yield wrong/blank labels. But it should be fixed in the same PR for spec compliance. `option.text`, `option.value`, `option.selected`, `option.disabled`, `select.multiple`, `optgroup.label`, and `:scope`-qualified `querySelectorAll` all work correctly (verified).

## Upstream source location

Build under test = upstream `main` HEAD `ab53f92a` (in `/Users/navid/code/browser`).

- `src/browser/webapi/element/html/Select.zig` — has `getValue`, `getMultiple`, `getName`, `getSize`, `getForm`, `getLabels`, etc., but **no `getType`**, and no `type` entry in the JS-binding block (lines ~320–337). This is the bug.
- `src/browser/webapi/element/html/Option.zig` — has `getValue`, `getText`, `getSelected`, etc., but **no `getLabel`** (secondary).

### Proposed fix (trivial, modeled on existing getters)

In `Select.zig`:
```zig
pub fn getType(self: *const Select) []const u8 {
    return if (self.getMultiple()) "select-multiple" else "select-one";
}
```
and in the binding block:
```zig
pub const @"type" = bridge.accessor(Select.getType, null, .{});
```
(`getMultiple` already exists and reads the `multiple` attribute — see `Select.zig:128`.)

In `Option.zig`, add `getLabel` returning the `label` attribute or, when absent, the element's text content (mirror `getText` at `Option.zig:66`), and bind `label`.

## Why it is not gem-fixable

This is the app's own Choices.js library reading a standard DOM IDL attribute the browser must provide. The gem injects `_lightpanda` predicate helpers but does not (and should not) monkeypatch third-party libraries' DOM reads. The fix belongs in Lightpanda. Once `select.type` lands and is published, all 23 failures should clear with no gem or app change.

## Minimal reproducer (Rails-free, ready for an upstream issue)

`HTMLSelectElement.type` probe — pure CDP, no library needed:

```js
// data:text/html,<select id=one><option>A</option></select><select id=multi multiple><option>A</option></select>
JSON.stringify({
  selectOne_type:   document.getElementById('one').type,    // expect "select-one";  Lightpanda => undefined
  selectMulti_type: document.getElementById('multi').type,  // expect "select-multiple"; Lightpanda => undefined
  option_label:     document.querySelector('option').label, // expect "A"; Lightpanda => undefined
})
```

End-to-end with the actual library (also reproduced): load `choices.js` v11.2.3 into a page with a `<select>`, then `new Choices(select, {})` →
`TypeError: Cannot read properties of undefined (reading 'forEach') at Choices._addPredefinedChoices`.

### Repro harness used (recreate if needed)

A Node CDP script (`ws` module) that: `Target.createTarget` → `attachToTarget` → `Runtime.enable` → navigate to a `data:` URL with two selects → `Runtime.evaluate` the probe above. The browser binary is `~/.cache/lightpanda/lightpanda` (verify `dev.675x+`). Run `lightpanda serve --host 127.0.0.1 --port <p>` and point the script at `ws://127.0.0.1:<p>`.

## Recommended action

File an upstream issue + PR via the `lightpanda-upstream-pr` skill. This is a clean, small, spec-compliance fix with a minimal CDP reproducer and an obvious patch — exactly the shape that skill wants. Implement `HTMLSelectElement.type` (primary) and `HTMLOptionElement.label` (secondary) with Zig tests, build a self-contained Lightpanda+CDP reproducer, file the issue with the broken-vs-expected flow, then open a linked PR.

Add `HTMLSelectElement.type` / `HTMLOptionElement.label` to the gem's upstream wishlist and `.claude/rules/lightpanda-io.md` "missing Web APIs" notes so the 23 affected tests are explained until the fix is published.

---

## RESUME PROMPT (paste into a fresh Opus session in /Users/navid/code/capybara-lightpanda)

> You are resuming work in the `capybara-lightpanda` gem. Read
> `script/real-app-coverage/findings/cluster-2-choices-js-select-type.md`
> in full first — it has the complete root-cause analysis and a minimal repro.
> Do NOT re-derive the root cause; it is confirmed at the Zig-source level.
>
> One-line context: 23 the target Rails app system-test failures come from Choices.js
> failing to initialize because Lightpanda's `HTMLSelectElement.type` returns
> `undefined` (should be "select-one"/"select-multiple"), so Choices.js's
> `_loadChoices` never builds `_presetChoices` and `_addPredefinedChoices(undefined)`
> throws `TypeError: ...reading 'forEach'`. Secondary: `HTMLOptionElement.label`
> is also undefined. Both are missing getters in
> `/Users/navid/code/browser/src/browser/webapi/element/html/{Select,Option}.zig`.
>
> Your goal: land the upstream fix. Use the `lightpanda-upstream-pr` skill. The
> patch is trivial and specified in the findings file (a `getType` returning
> "select-multiple"/"select-one" based on the existing `getMultiple`, plus a
> `type` binding; and a `getLabel` on Option mirroring `getText`). Steps:
> 1. Verify it still reproduces on current nightly with the minimal CDP probe in
>    the findings file (the browser binary is `~/.cache/lightpanda/lightpanda`;
>    confirm it is `dev.675x+`, else rebuild from `/Users/navid/code/browser`
>    `main` — note this machine is CLT-only so a from-scratch V8 build fails;
>    use the existing `zig-out/bin/lightpanda` as fallback).
> 2. Implement `HTMLSelectElement.type` (primary) and `HTMLOptionElement.label`
>    (secondary) in the two Zig files, with Zig tests.
> 3. Build a self-contained Lightpanda+CDP reproducer (NO Ruby/Capybara) — the
>    `data:` URL + `new Choices(select)` crash, or just the `select.type` probe.
> 4. File a GitHub issue on `lightpanda-io/browser` (broken-vs-expected flow,
>    runnable repro), then open a linked PR (`Closes #N`).
> 5. Update the gem's `.claude/rules/lightpanda-io.md` and upstream wishlist to
>    note these two missing IDL attributes and that 23 app tests depend on
>    the fix.
>
> Keep both repos clean (revert any diagnostic edits; remove scratch files).
> Once the PR is open and the gem rules updated, you are done — the 23 tests
> clear automatically once the fix is published in a nightly the gem floor
> accepts; no gem or app code change is needed.
