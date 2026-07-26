# Sync target: Cuprite

Repo: https://github.com/rubycdp/cuprite
Role: **peer Capybara CDP driver** (built on Ferrum). Defines what's *idiomatic* for the Capybara::Driver layer specifically — error mapping, modal handling, JS polyfills shipped to the page.

Rules destination: `.claude/rules/ruby-cdp-peers.md` (Cuprite section)

Activity baseline (verify each sync — these go stale): moderately active. ~8 commits in 2026 then quiet stretches. Last release **v0.17 (2025-05-11)**, no 2026 release yet. Treat as **lower-priority** secondary sync — check it but don't block on it.

## What to read before reconning

- `.claude/rules/ruby-cdp-peers.md` — Cuprite section
- `lib/capybara/lightpanda/driver.rb` — particularly the `invalid_element_errors` list and Capybara error mapping
- `lib/capybara/lightpanda/javascripts/{turbo,predicates,attach}.js` — the JS bundle (split by concern, assembled by `auto_scripts.rb`) injected on every navigation

### First sync? Discover existing adoptions before reconning

If the Cuprite **Adopted** section in `ruby-cdp-peers.md` is empty, see the same `git grep` recipe in `references/ferrum.md` — Cuprite mentions surface alongside Ferrum mentions. Record any `# Cuprite pattern` / `# cuprite parity` hits as candidate "Already adopted" entries.

## Recon commands

### Recent commits

```bash
gh api repos/rubycdp/cuprite/commits \
  --jq '.[] | {sha: .sha[0:8], date: .commit.author.date[0:10], message: .commit.message | split("\n")[0]}' \
  | head -30
```

### Open PRs — mandatory here, because Cuprite barely merges

**Run this every sync, before the commit scan.** Cuprite is the slowest-merging
target: no release since v0.17 (2025-05-11), and `main` HEAD went untouched
across the 2026-07-24 → 2026-07-25 window. Its 10 open PRs are where the
driver-layer thinking actually shows up.

```bash
gh pr list --repo rubycdp/cuprite --state open --limit 30 \
  --json number,title,createdAt,isDraft \
  --jq '.[] | "\(.number)\t\(.createdAt[0:10])\tdraft=\(.isDraft)\t\(.title)"'
```

Grade each against `ruby-cdp-peers.md`, and note that an open PR can **invalidate
a Diverged entry** — that is the failure mode this check exists to catch:

- **#316 "Support `Element#drop` for files and strings"** (open 2026-07-09) directly
  contradicts our recorded divergence, which asserts Cuprite has *no* `drop` and
  that ours therefore exceeds it. Still true of their `main`, no longer true of
  their intent. Body read 2026-07-26: theirs is **also geometry-free** (ported from
  Capybara's Selenium `html5_drag.rb`), so the predicted "theirs assumes
  coordinates" axis is wrong — the real difference is how files reach the page.
  Cuprite synthesizes a hidden `<input type=file>` and attaches via
  `DOM.setFileInputFiles`, so the browser reads bytes off disk; our `DROP_JS`
  base64s them over the CDP WebSocket and needs `--cdp-max-message-size` raised
  to 100 MiB for a ~70 MB ceiling. When it merges, weigh their approach on that
  axis and rewrite the entry.
- **#320 `raise_on_unhandled_modal`**, **#313 empty/nil keys in `Node#send_keys`** —
  both land in areas we implement (pre-armed modals, `send_keys`), so they are
  adoption candidates or risks depending on what the body says.

Do not promote an open PR to an "Adopted"/"Diverged" edit in the rules file — it
has not landed. Record it as a watch item in `state/last-sync.md` with its number
and what it would change, and re-check its state next sync.

### Releases and CHANGELOG

```bash
gh release list --repo rubycdp/cuprite --limit 5
gh api repos/rubycdp/cuprite/contents/CHANGELOG.md --jq '.content' | base64 -d | head -60
```

### Compare specific source files against ours

Cuprite is small — only ~7 files of interest. Direct file-by-file comparison is feasible.

| Cuprite file | Our equivalent | What to look for |
|---|---|---|
| `lib/capybara/cuprite/driver.rb` | `lib/capybara/lightpanda/driver.rb` | Error mapping (Ferrum errors → Capybara errors), `invalid_element_errors`, `wait_for_reload`, modal handling entrypoints |
| `lib/capybara/cuprite/node.rb` | `lib/capybara/lightpanda/node.rb` | Capybara::Driver::Node API surface — what they implement vs us, especially `set` for various input types, `drag_to`, `hover`, `right_click` |
| `lib/capybara/cuprite/errors.rb` | `lib/capybara/lightpanda/errors.rb` | Driver-level error classes (distinct from Ferrum's), what they catch and re-raise as Capybara errors |
| `lib/capybara/cuprite/javascripts/index.js` | `lib/capybara/lightpanda/javascripts/{turbo,predicates,attach}.js` (split by concern, assembled by `auto_scripts.rb`) | Polyfills/helpers injected per page. We ship the Turbo tracker (`turbo.js`) + DOM predicates (`predicates.js`); XPath is now native (`Document.evaluate`, PR #2305), not polyfilled. What do they ship that we don't? |

## Skip these — Chrome-specific or Lightpanda-incompatible

- `lib/capybara/cuprite/options.rb` — Chromium flag list, not transferable
- Anything related to Chrome binary discovery / Xvfb / headless flag toggling
- ~~File upload helpers~~ — no longer a skip: file input support landed upstream (build ≥6672, PR #2635 + #2654) and the gem wires `attach_file` via `DOM.setFileInputFiles`. Cuprite's file-upload / `drag_to` helpers are now comparison candidates.

## Categorize findings

Same buckets as Ferrum (see `references/ferrum.md`):

- **Adoption candidates** — Cuprite patterns we don't have, especially in error mapping and the JS bundle
- **Already adopted** — note when Cuprite changes a pattern we mirror
- **Diverged on purpose** — places where Lightpanda's missing capabilities force divergence (e.g., we don't implement screenshots; Cuprite does)
- **New risks** — bugs Cuprite fixed that may also affect us

## Updating `ruby-cdp-peers.md`

Same shape as the Ferrum section. Keep the Cuprite section terse — it's a smaller surface and a slower-moving target.
