# Sync target: Ferrum

Repo: https://github.com/rubycdp/ferrum
Role: **peer Ruby CDP client** — defines what's _idiomatic_ for a Ruby gem talking to CDP. Findings here surface adoption candidates: error vocabulary, retry helpers, frame/runtime split, JS bundle organization.

Rules destination: `.claude/rules/ruby-cdp-peers.md` (Ferrum section)

Activity baseline (verify each sync — these go stale): very active. ~40 commits Feb–Apr 2026, last release **v0.17.2 (2026-03-24)**. Treat as primary peer-gem sync target.

## What to read before reconning

- `.claude/rules/ruby-cdp-peers.md` — what we've already adopted and what's outstanding
- `lib/capybara/lightpanda/` — particularly `node.rb`, `frame.rb`, `cookies.rb`, `errors.rb`, `utils/event.rb`, `client.rb`. These are the surfaces where Ferrum's design directly competes with ours.

### First sync? Discover existing adoptions before reconning

If `ruby-cdp-peers.md`'s Ferrum **Adopted** section is empty (or near-empty), the rules file can't tell you what we already mirror — but our source comments often do. Grep our gem for explicit Ferrum mentions to seed the bucket:

```bash
git grep -nE -i 'ferrum|cuprite' lib/ spec/ | grep -vE 'github\.com|rubycdp|^Binary|\.gemspec|README'
```

Look for phrases like "Mirrors ferrum's …", "Cuprite pattern", "ferrum parity". Each hit is a candidate "Already adopted" entry — verify by comparing the named Ferrum file/method against our implementation, then record in the rules file. After this first pass the rules file is the source of truth and future syncs skip this step.

## Recon commands

### Recent commits (skip Chrome-specific noise)

Project the first line of each commit message into a field _before_ filtering — the multi-line `.commit.message` form has tripped up the `select(... | test(...))` pipeline in practice (jq error "expected an object but got: string" when the message contains certain characters). Filtering on the projected single-line `msg` is robust:

```bash
gh api 'repos/rubycdp/ferrum/commits?per_page=40' \
  --jq '.[] | {sha: .sha[0:8], date: .commit.author.date[0:10], msg: (.commit.message | split("\n")[0])} | select((.msg | ascii_downcase) | test("error|retry|attempt|frame|runtime|cookie|node|callfunctionon|evaluate|context|target|dialog|polyfill")) | select((.msg | ascii_downcase) | test("screenshot|pdf|xvfb|proxy|download|tracing") | not)'
```

### Open PRs — the signal merged commits can't give you

**Run this every sync, before the commit scan.** Ferrum merges slowly: `main` HEAD
sat unmoved for the whole 2026-07-24 → 2026-07-25 window while the PR queue held
18 open PRs, several of them gem-relevant. A commits-only recon reports "nothing
new" on exactly the syncs where the queue is where the information is.

```bash
gh pr list --repo rubycdp/ferrum --state open --limit 30 \
  --json number,title,createdAt,isDraft \
  --jq '.[] | "\(.number)\t\(.createdAt[0:10])\tdraft=\(.isDraft)\t\(.title)"'
```

An open PR is worth reading for two things a merged commit never tells you:

- **A bug they found in a design we share** → **New risks**, and often the cheapest
  audit we can run. Ferrum #602 ("make the CDP send path thread-safe") names two
  concrete races: an unlocked `@command_id` increment handing two threads the same
  id, and `websocket-driver` called from the caller and reader threads at once,
  interleaving frame bytes. Both apply verbatim to our hand-rolled client, so both
  got checked: `client.rb#next_command_id` locks with `@mutex`, and
  `client/web_socket.rb` guards `text` / `close` / `parse` with `@driver_mutex`
  (the one unguarded `@driver.parse` is in `read_handshake_response`, which runs
  before the reader thread exists). Verified immune 2026-07-25 — record the
  verdict either way, so the next sync doesn't re-audit it.
- **A capability arriving that would invalidate a Diverged or Outstanding entry** →
  re-read that entry now rather than after it merges.

Read the PR body, not just the title — the bug description is the transferable
part, and it is usually far more precise than the eventual commit message.

**A closed, unmerged PR does not mean rejected work.** Verify before concluding
anything from state alone: our own lightpanda PR #3051 shows `CLOSED` with no
merge, yet the identical commit landed days later on a maintainer's branch under
a different PR number. Check whether the change is in the tree
(`git log --oneline -- <path>`) before recording a rejection.

### Releases and CHANGELOG

```bash
gh release list --repo rubycdp/ferrum --limit 5
gh api repos/rubycdp/ferrum/contents/CHANGELOG.md --jq '.content' | base64 -d | head -150
```

### Compare specific source files against ours

These are the four files where divergence matters most. Fetch each, read against our equivalent, note differences.

| Ferrum file                                              | Our equivalent                                                                                | What to look for                                                                      |
| -------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `lib/ferrum/errors.rb`                                   | `lib/capybara/lightpanda/errors.rb`                                                           | New error classes (transient vs fatal), inheritance, what gets raised when            |
| `lib/ferrum/utils/attempt.rb`                            | `lib/capybara/lightpanda/utils/event.rb` (closest) — we don't yet have a dedicated retry util | Retry policy: which errors trigger retry, max attempts, backoff                       |
| `lib/ferrum/frame/runtime.rb`, `lib/ferrum/frame/dom.rb` | `lib/capybara/lightpanda/node.rb`, `frame.rb`                                                 | `callFunctionOn` invocation patterns, isolated-world handling, frame stack management |
| `lib/ferrum/cookies.rb` + `lib/ferrum/cookies/`          | `lib/capybara/lightpanda/cookies.rb`                                                          | Cookie sweep/clear strategy, cross-origin handling                                    |

Bonus comparison candidates if time permits:

- `lib/ferrum/client.rb` — WebSocket dispatcher, command timeout handling
- `lib/ferrum/javascripts/index.js` — JS bundle organization (theirs is single-file; ours is split by concern into `javascripts/{turbo,predicates,attach}.js`, assembled by `auto_scripts.rb`)
- `lib/ferrum/keyboard.rb` + `lib/ferrum/keyboard.json` — key-code table (copy verbatim if we ever need richer `Input.dispatchKeyEvent`)

## Skip these — Chrome-specific, not transferable

Lightpanda doesn't have these capabilities or they don't fit our context:

- `lib/ferrum/page/screenshot.rb`, `page/screencast.rb`, `page/animation.rb`, `page/tracing.rb`, `page/stream.rb` — no real rendering pipeline in Lightpanda
- `lib/ferrum/browser/xvfb.rb`, `browser/binary.rb`, `browser/version_info.rb` — Chromium binary/X-server discovery
- `lib/ferrum/network/auth_request.rb`, `network/intercepted_request.rb`, `proxy.rb`, `downloads.rb` — Lightpanda's Fetch domain is barely used
- `lib/ferrum/rgba.rb` — screenshot color helper
- DevTools Protocol version bumps in `client.rb` — Lightpanda implements its own subset; Chrome CDP version drift is irrelevant

## Categorize findings

For Ferrum, the report uses one bucket the Lightpanda flow doesn't:

- **Adoption candidates** — patterns/APIs Ferrum has that we don't. Each entry should name (a) the Ferrum file, (b) our equivalent file, (c) why adopting would help (clarity, fewer bugs, parity with idiomatic Ruby CDP code), (d) rough effort (tiny/medium/large).
- **Already adopted** — patterns we mirrored from a previous sync. Note when Ferrum has since diverged (e.g., they added a new transient error class — should we mirror it?).
- **Diverged on purpose** — places we deliberately differ from Ferrum because Lightpanda's constraints require it. Don't flag these as adoption candidates again.
- **New risks** — bugs Ferrum fixed that may also affect us (e.g., cookie sweep, frame stack reset).

## Updating `ruby-cdp-peers.md`

The Ferrum section is small by design. Keep it as:

- **Last reviewed**: date + Ferrum version/SHA
- **Adopted**: bulleted list of patterns we already mirror, each with Ferrum file ↔ our file
- **Outstanding adoption candidates**: bulleted list, each with effort estimate
- **Diverged on purpose**: bulleted list with the constraint that forces divergence (so future syncs don't re-flag them)

Don't write a changelog. When a Ferrum pattern is adopted in our gem, move it from "Outstanding" to "Adopted" and stop. When Ferrum changes a pattern we already adopted, edit the "Adopted" entry inline.
