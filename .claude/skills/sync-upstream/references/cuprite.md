# Sync target: Cuprite

Repo: https://github.com/rubycdp/cuprite
Role: **peer Capybara CDP driver** (built on Ferrum). Defines what's *idiomatic* for the Capybara::Driver layer specifically — error mapping, modal handling, JS polyfills shipped to the page.

Rules destination: `.claude/rules/ruby-cdp-peers.md` (Cuprite section)

Activity baseline (verify each sync — these go stale): moderately active. ~8 commits in 2026 then quiet stretches. Last release **v0.17 (2025-05-11)**, no 2026 release yet. Treat as **lower-priority** secondary sync — check it but don't block on it.

## What to read before reconning

- `.claude/rules/ruby-cdp-peers.md` — Cuprite section
- `lib/capybara/lightpanda/driver.rb` — particularly the `invalid_element_errors` list and Capybara error mapping
- `lib/capybara/lightpanda/javascripts/index.js` — the JS bundle injected on every navigation

### First sync? Discover existing adoptions before reconning

If the Cuprite **Adopted** section in `ruby-cdp-peers.md` is empty, see the same `git grep` recipe in `references/ferrum.md` — Cuprite mentions surface alongside Ferrum mentions. Record any `# Cuprite pattern` / `# cuprite parity` hits as candidate "Already adopted" entries.

## Recon commands

### Recent commits

```bash
gh api repos/rubycdp/cuprite/commits \
  --jq '.[] | {sha: .sha[0:8], date: .commit.author.date[0:10], message: .commit.message | split("\n")[0]}' \
  | head -30
```

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
| `lib/capybara/cuprite/javascripts/index.js` | `lib/capybara/lightpanda/javascripts/index.js` | Polyfills/helpers injected per page. We have the XPath polyfill + #id rewriter + Turbo tracker; what do they ship that we don't? |

## Skip these — Chrome-specific or Lightpanda-incompatible

- `lib/capybara/cuprite/options.rb` — Chromium flag list, not transferable
- Anything related to Chrome binary discovery / Xvfb / headless flag toggling
- File upload helpers — Lightpanda doesn't support `input[type=file]` (issue #2175 upstream)

## Categorize findings

Same buckets as Ferrum (see `references/ferrum.md`):

- **Adoption candidates** — Cuprite patterns we don't have, especially in error mapping and the JS bundle
- **Already adopted** — note when Cuprite changes a pattern we mirror
- **Diverged on purpose** — places where Lightpanda's missing capabilities force divergence (e.g., we don't implement screenshots; Cuprite does)
- **New risks** — bugs Cuprite fixed that may also affect us

## Updating `ruby-cdp-peers.md`

Same shape as the Ferrum section. Keep the Cuprite section terse — it's a smaller surface and a slower-moving target.
