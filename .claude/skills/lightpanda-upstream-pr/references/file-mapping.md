# File Mapping: Wishlist Item → Source

Two maps for items still pending upstream. Resolved or retracted items (struck through or marked `RESOLVED` in `references/upstream-wishlist.md`) are intentionally absent — the gem-side workaround has been deleted post-fix, and the upstream Zig file is no longer a useful starting point. Cross-reference the wishlist heading status before adding rows here.

Last reconciled: 2026-11-18 (upstream `main` `786d715f8`, build 12255).

## Item → gem-side workaround (`/Users/navid/code/personal/capybara-lightpanda/`)

Read these for context before editing the Zig side. The workaround pins down the behavior the fix must produce — return shape, error code, event sequence. For any item not listed here, the wishlist entry's own **Gem workaround** line is the pointer. Symbols, not line numbers: `rg -n "def <name>" lib/` finds them.

| Item | File on gem side |
|---|---|
| A10 | `lib/capybara/lightpanda/browser/navigation.rb` (`go_to` → `wait_for_page_load` → `page_ready?` — readyState polling fallback when `Page.loadEventFired` never arrives) |
| A11 | `lib/capybara/lightpanda/browser.rb` (`with_default_context_wait` — retries the post-nav `NoExecutionContextError` race once the next default context is created; wraps the finds in `browser/finder.rb` and `node.rb`) |
| A12 | `lib/capybara/lightpanda/browser/navigation.rb` (`handle_navigation_crash` — reconnects on `TargetClosedError` / `DeadBrowserError` via `Browser#reconnect`) |

## Item → upstream Zig source (`/Users/navid/code/upstream/browser/`)

Starting points only. Confirm with `rg`/`grep` — file layout drifts.

CDP domain files live at `src/server/cdp/domains/<domain>.zig` (shared CDP plumbing and `testing.zig` in `src/server/cdp/`). Browser-internal logic lives under `src/browser/` (navigation lifecycle in `Frame.zig`, styles in `StyleManager.zig`). JS API surfaces (DOM, HTML elements) live under `src/browser/webapi/` (e.g. `webapi/Element.zig`, `webapi/element/Html.zig`, `webapi/XPathResult.zig`).

| Item | Likely file(s) |
|---|---|
| A10 (`Page.loadEventFired` unreliable) | `src/browser/Frame.zig` (navigation lifecycle, `documentIsLoaded`) + `src/server/cdp/domains/page.zig` (`frameLoaded` / `frameDOMContentLoaded` emit the events, dispatched from `src/server/cdp/CDP.zig`) |
| A11 (NoExecutionContextError after click-driven nav) | `src/server/cdp/domains/runtime.zig` (`evaluate` goes to V8's inspector — context recreation timing) |
| A12 (WebSocket dies on complex navigation) | `src/server/WS.zig`, `src/server/Server.zig` (WebSocket framing) — verify still reproduces; #1849 is closed and the gem keeps its recovery defensively |

To find the dispatch enum for CDP additions:

```bash
rg -n "fn processMessage|stringToEnum\(enum" /Users/navid/code/upstream/browser/src/server/cdp/domains/network.zig
```

For JS APIs, look in `src/browser/webapi/` for `.zig` files — APIs are bound through Zig→V8 reflection (look for `pub const` declarations of method names).

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
| `tests/navigation/` | `webapi/navigation/Navigation.zig` | Navigation API (`navigation.*`) |
| `tests/navigator/` | `webapi/Navigator.zig` | navigator.* |
| `tests/node/` | `webapi/Node.zig` | Node tree / traversal |
| `tests/performance_observer/` | `webapi/PerformanceObserver.zig` | PerformanceObserver |
| `tests/resize_observer/` | `webapi/ResizeObserver.zig` | ResizeObserver |
| `tests/shadowroot/` | `webapi/ShadowRoot.zig` | ShadowRoot |
| `tests/shared_worker/` | `webapi/SharedWorker.zig` | SharedWorker |
| `tests/webaudio/` | `webapi/webaudio/OfflineAudioContext.zig` | Web Audio |
| `tests/window/` | `webapi/Window.zig` | window.*, **Location** ⚠ |
| `tests/worker/` | `webapi/Worker.zig` | Worker / WorkerGlobalScope |

⚠ Note `Location.zig` lives under `webapi/` but its tests run via `Window.zig`'s `htmlRunner("window", .{})`. There is **no** `test "WebApi: Location"` block in `webapi/Location.zig` — adding one would re-execute `tests/window/location.html`. Drop fixtures into `tests/window/` instead.

Other webapi files (`Performance.zig`, `Blob.zig`, `FileReader.zig`, `XMLSerializer.zig`, `TreeWalker.zig`, etc.) own single `.html` files, not a directory (`History.zig` runs the top-level `tests/history*.html` one by one) — adding a sibling `test "..."` block in those is fine. Refresh this table when a new directory runner lands:

```bash
rg -n 'htmlRunner\("[a-z_]+", \.\{' /Users/navid/code/upstream/browser/src/browser/webapi/
```
