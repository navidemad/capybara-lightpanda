---
name: lightpanda-upstream-pr
description: Drive a single upstream Lightpanda PR end-to-end — pick one item from this skill's references/upstream-wishlist.md (Section A bug or Section B missing method), verify it's still broken on current nightly, locate the Zig code in /Users/navid/code/browser, implement the fix with a Zig test, validate that the gem's workaround can be deleted, and submit the PR via gh. Use this skill when the user says "fix A1 upstream", "tackle the next Lightpanda bug", "open a PR for the cookie clearing bug", "implement A14 upstream", "let's knock out one of the upstream items", "PR the requestSubmit polyfill", "send the form.submit fix to lightpanda-io". Do NOT use for gem-side code changes (those edit /Users/navid/code/capybara-lightpanda — different repo) or for general upstream reconnaissance (that's the sync-upstream skill). Section C items (no rendering, no compositor) are out of scope and the skill should refuse them.
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

## Step 0: Pick the item

Source of truth: `references/upstream-wishlist.md` (this skill's references directory; absolute path `/Users/navid/code/capybara-lightpanda/.claude/skills/lightpanda-upstream-pr/references/upstream-wishlist.md`). Each entry has an ID (`A1`–`A19`, `B1`–`B11`).

User typically names the item directly ("fix A14"). If they don't:

- Ask which one, OR
- Suggest the next from the recommended order (Step 0a) and confirm.

**Refuse and explain** if the user names a Section C item — those are inherent (no rendering engine). Recommend running cuprite for that lane instead. Same for already-fixed items (e.g. A19) and items with an open PR by us (e.g. A8 → PR #2244 already filed).

### Step 0a: Recommended order if the user is undecided

The wishlist's "Quick wins" section reflects the priority. If unsure, pick the smallest still-actionable item:

1. **A14** — `requestSubmit()` polyfill on `HTMLFormElement`. Smallest, isolated, easy to test. Good first PR.
2. **A6** — `Page.reload` replays POST. Targeted CDP fix, single domain file.
3. **A1 + A2 + B3** — cookie clearing trio. Bundle these because they share a root cause. (Exception to the "one PR per item" rule — only because the upstream fix is a single change.)
4. **A3** — `Page.handleJavaScriptDialog` actually dismisses/accepts. Touches `page.zig` + dialog plumbing.
5. **A8** — already filed as PR #2244, just check status / nudge reviewers, don't re-file.
6. **B1** — `XPathResult` + `document.evaluate`. Largest scope (~700 LOC drop on the gem side). Last because it's the most invasive Zig change.

Section A bugs > Section B missing methods, generally — bugs have clearer "want" semantics (Chrome behavior). Missing methods may need design discussion upstream first.

### Step 0b: Anti-patterns (refuse to do these)

- **Bundling unrelated fixes into one PR.** Each item gets its own branch + PR. Reviewers reject mixed changes. The A1+A2+B3 bundle above is the only exception, and only because they share a one-function fix.
- **Writing Ruby tests for the Zig fix.** Verification on the gem side is a separate phase (Step 5) and uses the *existing* gem-side test as a regression check, not a new spec.
- **Skipping the Zig test.** Every fix gets at least one `test "..."` block in the same .zig file or under `src/browser/tests/`. CI requires it and reviewers will block.
- **Re-filing A8.** PR #2244 is already open. If user asks to "do A8", check the PR status with `gh pr view 2244 --repo lightpanda-io/browser` and report instead of opening a duplicate.

## Step 1: Pre-flight

Before touching any code, confirm three things:

### 1a. The bug still reproduces on current `main`

```bash
cd /Users/navid/code/browser
git fetch origin && git log --oneline origin/main -10
```

Then either:
- Build locally (`make build` or `zig build` per repo Makefile) and reproduce against the gem's existing failing spec, OR
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

The wishlist says where the workaround lives. Read it. The fix has to make the workaround unnecessary, so understanding what the workaround does pins down the spec.

Map of items → gem workaround files:

| Item | File on gem side |
|---|---|
| A1, A2, B3 | `lib/capybara/lightpanda/cookies.rb` (sweep_visited_origins) |
| A3 | `lib/capybara/lightpanda/browser.rb` (prepare_modals, accept_modal, etc.) |
| A4, A5 | `lib/capybara/lightpanda/node.rb` (CLICK_JS, IMPLICIT_SUBMIT_JS) |
| A8 | `lib/capybara/lightpanda/javascripts/index.js` (querySelector rewriter) |
| A10 | `lib/capybara/lightpanda/browser.rb` (wait_for_page_load) |
| A11 | `lib/capybara/lightpanda/browser.rb` (with_default_context_wait) |
| A12 | `lib/capybara/lightpanda/browser.rb` (handle_navigation_crash) |
| A14 | `lib/capybara/lightpanda/javascripts/index.js` (requestSubmit polyfill) |
| B1 | `lib/capybara/lightpanda/javascripts/index.js` (XPathEval IIFE) |
| B2 | `lib/capybara/lightpanda/browser.rb` (back, forward) |

Read the gem file's relevant section. Note the exact behavior the workaround relies on (return shape, error code, event name) — this is what the upstream fix must match.

## Step 2: Bootstrap branch in `/Users/navid/code/browser`

Always start from a clean `main`:

```bash
cd /Users/navid/code/browser
git status                                     # must be clean (mise.toml ignored)
git checkout main && git pull origin main
git checkout -b fix-<item-id>-<slug>           # e.g. fix-a14-requestsubmit, fix-a1-clearbrowsercookies
```

Verify `mise.toml` is gitignored locally so it doesn't leak into a commit:

```bash
grep -F "mise.toml" .git/info/exclude
```

If missing, add it before doing any work.

## Step 3: Locate the Zig code

CDP domain files live at `src/cdp/domains/<domain>.zig`. Browser-internal logic lives at `src/browser/`. JS API surface (DOM, HTML elements) lives at `src/browser/<area>/` (e.g. `src/browser/forms/`, `src/browser/dom/`).

Mapping per item (use as a starting point, then `grep`/`rg` to confirm):

| Item | Likely file(s) |
|---|---|
| A1 (`Network.clearBrowserCookies`) | `src/cdp/domains/network.zig` (dispatch enum + handler) |
| A2 (`Network.getCookies` scope) | `src/cdp/domains/network.zig` (handler reads current page origin — change to enumerate jar) |
| A3 (`handleJavaScriptDialog`) | `src/cdp/domains/page.zig` (dispatch handler — currently always errors) + dialog plumbing in `src/browser/Page.zig` |
| A4 (`form.submit()`) | `src/browser/forms/HTMLFormElement.zig` (or wherever `submit` is bound) |
| A5 (`document.write`) | `src/browser/document/Document.zig` |
| A6 (`Page.reload` replays POST) | `src/cdp/domains/page.zig` (reload handler) + `src/browser/Page.zig` (navigation history entry shape) |
| A7 (`<select>` empty FormData) | `src/browser/forms/` (FormData construction) |
| A8 (`#id` selector) | `src/browser/css/` (selector engine, `Frame.getElementByIdFromNode`) — **PR #2244 already open** |
| A10 (`Page.loadEventFired`) | `src/browser/Page.zig` (navigation lifecycle) + `src/cdp/domains/page.zig` (event emission) |
| A11 (NoExecutionContextError) | `src/cdp/domains/runtime.zig` (evaluate — add wait/queue for new context) |
| A14 (`requestSubmit`) | `src/browser/forms/HTMLFormElement.zig` |
| A15 (`location.pathname` navigation) | `src/browser/dom/Location.zig` (or similar) |
| B1 (`XPathResult`/`document.evaluate`) | New: `src/browser/dom/XPathEvaluator.zig` (large) |
| B2 (history CDP methods) | `src/cdp/domains/page.zig` (add new dispatch entries) |
| B3 (`Network.getAllCookies`) | `src/cdp/domains/network.zig` (add dispatch entry) |
| B4 (`setFileInputFiles`) | `src/cdp/domains/page.zig` + file input plumbing in `src/browser/forms/` |

Find the dispatch enum for CDP additions:

```bash
rg -n "fn processMessage" /Users/navid/code/browser/src/cdp/domains/network.zig
rg -n "method_name" /Users/navid/code/browser/src/cdp/domains/network.zig | head
```

For JS APIs, check `src/browser/<area>/` for `.zig` files — APIs are bound through Zig→V8 reflection (look for `pub const` declarations of method names).

## Step 4: Implement fix + Zig test

Use the implementation prompt template below to drive the Zig changes. Apply it as a self-contained brief — do not assume context from this conversation carries over if you spawn an agent.

### 4a. Implementation prompt template

When making the fix, structure work as TDD:

> **Context**: Working in `/Users/navid/code/browser`, the Lightpanda browser (Zig 0.15.2 + V8). Branch `fix-<id>-<slug>`. Need to fix item `<ID>` from `references/upstream-wishlist.md` in the gem repo: `<one-line description>`.
>
> **Today's behavior**: `<copy from wishlist>`
>
> **Want**: `<copy from wishlist>`
>
> **Where to look**:
> - Primary: `<file from Step 3 mapping>`
> - Related: `<any test fixtures or sibling files>`
>
> **TDD steps**:
> 1. Write a failing test in `<test file>` that exercises the bug. For CDP fixes use `test "cdp.<Domain> <method>"` blocks in the domain `.zig` file (pattern: see existing tests in `src/cdp/domains/network.zig`). For JS API fixes use HTML fixtures under `src/browser/tests/<area>/` (pattern: see `src/browser/tests/element/duplicate_ids.html` from PR #2244).
> 2. Confirm the test fails by running `zig build test` (scoped to the right module if possible — the full suite is slow).
> 3. Implement the fix in `<primary file>`. Keep the diff minimal — no surrounding cleanup, no formatting churn unrelated to the fix.
> 4. Confirm the test now passes and no other tests regress (`zig build test` over the touched module).
> 5. Document any spec/CDP-protocol assumption in a code comment **only if** the assumption is non-obvious from the code itself.

### 4b. Verification gates before moving on

- `zig build test` (or scoped equivalent) passes — including the new test.
- `git diff` shows only files relevant to the fix. No `mise.toml`, no editor config.
- The new test would have failed without the fix (toggle the fix line and confirm).

If `zig build` fails for unrelated reasons (toolchain version, dependency churn), stop and check `mise.toml` / `.zig-version` — don't paper over the build error.

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

## Step 6: Submission

```bash
cd /Users/navid/code/browser
git status                                     # confirm only intended files
git diff --stat                                # confirm reasonable surface
git add <specific files>                       # NEVER `git add -A` here — the wishlist is gitignored but local-build artifacts may not be
git commit                                     # use the template below
git push -u origin fix-<id>-<slug>
gh pr create --repo lightpanda-io/browser \
  --base main \
  --title "<title>" \
  --body "<body from template>"
```

### 6a. Commit message template

```
<area>: <one-line summary, imperative mood>

<2-4 sentence body explaining root cause and fix>

Closes #<issue> (if any)
```

Match the project's commit style — check `git log --oneline -20` for examples. Lightpanda uses lowercase area prefixes (`cdp:`, `dom:`, `forms:`, `page:`).

### 6b. PR description template

```markdown
## What

<one-paragraph description of the bug and fix>

## Today

<paste from references/upstream-wishlist.md "Today" line — the actual broken behavior>

## Want

<paste from references/upstream-wishlist.md "Want" line — Chrome / spec behavior>

## How

<bullet list of the change — files touched, key functions modified, any new abstractions>

## Test

- New test: `<file:test name>` — fails before, passes after.
- Manual repro: <if applicable, e.g. "via capybara-lightpanda's `Cookies#clear` smoke spec, which fails before the fix and passes after">.

## Notes

<any caveats, follow-ups, or known limitations of this fix>
```

Do **not** mention `capybara-lightpanda` or the wishlist by name in the PR body. The fix should stand on its own merits — Lightpanda is a browser used by many clients, and naming one downstream consumer biases reviewers. Refer to "downstream Capybara/CDP clients" generically if context demands.

### 6c. Post-submit hygiene

After the PR opens:

1. Capture the PR URL in the report back to the user.
2. **Do not** mark the wishlist item as fixed in `references/upstream-wishlist.md` yet — only when the PR merges and ships in a nightly. Add a note next to the item: `**Upstream PR**: #<n> (open as of YYYY-MM-DD)`.
3. **Do not** delete the gem-side workaround — that's a follow-up gem PR after the nightly ships, in a separate turn.

## Step 7: Report back

Single concise summary to the user:

```
Item: <ID> — <title>
Branch: fix-<id>-<slug>
PR: <URL>

Diff: <files changed>, <lines>
Tests: <new test names>
Validation: <one-line — did the gem's workaround become deletable in principle? yes/no/partial>

Next:
- Wait for nightly to ship the fix.
- Follow-up gem PR: delete <workaround> in /Users/navid/code/capybara-lightpanda when nightly drops.
```

If you stopped before submitting (because the bug was already fixed, a duplicate PR exists, or the fix needed design discussion), the report explains why and what's needed to unblock — no PR URL.
