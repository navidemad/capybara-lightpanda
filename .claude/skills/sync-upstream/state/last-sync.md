# Sync Upstream — Last-Run State

Last run: 2026-05-13 (afternoon, post-#2431 merge + batch-mode validation)
Last run targets: Lightpanda (targeted — upstream PR #2431 merge follow-up)

## Open recommendations

Each entry stays here until the gem code change happens, the upstream PR/issue resolves, or the entry becomes stale. Reconcile each one at Step 1 of the next run.

- **bump-min-nightly-and-relax-refresh-frame-stack** [HIGH, but BLOCKED on nightly ≥6199 being published] — Two coordinated changes, one release:
  1. `lib/capybara/lightpanda/process.rb` — bump `MINIMUM_NIGHTLY_BUILD` from 6109 to the first nightly carrying both PR #2431 (`ffc2baa7`) and PR #2445 (`12971a24`). Both merged 2026-05-13 after nightly 6198 was published, so the floor will be ≥6199.
  2. `lib/capybara/lightpanda/browser.rb:816-840` + helper at 850-861 — relax the `refresh_frame_stack!` rescue. The contextId churn (issue #2400) is fixed upstream and batch-mode frame specs now run clean (24 / 0F / 4P, validated 2026-05-13 across seeds 62467 / 99999 / 11111). Options: drop the rescue entirely, or keep it as a no-op defense-in-depth — judgment call. Don't ship #2 without #1, otherwise end-users on older nightlies break. Effort: tiny.

- **htmldialog-polyfill-cleanup** [LOW] — `lib/capybara/lightpanda/javascripts/polyfills.js:80-105` ("Bug #4" block). Drop the feature-detected `HTMLDialogElement.{show, showModal, close}` polyfill in the same nightly-floor bump above — PR #2435 (`HTMLDialogElement.{show, showModal, close}`) also merged 2026-05-13 and will ship in the same nightly ≥6199. Polyfill auto-degrades to no-op on supporting nightlies, so this is purely dead-code removal. Effort: tiny.

- **gem-pr-20-rebase-or-close** [LOW] — `navidemad/capybara-lightpanda#20` (branch `docs/pr-2431-validation-findings`, OPEN). Its central finding — *"PR #2431 cures contextId churn but introduces batch pollution"* — was based on a build that lacked PR #2445. Today's validation against the post-#2445 main binary disproves the pollution conclusion: same seeds, 0 failures. The PR's doc diffs are also now redundant: the rules file and state file have been updated directly in main with the correct (post-validation) picture. Cleanest path: **close PR #20 as superseded**, optionally referencing this state file from the close comment. Rebase would mean dropping every hunk anyway. Effort: tiny.

## Watch items

Upstream PRs / issues to recheck next sync. Promote to findings if they move.

- **next-nightly-after-2026-05-13-merges** — Next Lightpanda nightly build (≥6199) will be the first to carry today's stack of merges relevant to this gem: PR #2431 (iframe contextId fix), PR #2445 (BrowserContext arena reset on dispose), PR #2435 (HTMLDialogElement native methods), PR #2437 (window.frameElement). When the nightly publishes, both open recommendations above (`bump-min-nightly-and-relax-refresh-frame-stack`, `htmldialog-polyfill-cleanup`) become actionable in a single release. Nightly tag was still at 6198 as of 2026-05-13 afternoon.
