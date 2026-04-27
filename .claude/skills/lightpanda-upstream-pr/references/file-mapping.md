# File Mapping: Wishlist Item → Source

Two maps. One points at the gem-side workaround (read-only — gives you the spec the upstream fix has to match). The other points at the upstream Zig source you'll edit.

## Item → gem-side workaround (`/Users/navid/code/capybara-lightpanda/`)

Read these for context before editing the Zig side. The workaround pins down the behavior the fix must produce — return shape, error code, event sequence.

| Item | File on gem side |
|---|---|
| A1, A2, B3 | `lib/capybara/lightpanda/cookies.rb` (sweep_visited_origins) |
| A3 | `lib/capybara/lightpanda/browser.rb` (prepare_modals, accept_modal, etc.) |
| A4, A5 | `lib/capybara/lightpanda/node.rb` (CLICK_JS, IMPLICIT_SUBMIT_JS) |
| A8 | `lib/capybara/lightpanda/javascripts/index.js` (querySelector rewriter) |
| A10 | `lib/capybara/lightpanda/browser.rb` (wait_for_page_load) |
| A11 | `lib/capybara/lightpanda/browser.rb` (with_default_context_wait) |
| A12 | `lib/capybara/lightpanda/browser.rb` (handle_navigation_crash) |
| A14 | `lib/capybara/lightpanda/javascripts/index.js` (requestSubmit polyfill) |
| B1 | `lib/capybara/lightpanda/javascripts/index.js` (XPathEval IIFE) |
| B2 | `lib/capybara/lightpanda/browser.rb` (back, forward) |

## Item → upstream Zig source (`/Users/navid/code/browser/`)

Starting points only. Confirm with `rg`/`grep` — file layout drifts.

CDP domain files live at `src/cdp/domains/<domain>.zig`. Browser-internal logic lives under `src/browser/`. JS API surfaces (DOM, HTML elements) live at `src/browser/<area>/` (e.g. `src/browser/forms/`, `src/browser/dom/`).

| Item | Likely file(s) |
|---|---|
| A1 (`Network.clearBrowserCookies`) | `src/cdp/domains/network.zig` (dispatch enum + handler) |
| A2 (`Network.getCookies` scope) | `src/cdp/domains/network.zig` (handler reads current page origin — change to enumerate jar) |
| A3 (`handleJavaScriptDialog`) | `src/cdp/domains/page.zig` (dispatch handler — currently always errors) + dialog plumbing in `src/browser/Page.zig` |
| A4 (`form.submit()`) | `src/browser/forms/HTMLFormElement.zig` (or wherever `submit` is bound) |
| A5 (`document.write`) | `src/browser/document/Document.zig` |
| A6 (`Page.reload` replays POST) | `src/cdp/domains/page.zig` (reload handler) + `src/browser/Page.zig` (navigation history entry shape) |
| A7 (`<select>` empty FormData) | `src/browser/forms/` (FormData construction) |
| A8 (`#id` selector) | `src/browser/css/` (selector engine, `Frame.getElementByIdFromNode`) |
| A10 (`Page.loadEventFired`) | `src/browser/Page.zig` (navigation lifecycle) + `src/cdp/domains/page.zig` (event emission) |
| A11 (NoExecutionContextError) | `src/cdp/domains/runtime.zig` (evaluate — add wait/queue for new context) |
| A14 (`requestSubmit`) | `src/browser/forms/HTMLFormElement.zig` |
| A15 (`location.pathname` navigation) | `src/browser/dom/Location.zig` (or similar) |
| B1 (`XPathResult`/`document.evaluate`) | New: `src/browser/dom/XPathEvaluator.zig` (large) |
| B2 (history CDP methods) | `src/cdp/domains/page.zig` (add new dispatch entries) |
| B3 (`Network.getAllCookies`) | `src/cdp/domains/network.zig` (add dispatch entry) |
| B4 (`setFileInputFiles`) | `src/cdp/domains/page.zig` + file input plumbing in `src/browser/forms/` |

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
