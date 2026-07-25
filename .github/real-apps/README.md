# Real-apps smoke tests

A matrix of real Rails OSS projects, each patched to swap their headless-browser
driver for `capybara-lightpanda`, run as a GitHub Actions job to catch regressions
against actual production-shape codebases.

## Layout

```
.github/real-apps/
├── README.md                   # this file
├── causes.yml                  # why each baseline failure fails
└── patches/
    ├── forem.patch             # was on Cuprite
    ├── solidus.patch           # was on Selenium
    ├── spree.patch             # was on Selenium
    ├── decidim.patch           # was on Selenium
    ├── mastodon.patch          # was on Playwright
    └── alonetone.patch         # was on Playwright (MySQL app)

.github/workflows/
└── real-apps.yml               # matrix workflow
```

## How a patch is structured

Each patch is a `git diff HEAD` against the upstream SHA pinned in
`.github/workflows/real-apps.yml`. Patches reference the gem's checkout path
through the placeholder `__CAPYBARA_LIGHTPANDA_PATH__`; the workflow substitutes
it with `$GITHUB_WORKSPACE/capybara-lightpanda` at apply time so the `path:`
Gemfile entry resolves to the runner-side checkout.

## Why the failures fail

A baseline records *that* something fails, never *why*, and a file of
undiagnosed lines looks exactly like a file of understood limitations. Only one
of those is safe to ship on.

`causes.yml` closes that gap: each cause carries a summary, a confidence
(`confirmed` / `likely` / `unknown`), an optional reference to the wishlist or
an upstream issue, and the regexps that match it against the baseline key and
the run's failure message. `check_baseline.rb` prints the per-cause tally and
lists anything matching no cause:

```
Known failures by cause:
  layout-measuring-js           38  (confirmed)
  select2-v3-flow               16  (likely)
  ajax-partial-not-applied       6  (likely)
  multipart-content-loss         5  (confirmed)
  search-returns-nothing         2  (unknown)
  selenium-only-api              1  (confirmed)
```

The number to drive down is the unattributed count, then the `unknown` and
`likely` confidences. Causes live here rather than in the baselines because
`REFRESH=1` rewrites those wholesale.

## Running locally

Use the boot harness — it is this workflow ported step for step, reading the
matrix out of `real-apps.yml` so it can never drift from CI:

```bash
script/real-app/boot.sh solidus                    # checkout, patch, bundle, dummy app, binary
script/real-app/spec.sh solidus \
  spec/features/admin/orders/order_details_spec.rb \
  -e "should allow me to make a split"
```

`spec.sh` attaches the gem's instruments (`console_logs`, `network.traffic`) to
every failing example and then reports whether the failure is in this target's
baseline and which `causes.yml` entry it matches. See
[`script/real-app/README.md`](../../script/real-app/README.md).

Doing it by hand is still four commands — clone the pinned SHA, substitute
`__CAPYBARA_LIGHTPANDA_PATH__` into the patch, `git apply`, then follow the
project's own setup — but the traps (per-target Ruby, `work_dir` vs `spec_dir`,
pre-provisioning the binary before WebMock loads) are what the harness exists to
carry.

## Refreshing a patch when upstream moves

1. `cd target-repo && git checkout main && git pull`
2. Re-apply the patch (or redo the swap manually if it conflicts)
3. `git diff HEAD -- <changed files> > patch`
4. `sed -i '' 's|<your-local-path>|__CAPYBARA_LIGHTPANDA_PATH__|g' patch`
5. Update the `sha:` in `real-apps.yml` to the new upstream HEAD
6. Move the patch into `.github/real-apps/patches/`

## What the workflow runs

A small, fast subset per target — enough to prove the swap works and the gem
boots a Lightpanda process, not a full suite. See `spec:` in each matrix entry
for the exact files. Broader local results (~89% pass on Forem, 77% on Solidus,
47% on Spree, mostly-clean on Decidim) are documented in
[`TESTING_PROGRESS.md`](https://github.com/.../TESTING_PROGRESS.md) of the
exercise scratch directory.
