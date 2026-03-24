---
name: sync-upstream
description: Check Lightpanda upstream repo for CDP changes, fixed bugs, new issues, and opportunities to improve capybara-lightpanda. Use this skill whenever the user mentions syncing upstream, checking Lightpanda changes, auditing whether workarounds are still needed, preparing a gem release, verifying CDP methods exist upstream, or investigating whether a specific CDP behavior (like Page.loadEventFired, Network.clearBrowserCookies, XPathResult) has changed or been fixed. Also use when the user reports a BrowserError or CDP failure and wants to know if it's a Lightpanda limitation. Do NOT use for implementing code changes, fixing the XPath polyfill JS, setting up CI, or refactoring driver methods -- those are code tasks, not upstream investigations.
user_invocable: true
model: opus
effort: max
---

# Sync Upstream Lightpanda

You are auditing the Lightpanda browser upstream repo (https://github.com/lightpanda-io/browser) for changes that affect the capybara-lightpanda gem.

## Adapt to Context

Before starting, read the user's prompt carefully. There are two modes:

**Targeted investigation** — The user asks about a specific behavior (e.g., "has Page.loadEventFired been fixed?", "can we remove the readyState fallback?"). Focus your investigation on that topic. Skip unrelated checks. Still read lightpanda-io.md for context, but go deep on the specific question rather than broad.

**Full sync** — The user asks for a general check, periodic sync, or pre-release audit. Run the complete workflow below.

For pre-release audits specifically, end your report with an explicit **Release Readiness** section: "Safe to release" or "Block release because..." with clear reasoning.

## Step 1: Gather Current State

Read `.claude/rules/lightpanda-io.md` to understand:
- Which CDP methods this gem uses (the "CDP Methods Used by This Gem" list)
- Known bugs and workarounds
- Tracked upstream issues
- Known limitations

Read `lib/capybara/lightpanda/browser.rb`, `lib/capybara/lightpanda/driver.rb`, and `lib/capybara/lightpanda/node.rb` to understand current implementation.

## Step 2: Check Upstream Changes

Use `gh` CLI and WebFetch to check the upstream repo. Run these checks in parallel where possible:

### 2a. Recent Commits to CDP Domains

```bash
gh api repos/lightpanda-io/browser/commits \
  --jq '.[] | select(.commit.message | test("(?i)cdp|runtime|page|network|dom|target|cookie|xpath|navigate|dialog|frame|input")) | {sha: .sha[0:8], date: .commit.author.date[0:10], message: .commit.message | split("\n")[0]}'
```

### 2b. Recently Closed Issues We Track

Check each issue from the "Upstream Open Issues" table in lightpanda-io.md:
```bash
gh issue view <NUMBER> --repo lightpanda-io/browser --json state,title,closedAt
```

### 2c. New Issues That Affect Us

```bash
gh api "repos/lightpanda-io/browser/issues?state=open&per_page=50&sort=created&direction=desc" \
  --jq '.[] | select(.title | test("(?i)cdp|cookie|navigate|xpath|runtime|evaluate|dom|network|page|target|frame|dialog|websocket")) | {number: .number, title: .title, created: .created_at[0:10]}'
```

### 2d. Verify Our CDP Methods Exist Upstream

This is the most important check. Fetch each CDP domain source file and verify that **every method listed in "CDP Methods Used by This Gem"** actually exists in the upstream dispatch enum. Lightpanda doesn't implement all Chrome CDP methods — some we call may silently fail or return errors.

Files to check:
- `src/cdp/domains/page.zig` — verify `Page.navigate`, `Page.reload`, `Page.enable`, `Page.getNavigationHistory`, `Page.navigateToHistoryEntry`, `Page.handleJavaScriptDialog`, `Page.loadEventFired`
- `src/cdp/domains/runtime.zig` — verify `Runtime.evaluate`, `Runtime.callFunctionOn`, `Runtime.getProperties`, `Runtime.releaseObject`
- `src/cdp/domains/network.zig` — verify `Network.getAllCookies` vs `Network.getCookies`, `Network.setCookie`, `Network.deleteCookies`, `Network.clearBrowserCookies`
- `src/cdp/domains/dom.zig` — verify `DOM.getDocument`, `DOM.querySelector`, `DOM.querySelectorAll`
- `src/cdp/domains/target.zig` — verify `Target.createTarget`, `Target.attachToTarget`

Use WebFetch on GitHub raw URLs or `gh api` to read file contents. Look for the method name in the `processMessage` dispatch enum — if it's not there, the method doesn't exist and our gem is calling a non-existent endpoint.

Also check for new methods that could improve the driver (e.g., `Page.addScriptToEvaluateOnNewDocument`, `Input.dispatchMouseEvent`, `DOM.resolveNode`).

### 2e. Release Notes

```bash
gh release list --repo lightpanda-io/browser --limit 5
```

## Step 3: Analyze Impact

For each finding, categorize it:

### Broken: Methods We Call That Don't Exist
Methods listed in "CDP Methods Used by This Gem" that are NOT in upstream source. These are bugs in our gem — we're calling endpoints that don't exist. Flag with specific file and line number in our codebase.

### Workaround Removal Opportunities
Bugs we work around that may now be fixed:
- `Page.loadEventFired` reliability → could simplify `Browser#go_to`
- `Network.clearBrowserCookies` crash → could simplify `Cookies#clear`
- `XPathResult` not implemented → could remove/reduce polyfill
- `Page.handleJavaScriptDialog` not confirmed → could enable modal support

### New CDP Methods Available
Methods that weren't available before but could improve the driver.

### New Bugs or Regressions
Issues that could break our gem or require new workarounds.

### Feature Opportunities
New Lightpanda capabilities that could unlock features in our driver (e.g., frame support, file upload, Web APIs).

## Step 4: Update Rules File

If there are meaningful changes, update `.claude/rules/lightpanda-io.md`:
- Move closed issues out of the "Open Issues" table
- Add newly discovered issues
- Update CDP method support notes
- Update limitation notes for anything that's been fixed
- Flag methods in "CDP Methods Used by This Gem" that don't actually exist upstream
- Add newly available methods to "Available CDP Methods" section

**Important**: Only update facts you've verified. Don't speculatively mark issues as fixed without confirmation.

## Step 5: Generate Report

Present a structured report to the user:

```
## Upstream Sync Report — [date]

### Broken: CDP Methods We Call That Don't Exist
- [ ] `Page.reload` — not in page.zig dispatch enum. Browser#refresh (browser.rb:122) will fail.

### Workarounds to Re-evaluate
- [ ] Issue #XXXX (description) — now CLOSED, test if workaround can be removed

### New Capabilities
- [ ] `Runtime.callFunctionOn` now supported — could replace JS node registry

### New Risks
- [ ] Issue #XXXX — new bug that may affect us

### Rules File Updated
- Changed X, Y, Z in lightpanda-io.md

### Recommended Next Steps
1. [CRITICAL] ...
2. [HIGH] ...
3. [MEDIUM] ...

### Release Readiness (if pre-release audit)
**Safe to release** / **Block release** — with reasoning.
```

## Step 6: Suggest Code Changes (if applicable)

If a workaround can be removed or a new feature can be adopted, describe the specific code change but **do not implement it** unless the user asks. The goal of this skill is reconnaissance and planning, not automatic code changes.
