---
name: sync-upstream
description: Audit upstream repos that affect the capybara-lightpanda gem — the Lightpanda browser (lightpanda-io/browser), and the peer Ruby CDP gems Ferrum (rubycdp/ferrum) and Cuprite (rubycdp/cuprite). Use this skill whenever the user mentions syncing upstream, checking Lightpanda changes, auditing whether workarounds are still needed, preparing a gem release, verifying CDP methods exist upstream, investigating a specific CDP behavior (Page.loadEventFired, Network.clearBrowserCookies, XPathResult, modal handling), or asks what's new in Ferrum or Cuprite, what patterns we should adopt from them, whether a Ferrum error class or retry helper is worth mirroring, or whether Cuprite's driver does X better. Also use when the user reports a BrowserError or CDP failure and wants to know if it's a Lightpanda limitation, or when they want a pre-release peer-gem comparison. Do NOT use for implementing code changes, fixing the XPath polyfill JS, setting up CI, or refactoring driver methods — those are code tasks, not upstream investigations.
user_invocable: true
model: opus
effort: max
---

# Sync Upstream

Audit upstream repos for changes that affect `capybara-lightpanda`. This skill is **reconnaissance and planning**, not implementation. Three sync targets, two different categories of finding:

| Target | Repo | Role | Findings unlock |
|---|---|---|---|
| **Lightpanda** | lightpanda-io/browser | Backend (Zig browser) | Workaround removal, new CDP capabilities, new risks |
| **Ferrum** | rubycdp/ferrum | Peer Ruby CDP client | Idiomatic adoption candidates (errors, retry, frame/runtime split) |
| **Cuprite** | rubycdp/cuprite | Peer Capybara CDP driver | Driver-layer adoption candidates (error mapping, JS polyfills) |

Lightpanda defines what's *possible*. Ferrum and Cuprite define what's *idiomatic* for a Ruby gem doing the same job. Different questions, different rules-file destinations, but a shared workflow worth running together — especially before a release.

## Step 0: Pick targets

Read the user's prompt and pick which targets to run:

- **All three** — phrases like "sync upstream", "pre-release audit", "check what's new", "general upstream check"
- **Lightpanda only** — Lightpanda-specific symptoms (CDP method behavior, browser bug, navigation issue, BrowserError, "is this a Lightpanda limitation?")
- **Ferrum only** — "what's new in Ferrum?", "did Ferrum add X?", "should we adopt their retry/error/frame pattern?"
- **Cuprite only** — "how does Cuprite handle Y?", "is our driver error mapping behind Cuprite?"
- **Targeted investigation** — a single specific question (e.g., "has Page.loadEventFired been fixed?"). Run only the relevant target and skip unrelated checks. Still read the rules files for context, but go deep on the question.

Tell the user which targets you've picked and why before starting recon. They can redirect.

## Step 1: Gather current state

Read both rules files unconditionally — the answers to "what changed?" depend on knowing what we already know:

- `.claude/rules/lightpanda-io.md` — current understanding of the browser
- `.claude/rules/ruby-cdp-peers.md` — adopted/outstanding patterns from Ferrum and Cuprite

Then read the gem source surfaces relevant to the targets you picked:

- Lightpanda → `lib/capybara/lightpanda/browser.rb`, `node.rb`, `cookies.rb`, `frame.rb` (workarounds depend on browser quirks)
- Ferrum → `lib/capybara/lightpanda/node.rb`, `frame.rb`, `cookies.rb`, `errors.rb`, `utils/event.rb`, `client.rb` (the surfaces where Ferrum's design directly competes with ours)
- Cuprite → `lib/capybara/lightpanda/driver.rb`, `javascripts/index.js` (driver-layer error mapping + JS bundle)

## Step 2: Per target, follow its reference file

Each target has a per-target reference with concrete recon commands, source-tree pointers, and what to skip:

- `references/lightpanda.md` — CDP method existence checks, gh queries, lightpanda-io.md update rules
- `references/ferrum.md` — Ferrum source tree, file-by-file comparisons against our gem, what's Chrome-specific to skip
- `references/cuprite.md` — Cuprite driver/error/JS comparisons

Run target recons in parallel where possible (each `gh api` or WebFetch is independent).

## Step 3: Categorize findings

Use this taxonomy across all targets — every finding lands in exactly one bucket:

- **Broken** — methods we call that no longer exist upstream (Lightpanda only). Bugs in our gem. Flag with our gem-side file:line.
- **Workaround removal** — bugs we work around that are now fixed (Lightpanda). Always require validation before recommending removal: build the local browser from `main` (see `references/lightpanda.md` "Build local browser from main"), then prompt the user to run specs with `LIGHTPANDA_BIN=/Users/navid/code/browser/zig-out/bin/lightpanda`. Don't run specs unprompted. After workaround validation, also run the **skip-pattern audit** (`AUDIT_SKIPS=1`, see `references/lightpanda.md` "Audit obsolete spec skip patterns") — Lightpanda fixes browser-side gaps independently of the workarounds we file PRs for, so `spec/spec_helper.rb` skip patterns can quietly become obsolete.
- **New capabilities** — CDP methods or browser features now available that could replace JS workarounds (Lightpanda).
- **Adoption candidates** — patterns/APIs Ferrum or Cuprite has that we don't, and that aren't Lightpanda-blocked. Each entry: peer file ↔ our file ↔ rationale ↔ rough effort (tiny/medium/large).
- **Already adopted** — patterns we mirror from a previous sync. Note when the peer has since diverged (do we re-mirror?).
- **Diverged on purpose** — places we deliberately differ because Lightpanda's constraints require it. Don't flag as adoption candidates again.
- **New risks** — open issues / regressions that could break our gem, or bugs the peers fixed that may also affect us.

## Step 4: Update the right rules file

- Lightpanda findings → `.claude/rules/lightpanda-io.md` (per `references/lightpanda.md` hygiene rules)
- Ferrum / Cuprite findings → `.claude/rules/ruby-cdp-peers.md` (per `references/{ferrum,cuprite}.md` hygiene rules)

Both rules files are **current-state references, not changelogs**. Edit affected sections inline; don't append a "Recently Merged Fixes" section. Closed issues / adopted patterns get deleted or moved, not archived.

**Verify before claiming.** Don't speculatively mark issues as fixed or methods as added without confirmation from the upstream issue/PR. For workaround-removal claims specifically, validation = specs green against `LIGHTPANDA_BIN` pointing at the locally-built `main` browser (see `references/lightpanda.md`).

## Step 5: Generate report

Use this exact template. Omit sections with no findings rather than leaving them empty.

```
## Upstream Sync Report — [date]

Targets run: [Lightpanda / Ferrum / Cuprite / subset]

### Lightpanda
**Broken**
- [ ] ...
**Workarounds to re-evaluate**
- [ ] ...
**New capabilities**
- [ ] ...
**New risks**
- [ ] ...

### Ferrum
**Adoption candidates**
- [ ] [tiny/medium/large] pattern → ferrum_file ↔ our_file ↔ why
**Diverged (revisit?)**
- [ ] ...
**New risks**
- [ ] ...

### Cuprite
**Adoption candidates**
- [ ] ...
**New risks**
- [ ] ...

### Rules files updated
- lightpanda-io.md: ...
- ruby-cdp-peers.md: ...

### Recommended next steps
1. [CRITICAL] ...
2. [HIGH] ...
3. [MEDIUM] ...

### Release Readiness (only if pre-release audit)
**Safe to release** / **Block release because** — with reasoning.
```

For pre-release audits specifically, the **Release Readiness** section is required. "Block release" should only fire on Lightpanda-side breakage (broken CDP methods, regressions affecting test passage). Ferrum/Cuprite adoption candidates never block a release — they're improvement opportunities, not bugs.

## Step 6: Suggest code changes (do not implement)

If a finding has a clear next code change (workaround removal, pattern adoption), describe the specific change in the report — file:line, what to change, why — but **do not implement it** unless the user explicitly asks. The skill is for reconnaissance and planning. Code edits belong in a follow-up turn where the user has agreed to the scope.

For each recommended workaround removal, also output the exact validation command for the user to run before any cleanup, and pause:

```
LIGHTPANDA_BIN=/Users/navid/code/browser/zig-out/bin/lightpanda bundle exec rake spec:incremental
```

Don't run it yourself — `spec:incremental` is long-running and the user decides when to validate.
