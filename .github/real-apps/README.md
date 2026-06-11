# Real-apps smoke tests

A matrix of real Rails OSS projects, each patched to swap their headless-browser
driver for `capybara-lightpanda`, run as a GitHub Actions job to catch regressions
against actual production-shape codebases.

## Layout

```
.github/real-apps/
├── README.md                   # this file
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

## Running locally

Make sure Postgres + Redis are reachable, then:

```bash
# clone a target alongside capybara-lightpanda
cd ..
git clone --depth 1 https://github.com/forem/forem
cd forem

# substitute the placeholder and apply
sed "s|__CAPYBARA_LIGHTPANDA_PATH__|$(pwd)/../capybara-lightpanda|g" \
    ../capybara-lightpanda/.github/real-apps/patches/forem.patch | git apply

# from here, follow the project's normal setup
bundle install
yarn install
bin/rails db:create db:schema:load RAILS_ENV=test
bundle exec rspec spec/system/user_views_logo_spec.rb
```

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
