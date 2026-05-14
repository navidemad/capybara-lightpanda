# Sync Upstream — Last-Run State

Last run: 2026-05-14
Last run targets: Lightpanda / Ferrum / Cuprite (full sync) + follow-up investigation of New capabilities

## Open recommendations

Each entry stays here until the gem code change happens, the upstream PR/issue resolves, or the entry becomes stale. Reconcile each one at Step 1 of the next run.

- **polyfills-js-removal — floor bump pending** [HIGH] — `lib/capybara/lightpanda/process.rb` only: bump `MINIMUM_NIGHTLY_BUILD` + refresh the PR-changelog comment at L14-44 (it still names `polyfills.js` at L28/L41). The `polyfills.js` removal itself is **done in the working tree** (2026-05-14, uncommitted): deleted `javascripts/polyfills.js` + `auto_scripts.rb` `POLYFILLS_*` constants + `browser.rb` register line + `CLAUDE.md` mention; moved Bug #7 to `UPSTREAM_BUGS.md` "Bugs résolus"; de-referenced `polyfills.js` in `upstream_bugs_test.rb` comments. Validated: `rake suite` green against locally-built `main` `1.0.0-dev.6226+2f3a426fb` (includes PR #2450 `143bffdfe`) — 1399 examples, 0 failures, 94 pending. **DO NOT COMMIT/SHIP** until `MINIMUM_NIGHTLY_BUILD` is bumped to the first published nightly containing `143bffdfe` — PR #2450 merged after the 2026-05-14 nightly cut, so the next nightly (~2026-05-15) is the earliest. The floor bump + process.rb comment refresh ride together as one commit. Effort: tiny once the nightly is out.
- **upstream-bugs-md-stale-3-4** [LOW] — `UPSTREAM_BUGS.md` Bug #3 and Bug #4 full entries still describe `polyfills.js` workarounds (`patchDispatch` IIFE, HTMLDialogElement prototype block) that were already removed from `polyfills.js` before the 2026-05-14 cleanup — and now reference a deleted file. Pre-existing staleness, left untouched during the Bug #7 removal because verifying their exact upstream fix status (Bug #3 ≈ PR #2368? Bug #4 = PR #2435) is a separate pass. Either move them to "Bugs résolus" or rewrite their "### Workaround" sections.

- **iscontenteditable-comment-refresh** [DONE 2026-05-14] — `javascripts/index.js` comment refreshed + dead `if (el.isContentEditable) return true;` short-circuit removed. Resolved; drop on next run.

## Watch items

Upstream PRs / issues to recheck next sync. Promote to findings if they move.

- **lightpanda-io/browser#2309** — `HTMLElement.isContentEditable` IDL attribute. State as of 2026-05-14: CLOSED 2026-04-30 (won't-fix). Verified this sync against the PR #2310 diff — `getIsContentEditable` runs the spec ancestor-walk but **always returns `false`** (Lightpanda has no caret/keyboard editing pipeline); the test fixture asserts `false` for every case. Gem polyfill `_lightpanda.isContentEditable` at `javascripts/index.js:147` MUST stay. Watch only — promote to a finding if upstream ever reopens with a real ancestor-walking return value.
- **Network cache survival across `Target.disposeBrowserContext`** — PRs #2453-2455 (merged 2026-05-14) added `Network.clearBrowserCache` / `canClearBrowserCache` / `requestServedFromCache` + `Response.fromDiskCache`. HTTP caching is brand-new in Lightpanda. Once these land in a nightly the gem consumes, check whether the HTTP cache survives `Target.disposeBrowserContext` (the gem's `Driver#reset!` path). If it does, `reset!` likely needs a `Network.clearBrowserCache` call to prevent cross-test cache pollution. Not a problem today — current nightly barely caches.
- **CSSOM cascade resolution for `getComputedStyle`** — no upstream PR yet. The `_lightpanda.isVisible` `offsetParent === null` fallback exists because Lightpanda's CSSOM doesn't resolve every cascade case Chrome does. 2026-05-14 sync: no commits touched `getComputedStyle` or cascade resolution. Re-check next sync by scanning commits for those terms.
- **`innerText` rendering-aware implementation** — `_lightpanda.visibleText` exists because Lightpanda's `innerText` returns `textContent` verbatim (no rendering). Structural limitation tied to "no rendering engine" — unlikely to land. 2026-05-14 sync: no movement.
