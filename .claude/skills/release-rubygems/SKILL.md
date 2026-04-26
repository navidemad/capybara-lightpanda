---
name: release-rubygems
description: Cut a new release of the capybara-lightpanda gem end-to-end — bump version.rb, prepend a CHANGELOG section drafted from commits since the last tag, run the same pre-flight as CI (rubocop + spec:unit), commit, push, tag, and surface the GitHub Actions URL so the user can approve the rubygems environment. Use this skill whenever the user says "cut a release", "release the gem", "ship the gem", "ship 0.2.0" / any specific version, "bump and release", "tag a new version of capybara-lightpanda", "publish to rubygems", or otherwise signals they want to push a new version of capybara-lightpanda to RubyGems via the Trusted Publishing workflow. Do NOT use for: editing CHANGELOG.md outside a release flow, bumping VERSION without releasing, releases of any other gem (this skill is hardcoded to capybara-lightpanda and refuses to run elsewhere), or fixing a release that already failed mid-flight (handle that manually — the steps here are not idempotent past the tag push).
user_invocable: true
model: opus
effort: max
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

```bash
bundle exec rubocop
bundle exec rake spec:unit
```

Optional but cheap: `gem build capybara-lightpanda.gemspec && rm capybara-lightpanda-*.gem`. Catches gemspec errors (missing files, validation warnings) that the workflow doesn't explicitly check but RubyGems will reject at push time. Skip only if the user is in a hurry.

If anything fails: stop, surface the error, do not commit. The repo is still clean (only version.rb + CHANGELOG.md edited, both reversible with `git checkout --`).

## Step 5 — Commit, push, tag, push tag

This is the point of no return for the **tag push** specifically. Stage and commit first (recoverable), push the bump commit (mostly recoverable via revert), then tag and push the tag (the workflow runs immediately).

```bash
git add -u            # stages version.rb, CHANGELOG.md, and every version-bearing file edited in step 3
git status            # sanity-check that no untracked files are being missed
git commit -m "Release X.Y.Z"
git push origin main
git tag vX.Y.Z
git push origin vX.Y.Z
```

`git add -u` only stages tracked files that you've modified — safer than `git add .` (which would also pick up untracked junk) but it does require every version-bearing file to already be tracked. If the bump touched a brand-new file (rare), add it explicitly.

Don't squash these into one compound command — if `git push origin main` fails because someone else pushed in the meantime, you want to stop before tagging.

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
Fix the issue, recommit, and re-tag.
```

Resolve `<owner>` from `git config --get remote.origin.url` (extract the github.com path). Don't hardcode it — the user might fork.

## Things this skill does NOT do

- **It does not edit the gemspec.** Dependencies, metadata, descriptions stay where they are. If those need to change, that's a separate PR before the release.
- **It does not bump dev dependencies** in `Gemfile.lock`. Lockfile churn during a release is noise.
- **It does not write release notes anywhere except CHANGELOG.md.** The GitHub Release body is auto-generated by `rubygems/release-gem@v1` from the commit list — duplicating that here is busywork.
- **It does not handle yanking, hotfix branches, or release-from-non-main.** Out of scope; do those by hand if needed.
- **It does not poll the workflow run.** Watching the Actions tab is a human's job; polling burns tokens for no benefit.

## When something goes sideways

- **Pre-flight fails locally** — abort, fix, retry. Nothing was committed.
- **`git push origin main` rejected** — someone pushed while you were preparing. `git pull --rebase origin main`, re-run the pre-flight (the rebase may have introduced conflicts), continue.
- **Tag pushed but workflow fails before publish** — delete the tag locally and on origin (commands above), fix the issue, recommit, re-tag with the same version (you haven't burned the version because the gem wasn't pushed to rubygems.org yet).
- **Gem pushed to rubygems.org but you regret it** — that version is permanent. Yank it from rubygems.org if it's actively harmful, otherwise just bump and release the next version with a fix. Trusted Publishing doesn't change this.
