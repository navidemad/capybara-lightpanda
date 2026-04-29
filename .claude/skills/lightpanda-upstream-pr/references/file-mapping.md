# File Mapping: Wishlist Item → Source

Two maps for items still pending upstream. Resolved or retracted items (annotated `FIXED + SHIPPED + GEM CLEANED UP` or `NOT A BUG (retracted ...)` in `references/upstream-wishlist.md`) are intentionally absent — the gem-side workaround has been deleted post-fix, and the upstream Zig file is no longer a useful starting point. Cross-reference the wishlist heading status before adding rows here.

Last reconciled: 2026-04-29.

## Item → gem-side workaround (`/Users/navid/code/capybara-lightpanda/`)

Read these for context before editing the Zig side. The workaround pins down the behavior the fix must produce — return shape, error code, event sequence.

| Item | File on gem side |
|---|---|
| A3 | `lib/capybara/lightpanda/browser.rb` (`prepare_modals` line 473; modal capture via `Page.javascriptDialogOpening` event — does NOT call `handleJavaScriptDialog`. PR #2261 OPEN proposes the upstream pre-arm model.) |
| A10 | `lib/capybara/lightpanda/browser.rb` (`go_to` line 136 — readyState polling fallback; `wait_for_page_load` line 802) |
| A11 | `lib/capybara/lightpanda/browser.rb` (`with_default_context_wait` line 165 — wraps the post-nav `NoExecutionContextError` race in a retry loop) |
| A12 | `lib/capybara/lightpanda/browser.rb` (`handle_navigation_crash` line 827 — reconnects on `TargetClosedError` / `DeadBrowserError`) |
| B1 | `lib/capybara/lightpanda/javascripts/index.js` (`XPathEval` IIFE line 74; `xpathFind` line 790; `document.evaluate` shim line 1013 — XPath 1.0 evaluator + spec polyfill, ~700 LOC) |
| B2 | `lib/capybara/lightpanda/browser.rb` (`back` line 173, `forward` line 177 — JS `history.back()` / `history.forward()`. PR #2289 OPEN proposes native `Page.getNavigationHistory` + `Page.navigateToHistoryEntry`.) |

## Item → upstream Zig source (`/Users/navid/code/browser/`)

Starting points only. Confirm with `rg`/`grep` — file layout drifts.

CDP domain files live at `src/cdp/domains/<domain>.zig`. Browser-internal logic lives under `src/browser/`. JS API surfaces (DOM, HTML elements) live at `src/browser/<area>/` (e.g. `src/browser/forms/`, `src/browser/dom/`).

| Item | Likely file(s) |
|---|---|
| A3 (`handleJavaScriptDialog` accepts/dismisses) | `src/cdp/domains/page.zig` (dispatch handler — currently always errors `-32000 No dialog is showing`) + dialog plumbing in `src/browser/Page.zig` |
| A10 (`Page.loadEventFired` unreliable) | `src/browser/Page.zig` (navigation lifecycle) + `src/cdp/domains/page.zig` (event emission ordering — see PR #2032's reorder of Loaded vs. DOMContentLoaded) |
| A11 (NoExecutionContextError after click-driven nav) | `src/cdp/domains/runtime.zig` (`evaluate` — add wait/queue for context recreation) |
| A12 (WebSocket dies on complex navigation) | `src/server/*.zig` (WebSocket framing) — verify still reproduces; PR #1850 (merged 2026-03-16) addressed the original #1849, so wishlist may be stale for this item |
| B1 (`XPathResult` / `document.evaluate`) | New: `src/browser/dom/XPathEvaluator.zig` (large — port the gem's XPath 1.0 evaluator from `index.js`) |
| B2 (history CDP methods) | `src/cdp/domains/page.zig` (add `getNavigationHistory` + `navigateToHistoryEntry` dispatch entries) — PR #2289 OPEN |
| B4 (`setFileInputFiles`) | `src/cdp/domains/page.zig` (dispatch) + file input plumbing in `src/browser/forms/` (#2175) |

To find the dispatch enum for CDP additions:

```bash
rg -n "fn processMessage" /Users/navid/code/browser/src/cdp/domains/network.zig
rg -n "method_name" /Users/navid/code/browser/src/cdp/domains/network.zig | head
```

For JS APIs, look in `src/browser/<area>/` for `.zig` files — APIs are bound through Zig→V8 reflection (look for `pub const` declarations of method names).

## Directory test runners

Several `src/browser/webapi/<File>.zig` files own an entire `src/browser/tests/<dir>/` directory of HTML fixtures via `testing.htmlRunner("<dir>", .{})`. **Before adding a `test "..."` block in `webapi/<File>.zig` that calls `htmlRunner("<dir>/<file>.html", .{})`, check this table** — adding one duplicates work the directory runner already does, and reviewers flag it.

| Directory | Owning test file | Add fixtures here |
|---|---|---|
| `tests/cdata/` | `webapi/CData.zig` | character data |
| `tests/console/` | `webapi/Console.zig` | console.* APIs |
| `tests/custom_elements/` | `webapi/CustomElementRegistry.zig` | custom-element registry |
| `tests/document/` | `webapi/Document.zig` | Document / HTMLDocument APIs |
| `tests/document_fragment/` | `webapi/DocumentFragment.zig` | document fragments |
| `tests/element/` | `webapi/Element.zig` | Element + HTMLElement subclasses |
| `tests/intersection_observer/` | `webapi/IntersectionObserver.zig` | IntersectionObserver |
| `tests/mutation_observer/` | `webapi/MutationObserver.zig` | MutationObserver |
| `tests/navigator/` | `webapi/Navigator.zig` | navigator.* |
| `tests/node/` | `webapi/Node.zig` | Node tree / traversal |
| `tests/performance_observer/` | `webapi/PerformanceObserver.zig` | PerformanceObserver |
| `tests/shadowroot/` | `webapi/ShadowRoot.zig` | ShadowRoot |
| `tests/window/` | `webapi/Window.zig` | window.*, **Location** ⚠, History |
| `tests/worker/` | `webapi/Worker.zig` | Worker / WorkerGlobalScope |

⚠ Note `Location.zig` lives under `webapi/` but its tests run via `Window.zig`'s `htmlRunner("window", .{})`. There is **no** `test "WebApi: Location"` block in `webapi/Location.zig` — adding one would re-execute `tests/window/location.html`. Drop fixtures into `tests/window/` instead.

Other webapi files (`Performance.zig`, `Blob.zig`, `FileReader.zig`, `XMLSerializer.zig`, `TreeWalker.zig`, etc.) own a single `.html` file, not a directory — adding a sibling `test "..."` block in those is fine. Refresh this table when a new directory runner lands:

```bash
rg -n 'htmlRunner\("[a-z_]+", \.\{\}\)' /Users/navid/code/browser/src/browser/webapi/*.zig
```
