---
name: release-rubygems
description: Cut a new release of the capybara-lightpanda gem end-to-end — bump version.rb, prepend a CHANGELOG section drafted from commits since the last tag, run the same pre-flight as CI (rubocop + test:unit), commit the bump on a release branch, merge a release PR, tag the squash-merge SHA, push the tag, and surface the GitHub Actions URL so the user can approve the rubygems environment. Use this skill whenever the user says "cut a release", "release the gem", "ship the gem", "ship 0.2.0" / any specific version, "bump and release", "tag a new version of capybara-lightpanda", "publish to rubygems", or otherwise signals they want to push a new version of capybara-lightpanda to RubyGems via the Trusted Publishing workflow. Do NOT use for: editing CHANGELOG.md outside a release flow, bumping VERSION without releasing, releases of any other gem (this skill is hardcoded to capybara-lightpanda and refuses to run elsewhere), or fixing a release that already failed mid-flight (handle that manually — the steps here are not idempotent past the tag push).
user_invocable: true
model: opus
effort: high
---

# Release capybara-lightpanda

Drives the human-side steps of cutting a new release. The actual publish to RubyGems happens in `.github/workflows/release.yml` via OIDC trusted publishing once the `vX.Y.Z` tag lands on origin. This skill's job is to land that tag with everything the workflow's pre-flight will check already in place — so the run goes green on the first try.

The skill is deliberately repo-specific. Releasing other gems works differently (different version path, changelog conventions, workflow); generalizing prematurely would make this less reliable, not more.

## Preconditions — refuse if any fails

Run all of these before touching anything. If any check fails, stop and tell the user what's wrong; do not proceed.

1. **Right repo** — `pwd` must end in `capybara-lightpanda` AND `capybara-lightpanda.gemspec` must exist in the working directory. If not, refuse with: "This skill only releases capybara-lightpanda. cd into that repo and try again."
2. **Workflow exists** — `.github/workflows/release.yml` must exist. If missing, refuse: the trusted-publishing workflow is the whole point.
3. **On main, clean tree** — `git rev-parse --abbrev-ref HEAD` is `main`, `git status --porcelain` is empty.
4. **Up-to-date with origin** — `git fetch origin` then verify `git rev-list --count HEAD..origin/main` is 0 (no remote commits ahead) and `git rev-list --count origin/main..HEAD` is 0 (no unpushed commits — those would be released as part of the bump commit and surprise the user).
5. **Tag doesn't already exist** — for the computed `vX.Y.Z`, `git rev-parse "vX.Y.Z" 2>/dev/null` must fail AND `git ls-remote --tags origin "refs/tags/vX.Y.Z"` must return empty. If either exists, refuse — don't reuse a version.

## Step 1 — Determine the next version

Read `lib/capybara/lightpanda/version.rb` and parse the `VERSION = "X.Y.Z"` constant.

If the user named a specific version in their request ("ship 0.2.0", "release 1.0.0"), use that — but still validate it's strictly greater than the current one (refuse on downgrade or same-version).

Otherwise, ask: "Current version is X.Y.Z. Patch (X.Y.Z+1), minor (X.Y+1.0), or major (X+1.0.0)?" Take their answer and compute the next version. Don't proceed without an explicit choice — guessing here costs an unrecoverable version number.

Pre-release suffixes (`0.2.0.beta1`, `1.0.0.rc1`) are out of scope. If the user explicitly asks for one, hand off — the workflow's tag-matches-version regex assumes plain `X.Y.Z`.

## Step 2 — Draft the CHANGELOG entry

Find the last release tag with `git describe --tags --abbrev=0 --match 'v*'`. The 0.1.0 release is already in the file, so this skill always has a prior tag to diff against.

Get the commits since that tag:

```bash
git log <last-tag>..HEAD --pretty=format:'%h %s' --no-merges
```

Group them into Keep-a-Changelog sections. Use these section names, in this order, omitting any that are empty:

- **Added** — new public API (new methods on Driver/Browser/Node/Cookies, new options)
- **Changed** — behavior changes to existing public API
- **Fixed** — bug fixes (anything fixing a workaround, a Lightpanda quirk, a CDP edge case)
- **Removed** — deprecations finalized, removed APIs
- **Internal** — refactors, test infra, doc updates that don't affect users

Use commit-message intent (and the diff if a message is ambiguous) to bin commits. Squash near-duplicates ("Apply review feedback", "Fix rubocop") into the entry they belong to or drop them if purely internal noise.

Note: the existing 0.1.0 entry uses topical headings (Driver, CDP client, Cookies, etc.) because it's a first-release inventory. From 0.2.0 onward, use Keep-a-Changelog Added/Changed/Fixed — that's the more useful framing for incremental releases. Don't mimic 0.1.0's structure.

**Write for the audience: Rails developers using the gem to test their apps.** They are NOT browser engineers. They want to know what changed _in their test suite_, not what happened in the engine. Apply these rules:

- **Cite behavior, not mechanisms.** "Form interactions are more reliable on Turbo Drive pages" beats "drop CLICK_JS fetch+swap workaround now that Frame.submitForm calls scheduleNavigationWithArena natively". The reader doesn't know what `CLICK_JS` is — they know whether their `click_button` tests pass.
- **No upstream PR numbers.** Phrases like "PR #2261", "upstream PR #2342", "via Lightpanda PR" are noise to a Rails dev. They don't open the Lightpanda repo. State the user-visible result and stop.
- **No Zig / V8 / CDP / "polyfill" / "wishlist" jargon.** If a sentence requires the reader to know what `Page.handleJavaScriptDialog` is, or what a "JS bundle injected via `Page.addScriptToEvaluateOnNewDocument`" means, rewrite it as the observable behavior change.
- **Frame Removed entries as "no code change required on your end".** When a polyfill leaves the gem because Lightpanda now does it natively, the user-facing impact is _nothing changes for them_ — emphasize that, don't enumerate every dropped helper.
- **Lead with the upgrade action, if any.** "Update Lightpanda before upgrading" or "Driver options moved" should land in the first sentence of the section heading or as a top-of-entry note, not buried in a bullet.
- **Default to fewer bullets, denser prose.** A single sentence covering "modals now actually drive the JS return value end-to-end" beats three bullets explaining the pre-arm flow.
- **Skip-pattern bookkeeping is not a feature.** "13+ obsolete skip patterns dropped" tells the reader nothing actionable. Either name the _capability_ now working ("Capybara's `#has_field with valid` specs now pass") or omit it.
- **Internal section is for things the reader might still notice but doesn't act on** — README redesign, test infra rewrites. Keep it short. CI changes, sync-upstream audits, wishlist tracking, and skill refinements belong nowhere in the user-facing changelog.

Show the user the draft as a fenced markdown block and ask: "Edit anything? Reply 'looks good' to apply, or paste the revised version." Iterate until they approve. Don't write to CHANGELOG.md before approval — easier to keep iterating in chat than to edit-and-revert.

## Step 3 — Apply the bump

Once the user approves the changelog draft:

1. Edit `lib/capybara/lightpanda/version.rb` — replace the version string with the new one. This is the canonical source.
2. Edit `CHANGELOG.md` — insert the new section directly under the `# Changelog` header (above the previous most-recent entry). Heading format: `## [X.Y.Z] - YYYY-MM-DD`, where the date is **today** (use `date +%Y-%m-%d`, not a remembered date — release date matters for the changelog, and remembered dates are often stale).
3. Bump every other file that mirrors the version. Find them with:

   ```bash
   grep -rn "version-bearing" --exclude-dir=.git --exclude-dir=public --exclude-dir=resources .
   ```

   Each match is a sentinel comment placed directly **above** a line containing the literal old version string. For each match, replace the old version with the new on the next non-blank line. As of now the sentinels live in:

   - `docs/hugo.toml` — `[params].version` (the docs site reads this via `{{ .Site.Params.version }}` in `layouts/index.html`; bumping the param updates both the hero and footer pills)
   - `BETA_TESTING.md` — the prose mention in the opening paragraph
   - `.github/ISSUE_TEMPLATE/beta-feedback.yml` — the `placeholder:` for the gem-version field

   Don't grep-and-replace the old version repo-wide — `CHANGELOG.md` legitimately mentions every past version (`## [0.1.0]`, etc.) and a blanket replace would corrupt the history.

   If a future version-bearing reference is added somewhere new, mark it with a `# version-bearing — keep in sync with lib/capybara/lightpanda/version.rb` comment (HTML comment in markdown, `#` in TOML/YAML) directly above the line. The grep above will then find it on the next release without anyone updating this skill.

Show a `git diff` of all touched files for the user to skim before any commit happens.

## Step 4 — Run the workflow's pre-flight locally

The `.github/workflows/release.yml` will run these on the runner; running them locally first means a failure here is recoverable (just abort), but a failure on the runner after the tag is pushed is not.

The exact commands that the workflow runs (and that we mirror locally):

```bash
bundle install            # if gems aren't already installed
bundle exec rubocop
bundle exec rake test:unit
```

Note: it's `rake test:unit`, NOT `rake spec:unit` — the local Minitest suite. RSpec (`rake spec:shared`) is only the Capybara shared-spec battery and is not part of the release pre-flight.

`bundle install` will also rewrite `Gemfile.lock` to update the path-gem self-reference (`capybara-lightpanda (X.Y.Z)`) to the new version — that line MUST be included in the release commit; see Step 5.

Optional but cheap: `gem build capybara-lightpanda.gemspec && rm capybara-lightpanda-*.gem`. Catches gemspec errors (missing files, validation warnings) that the workflow doesn't explicitly check but RubyGems will reject at push time. Skip only if the user is in a hurry.

If anything fails: stop, surface the error, do not commit. The repo is still clean (only version.rb + CHANGELOG.md + version-bearing files + Gemfile.lock edited, all reversible with `git checkout --`).

## Step 5 — Commit on a release branch, merge PR, tag, push tag

This is the point of no return for the **tag push** specifically. The bump lands on `main` via a release branch + PR (the global `~/.claude/hooks/block-git-danger.sh` refuses direct `git commit`/`push` on `main`/`master`). Then we tag the squash-merge SHA from the still-checked-out release branch — staying off `main` is what lets the tag push through.

```bash
# Stage the bump
git add -u                                  # version.rb, CHANGELOG.md, version-bearing files, Gemfile.lock
git status                                  # sanity-check nothing untracked is being missed

# Land the bump on main via PR
git checkout -b release/vX.Y.Z
git commit -m "Release X.Y.Z"
git push -u origin release/vX.Y.Z
gh pr create --title "Release X.Y.Z" --body "$(cat <<'EOF'
Version bump for X.Y.Z. After merge, the `vX.Y.Z` tag will be pushed to trigger the trusted-publishing workflow.

See `CHANGELOG.md` for the user-facing summary.
EOF
)"
gh pr merge <pr-number> --squash --delete-branch=false   # keep the local branch — needed for the tag push below

# Tag the squash-merge SHA on main (NOT the local release-branch SHA — squash creates a different commit)
git fetch origin
git tag vX.Y.Z origin/main
git push origin vX.Y.Z
```

A few non-obvious notes:

- **`git add -u`** only stages tracked files that you've modified — safer than `git add .` (which would also pick up untracked junk) but it does require every version-bearing file to already be tracked. If the bump touched a brand-new file (rare), add it explicitly.
- **`gh pr merge --delete-branch=false`** is deliberate. The deletion would auto-switch your working copy back to `main`, and the next `git push origin vX.Y.Z` would then be blocked by the hook. Keep the release branch checked out until the tag is pushed; clean it up in Step 6.
- **Tag `origin/main`, not `HEAD`.** A squash merge creates a new commit on `main` with a different SHA than your local release-branch commit; the workflow runs against the tagged commit, so you want the tag pointing at the canonical `main` SHA, not your unmerged feature commit.
- **Don't squash these into one compound command.** If `git push -u origin release/vX.Y.Z` is rejected because the branch already exists, or if `gh pr merge` fails because CI hasn't passed, you want to stop before tagging.

## Step 6 — Surface the workflow URL and what to do next

Print, exactly:

```
Tag vX.Y.Z pushed. The release workflow is running:

  https://github.com/<owner>/capybara-lightpanda/actions/workflows/release.yml

Next steps:
1. Watch the pre-flight + test jobs pass.
2. The job will pause at the 'rubygems' environment if you set required reviewers.
   Click "Review deployments" → Approve.
3. rubygems/release-gem@v1 will publish to rubygems.org via OIDC and create
   a GitHub Release. No further action needed once approved.

If pre-flight fails on the runner (shouldn't — we ran it locally), the tag is
still on origin. Delete it with:
  git push origin :refs/tags/vX.Y.Z && git tag -d vX.Y.Z
Fix the issue, recommit (on a new release branch — the original PR is already merged), and re-tag.

Once the workflow is green, clean up the release branch:
  git checkout main && git pull --ff-only && git branch -D release/vX.Y.Z && git push origin :release/vX.Y.Z
```

Resolve `<owner>` from `git config --get remote.origin.url` (extract the github.com path). Don't hardcode it — the user might fork.

## Things this skill does NOT do

- **It does not edit the gemspec.** Dependencies, metadata, descriptions stay where they are. If those need to change, that's a separate PR before the release.
- **It does not bump dev dependencies** in `Gemfile.lock`. Lockfile churn during a release is noise. The one exception is the path-gem self-reference (`capybara-lightpanda (X.Y.Z)`), which bundler rewrites automatically and which MUST be included in the release commit for the lockfile to stay valid.
- **It does not write release notes anywhere except CHANGELOG.md.** The GitHub Release body is auto-generated by `rubygems/release-gem@v1` from the commit list — duplicating that here is busywork.
- **It does not handle yanking, hotfix branches, or release-from-non-main.** Out of scope; do those by hand if needed.
- **It does not poll the workflow run.** Watching the Actions tab is a human's job; polling burns tokens for no benefit.

## When something goes sideways

- **Pre-flight fails locally** — abort, fix, retry. Nothing was committed.
- **`gh pr create` or `gh pr merge` fails** — likely because CI required by branch protection hasn't run yet, or someone else merged in the meantime. Resolve via the PR UI (wait for checks, rebase the release branch via `git fetch origin && git rebase origin/main` + force-push the release branch, etc.) and retry the merge. Do NOT tag until the PR is actually merged into `origin/main`.
- **You accidentally checked out `main` before pushing the tag** — `git push origin vX.Y.Z` will be blocked by the global hook. Either `git checkout release/vX.Y.Z` (still exists because we passed `--delete-branch=false`) and retry, or `git checkout -b tag-helper origin/main` from any name and push from there.
- **Tag pushed but workflow fails before publish** — delete the tag locally and on origin (commands above), fix the issue, open a NEW release PR with the fix (the original release PR is already merged — do not try to amend it), and re-tag with the same version (you haven't burned the version because the gem wasn't pushed to rubygems.org yet).
- **Gem pushed to rubygems.org but you regret it** — that version is permanent. Yank it from rubygems.org if it's actively harmful, otherwise just bump and release the next version with a fix. Trusted Publishing doesn't change this.
