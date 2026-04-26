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
- `lib/ferrum/javascripts/index.js` — JS bundle organization (theirs is single-file, like ours)
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
