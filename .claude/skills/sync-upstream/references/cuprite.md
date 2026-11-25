# Sync target: Cuprite

Repo: https://github.com/rubycdp/cuprite
Role: **peer Capybara CDP driver** (built on Ferrum). Defines what's *idiomatic* for the Capybara::Driver layer specifically — error mapping, modal handling, JS helpers shipped to the page.

Rules destination: `.claude/rules/ruby-cdp-peers.md` (Cuprite section). That file is the **single source of Cuprite state** — last reviewed release and `main` SHA, open PRs already audited, Adopted / Outstanding / Diverged entries. This file holds only the recon recipe; don't record versions, PR verdicts or adoption status here.

Cuprite merges in bursts with quiet stretches between. Treat it as a **lower-priority** secondary sync — check it but don't block on it.

## What to read before reconning

- `.claude/rules/ruby-cdp-peers.md` — Cuprite section: the review baseline to diff from, and what's already adopted, outstanding or diverged
- `lib/capybara/lightpanda/driver.rb` — particularly the `invalid_element_errors` list and Capybara error mapping
- `lib/capybara/lightpanda/javascripts/{attach,banner,predicates,turbo}.js` — the JS bundle (split by concern, linked by `auto_scripts.rb`) injected on every navigation
- `lib/capybara/lightpanda/cuprite_{driver,page,cookies}.rb` — the Cuprite-compatible surface (`register_cuprite_driver`, `page.command`, name-keyed cookies), which drifts when Cuprite's public API changes

### Rules file empty? Discover existing adoptions before reconning

If the Cuprite **Adopted** section in `ruby-cdp-peers.md` is ever empty, see the same `git grep` recipe in `references/ferrum.md` — Cuprite mentions surface alongside Ferrum mentions. Record any `# Cuprite pattern` / `# cuprite parity` hits as candidate "Already adopted" entries.

## Recon commands

### Recent commits

Diff from the `main` SHA recorded in `ruby-cdp-peers.md`.

```bash
gh api repos/rubycdp/cuprite/commits \
  --jq '.[] | {sha: .sha[0:8], date: .commit.author.date[0:10], message: .commit.message | split("\n")[0]}' \
  | head -30
```

### Open PRs — mandatory every sync

**Run this every sync, before the commit scan.** Between merge bursts, the open queue is where Cuprite's driver-layer thinking shows up.

```bash
gh pr list --repo rubycdp/cuprite --state open --limit 30 \
  --json number,title,createdAt,isDraft \
  --jq '.[] | "\(.number)\t\(.createdAt[0:10])\tdraft=\(.isDraft)\t\(.title)"'
```

Grade each against `ruby-cdp-peers.md`, and note that an open PR can **invalidate a Diverged entry** — that is the failure mode this check exists to catch. Read the body, not just the title: the predicted axis of difference is often wrong (Cuprite's `Element#drop` PR turned out to be geometry-free like ours; the real comparison was how files reach the page). Also check whether a PR already recorded in the rules file has merged or closed since.

Do not promote an open PR to an "Adopted"/"Diverged" edit in the rules file — it has not landed. Record it as a watch item in `state/last-sync.md` with its number and what it would change, and re-check its state next sync.

### Releases and CHANGELOG

```bash
curl -s https://rubygems.org/api/v1/versions/cuprite/latest.json   # the released version (GitHub releases lag: gem 0.20.1 vs release v0.20)
git ls-remote --tags https://github.com/rubycdp/cuprite 'v0.2*'
gh api repos/rubycdp/cuprite/contents/CHANGELOG.md --jq '.content' | base64 -d | head -60
```

### Compare specific source files against ours

Cuprite is small — only a handful of files of interest. Direct file-by-file comparison is feasible.

| Cuprite file | Our equivalent | What to look for |
|---|---|---|
| `lib/capybara/cuprite/driver.rb` | `lib/capybara/lightpanda/driver.rb` | Error mapping (Ferrum errors → Capybara errors), `invalid_element_errors`, `wait_for_reload`, modal handling entrypoints, new driver options |
| `lib/capybara/cuprite/node.rb` | `lib/capybara/lightpanda/node.rb` | Capybara::Driver::Node API surface — what they implement vs us, especially `set` for various input types, `drag_to`, `drop`, `hover`, `right_click` |
| `lib/capybara/cuprite/errors.rb` | `lib/capybara/lightpanda/errors.rb` | Driver-level error classes (distinct from Ferrum's), what they catch and re-raise as Capybara errors |
| `lib/capybara/cuprite/javascripts/index.js` | `lib/capybara/lightpanda/javascripts/*.js` | Helpers injected per page. We ship the Turbo tracker (`turbo.js`) + DOM predicates (`predicates.js`); XPath is native (`Document.evaluate`), not polyfilled. What do they ship that we don't? |
| `lib/capybara/cuprite/browser.rb`, `page.rb` | `lib/capybara/lightpanda/cuprite_{driver,page,cookies}.rb` | Public API a suite written for Cuprite calls; a new or renamed method is a compat gap |

## Testing a peer API we adopt

CI runs `test/compatibility/cuprite_contract.rb` against the Cuprite and Ferrum versions pinned in the `Gemfile` (`CONTRACT_DRIVER=cuprite`). A name that exists only in an unreleased or newer peer can't go in the shared contract until that pin moves: test it in `test/features/` (as `ferrum_021_api_test.rb` did for Ferrum 0.21) and record the move as a watch item for the peer's release.

## Skip these — Chrome-specific or Lightpanda-incompatible

- `lib/capybara/cuprite/options.rb` — Chromium flag list, not transferable
- `lib/capybara/cuprite/devices.rb` — device presets built on `Mozilla` user agents, which Lightpanda refuses (see the Emulation stubs constraint in `lightpanda-io.md`)
- Anything related to Chrome binary discovery / Xvfb / headless flag toggling

## Categorize findings

Same buckets as Ferrum (see `references/ferrum.md`):

- **Adoption candidates** — Cuprite patterns we don't have, especially in error mapping and the JS bundle
- **Already adopted** — note when Cuprite changes a pattern we mirror
- **Diverged on purpose** — places where Lightpanda's missing capabilities force divergence (e.g., we don't implement screenshots; Cuprite does)
- **New risks** — bugs Cuprite fixed that may also affect us

## Updating `ruby-cdp-peers.md`

Same shape as the Ferrum section. Keep the Cuprite section terse — it's a smaller surface and a slower-moving target.
