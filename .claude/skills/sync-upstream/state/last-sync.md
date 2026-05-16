# Sync Upstream — Last-Run State

Last run: 2026-05-16
Last run targets: Lightpanda / Ferrum / Cuprite (full sync)

## Open recommendations

Each entry stays here until the gem code change happens, the upstream PR/issue resolves, or the entry becomes stale. Reconcile each one at Step 1 of the next run.

- **upstream-bugs-md-stale-3-4** [LOW] — `UPSTREAM_BUGS.md` Bug #3 (lines 20-63) and Bug #4 (lines 67-79) — Both fixes are now confirmed upstream and the polyfills they describe were deleted by PR #45 (commit `104ad8a`). Bug #3 (`dispatchEvent` halt on listener throw) is fixed by PR #2368 (merged 2026-05-06, `events: report listener exceptions instead of halting dispatch`). Bug #4 (`HTMLDialogElement.{showModal, show, close}`) is fixed by PR #2435 (merged 2026-05-13). Both are below the current floor (`MINIMUM_NIGHTLY_BUILD = 6220`). Move both entries to the "Bugs résolus / rétractés" section at the top, matching Bug #5/#6/#7/#8's one-line bullet format. Effort: tiny.

## Watch items

Upstream PRs / issues to recheck next sync. Promote to findings if they move.

- **lightpanda-io/browser#2478** — `css: evaluate @media and matchMedia against viewport` (by navidemad). State as of 2026-05-16: OPEN, no maintainer comments. Inline-only narrow scope — explicitly carves out external `<link>` fetch. If merged, only the matchMedia + inline `@media` halves of `lightpanda-io.md` limitation #6 close. The current rules-file phrasing notes both the broad-scope "won't be accepted" verdict and the narrow-scope PR.
- **lightpanda-io/browser#2477** — `css: inline @media cascade application + matchMedia booleans` (issue paired with PR #2478). State 2026-05-16: OPEN, zero comments.
- **lightpanda-io/browser#2479** — `Implement Accessibility.queryAXTree CDP method (and fix latent frame-binding bug)` (by navidemad). State 2026-05-16: OPEN. Not directly gem-relevant (gem doesn't use Accessibility domain), but the "latent frame-binding bug" half might overlap with our `Browser#frame_stack` / `switch_to_frame` paths — re-check if maintainer comments surface a frame-routing concern.
- **lightpanda-io/browser#2481** — `ci: smoke test the MCP stdio server` (by navidemad). Infrastructure-only, not gem-relevant. Watch only.
- **lightpanda-io/browser#2483** — `Dockerfile: fix curl|sh pipefail; trim builder stage` (by navidemad). Infrastructure-only, not gem-relevant.
- **Network cache survival across `Target.disposeBrowserContext`** — PRs #2453-2456 (cache control surface) are all merged and below the current floor 6220. HTTP caching is now active in Lightpanda. Next sync: probe whether the cache survives `Target.disposeBrowserContext` (the gem's `Driver#reset!` path). If it does, `reset!` likely needs a `Network.clearBrowserCache` call to prevent cross-test cache pollution. Not a problem today but the surface now exists.
- **`innerText` rendering-aware implementation** — `_lightpanda.visibleText` exists because Lightpanda's `innerText` returns `textContent` verbatim (no rendering). Structural limitation tied to "no rendering engine" — unlikely to land. 2026-05-16 sync: no movement. Drop after one more idle sync if still unchanged.
