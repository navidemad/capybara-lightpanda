---
name: lightpanda-upstream-pr
description: Drive a single upstream Lightpanda contribution end-to-end — pick one item from this skill's references/upstream-wishlist.md (Section A bug or Section B missing method), verify it's still broken on current nightly, locate the Zig code in /Users/navid/code/browser, implement the fix with a Zig test, build a self-contained reproducer (Lightpanda + CDP only — never Ruby/Capybara), file a GitHub issue first with mermaid sequence diagrams of broken-vs-expected flow and the runnable repro script, then open a linked PR (`Closes #<issue>`) with mermaid flowcharts of the old-vs-new code path. Always issue first, then PR — never PR alone. Audience for issue/PR is a Zig browser engineer who is NOT familiar with Ruby, Rails, Capybara, RSpec, or Turbo — never use framework names; describe behavior in CDP/HTML-spec terms. Use this skill when the user says "fix A1 upstream", "tackle the next Lightpanda bug", "open a PR for the cookie clearing bug", "implement A14 upstream", "file an issue and PR for the requestSubmit gap", "send the form.submit fix to lightpanda-io". Do NOT use for gem-side code changes (those edit /Users/navid/code/capybara-lightpanda — different repo) or for general upstream reconnaissance (that's the sync-upstream skill). Section C items (no rendering, no compositor) are out of scope and the skill should refuse them.
user_invocable: true
model: opus
effort: max
---

# Lightpanda Upstream PR

Drive **one** Section A or Section B item from `references/upstream-wishlist.md` to a merged-quality upstream PR. This skill is **end-to-end implementation**, not reconnaissance — you write Zig, run Zig tests, push a branch, and open the PR.

Two repos are in play. Keep them straight:

| Path | Role | What this skill edits |
|---|---|---|
| `/Users/navid/code/capybara-lightpanda` | The gem (Ruby). Source of the wishlist. | NOTHING — only reads `references/upstream-wishlist.md` (this skill's own reference) and gem workaround sources for context. |
| `/Users/navid/code/browser` | Lightpanda upstream (Zig). | All edits land here. New branch, new commit, PR opened from here. |

The gem stays untouched in this skill. Removing the gem-side workaround happens in a **separate** turn after the upstream PR merges — never speculatively delete a workaround in the same session as the fix.

## Reference files (load when needed)

- `references/upstream-wishlist.md` — source of truth for items A1–A19, B1–B11. Read at Step 0.
- `references/file-mapping.md` — wishlist item → gem-side workaround file + upstream Zig source file, plus a directory test-runner table for `webapi/`. Read at Steps 1c, 3, and 4.
- `references/templates.md` — implementation prompt, reproducer skeleton, issue body, commit message, PR body, final report. Read at Steps 4, 6, 7, 8, 9.
- `references/visual-verification.md` — GitHub markdown rendering checklist used by Steps 7c and 8e.

## Audience: write for a Zig browser engineer, not a Rubyist

The Lightpanda maintainer works in Zig + V8 on a browser engine. They are **not** familiar with Ruby, Rails, ActiveRecord, Capybara, RSpec, Turbo, Stimulus, or any Ruby-side framework. Every issue body, PR description, commit message, and reproducer must land for that audience or it gets ignored.

Hard rules:

- **Never reproduce a bug with a Ruby/Capybara/RSpec test.** Reproducers must run with only Lightpanda + a CDP client the maintainer can run in 30 seconds: `curl` over websocket, a tiny Node script using `chrome-remote-interface`, or `lightpanda fetch` against a static HTML file. A Rails or Capybara repro is opaque — they can't run it without a Ruby toolchain they don't have.
- **Never describe behavior in framework terms.** Don't say "Capybara's `click_link` calls `Page.navigate` and then…" — say "a CDP client sending `Page.navigate` then awaiting the `Page.loadEventFired` event observes…". CDP semantics and HTML/DOM spec citations are universal; framework names aren't. Same for Turbo Drive — describe the actual DOM mutation pattern (`document.body.innerHTML = …; document.body.replaceWith(newBody)`) rather than naming the library.
- **Mermaid diagrams are required, not optional.** Every issue gets a sequence diagram of the broken vs. expected CDP/event flow. Every PR gets a flowchart of the old (broken) vs. new (fixed) code path. They cut review time dramatically when the reviewer is doing surgery on engine code they didn't write — a 10-line diagram replaces a paragraph of prose.
- **Cite the spec, not the consumer.** When stating expected behavior, link to: HTML Living Standard section, CDP protocol reference (`https://chromedevtools.github.io/devtools-protocol/`), or Chrome's source if the spec is silent. Never "because Capybara expects…".
- **Reproducer must be self-contained**: one `repro.html` + one `repro.sh` (or `repro.js`). No `bundle install`, no `gem install`, no `Gemfile`. If you need Node, declare the exact one-liner: `npm install --no-save chrome-remote-interface` and inline the script.

## Step 0: Pick the item

Source of truth: `references/upstream-wishlist.md`. Each entry has an ID (`A1`–`A19`, `B1`–`B11`).

User typically names the item directly ("fix A14"). If they don't:

- Ask which one, OR
- Suggest the next from the recommended order (Step 0a) and confirm.

**Refuse and explain** if the user names a Section C item — those are inherent (no rendering engine). Recommend running cuprite for that lane instead. For items that may already be addressed (already fixed, open PR by us), the duplicate check in Step 1b will catch them — don't hardcode their state here.

### Step 0a: Recommended order if the user is undecided

The wishlist's "Quick wins" section reflects the priority. If unsure, pick the smallest still-actionable item.

**First, filter through the wishlist's own annotations.** Each item in `references/upstream-wishlist.md` may carry a `**Upstream issue**:` / `**Upstream PR**:` line — items already filed by us are ineligible for this skill (don't open duplicates). Skim the candidates' wishlist entries before consulting the priority list below; Step 1b's `gh pr list` is the second-pass safety net, not the first.

1. **A14** — `requestSubmit()` polyfill on `HTMLFormElement`. Smallest, isolated, easy to test. Good first PR.
2. **A6** — `Page.reload` replays POST. Targeted CDP fix, single domain file.
3. **A1 + A2 + B3** — cookie clearing trio. Bundle these because they share a root cause. (Exception to the "one PR per item" rule — only because the upstream fix is a single change.)
4. **A3** — `Page.handleJavaScriptDialog` actually dismisses/accepts. Touches `page.zig` + dialog plumbing.
5. **A8** — `#id` selector regression after body replacement. Check `gh pr list` first; we may already have a PR open.
6. **B1** — `XPathResult` + `document.evaluate`. Largest scope (~700 LOC drop on the gem side). Last because it's the most invasive Zig change.

Section A bugs > Section B missing methods, generally — bugs have clearer "want" semantics (Chrome behavior). Missing methods may need design discussion upstream first.

### Step 0b: Anti-patterns (refuse to do these)

- **Bundling unrelated fixes into one PR.** Each item gets its own branch + issue + PR. Reviewers reject mixed changes. The A1+A2+B3 bundle above is the only exception, and only because they share a one-function fix.
- **Writing Ruby tests for the Zig fix.** Verification on the gem side is a separate phase (Step 5) and uses the *existing* gem-side test as a regression check, not a new spec.
- **Skipping the Zig test.** Every fix gets at least one `test "..."` block in the same .zig file or under `src/browser/tests/`. CI requires it and reviewers will block.
- **Opening a PR without an issue first.** Always file the issue (Step 7) before the PR (Step 8). An orphan PR has no place to record the reproducer cleanly and gives the maintainer no chance to weigh in on approach before code review.
- **Opening a PR without a `Closes #<n>` line.** The PR body MUST include the literal text `Closes #<issue-num>` referencing the Step 7 issue. This wires up GitHub's auto-close on merge. Without it, the issue stays open after the PR merges and someone has to remember to close it manually — which never happens. Step 8d verifies GitHub actually parsed the link via `gh pr view ... --json closingIssuesReferences`. If that returns empty, the PR body is wrong and must be edited before continuing.
- **Pasting a Ruby/Capybara/RSpec reproducer into the issue.** The maintainer can't run it. Reproducers are CDP + HTML only — see Step 6. If you can't reduce the bug to a CDP-only repro, the bug isn't isolated enough to fix yet.
- **Skipping mermaid diagrams.** Issue and PR both require diagrams (sequence diagram for the issue, flowchart for the PR). They're not decoration — they're the fastest way for a Zig engineer to understand a bug they didn't write.
- **Filing the issue or PR without visually verifying the rendering.** After every `gh issue create` and `gh pr create`, navigate to the URL with the Playwright MCP and confirm mermaid diagrams render as graphs (not as `mermaid` code blocks), code fences are intact, `Closes #<n>` is hyperlinked, and the body reads cleanly. See `references/visual-verification.md`. Steps 7c and 8e are mandatory, not optional.
- **Re-filing an item we already filed.** If `gh pr list` (Step 1b) returns an open PR by us for this item, report status and stop — don't open a duplicate.
- **Branching off a stale `main`.** Every session that enters `/Users/navid/code/browser` MUST `git checkout main && git pull origin main` before creating the fix branch — even if the repo "looks fine" or you were on `main` recently. Upstream moves fast; stale-base branches conflict and miss fixes. Step 2 enforces this; never skip it.
- **Running `zig build` without `$V8`.** Falls back to building V8 from source (~20+ min per invocation). The user's fish shell exports `$V8` via `~/.config/fish/conf.d/lightpanda.fish` pointing at a prebuilt V8 archive in `.lp-cache/prebuilt-v8/`. Always include `$V8` on every `zig build` command — see "Local build & test commands" below.
- **Running bare `zig build` instead of `mise exec -- zig build`.** The repo pins Zig 0.15.2 via `build.zig.zon`'s `minimum_zig_version`; the system Zig on this machine is newer (0.16.0). Bare `zig` in Claude's non-interactive subshells resolves to the system install — `cd` alone does NOT activate mise's pinned version (the directory hook only fires in interactive shells, not in the per-command subshells the Bash tool spawns). Building with the wrong Zig produces stdlib mismatch errors that look like real bugs. Always prefix `zig build` / `zig` invocations with `mise exec --`. See "Local build & test commands" below.
- **Running `make build` or `make build-dev` for verification.** Those forces `ReleaseFast` and rebuild the V8 snapshot — slower than what you need. Use `mise exec -- zig build check $V8` / `mise exec -- zig build test $V8` directly.

## Local build & test commands

Two non-negotiables on every `zig build` invocation:

1. **Prefix with `mise exec --`** so Zig 0.15.2 (pinned in the repo's `build.zig.zon` as `minimum_zig_version`, and pinned locally in `mise.toml`) is used. Bare `zig` in Claude's per-command Bash subshells resolves to the system install (currently 0.16.0 on this machine) because mise's directory activation only fires in interactive shells. Building with a Zig version newer than 0.15.2 produces stdlib mismatch errors that masquerade as real bugs and waste a debugging session.
2. **Pass `$V8`** so the build links against the prebuilt V8 archive at `/Users/navid/code/browser/.lp-cache/prebuilt-v8/libc_v8_<version>_macos_aarch64.a` instead of compiling V8 from source (~20+ min). The user's fish shell auto-exports `$V8` via `~/.config/fish/conf.d/lightpanda.fish`; the cache is keyed by `V8_VERSION` from `zig-pkg/v8-*/build.zig` so it refreshes when upstream bumps V8.

| Command | When to use |
|---|---|
| `mise exec -- zig build check $V8` | After every Zig edit. Fastest signal — type-check only, no codegen, no link. Catches compile errors across the whole project. |
| `TEST_FILTER=<pattern> mise exec -- zig build test $V8` | After writing/changing the test for the fix. Runs only matching `test "..."` blocks. Use during TDD iteration. |
| `mise exec -- zig build test $V8` | Before pushing. Full unit-test suite — verifies nothing else regressed. |
| `mise exec -- zig build $V8` | When you need a debug binary at `./zig-out/bin/lightpanda` (e.g., to re-run the Step 6 reproducer post-fix). |
| `mise exec -- zig build run $V8 -- <args>` | Build & run the binary in one step. |

Sanity-check the toolchain once per session before the first build: `mise exec -- zig version` must print `0.15.2`. If it doesn't, mise hasn't installed the pinned toolchain yet — run `mise install` in `/Users/navid/code/browser` and re-check.

Performance notes:
- First run after a dep update builds curl/brotli/sqlite/html5ever (~1–2 min). Subsequent runs are incremental.
- `mise exec -- zig build check $V8` typically finishes in <10s after warm-up.
- `mise exec -- zig build test $V8` runs in 30s–2min depending on what changed.
- The `extras` step (legacy_test, snapshot_creator) is not in the default — don't trigger it.

Local verification reduces the cost of a broken CI run: catch trivial errors on your machine first, let upstream CI be the authoritative second opinion (it builds on Linux against the upstream toolchain, which catches macOS-vs-Linux drift you can't see locally).

## Step 1: Pre-flight

Before touching any code, confirm three things:

### 1a. The bug still reproduces on current `main`

```bash
cd /Users/navid/code/browser
git fetch origin && git log --oneline origin/main -10
```

Then either:
- Reproduce against the latest nightly binary already on disk (via the gem's setup) using the existing failing spec or a CDP repro. The nightly is the cheapest pre-flight surface — no local rebuild needed just to confirm a known bug. If `main` has commits since the nightly that may have already fixed the bug, read the diff (`git diff <nightly-sha>..origin/main -- <relevant-files>`) and reason about whether the fix landed; if ambiguous, build a local debug binary with `mise exec -- zig build $V8` and re-run the repro against `./zig-out/bin/lightpanda`.
- For pure CDP/JS API gaps (A14, B1, etc.), grep the relevant `.zig` file for the missing symbol — absence is the repro.

If the bug appears already fixed, **stop and tell the user**. Recommend running `bundle exec rake spec` against current nightly on the gem to confirm, and update `.claude/rules/lightpanda-io.md` instead of opening a PR.

### 1b. No existing upstream issue or PR addresses it

```bash
# Issues touching this area
gh issue list --repo lightpanda-io/browser --search "<keyword>" --state all --limit 10

# PRs (open OR recently merged)
gh pr list --repo lightpanda-io/browser --search "<keyword>" --state all --limit 10
```

Keywords to use per item: `requestSubmit` for A14, `clearBrowserCookies` for A1, `getNavigationHistory` for B2, `XPathResult` for B1, `handleJavaScriptDialog` for A3, etc.

If a PR exists:
- **Open** — link it, ask user whether to add to it (comment) or skip. Don't open a duplicate.
- **Merged but not in nightly** — wait for next nightly, don't re-do.
- **Closed unmerged** — read the close reason. Either upstream rejected the approach (don't re-file the same way) or it was superseded (find the successor).

### 1c. Locate the gem-side workaround for context

The wishlist says where the workaround lives, and `references/file-mapping.md` has the full table (item → gem file). Read the workaround. The fix has to make it unnecessary, so understanding what the workaround does pins down the spec — exact return shape, error code, event name the upstream fix must match.

**Verify only the item you're fixing — don't take *adjacent* wishlist items at face value.** The wishlist is updated by hand and entries drift between reviews; a neighbor item described as broken may have been silently fixed upstream. If the design of your reproducer or fix depends on a neighbor item's behavior (e.g., A6's reproducer happens to call `form.submit()`, and A4 claims `form.submit()` doesn't navigate), spend two minutes confirming the neighbor is still broken — empirically, via a tiny CDP probe — before designing around the wishlist's claim. Cheaper than over-engineering a workaround you didn't need.

## Step 2: Bootstrap branch in `/Users/navid/code/browser`

**Non-negotiable**: every session that touches `/Users/navid/code/browser` starts by checking out `main` and pulling the latest from `origin`. The upstream repo moves fast — branching off a stale `main` means rebasing later, missed fixes, and PRs that conflict on day one. Do this even if you "just" left the repo on `main` in a previous session; another machine, another teammate, or a Dependabot bump may have advanced it.

```bash
cd /Users/navid/code/browser
git status                                     # must be clean (mise.toml ignored)
git checkout main                              # ALWAYS — never branch off whatever was checked out last
git pull origin main                           # ALWAYS — never branch off a stale main
git log --oneline -5                           # sanity-check the new HEAD
git checkout -b fix-<item-id>-<slug>           # e.g. fix-a14-requestsubmit, fix-a1-clearbrowsercookies
```

If `git status` is dirty (uncommitted work from a previous session, stray repro artifacts, etc.), stop and surface it to the user — do not stash, reset, or clean without permission. The user decides whether to keep, discard, or move that work.

**Remote naming**: this clone uses two remotes — `origin = lightpanda-io/browser` (upstream, where `git pull` reads from) and a personal fork (e.g. `fork = navidemad/browser`, where pushes go). Run `git remote -v` to confirm. The pull above targets `origin`; **the push at Step 8a targets the fork** (`git push -u fork ...`) and `gh pr create` needs `--head <fork-owner>:<branch> --repo lightpanda-io/browser` since the source branch lives on the fork. If `git remote -v` shows only `origin` pointing at your fork, the convention collapses to plain `origin` — but verify before assuming.

Pin the Zig toolchain via mise. The repo's `build.zig.zon` declares `minimum_zig_version = "0.15.2"` but does not commit a `.zig-version` / `.tool-versions` file, so each contributor manages their own pin. We use a local (gitignored) `mise.toml`:

```bash
# Ensure mise.toml exists with the right pin (idempotent — overwrites only if wrong/missing)
if ! grep -qF 'zig = "0.15.2"' mise.toml 2>/dev/null; then
  printf '[tools]\nzig = "0.15.2"\n' > mise.toml
fi

# Ensure it's gitignored locally so it doesn't leak into a commit
grep -qF "mise.toml" .git/info/exclude || echo "mise.toml" >> .git/info/exclude

# Install the pinned toolchain if not already, then verify
mise install
mise exec -- zig version   # MUST print 0.15.2 — abort if not
```

If `mise exec -- zig version` prints anything other than `0.15.2`, stop and surface it. Building with the wrong Zig produces stdlib errors that look like real bugs and burn debugging time.

## Step 3: Locate the Zig code

`references/file-mapping.md` has the item → Zig file map and `rg` recipes for finding CDP dispatch enums and JS API bindings. Use it as a starting point, then confirm with grep — file layout drifts.

## Step 4: Implement fix + Zig test

Use the implementation prompt template in `references/templates.md` to drive the Zig changes. The template can be applied two ways — work through it inline (default for small single-file changes) or paste it into a `general-purpose` subagent (better for multi-file changes or to keep main context lean). The template is self-contained either way; fill in the `<...>` placeholders before applying.

Before adding a `test "..."` block in `src/browser/webapi/<File>.zig`, consult the **Directory test runners** table in `references/file-mapping.md`. Many webapi files own an entire `tests/<dir>/` directory via `htmlRunner("<dir>", .{})` — adding a sibling test block that re-runs a fixture in that directory duplicates work and gets flagged in review. Drop new fixtures into the directory the runner already covers and skip the extra `test "..."` block.

Work TDD: failing test → confirm it fails → implement → confirm it passes → no regressions.

### 4a. Verification gates before moving on

Use the local commands from "Local build & test commands" — fast enough that all of these gates are cheap:

- `mise exec -- zig version` prints `0.15.2`, matching `build.zig.zon`'s `minimum_zig_version`. Anything else means mise isn't resolving the pinned toolchain — fix Step 2's pin before doing anything else, otherwise every subsequent build is suspect.
- `mise exec -- zig build check $V8` is clean. No compile errors anywhere in the project (not just the file you edited).
- A new `test "..."` block exists in the appropriate `.zig` file covering the fix. Run `TEST_FILTER=<test name> mise exec -- zig build test $V8` and confirm it passes.
- Toggle the fix off and confirm the new test fails — this proves the test actually exercises the fix, not some unrelated path. Restore the fix afterwards. **Prefer `Edit` to surgically revert the production lines, NOT `git stash`**: when the test sits in the same file as the fix (the common case for CDP changes — both live in `src/cdp/domains/<domain>.zig`), a `git stash` will sweep the test out alongside the fix and the toggle re-run reports `0 of 0 tests passed` instead of a real failure. The reliable pattern is: `Edit` the fix call site to its pre-fix shape (e.g. delete the `.method/.body/.header` fields, hardcode `.method = .GET`), run, observe failure, `Edit` it back. If you do reach for `git stash`, stage the test first (`git add <test-file>`) so `--keep-index` actually retains it.
- `mise exec -- zig build test $V8` (full suite, no filter) passes — catches regressions in adjacent code.
- The reproducer from Step 6 has been confirmed to exit 1 (bug observed) against the current nightly binary already on disk. Recommended: build a local debug binary with `mise exec -- zig build $V8` and re-run the reproducer against `./zig-out/bin/lightpanda` to confirm exit 0 (bug fixed end-to-end). This is the strongest pre-push signal — it validates the unit test, the binary, and the reproducer together. (The local debug build needs ~5 GB free in `.zig-cache`; if `df -h .` shows less, skip it — the unit test + pre-fix reproducer + CI cover the same ground, and a `NoSpaceLeft` error here only burns time. Don't auto-clean caches without asking the user.)
- The diff matches the surrounding file's existing style (naming, comment density, helper layout) and contains no "while-we're-here" reformatting. Outsider PRs get reviewed line-by-line — reviewers reject mixed scope. Every changed line traces directly to the bug; if you wrote 200 lines and 50 would do, rewrite.
- `git diff` shows only files relevant to the fix. No `mise.toml`, no editor config.

Local pass is necessary but not sufficient — upstream CI runs on Linux against the upstream toolchain and may surface platform-specific issues you can't see on macOS. Treat CI as the authoritative final check after a clean local pass.

### 4b. If upstream CI is broken for unrelated reasons

If recent `main` runs in upstream's GitHub Actions are red without your changes (toolchain mismatch, dependency churn, transient breakage), **stop and report the failing CI URL to the user**. Check via `gh run list --repo lightpanda-io/browser --branch main --limit 5`. Do not paper over it by editing `.zig-version`, bumping deps, or rebasing onto an older commit — those are separate decisions the user has to make. Possible next steps to surface: pin to the last green commit, file a separate upstream issue about the breakage, or wait it out. Local `zig build test $V8` passing on a red-CI `main` is a useful data point but doesn't substitute — surface the CI breakage anyway.

## Step 5: Validate against the gem (sanity check, no edits)

The point of this PR is to make the gem's workaround unnecessary. Spot-check that the fix actually does that, **without modifying gem code**:

```bash
cd /Users/navid/code/capybara-lightpanda
# Read the workaround from Step 1c.
# Mentally trace: with the upstream fix in place, would the workaround's gem-side
# fallback path still trigger? If yes, the upstream fix is incomplete.
```

For items where the gem skip-lists tests (`spec/spec_helper.rb`), the test should be runnable after the fix lands — but **don't unskip in this PR's scope**. That belongs to a follow-up gem PR.

For items where the gem implements a polyfill (A14, B1, A8), confirm the upstream behavior matches what the polyfill emulates — same return shape, same event sequence, same error semantics. If it doesn't, the polyfill won't be deletable, which means the fix is incomplete or the polyfill diverged from spec.

If the validation reveals a gap (fix works but doesn't fully obsolete the workaround): document the residual gap in the PR description rather than expanding scope. A partial fix is fine; a misleading PR is not.

## Step 6: Build the reproducer

Before filing anything, build a self-contained reproducer the maintainer can run with no Ruby toolchain. This artifact is referenced by both the issue (Step 7) and the PR (Step 8), so do it once, well.

A working `repro.js` + `repro.sh` skeleton lives in `references/templates.md` ("Reproducer skeleton (Step 6)"). It already encodes the non-default `chrome-remote-interface` config Lightpanda needs (`target: ws://...` + `local: true`), the `/json/version` readiness probe that asserts the listener is actually Lightpanda, and the port-cleanup pre-step. Start from that skeleton — don't rebuild it from scratch.

### 6a. Where to put it

Local workspace only — do **not** commit the reproducer to the upstream branch. Suggested layout:

```
/Users/navid/code/browser/repro/<id>-<slug>/
  repro.html            # minimal fixture, no frameworks
  repro.sh              # orchestrates lightpanda + driver + assertions
  repro.js              # (if needed) Node CDP client using chrome-remote-interface
  README.md             # what the script asserts; expected vs. actual output
```

Add the `repro/` directory to `.git/info/exclude` so it can't accidentally be committed.

### 6b. Reproducer requirements

The script must:

1. Start `lightpanda serve --host 127.0.0.1 --port 9222` in the background, with a clean PID trap so it dies when the script exits.
2. Serve `repro.html` over HTTP (`python3 -m http.server` on a free port is fine).
3. Drive the browser through CDP — pure curl/websocket if simple enough, otherwise a small Node script using `chrome-remote-interface` (one `npm install --no-save chrome-remote-interface` line at the top).
4. Print **exactly** the observation that demonstrates the bug, then `exit 1` if the bug is observed and `exit 0` if not. The maintainer should see the bug in one terminal command.
5. Include a header comment listing: prerequisites, what to run, expected output today, expected output after the fix.

Cap the whole thing at ~80 lines of shell + ~50 lines of JS. If the bug requires more than that to reproduce, the bug isn't isolated enough — split it.

**Keep the wishlist ID out of the file *contents*.** The directory name (`a6-page-reload-replay-post/`) is private — the maintainer never sees it. But anything inside the files (HTML `<title>`, JS comments, shell header comment, FAIL messages, Python module docstring) gets pasted verbatim into the issue body at Step 7, where strings like "A6 reproducer" or "see wishlist A4" are meaningless project-internal IDs that read as a downstream-consumer leak. Use generic, behavior-describing wording in the file contents — `"reload-replay-POST repro"`, `"FAIL: Page.reload regressed to GET."`, etc. The same rule applies to references to `capybara-lightpanda`, `Capybara`, `RSpec`, `Turbo`, etc. — none of those have any business appearing inside an upstream-facing reproducer.

### 6c. Verify the reproducer pre-fix and (recommended) post-fix

Run the reproducer against the current nightly binary already on disk and confirm exit code 1 (bug observed). This proves the bug exists in nightly and the reproducer correctly catches it.

After Step 4 implements the fix, build a local debug binary with `mise exec -- zig build $V8` and re-run the reproducer against `./zig-out/bin/lightpanda` to confirm exit 0 (bug fixed). This is the most direct end-to-end signal — it exercises the fix through the same CDP surface the maintainer will use to verify the patch. If the unit test passes but the reproducer still exits 1, the fix is incomplete (often: the test exercises an internal helper but the CDP dispatch path was missed).

## Step 7: File the issue first

The issue is filed **before** the PR, even when both go up the same day. The PR will close it via `Closes #<n>`. Filing the issue first gives the maintainer a place to comment on approach if they disagree, and gives the bug a permanent searchable record independent of any single PR's life.

### 7a. Compose the body

Use the issue body template in `references/templates.md`. The template includes both required mermaid sequence diagrams (broken vs. expected CDP flow) and slots for the reproducer.

### 7b. File the issue

**Use the `Write` tool to stage the body file at `/tmp/<id>-issue-body.md`, then pass it via `--body-file`.** Don't shell out a `cat <<'EOF' ... EOF` heredoc — body content frequently contains substrings (`process.env.X`, dotfile paths, `.env`-style references) that trip local pre-tool hooks and reject the bash invocation. `--body-file` also makes the re-publish loop cleaner: edit the file, then `gh issue edit <n> --body-file <same-file>`.

```bash
gh issue create --repo lightpanda-io/browser \
  --title "<title — area: short description>" \
  --body-file /tmp/<id>-issue-body.md
```

Capture the issue number from the response (e.g., `https://github.com/lightpanda-io/browser/issues/2400` → `2400`). The PR description and commit message both reference this number — wrong number means broken auto-close.

### 7c. Visually verify the issue rendering

Mermaid diagrams, nested code fences, and HEREDOC escape edge cases break in subtle ways that look fine in source but render wrong on GitHub. Apply the checklist from `references/visual-verification.md` (common section + issue-only section). If anything renders wrong or could read better, edit and re-publish before moving on.

## Step 8: Open the PR linked to the issue

Push the branch and open the PR. The PR body **must** contain a literal `Closes #<issue-num>` line referencing the issue from Step 7. This wires up GitHub's auto-close: when the PR merges, the issue closes automatically, the wishlist tracker stays accurate, and reviewers can see the linked issue in the right-sidebar of the PR. **Without this line, the issue stays open after merge** and someone has to remember to close it manually — which never happens.

GitHub recognizes any of: `Closes`, `closes`, `Close`, `Fixes`, `fixes`, `Resolves`, `resolves`, plus the past-tense variants. Pick **`Closes`** for consistency across all our PRs.

### 8a. Push and create

Stage the PR body the same way as the issue body — use the `Write` tool to put it at `/tmp/<id>-pr-body.md`, then pass `--body-file`. Heredoc invocations get tripped by local hooks; `--body-file` survives them and makes re-publish a single command.

```bash
cd /Users/navid/code/browser
git status                                     # confirm only intended files (no repro/, no mise.toml)
git diff --stat                                # confirm reasonable surface
git add <specific files>                       # NEVER `git add -A` — the repro dir and mise.toml are local-only
git commit                                     # use commit message template in references/templates.md — body MUST include "Closes #<issue-num>"
git push -u origin fix-<id>-<slug>             # if origin is your fork; on a two-remote setup substitute fork (see Step 2's "Remote naming")

# Sanity-check the prepared PR body BEFORE invoking gh pr create:
# - contains "Closes #<actual issue number from Step 7>" (not "<issue-num>" placeholder)
# - both mermaid diagrams are present
# - issue number is the real one captured in 7b, not a guess
grep -E "Closes #[0-9]+" /tmp/<id>-pr-body.md || { echo "MISSING Closes line — abort"; exit 1; }

gh pr create --repo lightpanda-io/browser \
  --base main \
  --title "<title>" \
  --body-file /tmp/<id>-pr-body.md
```

### 8b. Templates

Commit message and PR description templates are in `references/templates.md`. Match the project's commit style — check `git log --oneline -20` for examples. Lightpanda uses lowercase area prefixes (`cdp:`, `dom:`, `forms:`, `page:`, `runtime:`, `network:`).

Do **not** mention `capybara-lightpanda` or the wishlist by name in the PR or commit. The fix should stand on its own merits — Lightpanda is a browser used by many clients, and naming one downstream consumer biases reviewers. Refer to "downstream CDP clients" generically if context demands.

### 8c. Verify the auto-close link is wired up

Right after `gh pr create` returns the URL, verify GitHub actually parsed the `Closes #<n>` and linked the issue. A typo (`Close #1234.`, `closes#1234`, wrong number) silently fails and leaves the issue orphaned.

```bash
gh pr view <pr-num> --repo lightpanda-io/browser \
  --json closingIssuesReferences \
  --jq '.closingIssuesReferences[].number'
```

This must print the issue number from Step 7. If it's empty: edit the PR body via `gh pr edit <pr-num> --body-file <file>` to fix the `Closes` line, then re-run the check. Don't move on to Step 8d until the auto-close is confirmed.

### 8d. Visually verify the PR rendering

Same drill as 7c, against the PR URL this time. Apply the checklist from `references/visual-verification.md` (common section + PR-only section: flowchart rendering, hyperlinked `Closes #<n>`, Linked Issues sidebar, Files-changed tab matches Fix bullets). Fix-and-republish if anything reads sloppy — don't ship a sloppy artifact when polish is two minutes away.

### 8e. Post-submit hygiene

After the PR opens and the auto-close link is verified:

1. Capture both URLs (issue + PR) in the report back to the user.
2. **Do not** mark the wishlist item as fixed in `references/upstream-wishlist.md` yet — only when the PR merges and ships in a nightly. Add a note next to the item: `**Upstream issue**: #<i>, **Upstream PR**: #<n> (open as of YYYY-MM-DD)`.
3. **Do not** delete the gem-side workaround — that's a follow-up gem PR after the nightly ships, in a separate turn.

## Step 9: Report back

Use the final-report template in `references/templates.md`. If you stopped before submitting (because the bug was already fixed, a duplicate exists, or the fix needed design discussion), the report explains why and what's needed to unblock — no issue/PR URL, but if you filed an issue without a PR, surface that URL.
