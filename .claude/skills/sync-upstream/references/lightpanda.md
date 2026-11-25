# Sync target: Lightpanda browser

Repo: https://github.com/lightpanda-io/browser
Role: **backend** — defines what's *possible*. Browser bugs, CDP availability, navigation behavior. Findings here unlock workaround removal or surface new risks.

Rules destination: `.claude/rules/lightpanda-io.md`

## What to read before reconning

- `.claude/rules/lightpanda-io.md` — current understanding (CDP methods used, known bugs, tracked issues)
- `lib/capybara/lightpanda/browser.rb` (frames via `Browser#frame_stack`) and its modules under `browser/`, `node.rb`, `cookies.rb` — implementations whose workarounds depend on Lightpanda quirks

## Recon commands

### Recent commits to CDP-relevant areas

Project the first line of each commit message into a field _before_ filtering — the multi-line `.commit.message` form has tripped up `select(... | test(...))` in practice. Filter on the projected single-line `msg`:

```bash
gh api 'repos/lightpanda-io/browser/commits?per_page=40' \
  --jq '.[] | {sha: .sha[0:8], date: .commit.author.date[0:10], msg: (.commit.message | split("\n")[0])} | select((.msg | ascii_downcase) | test("cdp|runtime|page|network|dom|target|cookie|xpath|navigate|dialog|frame|input"))'
```

**When the window is long (verified 2026-08-18: 115 merges in 23 days), the 40-commit page above misses most of it.** Enumerate by PR instead, and number every merge from the local checkout so each finding carries the build it landed in:

```bash
gh pr list --repo lightpanda-io/browser --state merged --limit 200 \
  --search "merged:>=<last-sync-date>" --json number,title,mergedAt,author \
  --jq 'sort_by(.number) | .[] | "\(.number)\t\(.mergedAt[0:10])\t\(.author.login)\t\(.title)"'

B=/Users/navid/code/upstream/browser
git -C $B fetch -q origin --tags
git -C $B log --first-parent --format='%h %s' <last-snapshot-sha>..origin/main | \
  while read -r sha rest; do echo "$(git -C $B rev-list --count $sha) $sha $rest"; done
```

Use `git -C` (or a `( cd … )` subshell) for every command in the upstream checkout: a bare `cd` outside the session's folders resets the Bash tool's working directory, and the next command silently runs in the primary checkout.

`gh pr view` bodies are often empty on this repo (#3162, #3090, #3183…) — read `gh pr diff` or the local `git diff <parent> <merge> -- <file>` for those. And `Runtime.executionContextCreated` is emitted by the V8 inspector (`inspector.contextCreated`), so a literal grep of the zig tree finds nothing; that is not a missing event.

### Tracked issues — are any closed?

For each issue listed in the "Upstream open issues that affect this gem" table in `lightpanda-io.md`:

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

When `lightpanda-io.md` mentions a PR by number (search for `PR #` in that file), keep its state line in sync with what `gh pr view` reports. Stale "PR #X OPEN" notes against an actually-merged PR are exactly the kind of speculative claim Step 5 of SKILL.md tells us to avoid — and the prune pass (Step 4) is where those notes should be cleaned up.

### New issues that touch our domains

```bash
gh api "repos/lightpanda-io/browser/issues?state=open&per_page=50&sort=created&direction=desc" \
  --jq '.[] | select(.title | test("(?i)cdp|cookie|navigate|xpath|runtime|evaluate|dom|network|page|target|frame|dialog|websocket")) | {number: .number, title: .title, created: .created_at[0:10]}'
```

### Verify our CDP methods still exist upstream

Start from the diff since the last audited SHA (Step 8 baseline). Most runs end here:

```bash
git -C $B diff --stat <last-audited-sha> origin/main -- src/server/cdp
git -C $B diff <last-audited-sha> origin/main -- src/server/cdp/domains | grep -E '^-' | head   # removed dispatch lines?
```

An empty or unrelated diff (screenshot mode, AXNode) means the 36 commands and the emitted events are unchanged: say so with the SHA. Fall back to the per-file check below only when a domain file we call into changed.

This is the highest-value check — Lightpanda is in flux and an endpoint we depend on can be removed/renamed without warning. Fetch each domain file via `gh api` or WebFetch on raw GitHub URLs and grep the dispatch enum for every method in `lightpanda-io.md`'s "CDP commands used by the gem" table.

Files and methods to verify:
- `src/server/cdp/domains/page.zig` — `Page.navigate`, `Page.reload`, `Page.enable`, `Page.handleJavaScriptDialog`, `Page.loadEventFired` (event), `Page.captureScreenshot`, `Page.getLayoutMetrics`, `Page.addScriptToEvaluateOnNewDocument`
- `src/server/cdp/domains/runtime.zig` — `Runtime.evaluate`, `Runtime.callFunctionOn`, `Runtime.getProperties`, `Runtime.releaseObject`
- `src/server/cdp/domains/network.zig` — `Network.enable`, `Network.disable`, `Network.getCookies` (with `urls`), `Network.setCookie`, `Network.deleteCookies`, `Network.clearBrowserCookies`
- `src/server/cdp/domains/dom.zig` — `DOM.getDocument`, `DOM.querySelector`, `DOM.querySelectorAll`
- `src/server/cdp/domains/target.zig` — `Target.createTarget`, `Target.attachToTarget`

Look for the method name in the `processMessage` dispatch enum. If absent, the gem is calling a non-existent endpoint — flag with the gem-side file:line that calls it.

Also scan for new methods that could simplify our code (e.g., `Page.createIsolatedWorld` regressions, new `Input.*`, new `Network.*`).

### Releases

```bash
gh release list --repo lightpanda-io/browser --limit 5
gh api repos/lightpanda-io/browser/releases/tags/nightly \
  --jq '.assets[] | select(.name=="lightpanda-aarch64-macos") | .updated_at'
```

The nightly build number (e.g. `12421` in `1.1.0-nightly.12421+8bc75b49b`) is the floor for `MINIMUM_NIGHTLY_BUILD` recommendations, and neither GitHub field gives it (verified 2026-11-23): the nightly release's `publishedAt` is the release object's creation date (2024-07-16), the local `nightly` tag points at build 856, and asset names carry no build. Read it from the binary:

```bash
S=<scratchpad>/nightly-<date>; mkdir -p $S
gh release download nightly --repo lightpanda-io/browser --pattern 'lightpanda-aarch64-macos' --dir $S --clobber
chmod +x $S/lightpanda-aarch64-macos && $S/lightpanda-aarch64-macos version
```

A release candidate is a normal tag: `git -C $B rev-list --count <tag>` gives its build, and `git -C $B merge-base --is-ancestor <merge-sha> <tag>` says whether a PR is in it. An RC's macOS asset can be missing for a while (1.0.6-rc2, 2026-11-25): list the assets first and fall back to the previous RC.

## Build local browser from main (only when needed)

**When to run this**: only if Step 3 categorization produced at least one entry in the **Workaround removal** bucket (i.e. a previously-broken upstream behavior was fixed, and the gem still has a workaround). Otherwise skip — the build is slow and unnecessary for pure recon.

When required, build before validating any workaround-removal recommendation. `main` HEAD usually leads nightly by hours/days, so this is the only way to validate same-day.

**Don't edit anything in `/Users/navid/code/upstream/browser`** — that's the user's upstream contribution worktree. Read-only access (git pull, build) is fine; never edit, branch, or commit there from this skill.

If the worktree has uncommitted changes or is on a non-`main` branch, **stop and ask the user** — they may have an in-progress upstream contribution. Don't auto-stash or auto-checkout.

```bash
B=/Users/navid/code/upstream/browser
git -C $B status --porcelain  # must be empty before proceeding
git -C $B rev-parse --abbrev-ref HEAD  # must be 'main' before proceeding
git -C $B fetch origin && git -C $B pull --ff-only origin main
git -C $B rev-parse HEAD  # record this sha — goes into the report
```

**Skip the build when a release is tagged at `main` HEAD** (1.0.1 was, 2026-10-15): validate against the published artifact instead — `gh release download <tag> --repo lightpanda-io/browser --pattern 'lightpanda-aarch64-macos'` into the scratchpad. It is exactly what release-channel users run, and a release binary prints a bare semver, so `browser.nightly_build` is `nil`: any test gated on it takes its below-the-build path there, which is the point of validating on it before a floor bump.

**Skip the build if up to date.** If `zig-out/bin/lightpanda` exists and its mtime is newer than the HEAD commit's author date, the binary already matches `main` — reuse it. Otherwise:

Run `make -C /Users/navid/code/upstream/browser download-v8` first, every time: its `test -f` guard makes it a no-op when the pinned archive is cached, and the zig-v8 pin moves between syncs (v0.6.2 → v0.6.3 on 2026-11-23).

```bash
SHIM=<scratchpad>/xcrun-shim; mkdir -p "$SHIM"
printf '%s\n' '#!/bin/sh' \
  'for a in "$@"; do [ "$a" = "--show-sdk-path" ] && { echo /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk; exit 0; }; done' \
  'exec /usr/bin/xcrun "$@"' > "$SHIM/xcrun"; chmod +x "$SHIM/xcrun"
(cd /Users/navid/code/upstream/browser && PATH="$SHIM:$PATH" mise exec -- zig build -Doptimize=ReleaseFast)   # prints "Using prebuilt V8: …" then the version
```

No `-Dprebuilt_v8_path`: plain `zig build` picks the archive for the pinned zig-v8 tag from `.lp-cache/prebuilt-v8/<tag>/` (verified 2026-11-10, 11977). The old `ls .lp-cache/prebuilt-v8/*.a` glob finds nothing since the archives moved into tag directories, so it built with an empty path and failed. The shim works around the macOS 27 SDK breaking Zig's linker (see `~/.claude/notes/zig.md`). If the build log mentions `gclient`/`depot_tools`, the pinned tag's archive is missing and a V8 source build has started: stop it and run `make download-v8` first.

After the build, **do not run specs unprompted**. Print a one-line handoff for the user, then pause:

```
Built lightpanda from main (HEAD <sha>, V8 <archive name>).
To validate the workaround-removal recommendations, run:

  LIGHTPANDA_BIN=/Users/navid/code/upstream/browser/zig-out/bin/lightpanda CLEAR=1 bundle exec rake test:incremental
  LIGHTPANDA_BIN=/Users/navid/code/upstream/browser/zig-out/bin/lightpanda bundle exec rake spec:shared:parallel

(the full run takes 10+ min — your call.)
```

Record the HEAD sha in the report's **Workarounds to re-evaluate** entries so the validation context is reproducible.

## Audit obsolete spec skip patterns

After workaround removal, also audit `spec/spec_helper.rb`'s skip patterns — Lightpanda fixes browser-side gaps independently of the workarounds we file PRs for, so patterns can quietly become obsolete or over-broad without anyone noticing.

**`AUDIT_SKIPS` covers only half the skips — verified 2026-07-26, don't re-derive.** It audits `browser_limitation_patterns` and nothing else. The `capybara_skip:` feature list in `session_spec.rb` is enforced by *Capybara itself*: `Capybara::SpecHelper.configure` sets `config.filter_run_excluding requires: method(:filter).to_proc`, which **excludes** those examples from the run. Excluded examples never execute, so tagging them `:skip_audit` cannot pull them back in — an inclusion filter does not override an exclusion filter. (The `metadata[:skip] = "Lightpanda doesn't support: …"` branch in our `spec_helper.rb` is dead code shadowed by that filter; harmless, but don't read it as the mechanism.) To audit a *feature*, re-run the battery with a reduced `capybara_skip` instead — a throwaway spec file calling `run_specs(..., capybara_skip: [])` works, then diff its example list against the normal run's to isolate the gated ones. That is how the 2026-07-26 run found `html5_drag` was hiding 5 passing `Element#drop` specs.

The gem's audit mode: setting `AUDIT_SKIPS=1` flips every `metadata[:skip] = "..."` in `browser_limitation_patterns` to `metadata[:skip_audit] = true`, and `filter_run_when_matching(:skip_audit)` narrows the run to *only* those specs. So a single rspec invocation tells you which patterns can be dropped or narrowed:

```bash
AUDIT_SKIPS=1 LIGHTPANDA_BIN=/Users/navid/code/upstream/browser/zig-out/bin/lightpanda \
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

- Closed upstream issues → **delete** their row from the "Upstream open issues that affect this gem" table. No "Closed Issues" section.
- New open issues → add only if they touch CDP methods we use, navigation, cookies, JS context, or crashes. Skip CLI-only, MCP-only, build/CI, and pure-internal-refactor issues.
- Fixed limitations → update the relevant section in place; don't archive the old text.
- Method support changes → move methods between "CDP commands used by the gem" and "Available CDP methods (not yet used by this gem)"; note partial or stub support inline.
- Methods we call that don't exist upstream → flag them in "CDP commands used by the gem" with a note.

**Do not add a chronological "Recently Merged Fixes" changelog.** When a merged PR changes gem-relevant behavior, edit the affected section inline and add the PR number there. PRs that don't change gem behavior must not be recorded.

**Verify before claiming.** Don't speculatively mark issues as fixed without confirmation from the upstream issue/PR.

## Validate a published binary (when the user asks)

Before a pin bump, or when a nightly or RC carries behavior the rules file records as unvalidated. Download the binary as in "Releases", then from the sync worktree:

```bash
BIN=<scratchpad>/<dir>/lightpanda-aarch64-macos
LIGHTPANDA_BIN=$BIN bundle exec rake test:all
LIGHTPANDA_BIN=$BIN bundle exec rake spec:shared:parallel
AUDIT_SKIPS=1 LIGHTPANDA_BIN=$BIN bundle exec rspec spec/features/session_spec.rb --format json --out <scratchpad>/audit.json
```

Run them in one background command (`run_in_background`), then extract the audit passes with the script under "Audit obsolete spec skip patterns". The audit run exits 1 by design (every example it selects is a known failure); only the passed count matters. Record the result in the rules file's "Behavior above the floor" header: build, date, `test:all` run count, shared specs green, skip audit N/43.

## Probe a behavior

To settle what a change does on the pinned release (an emulation command's real effect, how Enter edits a field), drive a throwaway page instead of reasoning from source. A script in the scratchpad, run from the worktree with `bundle exec ruby -Ilib <script>`:

```ruby
require "capybara"
require "capybara-lightpanda"
html = "<form onsubmit='event.preventDefault(); document.body.dataset.submitted = 1'><input id=i></form>"
app = ->(_env) { [200, { "content-type" => "text/html" }, [html]] }
Capybara.server = :puma, { Silent: true }   # :webrick is not installed
session = Capybara::Session.new(:lightpanda, app)
session.visit("/")
session.find("#i").send_keys("a\n")
p session.evaluate_script("document.body.dataset.submitted")
session.driver.quit
```

For raw CDP, `Capybara::Lightpanda::Browser.new(timeout: 10)` takes a Hash of options (not an `Options` object), then `start`, `go_to`, `page_command(...)`, `quit`. Put the probe result and the version it ran on in the finding ("verified 2026-11-25 on 1.0.5").

