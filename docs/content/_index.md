---
title: "Capybara::Lightpanda"
---

If you already drive Capybara with `cuprite`, the architecture you've chosen is right — same `page.driver` surface, same Capybara semantics, same DSL. `capybara-lightpanda` is the headless companion that runs alongside it, not a rewrite of how you write tests.

```ruby
# Gemfile — same group, additional gem
group :test do
  gem "cuprite"           # keep for visual specs / pixel diffs
  gem "capybara-lightpanda"
end
```

Wire the driver in your test setup. In Rails 7+ / Rails 8 with system tests:

```ruby
require "capybara-lightpanda"

Capybara::Lightpanda.configure do |config|
  config.host    = "127.0.0.1"
  config.port    = 9222
  config.timeout = 15
end

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :lightpanda
end
```

Install the browser once (or use the official Docker image):

```bash
# macOS
brew install lightpanda-io/lightpanda/lightpanda

# Linux x86_64
curl -L -o lightpanda https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-x86_64-linux
chmod +x lightpanda
```

### Run both, gated by `BROWSER=lightpanda`

The dual-driver pattern lets your CI keep cuprite for the few specs that need pixels while everything else runs on lightpanda. One env var, no rewrites:

```ruby
# spec/support/capybara.rb (or test/support/...)
if ENV["BROWSER"] == "lightpanda"
  require "capybara-lightpanda"

  Capybara::Lightpanda.configure { |c| c.timeout = 15 }

  Capybara.default_driver    = :lightpanda
  Capybara.javascript_driver = :lightpanda
else
  # your existing cuprite (or selenium-chrome) setup
end
```

```bash
# fast headless lane — DOM, forms, Turbo, network, cookies
BROWSER=lightpanda bundle exec rails test test/system/

# pixel lane — visual specs, screenshots, layout-dependent assertions
bundle exec rails test test/system/
```

<aside class="md-callout md-callout--rollback" role="note">
  <span class="md-callout__glyph" aria-hidden="true">↺</span>
  <span class="md-callout__body">
    <strong>Rollback is the env var.</strong>
    Drop <code>BROWSER=lightpanda</code> and your suite returns to Cuprite. <code>Gemfile.lock</code> is the only persistent change — no Capybara registration is touched outside the <code>if</code> branch above.
  </span>
</aside>

In **GitHub Actions** the dual-lane pattern is two short jobs that share a checkout. Drop the binary in once and gate on the env var:

```yaml
# .github/workflows/system_tests.yml
jobs:
  headless:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: ruby/setup-ruby@v1
        with: { ruby-version: "3.3", bundler-cache: true }
      - name: Install Lightpanda
        run: |
          curl -sSL -o /usr/local/bin/lightpanda \
            https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-x86_64-linux
          chmod +x /usr/local/bin/lightpanda
      - run: bundle exec rails test test/system/
        env: { BROWSER: lightpanda }

  visual:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: ruby/setup-ruby@v1
        with: { ruby-version: "3.3", bundler-cache: true }
      - run: bundle exec rails test test/system/   # cuprite / chrome lane
```

### `page.driver` — same surface

If your specs already call into `page.driver` (cookies, network, debug, headers), most of those calls work identically because the API mirrors what cuprite users expect:

```ruby
# Cookies — same names, same shape
page.driver.set_cookie("session_id", value, domain: "127.0.0.1", httpOnly: true)
page.driver.cookies                       # Hash of cookies on the current page
page.driver.clear_cookies
page.driver.remove_cookie("session_id")

# Navigation
page.driver.go_back
page.driver.go_forward
page.driver.refresh

# JS — Capybara's standard methods route through the V8 engine
execute_script "window.example = 'hi'"
evaluate_script "document.title"
```

### In your test suite

Honest numbers from a Rails 8.1 app — Turbo + Stimulus, 24 DOM-only system tests on an M-series laptop:

| Driver         | Tests     | Time   | RSS / worker |
|----------------|-----------|--------|--------------|
| **Lightpanda** | 24 / 24   | 6.89s  | **~17 MB**   |
| **Chrome**     | 24 / 24   | 7.09s  | ~280 MB      |

**Identical results.** On a 24-test suite the wall-clock margin is small — Capybara's own wait time dominates, just as it does on Chrome — so don't read the 3% as "the speed claim." The win that pays for itself is the right column:

- **Memory headroom.** A 2 GB CI runner that hosts one Chromium can host 8–10 lightpanda processes. Parallelism scales where it didn't before.
- **Cold start.** No Skia, no Blink, no GPU process, no compositor — the binary is resident in milliseconds.
- **Less flake.** Removing the Chromium boot removes one of the loudest sources of CI noise.

The upstream **9× / 16×** numbers on this page are reproduced from [lightpanda.io](https://lightpanda.io/) — a 933-page synthetic crawl on AWS m5.large. They show the ceiling at scale; the table above shows the floor on a real Rails suite.

