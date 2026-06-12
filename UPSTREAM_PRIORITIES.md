# Upstream priority focus — Capybara/Rails lens

Synthesis of two passes over `lightpanda-io/browser` (2026-06-12): the last 20 merged PRs
per maintainer, and the blog/roadmap signals. Filtered to what passes through Capybara's
API. Cross-referenced with `UPSTREAM_BUGS.md`, the upstream wishlist, and the live open-PR
list (checked 2026-06-12).

Maintainer lanes, for targeting PRs:
- **krichprollsch** — forms, networking, cookies, CDP shape, CI. Currently deep in the
  form-submit path (#2654 multipart, #2639 constraint validation, #2638/#2637 XHR).
- **karlseguin** — arenas/GC, script pipeline, WPT compliance, geometry, `Server.zig`.
  Avoid colliding with ScriptManager/arena core (churns weekly).

## Already in flight — shepherd, don't start

Filed by us, open upstream as of 2026-06-12. The work here is review-response, not coding.

| Item | Upstream PR | What |
|------|-------------|------|
| A47 — `Page.navigate` hangs on failed navigation | **#2729 (open, ours)** | Answer with `errorText` instead of hanging → defuses `DeadBrowserError` cascade |
| A48 — console types all `"info"` | **#2731 (open, ours)** | `console.log`/`warn` get their own `consoleAPICalled` types |
| A44 — CDP WS dies at 512 KiB inbound | **#2717 (open, ours)** + issue #2716 | Cap raised to Chrome's 100 MB → unblocks axe-core bundle injection |
| B18 — `@layer` dropped from cascade | **#2719 (open, ours)** + issue #2718 | Tailwind v4 / Rails 8 visibility predicates |
| B14 — Tab moves `document.activeElement` | **#2700 (open, ours)** | Unblocks `:active_element` capability |
| A46 — `globalPrivacyControl` hardcoded `true` | **#2726 (open, ours)** | Consent banners render again |
| B16 — file downloads | **#2722 (open, external — Ar-maan05)** + our issue #2701 | `Browser.setDownloadBehavior` → `:download`. Watch/review, don't duplicate |

## Merged — gem-side cleanup owed

| Item | Upstream PR | Gem action |
|------|-------------|------------|
| A43 — 3xx without `Location` aborts navigation | **#2714 merged 2026-06-10 (ours)** | Unpin alonetone spec once nightly > e1851309; `UPSTREAM_BUGS.md` Bug #11 still says "issue pas encore filée / aucun workaround" — stale, update it |
| B17 — `:has()` relative selectors | **#2712 merged 2026-06-12 (ours)** + issue #2711 | Drop the skip/workaround for the Bootstrap list-group selector; update wishlist entry |

## Next contributions — ready to code, nothing filed yet

Self-contained enough to go straight to a spec-cited PR (or, for A45, gem-side
investigation work that needs no upstream input).

| # | Item | What | Why now (evidence) | Effort | Lane | Gem payoff |
|---|------|------|--------------------|--------|------|------------|
| 1 | **A45 re-verify, then root-cause** | Multipart POST body truncated → Rack `EOFError` | krichprollsch rewrote that exact path two weeks ago (#2654, `body_init.zig`/`FormData.zig`). Wishlist notes seven minimal form shapes encode byte-exact on nightly 6703 — needs a raw capture against a real failing app form before it's filable. Biggest real-apps failure cluster (solidus + decidim) | Verify: hours. Fix: unknown until root-caused | krichprollsch | "Rails forms don't work" headline bug gone |
| 2 | **B5#1 — `keyCode` gated on `isTrusted`** | Synthetic `Input.dispatchKeyEvent` returns `keyCode` 0 | Gate at `KeyboardEvent.zig:383`; Chrome's CDP behavior says loosen it. Single localized change | Small | either | Un-skip `#send_keys should generate key events` |

## Maintainer conversations opened — awaiting direction (processed 2026-06-12)

All four items were taken through the pre-flight probe on nightly 6736. Two turned out
not to be bugs and were retracted instead of filed; two are now upstream issues with
repros and explicit scope questions, awaiting maintainer ack before any PR.

| # | Item | Outcome | Detail | Gem action |
|---|------|---------|--------|------------|
| 1 | **Bug #9 — `requestSubmit()` throws on canceled SubmitEvent** | **RETRACTED — fixed upstream** | Pure-CDP probe on nightly 6736: returns silently for both form-level and document-level (bubbling) cancel listeners. Almost certainly fixed by #2639's submit-path rework | **DONE 2026-06-12** — the `try/catch` was already gone from `CLICK_JS` (removed in an earlier refactor); added a contract test (`upstream_bugs_test.rb` « Bug #9 ») and retired the entry from `UPSTREAM_BUGS.md` |
| 2 | **Bug #10 — `Runtime.evaluate` leaks top-level `const`/`let`** | **RETRACTED — Chrome parity, not a bug** | Chrome (headless-shell) throws the identical `SyntaxError` without `replMode`; with `replMode: true` both Chrome AND Lightpanda allow redeclaration. Top-level lexical bindings persisting across classic scripts is spec behavior | **DONE 2026-06-12** — `browser.rb` now passes `replMode: true` on both no-args paths (IIFE wrap removed, `exceptionDetails` raise kept); replMode semantics probed on nightly 6736 (10 cases incl. throw with `awaitPromise: false`); contract tests added; entry retired from `UPSTREAM_BUGS.md` |
| 3 | **B10 — `getComputedStyle` cascade incomplete** | **Issue #2733 filed (2026-06-12)** | Probe sharpened the claim: computed style returns `""` for ALL properties except `display`/`visibility` — even inline declarations (readable via `el.style`) are dropped. Issue carries the repro + a two-option scope question (per-property extension vs. general declaration retention) | Wait for maintainer direction, then implement |
| 4 | **A23 — `innerText` block-level line breaks** | **Issue #2734 filed (2026-06-12)** | Both halves verified on 6736: no block-boundary breaks (`"firstsecondtail"`) and `display:none` descendants leak. Issue proposes v1 = existing StyleManager `display:none` truth + UA-default display table + line-collapsing pass, deferring full-cascade bits to #2733 | Wait for maintainer direction, then implement |

## Track, don't build

| Item | Signal | Gem action |
|------|--------|------------|
| **Multi-tab / multi-threading in one process** | Blog: explicitly "working on that feature"; prerequisite for B15 (`window.open` independent CDP targets → `:windows`) | Design the session pool so one-process-N-tabs slots in later; watch upstream branches. Changes parallel-worker economics (one process per CI host instead of per worker) |
| **Geometry softening** | `offsetParent` (#2695), `scroll/scrollTo/scrollBy` (#2672) — first moves into "inherent limitation" territory (C2/C3) | Re-probe capability flags against nightlies periodically; section C may not stay closed |
| **Request interception** | Shipped upstream (Feb) | Gem feature: Cuprite-style URL blocklist/allowlist (skip analytics/CDN in tests) — expected by Cuprite migrators |
| **File downloads (B16)** | External PR #2722 open; our design issue #2701 awaiting maintainer call | Review the PR against the gem's `:download` needs; don't duplicate |
| **Maintainer stability work** | Arena-leak sweep (#2673/#2650/#2670), CDP-disconnect worker robustness (#2648), TCP timeout 2s→10s (#2651), script-ordering (#2688/#2675 → bears on A10) | No action — passively reduces A10/A12 flake class. Re-verify A10 frequency on new nightlies |

## Don't chase

- **LP domain / semantic tree / markdown / MCP / Web Bot Auth / robots.txt** — AI-agent
  surface, never passes through Capybara's API.
- **B15 (multi-window) as a contribution** — blocked on the multi-tab work above. Track instead.
- **ScriptManager / arena core PRs** — karlseguin churns these weekly; anything written
  there conflicts within days.
- **C11 `:hover` CSS state** — same interaction-driven-CSS class the maintainer declined
  for `@media` (C10).

## Working pattern that merges

Small, spec-cited, single-area PRs with a raw-CDP or WPT-style repro merge from outside
within days (#2714 and #2712 both merged this week). The repros in `UPSTREAM_BUGS.md` are
already in the accepted format. Every merged fix should delete a gem-side workaround —
keep the section D drop-on-fix LOC tally honest.
