---
name: sync-upstream
description: Audit upstream repos that affect the capybara-lightpanda gem — the Lightpanda browser (lightpanda-io/browser), and the peer Ruby CDP gems Ferrum (rubycdp/ferrum) and Cuprite (rubycdp/cuprite). Use this skill whenever the user mentions syncing upstream, checking Lightpanda changes, auditing whether workarounds are still needed, preparing a gem release, verifying CDP methods exist upstream, investigating a specific CDP behavior (Page.loadEventFired, Network.clearBrowserCookies, XPathResult, modal handling), or asks what's new in Ferrum or Cuprite, what patterns we should adopt from them, whether a Ferrum error class or retry helper is worth mirroring, or whether Cuprite's driver does X better, or what is sitting unmerged in a peer gem's open PR queue. Also use when the user reports a BrowserError or CDP failure and wants to know if it's a Lightpanda limitation, when they want a pre-release peer-gem comparison, or when a shared Rails helper hits a Selenium-named method (browser.logs, execute_async_script, execute_cdp, switch_to) and the compat surface in selenium_compat.rb may have drifted. Do NOT use for implementing code changes, fixing the XPath polyfill JS, setting up CI, or refactoring driver methods — those are code tasks, not upstream investigations.
user_invocable: true
model: opus
effort: xhigh
---

# Sync Upstream

Audit upstream repos for changes that affect `capybara-lightpanda`. This skill is **reconnaissance and planning**, not implementation. Three sync targets, two different categories of finding:

| Target         | Repo                  | Role                     | Findings unlock                                                    |
| -------------- | --------------------- | ------------------------ | ------------------------------------------------------------------ |
| **Lightpanda** | lightpanda-io/browser | Backend (Zig browser)    | Workaround removal, new CDP capabilities, new risks                |
| **Ferrum**     | rubycdp/ferrum        | Peer Ruby CDP client     | Idiomatic adoption candidates (errors, retry, frame/runtime split) |
| **Cuprite**    | rubycdp/cuprite       | Peer Capybara CDP driver | Driver-layer adoption candidates (error mapping, JS polyfills)     |
| **Selenium**   | SeleniumHQ/selenium   | API we imitate (`rb/` only) | Drift in the Selenium-named compat surface. **On demand only** — see below |

Lightpanda defines what's _possible_. Ferrum and Cuprite define what's _idiomatic_ for a Ruby gem doing the same job. Different questions, different rules-file destinations, but a shared workflow worth running together — especially before a release.

Selenium is deliberately not in that set. It is not a peer — no CDP, no shared architecture — and it is checked for one narrow reason: `browser/selenium_compat.rb` answers four Selenium-named methods that shared Rails helpers call, and drift there breaks whole spec files. It is a **conformance** check, never an adoption one, and it is **excluded from "all three"/"sync upstream"**. Run it only on the triggers in `references/selenium.md`.

**Scan open PRs, not just merged commits.** For Ferrum and Cuprite this is mandatory every run and belongs *before* the commit scan. Both merge slowly — across the 2026-07-24 → 2026-07-25 window neither `main` moved at all, while their queues held 18 and 10 open PRs including a CDP thread-safety fix and an `Element#drop` implementation that contradicts one of our recorded divergences. A commits-only recon reports "nothing new" precisely when the queue holds the information. Per-target commands and grading rules live in each reference file.

## Step 0: Pick targets

Read the user's prompt and pick which targets to run:

- **All three** — phrases like "sync upstream", "pre-release audit", "check what's new", "general upstream check". This means Lightpanda + Ferrum + Cuprite; it does **not** pull in Selenium.
- **Lightpanda only** — Lightpanda-specific symptoms (CDP method behavior, browser bug, navigation issue, BrowserError, "is this a Lightpanda limitation?")
- **Ferrum only** — "what's new in Ferrum?", "did Ferrum add X?", "should we adopt their retry/error/frame pattern?"
- **Cuprite only** — "how does Cuprite handle Y?", "is our driver error mapping behind Cuprite?"
- **Selenium (add-on)** — only when `selenium_compat.rb` changed since the last sync, a real-app failure shows a shared helper calling a Selenium-named method, or the user asks. Never on its own initiative; see `references/selenium.md` for why a broad Selenium recon is nearly always empty.
- **Targeted investigation** — a single specific question (e.g., "has Page.loadEventFired been fixed?"). Run only the relevant target and skip unrelated checks. Still read the rules files for context, but go deep on the question.

Tell the user which targets you've picked and why before starting recon. They can redirect.

## Step 1: Gather current state

Read both rules files unconditionally — the answers to "what changed?" depend on knowing what we already know:

- `.claude/rules/lightpanda-io.md` — current understanding of the browser
- `.claude/rules/ruby-cdp-peers.md` — adopted/outstanding patterns from Ferrum and Cuprite

Also read the **previous run's state** if it exists:

- `.claude/skills/sync-upstream/state/last-sync.md` — open recommendations and watch items carried forward from the prior run.

The state file is how the skill remembers what was outstanding last time. Treat each entry as a question for this run:

- **Recommendations**: is the underlying state still the same (still pending), or has the user done it / has it been invalidated? Verify by checking the gem source (does the code change still need to happen?) or the upstream issue/PR. Don't trust the state file blindly — it's a snapshot from the prior run.
- **Watch items**: did the upstream PR/issue move? Check the linked PR/issue state. If merged → promote to a finding in this run's report. If closed without merge → drop it.

The state file is absent on first run; that's fine — just skip the carry-forward.

Then read the gem source surfaces relevant to the targets you picked:

- Lightpanda → `lib/capybara/lightpanda/browser.rb`, `node.rb`, `cookies.rb`, `frame.rb` (workarounds depend on browser quirks)
- Ferrum → `lib/capybara/lightpanda/node.rb`, `frame.rb`, `cookies.rb`, `errors.rb`, `utils/event.rb`, `client.rb` (the surfaces where Ferrum's design directly competes with ours)
- Cuprite → `lib/capybara/lightpanda/driver.rb`, `javascripts/index.js` (driver-layer error mapping + JS bundle)

## Step 2: Per target, follow its reference file

Each target has a per-target reference with concrete recon commands, source-tree pointers, and what to skip:

- `references/lightpanda.md` — CDP method existence checks, gh queries, lightpanda-io.md update rules
- `references/ferrum.md` — open-PR scan, Ferrum source tree, file-by-file comparisons against our gem, what's Chrome-specific to skip
- `references/cuprite.md` — open-PR scan, Cuprite driver/error/JS comparisons
- `references/selenium.md` — the four-method compat surface, and when NOT to run it

Run target recons in parallel where possible (each `gh api` or WebFetch is independent).

**A closed, unmerged PR is not proof of rejected work** — on any target. Verified 2026-07-25: our own lightpanda PR #3051 reported `CLOSED` with no merge, while the identical commit had landed under a maintainer's own PR number days later. Before recording "upstream rejected this", confirm against the tree (`git log --oneline -- <path>`), not against PR state alone.

## Step 3: Categorize findings

Use this taxonomy across all targets — every finding lands in exactly one bucket:

- **Broken** — methods we call that no longer exist upstream (Lightpanda only). Bugs in our gem. Flag with our gem-side file:line.
- **Workaround removal** — bugs we work around that are now fixed (Lightpanda). Always require validation before recommending removal: build the local browser from `main` (see `references/lightpanda.md` "Build local browser from main"), then prompt the user to run specs with `LIGHTPANDA_BIN=/Users/navid/code/browser/zig-out/bin/lightpanda`. Don't run specs unprompted. After workaround validation, also run the **skip-pattern audit** (`AUDIT_SKIPS=1`, see `references/lightpanda.md` "Audit obsolete spec skip patterns") — Lightpanda fixes browser-side gaps independently of the workarounds we file PRs for, so `spec/spec_helper.rb` skip patterns can quietly become obsolete.
- **New capabilities** — CDP methods or browser features now available that could replace JS workarounds (Lightpanda).
- **Adoption candidates** — patterns/APIs Ferrum or Cuprite has that we don't, and that aren't Lightpanda-blocked. Each entry: peer file ↔ our file ↔ rationale ↔ rough effort (tiny/medium/large).
- **Already adopted** — patterns we mirror from a previous sync. Note when the peer has since diverged (do we re-mirror?).
- **Diverged on purpose** — places we deliberately differ because Lightpanda's constraints require it. Don't flag as adoption candidates again.
- **New risks** — open issues / regressions that could break our gem, or bugs the peers fixed that may also affect us.

Open PRs feed the last three buckets, never the first two, because nothing has landed yet:

- A peer PR describing a **bug in a design we share** is a **New risk** and a cheap audit — check whether we have the same defect, then record the verdict (including "immune, and here's the line that makes us immune") so the next sync doesn't repeat the work.
- A peer PR **building something we listed as Diverged or Outstanding** invalidates that entry's premise. Don't rewrite the rules file yet — the claim about their `main` is still true. Log it as a watch item with what it would change.
- Never promote an unmerged PR into an "Adopted" or "Diverged" edit. Rules files describe shipped code.

## Step 4: Prune-and-densify pass

Both rules files are loaded into Claude's context on every conversation in this project (`CLAUDE.md` includes them). They cost ~10K tokens, every turn — stale or verbose entries pay that cost forever. This pass runs BEFORE Step 5 (apply new findings) so the prune is a separate, auditable diff from the new-content edits.

For each entry in `lightpanda-io.md` and `ruby-cdp-peers.md`, ask three questions:

1. **Still current?** Re-verify the underlying claim:
   - "Open Issues That Affect This Gem" rows → `gh issue view <N> --repo lightpanda-io/browser --json state` for every issue listed; if `CLOSED`, delete the row.
   - "CDP Methods Used by This Gem" entries → grep the gem source (`git grep -nE "command\(.Network\.getCookies"` etc.); if no gem caller, move to the available-but-unused list or drop.
   - PR references (`PR #NNNN`) embedded in rules text → `gh pr view <N> --json state,mergedAt`. If merged > 30 days ago AND the gem floor in `process.rb` covers it AND no gem-side TODO mentions the PR number, the inline `(PR #N, …)` parenthetical can be dropped — the floor comment in `process.rb` is the authoritative record.
   - "Outstanding adoption candidates" (ruby-cdp-peers.md) → grep the gem for the named pattern (e.g. `git grep -n "wait_for_stop_moving" lib/`); if it exists, move "Outstanding" → "Adopted".
   - "Adopted" entries → verify the cited gem file:line still exists (`git grep -n "<symbol>" lib/`). If the symbol moved, update the pointer; if the symbol was deleted, drop the entry.

2. **Still load-bearing?** Can a future reader who has the gem source open figure this out without the entry?
   - Yes → delete. The code is the source of truth.
   - No (subtle invariant, hidden constraint, past-incident reason) → keep, but compress.

3. **Densable?** Hold each surviving entry against these targets:
   - "Open Issues" table row: ≤ 1 line, columns `Issue | Impact | Description`.
   - "CDP Methods Used" entries: bare method name, no prose unless the gem does something non-obvious with it.
   - Adopted / Outstanding / Diverged entry: `peer_file ↔ our_file ↔ one-clause why` — usually one line, two at most.
   - "Limitation" sections: lead with the one-line claim; supporting prose only when a reader would otherwise re-discover a bug we already paid for.
   - If an entry has multiple paragraphs of historical narrative ("originally we did X, then PR #N landed, then we tried Y, …"), keep the current behavior in one sentence and delete the history. `git log` is the changelog.

Mechanical rules:

- **Delete, don't archive.** No "Recently Merged Fixes", no "Historical Notes", no commented-out lines. If you need the old text, `git log -p` has it.
- **Don't preserve numbering for missing entries.** If a list had A1–A9 and A4 becomes obsolete, renumber (or convert to bullets). The rules files aren't the upstream-wishlist's stable-cross-ref doc.
- **One pass per file per sync run.** Don't loop — diminishing returns and risk of over-pruning.
- **Surface what you cut in the report** (Step 6's "Prune pass" section). The user sees the entries you dropped and can object before the diff lands.

Skip the prune pass entirely on a **targeted investigation** (Step 0's last bucket) — single-question runs shouldn't drag a full audit along.

## Step 5: Update the right rules file

- Lightpanda findings → `.claude/rules/lightpanda-io.md` (per `references/lightpanda.md` hygiene rules)
- Ferrum / Cuprite findings → `.claude/rules/ruby-cdp-peers.md` (per `references/{ferrum,cuprite}.md` hygiene rules)

Both rules files are **current-state references, not changelogs**. Edit affected sections inline; don't append a "Recently Merged Fixes" section. Closed issues / adopted patterns get deleted or moved, not archived.

**Verify before claiming.** Don't speculatively mark issues as fixed or methods as added without confirmation from the upstream issue/PR. For workaround-removal claims specifically, validation = specs green against `LIGHTPANDA_BIN` pointing at the locally-built `main` browser (see `references/lightpanda.md`).

## Step 6: Generate report

Use this exact template. Omit sections with no findings rather than leaving them empty.

```
## Upstream Sync Report — [date]

Targets run: [Lightpanda / Ferrum / Cuprite / subset]

### Carry-forward from previous run
(Only when state/last-sync.md existed at Step 1.)
- ✅ Done: [slug] — [one-line: where the gem code now lives, or which upstream PR closed it]
- ⏳ Still open: [slug] — [reason it's still pending]
- ❌ Stale: [slug] — [why it's no longer relevant]

### Prune pass
(Omit only on targeted investigations.)
- lightpanda-io.md: deleted N entries (issue #X closed, PR #Y embedded ref removed); compressed M entries from prose to one-liner.
- ruby-cdp-peers.md: moved K entries from Outstanding to Adopted; compressed J entries.
- Total token delta: roughly −N tokens from CLAUDE.md context.

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
**Open PRs (not landed — watch items)**
- [ ] #N title — what it would change for us; if it names a bug in shared design, the audit verdict on our side
**Diverged (revisit?)**
- [ ] ...
**New risks**
- [ ] ...

### Cuprite
**Adoption candidates**
- [ ] ...
**Open PRs (not landed — watch items)**
- [ ] ...
**New risks**
- [ ] ...

### Selenium
(Only when the compat-surface triggers fired. State "skipped — no trigger" otherwise.)
**Compat drift**
- [ ] method ↔ selenium file ↔ what changed shape

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

## Step 7: Suggest code changes (do not implement)

If a finding has a clear next code change (workaround removal, pattern adoption), describe the specific change in the report — file:line, what to change, why — but **do not implement it** unless the user explicitly asks. The skill is for reconnaissance and planning. Code edits belong in a follow-up turn where the user has agreed to the scope.

For each recommended workaround removal, also output the exact validation command for the user to run before any cleanup, and pause:

```
LIGHTPANDA_BIN=/Users/navid/code/browser/zig-out/bin/lightpanda bundle exec rake spec:incremental
```

Don't run it yourself — `spec:incremental` is long-running and the user decides when to validate.

## Step 8: Persist state for the next run

After the report, **overwrite** `.claude/skills/sync-upstream/state/last-sync.md` with the report's open items so the next run can pick up where this one left off. Use this exact format:

```markdown
# Sync Upstream — Last-Run State

Last run: YYYY-MM-DD
Last run targets: [Lightpanda / Ferrum / Cuprite / subset]

## Open recommendations

Each entry stays here until the gem code change happens, the upstream PR/issue resolves, or the entry becomes stale. Reconcile each one at Step 1 of the next run.

- **[slug]** [PRIORITY] — `path/file.rb:line` — What to do, in one sentence. Why it's outstanding (PR #N merged date, or pattern not yet adopted). Effort (tiny/medium/large).

## Watch items

Upstream PRs / issues to recheck next sync. Promote to findings if they move.

- **lightpanda-io/browser#N** — Title. State as of YYYY-MM-DD: OPEN / MERGED / CLOSED. Why we care.
```

Rules:

- **One entry per slug** — slugs are short kebab-case identifiers (e.g. `htmldialog-polyfill-cleanup`, `pr-2431-frame-context-fix`). Stable across runs so reconciliation is trivial.
- **No duplicates from the rules files.** Anything fully described in `lightpanda-io.md` (open issues table) or `ruby-cdp-peers.md` (outstanding adoption candidates) doesn't need to be in the state file — the rules files are the source of truth for those. State file is specifically for _follow-up actions_ (cleanup, validation, gem-side code changes) and _watch items_ (upstream PRs we expect to land soon).
- **Always overwrite the whole file.** Don't append — Step 6's report is the authoritative source for what's still open after this run.
- **If there's nothing open**, write the headers + an explicit `(none)` under each section so future runs know the file is current, not abandoned.

The file `state/last-sync.md` is gitignored — local-only sync bookkeeping that the next run reads. The Write tool creates the parent directory as needed on a fresh clone, so no `.gitkeep` is required. It's a single Markdown file, not a JSON store — human-editable if the user wants to drop a stale item between runs.
