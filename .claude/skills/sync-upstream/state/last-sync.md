# Sync Upstream — Last-Run State

Last run: 2026-05-13
Last run targets: Lightpanda + Ferrum + Cuprite

## Open recommendations

Each entry stays here until the gem code change happens, the upstream PR/issue resolves, or the entry becomes stale. Reconcile each one at Step 1 of the next run.

- **htmldialog-polyfill-cleanup** [LOW] — `lib/capybara/lightpanda/javascripts/polyfills.js:80-105` ("Bug #4" block). Drop the feature-detected `HTMLDialogElement.{show, showModal, close}` polyfill in a coordinated release that bumps `Process::MINIMUM_NIGHTLY_BUILD` past the build that contains upstream PR #2435 (merged 2026-05-13T04:17 UTC; nightly 6198 was published 03:35 UTC, *before* the merge, so the first nightly carrying the fix will be ≥6199). The polyfill auto-degrades to a no-op on supporting nightlies — no urgency, but the dead block is worth removing on the next release. Effort: tiny.

- **fix-bug9-ref-in-peers-md** [DONE in this run] — Was a stale reference (`Known Bug #9 in lightpanda-io.md`) in `ruby-cdp-peers.md`. Replaced with a pointer to the "No rendering engine (CSS much improved)" limitation. Listed here only so the next run sees it was addressed and doesn't re-flag it; safe to drop after one more sync cycle.

## Watch items

Upstream PRs / issues to recheck next sync. Promote to findings if they move.

- **lightpanda-io/browser#2431** — "fix(cdp): remove duplicate Page.frameNavigated and fix context registration for iframes". State as of 2026-05-13: OPEN (HEAD `806497c0`). **Locally validated 2026-05-13** by building from the PR branch (binary `1.0.0-dev.6157+806497c0`) and running `spec/features/session_spec.rb` `#switch_to_frame` + `#within_frame` against it. Findings: (a) **the original `NoExecutionContextError "Cannot find context with specified id"` is gone** — every previously-failing frame test passes in isolation, confirming the PR cures the contextId churn; (b) **batch-mode runs surface 8–14 *different* failures** (`Capybara::ElementNotFound` for the iframe element itself, or for content inside it after switching frames), seed-dependent (seed 62467 → 14 failures; 99999 → 11; 11111 → 8). That's cross-test state pollution, NOT the contextId bug — `Browser#find_in_frame`'s `refresh_frame_stack!` only rescues `NoExecutionContextError`, so it doesn't help here. **Conclusion**: the watch item's "relax the mitigation" precondition is only *partially* satisfied; we cannot drop the mitigation yet. Next step is to determine whether the batch pollution is a gem-side issue (cookie/storage/iframe leak between specs?) or a regression introduced by PR #2431. Either way, drop-mitigation PR is on hold; comment on #2431 with the batch-mode finding once we've narrowed the cause.

- **next-nightly-after-pr-2435** — Next Lightpanda nightly build (≥6199) will be the first to carry the HTMLDialogElement.{show, showModal, close} native methods (PR #2435 merged 2026-05-13T04:17 UTC, after nightly 6198 was published). Once a nightly with this fix is released, the cleanup recommendation above (`htmldialog-polyfill-cleanup`) becomes actionable — pair it with a `MINIMUM_NIGHTLY_BUILD` bump in `lib/capybara/lightpanda/process.rb`.
