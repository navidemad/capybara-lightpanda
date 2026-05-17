# Sync Upstream — Last-Run State

Last run: 2026-05-16
Last run targets: Lightpanda / Ferrum / Cuprite (full sync)

## Open recommendations

Each entry stays here until the gem code change happens, the upstream PR/issue resolves, or the entry becomes stale. Reconcile each one at Step 1 of the next run.

- **upstream-wishlist-a41-stale** [LOW] — `.claude/skills/lightpanda-upstream-pr/references/upstream-wishlist.md` A41 section — Entry says "Upstream issue/PR: not yet filed" but PR #2475 (`js: emit null when JSON-stringifying unserializable values`, closes #2473) merged 2026-05-15 23:24 UTC. Move A41 to the "résolus / rétractés" / one-liner zone matching A1–A9 (note that the gem's `web_socket.rb#warn_parse_failure` dedupe stays as defense-in-depth). The file is currently `M` in git status (in-progress edit by user) — coordinate before editing. Effort: tiny.
- **public-nightly-lags-floor** [MEDIUM] — `lib/capybara/lightpanda/process.rb:49` floor is now `6269`, but the public nightly tag was last published 2026-05-16 03:36 UTC (build ≤6268), **hours before** PR #2478 merged at 13:42 UTC. Users running `Binary.update` against the public nightly will hit `BinaryError: Lightpanda <ver> is too old` until the next nightly publishes. Mitigation: validated locally against `1.0.0-dev.6269+ab63cfbf3` (built from `main`), passes `rake test:all` (313/0 failures) + `rake spec:shared:parallel` (4 workers / 0 failures / 92.5s). Watch for the next nightly publish; if a user hits the floor error before then, document the manual local-build workaround. Effort: monitor only.

## Watch items

Upstream PRs / issues to recheck next sync. Promote to findings if they move.

- **lightpanda-io/browser#2479** — `Implement Accessibility.queryAXTree CDP method (and fix latent frame-binding bug)` (by navidemad). State 2026-05-16: OPEN, no maintainer comments. Not directly gem-relevant (gem doesn't use Accessibility domain), but the "latent frame-binding bug" half might overlap with our `Browser#frame_stack` / `switch_to_frame` paths — re-check if maintainer comments surface a frame-routing concern. Drop after one more idle sync if no maintainer engagement.
- **Network cache survival across `Target.disposeBrowserContext`** — PRs #2453–2456 (cache control surface) all merged and below the current floor 6220. HTTP caching is active in Lightpanda. Next sync: probe whether the cache survives `Target.disposeBrowserContext` (the gem's `Driver#reset!` path). If it does, `reset!` likely needs a `Network.clearBrowserCache` call to prevent cross-test cache pollution. Not a problem today but the surface now exists.
- **`innerText` rendering-aware implementation** — `_lightpanda.visibleText` exists because Lightpanda's `innerText` returns `textContent` verbatim (no rendering). Structural limitation tied to "no rendering engine" — unlikely to land. 2026-05-16 sync: still no movement (second idle sync). Drop after one more idle sync if still unchanged.
