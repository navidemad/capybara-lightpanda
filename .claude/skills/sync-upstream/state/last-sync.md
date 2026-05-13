# Sync Upstream — Last-Run State

Last run: 2026-05-13 (evening, targeted `index.js` impact audit)
Last run targets: Lightpanda (targeted — recon for `lib/capybara/lightpanda/javascripts/index.js` simplification opportunities)

## Open recommendations

(none — all 2026-05-13 afternoon carry-forwards landed in commits `160d5c6` and `2ed7391`. Today's evening recon against ~120 upstream commits and all open PRs found no new opportunity to simplify `index.js`.)

## Watch items

Upstream PRs / issues to recheck next sync. Promote to findings if they move.

- **lightpanda-io/browser#2309** — `HTMLElement.isContentEditable IDL attribute not implemented`. State as of 2026-05-13: CLOSED 2026-04-30 as won't-fix (browser deliberately returns `false`, no caret/keyboard pipeline). Watch only — if upstream ever reopens with a real ancestor-walking implementation, the gem polyfill at `javascripts/index.js:171-182` could be retired. Currently documented as "Polyfill MUST stay" in `.claude/rules/lightpanda-io.md`.
- **CSSOM cascade resolution for `getComputedStyle`** — no PR yet, but the `_lightpanda.isVisible` `offsetParent === null` fallback (`javascripts/index.js:116-117`) exists specifically because Lightpanda's CSSOM doesn't resolve every cascade case Chrome does. If a future upstream PR closes that gap, we could drop the fallback. Track in the next sync by re-checking commits touching `getComputedStyle` or cascade resolution.
- **`innerText` rendering-aware implementation** — same shape as above; `_lightpanda.visibleText` exists because Lightpanda's `innerText` returns `textContent` verbatim (no rendering). Structural limitation tied to "no rendering engine" — unlikely to land, but worth a quick check each sync.
