# Sync target: Ferrum

Repo: https://github.com/rubycdp/ferrum
Role: **peer Ruby CDP client** — defines what's _idiomatic_ for a Ruby gem talking to CDP. Findings here surface adoption candidates: error vocabulary, retry helpers, frame/runtime split, JS bundle organization.

Rules destination: `.claude/rules/ruby-cdp-peers.md` (Ferrum section). That file is the **single source of Ferrum state** — last reviewed release and `main` SHA, open PRs already audited, Adopted / Outstanding / Diverged entries. This file holds only the recon recipe; don't record versions, PR verdicts or adoption status here.

## What to read before reconning

- `.claude/rules/ruby-cdp-peers.md` — Ferrum section: the review baseline (release + SHA) to diff from, and what's already adopted, outstanding or diverged
- `lib/capybara/lightpanda/` — particularly `node.rb`, `browser.rb` + `browser/runtime.rb`, `cookies.rb`, `errors.rb`, `utils/{event,attempt}.rb`, `client.rb` + `client/`. These are the surfaces where Ferrum's design directly competes with ours.

### Rules file empty? Discover existing adoptions before reconning

If `ruby-cdp-peers.md`'s Ferrum **Adopted** section is ever empty (fresh clone, file reset), our source comments can reseed it. Grep our gem for explicit Ferrum mentions:

```bash
git grep -nE -i 'ferrum|cuprite' lib/ spec/ test/ | grep -vE 'github\.com|rubycdp|^Binary|\.gemspec|README'
```

Look for phrases like "Mirrors ferrum's …", "Cuprite pattern", "ferrum parity". Each hit is a candidate "Already adopted" entry — verify by comparing the named Ferrum file/method against our implementation, then record in the rules file.

## Recon commands

### Recent commits (skip Chrome-specific noise)

Diff from the `main` SHA recorded in `ruby-cdp-peers.md`. Project the first line of each commit message into a field _before_ filtering — the multi-line `.commit.message` form has tripped up the `select(... | test(...))` pipeline in practice (jq error "expected an object but got: string" when the message contains certain characters). Filtering on the projected single-line `msg` is robust:

```bash
gh api 'repos/rubycdp/ferrum/commits?per_page=40' \
  --jq '.[] | {sha: .sha[0:8], date: .commit.author.date[0:10], msg: (.commit.message | split("\n")[0])} | select((.msg | ascii_downcase) | test("error|retry|attempt|frame|runtime|cookie|node|callfunctionon|evaluate|context|target|dialog|polyfill")) | select((.msg | ascii_downcase) | test("screenshot|pdf|xvfb|proxy|tracing") | not)'
```

### Open PRs — the signal merged commits can't give you

**Run this every sync, before the commit scan.** Ferrum can sit with `main` unmoved while the PR queue holds gem-relevant work; a commits-only recon reports "nothing new" on exactly the syncs where the queue is where the information is.

```bash
gh pr list --repo rubycdp/ferrum --state open --limit 30 \
  --json number,title,createdAt,isDraft \
  --jq '.[] | "\(.number)\t\(.createdAt[0:10])\tdraft=\(.isDraft)\t\(.title)"'
```

Skip PRs `ruby-cdp-peers.md` already records a verdict for, unless they changed since. An open PR is worth reading for two things a merged commit never tells you:

- **A bug they found in a design we share** → **New risks**, and often the cheapest audit we can run. Example of the shape: Ferrum #602 (CDP send-path thread safety) named two races — an unlocked command-id increment and `websocket-driver` called from two threads at once — that applied verbatim to our hand-rolled client; the immunity verdict now lives under "Transport constraints" in `ruby-cdp-peers.md`. Record the verdict either way, so the next sync doesn't re-audit it.
- **A capability arriving that would invalidate a Diverged or Outstanding entry** → re-read that entry now rather than after it merges.

Read the PR body, not just the title — the bug description is the transferable part, and it is usually far more precise than the eventual commit message.

**A closed, unmerged PR does not mean rejected work.** Verify before concluding anything from state alone: check whether the change is in the tree (`git log --oneline -- <path>`) before recording a rejection.

### Releases and CHANGELOG

Don't read the release from `gh release list`: Ferrum doesn't publish a GitHub release for every tag (2026-11-24 it still showed 0.20.1 as Latest while v0.21.0 was tagged and on rubygems).

```bash
curl -s https://rubygems.org/api/v1/versions/ferrum/latest.json   # the released version
git ls-remote --tags https://github.com/rubycdp/ferrum 'v0.2*'     # tags, incl. ones without a GitHub release
gh api repos/rubycdp/ferrum/contents/CHANGELOG.md --jq '.content' | base64 -d | head -150
```

### Compare specific source files against ours

These are the files where divergence matters most. Fetch each, read against our equivalent, note differences.

| Ferrum file | Our equivalent | What to look for |
| --- | --- | --- |
| `lib/ferrum/errors.rb` | `lib/capybara/lightpanda/errors.rb` | New error classes (transient vs fatal), inheritance, what gets raised when |
| `lib/ferrum/utils/attempt.rb` | `lib/capybara/lightpanda/utils/attempt.rb` | Retry policy: which errors trigger retry, max attempts, backoff |
| `lib/ferrum/frame/runtime.rb`, `lib/ferrum/frame/dom.rb` | `lib/capybara/lightpanda/browser/runtime.rb`, `node.rb`, `browser.rb` (`Browser#frame_stack`) | `callFunctionOn` invocation patterns, isolated-world handling, frame stack management |
| `lib/ferrum/cookies.rb` + `lib/ferrum/cookies/` | `lib/capybara/lightpanda/cookies.rb` | Cookie sweep/clear strategy, cross-origin handling |
| `lib/ferrum/network.rb` + `lib/ferrum/network/` | `lib/capybara/lightpanda/network.rb` + `network/` | Traffic tracking, redirect hops, idle waits |
| `lib/ferrum/downloads.rb` | `lib/capybara/lightpanda/downloads.rb` | Download events and blocking wait |

Bonus comparison candidates if time permits:

- `lib/ferrum/client.rb` — WebSocket dispatcher, command timeout handling (ours: `client.rb` + `client/`)
- `lib/ferrum/javascripts/index.js` — JS bundle organization (theirs is single-file; ours is split by concern into `javascripts/{attach,banner,predicates,turbo}.js`, linked by `auto_scripts.rb`)
- `lib/ferrum/keyboard.rb` + `lib/ferrum/keyboard.json` — key-code table (ours: `keyboard.rb`)

## Skip these — Chrome-specific, not transferable

Lightpanda doesn't have these capabilities or they don't fit our context:

- `lib/ferrum/page/screenshot.rb`, `page/screencast.rb`, `page/animation.rb`, `page/tracing.rb`, `page/stream.rb` — no real rendering pipeline in Lightpanda
- `lib/ferrum/browser/xvfb.rb`, `browser/binary.rb`, `browser/version_info.rb` — Chromium binary/X-server discovery
- `lib/ferrum/network/auth_request.rb`, `network/intercepted_request.rb`, `proxy.rb` — we use no Fetch interception
- `lib/ferrum/rgba.rb` — screenshot color helper
- DevTools Protocol version bumps in `client.rb` — Lightpanda implements its own subset; Chrome CDP version drift is irrelevant

## Categorize findings

For Ferrum, the report uses one bucket the Lightpanda flow doesn't:

- **Adoption candidates** — patterns/APIs Ferrum has that we don't. Each entry should name (a) the Ferrum file, (b) our equivalent file, (c) why adopting would help (clarity, fewer bugs, parity with idiomatic Ruby CDP code), (d) rough effort (tiny/medium/large).
- **Already adopted** — patterns we mirrored from a previous sync. Note when Ferrum has since diverged (e.g., they added a new transient error class — should we mirror it?).
- **Diverged on purpose** — places we deliberately differ from Ferrum because Lightpanda's constraints require it. Don't flag these as adoption candidates again.
- **New risks** — bugs Ferrum fixed that may also affect us (e.g., cookie sweep, frame stack reset).

## Updating `ruby-cdp-peers.md`

The Ferrum section keeps this shape:

- **Header line**: review date + release + `main` SHA, open PRs still worth tracking, and one-line verdicts for audited unreleased changes
- **Adopted**: one line per pattern, Ferrum file ↔ our file ↔ why
- **Transport constraints**: invariants of our CDP client that peer bugs were audited against
- **Outstanding adoption candidates**: bulleted list, each with effort estimate
- **Diverged on purpose**: bulleted list with the constraint that forces divergence (so future syncs don't re-flag them)

Don't write a changelog. When a Ferrum pattern is adopted in our gem, move it from "Outstanding" to "Adopted" and stop. When Ferrum changes a pattern we already adopted, edit the "Adopted" entry inline.
