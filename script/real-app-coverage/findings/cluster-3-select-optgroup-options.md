# Cluster #3 — `<option>`s inside `<optgroup>` are invisible to every `HTMLSelectElement` accessor

**Status:** Root cause confirmed (Lightpanda browser-side), minimally reproduced with a
Ruby-free CDP-only page, source located upstream. NOT gem-fixable.
**Last investigated:** 2026-07-25, against browser build `1.0.0-nightly.8285+de85a51d`, gem `HEAD`.
**Affected tests:** 15 of the 16 solidus baseline entries previously filed under
`select2-v3-flow` — every `complete_split_to` flow in
`order_details_spec.rb` ("Shipment edit page splitting to location/shipment") and
`shipments_spec.rb` ("moving variants between shipments", "when split shipment").
The 16th (`products/edit/taxons_spec.rb`) is a different mechanism and stays under
`select2-v3-flow`.
**Booted with:** `script/real-app/boot.sh solidus` + `script/real-app/spec.sh` (see
`script/real-app/README.md`).

---

## Symptom

```
expected to find visible css ".shipment" 2 times, found 1 match
```

The split UI accepts the destination — the select2 widget visibly reads
"Clarksville (100 on hand)" — and then the save click does nothing at all: no
POST, no alert, no error page. `network.traffic` for the failing example holds
6 requests, all `GET`, all 200, none of them the
`api/shipments/transfer_to_location` call the handler is supposed to make.

## Confirmed root cause

`HTMLSelectElement.options` (and every sibling accessor) walks **direct children
only**, so `<option>`s nested inside an `<optgroup>` do not exist as far as the
select is concerned. Solidus's split `<select name="item_stock_location">` puts
all real destinations inside two `<optgroup>`s.

The full chain, each step measured in the running app at the moment before the
save click (`script/real-app/spec.sh … -r split_probe.rb`, which prepends the
solidus helpers so state can be dumped *between* the select2 pick and the click):

| # | Step | Measured |
|---|---|---|
| 1 | select2 renders its dropdown from `element.find("option, optgroup")` — a plain DOM query | dropdown lists both locations, pick succeeds, `.select2-chosen` = `"Clarksville (100 on hand)"` |
| 2 | select2's `onSelect` calls `$(select).val("stock_location:2")`; jQuery's `valHooks.select.set` iterates **`elem.options`** | `options.length` = **1** (only the empty placeholder — a direct child); `querySelectorAll("option").length` = 3 |
| 3 | jQuery finds no match, so it sets `elem.selectedIndex = -1` | `selectedIndex` = **-1**, `select.value` = `""` |
| 4 | jQuery's getter returns `null` for a single select with nothing selected | `$(sel).val()` → `null` |
| 5 | solidus's `completeItemSplit` runs `this.$('[name="item_stock_location"]').val().split(':')` | `UNCAUGHT TypeError: Cannot read properties of null (reading 'split')`, captured through a `window.onerror` → `console.error` bridge into `browser.console_logs` |
| 6 | The handler dies before `Spree.ajax` | 0 POSTs in `network.traffic`; shipment count stays 1 |

Reproduced across the whole family: all 29 state dumps taken over one run of the
group (19 examples, the 15 baseline failures among them) show `options.length: 1`
and `value: ""`, and 28 of them show the `TypeError`.
The 29th is the pre-selection dump of the sibling example that *passes*
("should warn you if you have not selected a location or shipment"): with
nothing picked, `.val()` is `""` — not `null` — so `"".split(":")` works and the
app's `alert('Please select the split destination.')` fires as designed. That
contrast is what pins the failure on jQuery's *setter* driving `selectedIndex`
to -1, not on the select being empty to begin with.

## Minimal reproducer (no Ruby, no Capybara, no gem)

A static page with two identical selects — one flat (control), one with the
options wrapped in an `<optgroup>` — and the Lightpanda CLI:

```bash
python3 -m http.server 8731            # serve the file below as index.html
lightpanda fetch --log-level debug http://127.0.0.1:8731/index.html 2>&1 | grep -E 'ok |FAIL'
```

```html
<form id="grouped-form">
  <select name="s" id="grouped">
    <option value=""></option>
    <optgroup label="group">
      <option value="a">A</option>
      <option value="b">B</option>
    </optgroup>
  </select>
</form>
<script>
  var sel = document.getElementById("grouped");
  console.log("options.length", sel.options.length);              // spec: 3
  sel.value = "b";
  console.log("value", JSON.stringify(sel.value));                // spec: "b"
  console.log("selectedIndex", sel.selectedIndex);                // spec: 2
  console.log("selectedOptions", sel.selectedOptions.length);     // spec: 1
  console.log("FormData", JSON.stringify(new FormData(sel.form).get("s"))); // spec: "b"
</script>
```

Result on nightly 8285 — the flat control passes every row, the grouped select
fails everything except the raw DOM query:

| Check | flat `<select>` | options in `<optgroup>` | spec |
|---|---|---|---|
| `options.length` | 3 | **1** | 3 |
| `length` | 3 | **1** | 3 |
| `querySelectorAll("option").length` | 3 | 3 | 3 |
| `value` after `value = "b"` | `"b"` | **`""`** | `"b"` |
| `selectedIndex` after `value = "b"` | 2 | **0** | 2 |
| `selectedOptions.length` | 1 | **0** | 1 |
| `value` after `option.selected = true` | `"a"` | **`""`** | `"a"` |
| `value` after `selectedIndex = 2` | `"b"` | **`""`** | `"b"` |
| `new FormData(form).get("s")` | `"b"` | **`""`** | `"b"` |

## Upstream source

`src/browser/webapi/element/html/Select.zig` (checkout at build 8301):

- `getOptions` → `collections.NodeLive(.child_tag)`, and `.child_tag` resolves to
  `TreeWalker.Children` in `collections/node_live.zig` — direct children only.
- `getSelectedOptions` → `.selected_options`, same `TreeWalker.Children`.
- `effectiveOption`, `setValue`, `getSelectedIndex`, `setSelectedIndex` each walk
  `asNode().childrenIterator()` / `firstChild()`+`nextSibling()` directly.

Per HTML §the-select-element, a select's list of options is its option
*descendants* through `optgroup`, not its option children. `effectiveOption` is
also what feeds form submission, which is why `FormData` drops the value too.

## Elimination table (what was ruled out)

Signal for the in-app rows: the state dump evaluated in the live page between the
select2 pick and the save click. Signal for the browser rows: the flat-vs-grouped
reproducer above, same page, same run.

| Hypothesis | Ruled out by |
|---|---|
| The gem's click never reaches select2's result handler (the C13 wrapper-descent family) | `.select2-chosen` reads `"Clarksville (100 on hand)"` and the drop closes — select2's `onSelect` demonstrably ran |
| The select2 dropdown is never populated | `select_select2_result` finds and clicks the result label; the helper returns without raising |
| select2 keeps the value internally and the app reads the wrong place | the app reads `$(el).val()`, the standard path; `select2("val")` returns `null` too |
| The `<option>`s are missing from the DOM | `querySelectorAll("option").length` = 3, `optgroup` count = 2 |
| `option.selected` can't be set at all | on the flat control, `option.selected = true` → `value === "a"` |
| The app needs a `change`/`input` event the gem doesn't dispatch | the handler reads on *click*, and the value is already empty at click time |
| A gem-side click-path or event-dispatch bug | reproduced with zero Ruby/Capybara/gem: static page, no clicks, plain property access |
| Something solidus- or Rails-specific | the flat `<select>` in the same page, same run, passes all 9 checks |
| Fixable in the gem by setting `option.selected` instead of `select.value` | the property *can* be set, but `select.value` / `selectedOptions` / `FormData` all still read empty — every getter walks children too, so nothing the gem writes becomes visible to the app |

## Scope beyond select2

This is not a select2 bug and not limited to solidus. Any page whose `<select>`
groups its options is affected:

- **Capybara's plain `select "X", from: "Y"`** goes through the gem's
  `SELECT_OPTION_JS`, which for a single select does `sel.value = this.value` —
  exactly the setter that no-ops here. So selecting a grouped option is silently
  a no-op app-side.
- **Plain form submission** of a grouped select sends nothing for that field
  (`effectiveOption` → no entry).
- The gem's own **`SELECT_OPTION_JS` comment** ("Lightpanda doesn't auto-deselect
  siblings when we set `option.selected`") is a nearby symptom of the same
  children-only walk.

Why the gem's CI never caught it: Capybara's shared battery has `<optgroup>`
fixtures (`form.erb` `form_disabled_select`, `my_test_id`), but they are only
used by `disabled`-state and `find_field` examples. No battery example selects an
option nested in an optgroup and then asserts the resulting value, so the gem is
green on 1401 examples with this broken.

## Disposition

**Upstream bug, filed and fixed upstream (2026-07-25).** No gem workaround
exists (last row of the elimination table): a gem-side write can set the option
property, but every read path the application sees — `select.value`,
`selectedIndex`, `selectedOptions`, `options`, `FormData` — walks children only.

- **Issue**: [lightpanda-io/browser#3057](https://github.com/lightpanda-io/browser/issues/3057)
- **PR**: [lightpanda-io/browser#3058](https://github.com/lightpanda-io/browser/pull/3058)
  — a `select_options` collection mode (with `selected_options` moved onto the
  same walk) plus one `OptionIterator` shared by `effectiveOption` / `setValue` /
  `getSelectedIndex` / `setSelectedIndex` / `getLength` / `add`. Fixture
  `src/browser/tests/element/html/select-optgroup.html`; full Zig suite
  1073/1073; the reproducer above exits 1 on nightly 8285 and 0 on the branch.

Nothing to change gem-side now. When the PR merges and ships, the 15 entries
clear at the next `MINIMUM_NIGHTLY_BUILD` bump — no workaround to delete.

Wishlist entry: **A52**. `causes.yml`: the 15 split/transfer entries moved from
`select2-v3-flow` (likely) to `select-optgroup-invisible` (confirmed).

**Adjacent bug found and deliberately left out of #3058**: setting
`option.selected = true` on a single select does not deselect its siblings (the
"ask for a reset" algorithm never runs), so `select.value` returns the first of
several selected options. It reproduces on a flat select, so it is independent
of this cluster; the gem's `SELECT_OPTION_JS` already routes around it by
assigning `select.value`. Bundling it would have widened #3058's review surface
to two behaviors.

## How to reproduce the failure (fastest)

```bash
script/real-app/boot.sh solidus       # ~1 s warm, ~10 min cold
script/real-app/spec.sh solidus spec/features/admin/orders/order_details_spec.rb \
  -e "should allow me to make a split"
# → 1 failed, known, cause select-optgroup-invisible
```

Add `-r <probe>` with a file that prepends `Spree::TestingSupport::CapybaraExt`
to dump `select.options` / `select.value` between the select2 pick and
`click_icon :ok` — the version used for this investigation is reproduced in the
"Confirmed root cause" table above and takes ~20 lines.
