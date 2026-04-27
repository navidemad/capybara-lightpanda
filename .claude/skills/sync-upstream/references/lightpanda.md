# Sync target: Lightpanda browser

Repo: https://github.com/lightpanda-io/browser
Role: **backend** — defines what's *possible*. Browser bugs, CDP availability, navigation behavior. Findings here unlock workaround removal or surface new risks.

Rules destination: `.claude/rules/lightpanda-io.md`

## What to read before reconning

- `.claude/rules/lightpanda-io.md` — current understanding (CDP methods used, known bugs, tracked issues)
- `lib/capybara/lightpanda/browser.rb`, `node.rb`, `cookies.rb`, `frame.rb` — implementations whose workarounds depend on Lightpanda quirks

## Recon commands

### Recent commits to CDP-relevant areas

Project the first line of each commit message into a field _before_ filtering — the multi-line `.commit.message` form has tripped up `select(... | test(...))` in practice. Filter on the projected single-line `msg`:

```bash
gh api 'repos/lightpanda-io/browser/commits?per_page=40' \
  --jq '.[] | {sha: .sha[0:8], date: .commit.author.date[0:10], msg: (.commit.message | split("\n")[0])} | select((.msg | ascii_downcase) | test("cdp|runtime|page|network|dom|target|cookie|xpath|navigate|dialog|frame|input"))'
```

### Tracked issues — are any closed?

For each issue listed in the "Upstream Open Issues That Affect This Gem" table in `lightpanda-io.md`:

```bash
gh issue view <NUMBER> --repo lightpanda-io/browser --json state,title,closedAt
```

### PRs we've authored upstream (`navidemad`)

The user files patches to Lightpanda when they hit gem-side workarounds that need root-cause fixes (e.g. PR #2244 for the `#id` selector engine bug that drives our `querySelector` rewriter). The status of those PRs directly determines whether we can simplify our gem, so they need to be checked every sync:

```bash
gh pr list --repo lightpanda-io/browser --author navidemad --state all --limit 20 \
  --json number,title,state,createdAt,mergedAt,url
```

For each PR returned, classify by state:

- **OPEN** — note PR number, title, and how long it's been open. If `lightpanda-io.md` references the PR (e.g. "PR #2244 OPEN, … When merged: remove …"), confirm the note still matches reality.
- **MERGED** — high-priority finding. The gem-side workaround the PR was meant to obsolete can probably be removed. Add an entry in the report's **Workarounds to re-evaluate** bucket with: PR number, what gem code it unblocks, what test or spec validates the removal. Validation runs against a locally-built `main` binary (see "Build local browser from main" below) — don't wait for the nightly the gem currently consumes, since `main` HEAD usually leads nightly by hours or days. When recommending removal, also call out which `MINIMUM_NIGHTLY_BUILD` the user must bump in `lib/capybara/lightpanda/process.rb` before merging the gem-side cleanup so end-users (who don't build locally) aren't broken.
- **CLOSED (not merged)** — investigate. Either upstream rejected our approach, or the PR was superseded. Update `lightpanda-io.md` to drop any reference that assumed it would land, and check whether the underlying bug needs a new gem-side workaround.

When `lightpanda-io.md` mentions a PR by number (search for `PR #` in that file), keep its state line in sync with what `gh pr view` reports. Stale "PR #X OPEN" notes against an actually-merged PR are exactly the kind of speculative claim Step 4 of SKILL.md tells us to avoid.

### New issues that touch our domains

```bash
gh api "repos/lightpanda-io/browser/issues?state=open&per_page=50&sort=created&direction=desc" \
  --jq '.[] | select(.title | test("(?i)cdp|cookie|navigate|xpath|runtime|evaluate|dom|network|page|target|frame|dialog|websocket")) | {number: .number, title: .title, created: .created_at[0:10]}'
```

### Verify our CDP methods still exist upstream

This is the highest-value check — Lightpanda is in flux and an endpoint we depend on can be removed/renamed without warning. Fetch each domain file via `gh api` or WebFetch on raw GitHub URLs and grep the dispatch enum for every method in `lightpanda-io.md`'s "CDP Methods Used by This Gem" list.

Files and methods to verify:
- `src/cdp/domains/page.zig` — `Page.navigate`, `Page.reload`, `Page.enable`, `Page.handleJavaScriptDialog`, `Page.loadEventFired` (event), `Page.captureScreenshot`, `Page.getLayoutMetrics`, `Page.addScriptToEvaluateOnNewDocument`
- `src/cdp/domains/runtime.zig` — `Runtime.evaluate`, `Runtime.callFunctionOn`, `Runtime.getProperties`, `Runtime.releaseObject`
- `src/cdp/domains/network.zig` — `Network.enable`, `Network.disable`, `Network.getCookies` (with `urls`), `Network.setCookie`, `Network.deleteCookies`, `Network.clearBrowserCookies`
- `src/cdp/domains/dom.zig` — `DOM.getDocument`, `DOM.querySelector`, `DOM.querySelectorAll`
- `src/cdp/domains/target.zig` — `Target.createTarget`, `Target.attachToTarget`

Look for the method name in the `processMessage` dispatch enum. If absent, the gem is calling a non-existent endpoint — flag with the gem-side file:line that calls it.

Also scan for new methods that could simplify our code (e.g., `Page.createIsolatedWorld` regressions, new `Input.*`, new `Network.*`).

### Releases

```bash
gh release list --repo lightpanda-io/browser --limit 5
gh release view nightly --repo lightpanda-io/browser --json publishedAt,assets
```

The nightly build number (e.g. `5816` in `1.0.0-nightly.5816+a578f4d6`) is the floor for `MINIMUM_NIGHTLY_BUILD` recommendations. Get it from one of the assets' filename or the published timestamp — don't guess.

## Build local browser from main (only when needed)

**When to run this**: only if Step 3 categorization produced at least one entry in the **Workaround removal** bucket (i.e. a previously-broken upstream behavior was fixed, and the gem still has a workaround). Otherwise skip — the build is slow and unnecessary for pure recon.

When required, build before validating any workaround-removal recommendation. `main` HEAD usually leads nightly by hours/days, so this is the only way to validate same-day.

**Don't edit anything in `/Users/navid/code/browser`** — that's the user's upstream contribution worktree. Read-only access (git pull, build) is fine; never edit, branch, or commit there from this skill.

If the worktree has uncommitted changes or is on a non-`main` branch, **stop and ask the user** — they may have an in-progress upstream contribution. Don't auto-stash or auto-checkout.

```bash
cd /Users/navid/code/browser
git status --porcelain  # must be empty before proceeding
git rev-parse --abbrev-ref HEAD  # must be 'main' before proceeding
git fetch origin && git pull --ff-only origin main
git rev-parse HEAD  # record this sha — goes into the report
```

**Skip the build if up to date.** If `zig-out/bin/lightpanda` exists and its mtime is newer than the HEAD commit's author date, the binary already matches `main` — reuse it. Otherwise:

```bash
LP_V8=$(ls -t /Users/navid/code/browser/.lp-cache/prebuilt-v8/*.a | head -1)
echo "Using V8 archive: $LP_V8"
mise exec -- zig build -Doptimize=ReleaseFast -Dprebuilt_v8_path="$LP_V8"
```

The V8 archive name encodes the V8 version (e.g. `libc_v8_14.0.365.4_macos_aarch64.a`); pick the most recent file rather than hardcoding the version, since it changes when the upstream `build.zig` bumps the V8 prebuilt.

After the build, **do not run specs unprompted**. Print a one-line handoff for the user, then pause:

```
Built lightpanda from main (HEAD <sha>, V8 <archive name>).
To validate the workaround-removal recommendations, run:

  LIGHTPANDA_BIN=/Users/navid/code/browser/zig-out/bin/lightpanda bundle exec rake spec:incremental

(spec:incremental can take 10+ min — your call.)
```

Record the HEAD sha in the report's **Workarounds to re-evaluate** entries so the validation context is reproducible.

## Audit obsolete spec skip patterns

After workaround removal, also audit `spec/spec_helper.rb`'s skip patterns — Lightpanda fixes browser-side gaps independently of the workarounds we file PRs for, so patterns can quietly become obsolete or over-broad without anyone noticing.

The gem has a built-in audit mode: setting `AUDIT_SKIPS=1` flips every `metadata[:skip] = "..."` to `metadata[:skip_audit] = true`, and `filter_run_when_matching(:skip_audit)` narrows the run to *only* the previously-skipped specs. So a single rspec invocation tells you which patterns can be dropped or narrowed:

```bash
AUDIT_SKIPS=1 LIGHTPANDA_PATH=/Users/navid/code/browser/zig-out/bin/lightpanda \
  bundle exec rspec spec/features/session_spec.rb \
  --format json --out /tmp/audit.json
```

Then extract the passes:

```bash
ruby -rjson -e '
data = JSON.parse(File.read("/tmp/audit.json"))
passed = data["examples"].select { |e| e["status"] == "passed" }
puts "Total: #{data["examples"].size}, passed: #{passed.size}, failed: #{data["examples"].count { |e| e["status"] == "failed" }}"
passed.each { |e| puts "  #{e["full_description"]}" }
'
```

Each passing example points at a skip pattern that's either fully obsolete (drop it) or too broad (narrow it). When narrowing, prefer patterns that match the actual failing description rather than the whole describe-block — e.g. `/#accept_confirm should accept the confirm/` instead of the blanket `/#accept_confirm/`.

After narrowing, re-run the full session spec without `AUDIT_SKIPS` to confirm the un-skipped specs pass deterministically (no flakes), and that the pending count dropped by the expected amount. Add the audit findings to the **Workarounds to re-evaluate** bucket in the report.

## Categorize findings

- **Broken**: methods we call that no longer exist upstream → bugs in our gem.
- **Workaround removal**: bugs we work around that have been fixed → simplification opportunities. Always validate before removing (run `bundle exec rake spec` against current nightly).
- **New capabilities**: CDP methods now available that could replace JS workarounds.
- **New risks**: open issues / regressions that could break our gem.

## Updating `lightpanda-io.md`

The doc is a **current-state reference, not a git log**. Keep it focused on what affects gem behavior today.

- Closed upstream issues → **delete** their row from the "Upstream Open Issues That Affect This Gem" table. No "Closed Issues" section.
- New open issues → add only if they touch CDP methods we use, navigation, cookies, JS context, or crashes. Skip CLI-only, MCP-only, build/CI, and pure-internal-refactor issues.
- Fixed limitations → update the relevant section in place; don't archive the old text.
- Method support changes → move methods between Used / NOT Available / Partially Implemented / Recently Implemented / Available-but-unused.
- Methods we call that don't exist upstream → flag them in "CDP Methods Used by This Gem" with a note.

**Do not add a chronological "Recently Merged Fixes" changelog.** When a merged PR changes gem-relevant behavior, edit the affected section inline and add the PR number there. PRs that don't change gem behavior must not be recorded.

**Verify before claiming.** Don't speculatively mark issues as fixed without confirmation from the upstream issue/PR.
