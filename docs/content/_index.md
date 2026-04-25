---
title: "Capybara::Lightpanda"
---

## Pair with Cuprite

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

## Compatibility &amp; status

| Component   | Required           | Tested with           |
|-------------|--------------------|-----------------------|
| Ruby        | ≥ 3.3              | 3.3, 4.0              |
| Capybara    | ≥ 3.0              | 3.40+                 |
| Rails       | _(driver-agnostic)_ | 7.x, 8.0, 8.1        |
| Lightpanda  | nightly or ≥ 0.2.6 | nightly (2026-04-24)  |

**Status.** `0.1.0` — public beta. The CDP surface is stable; Lightpanda upstream is moving fast and changes land here often. Released under the **MIT** license.

**Where the driver falls back to a workaround** (so you know what you're trusting):

- **XPath** — polyfilled in JS (~80% selector coverage). Native `XPathResult` doesn't exist in Lightpanda yet.
- **Navigation** — `Page.loadEventFired` is unreliable upstream, so the gem polls `document.readyState` as a fallback.
- **History** — `back` / `forward` route through `history.back()` / `forward()` JS (the CDP methods are missing upstream).
- **Cookies** — `Network.clearBrowserCookies` works on ≥ 0.2.6; older binaries fall back to per-cookie deletes.

If a spec hits something genuinely unsupported (file uploads, real screenshots), the driver raises `Capybara::NotImplementedError` so you can `skip` it cleanly. The full matrix is in [§06](#capabilities).

## In your test suite

Honest numbers from a Rails 8.1 app — Turbo + Stimulus, 24 DOM-only system tests on an M-series laptop:

| Driver         | Tests     | Time   | Speed         | RSS / worker |
|----------------|-----------|--------|---------------|--------------|
| **Lightpanda** | 24 / 24   | 6.89s  | 3.48 tests/s  | **~17 MB**   |
| **Chrome**     | 24 / 24   | 7.09s  | 3.38 tests/s  | ~280 MB      |

**Identical results.** On a 24-test suite the wall-clock margin is small — Capybara's own wait time dominates, just as it does on Chrome — so don't read the 3% as "the speed claim." The win that pays for itself is the right column:

- **Memory headroom.** A 2 GB CI runner that hosts one Chromium can host 8–10 lightpanda processes. Parallelism scales where it didn't before.
- **Cold start.** No Skia, no Blink, no GPU process, no compositor — the binary is resident in milliseconds.
- **Less flake.** Removing the Chromium boot removes one of the loudest sources of CI noise.

The upstream **9× / 16×** numbers on this page are reproduced from [lightpanda.io](https://lightpanda.io/) — a 933-page synthetic crawl on AWS m5.large. They show the ceiling at scale; the table above shows the floor on a real Rails suite.

## Documentation

- [README](https://github.com/navidemad/capybara-lightpanda/blob/main/README.md) — installation, configuration, full API
- [CHANGELOG](https://github.com/navidemad/capybara-lightpanda/blob/main/CHANGELOG.md) — release notes
- [Examples](https://github.com/navidemad/capybara-lightpanda/tree/main/examples) — runnable Rails demos covering both **RSpec** and **Minitest**, with and without **Turbo**:
  - [`rails_minitest_example.rb`](https://github.com/navidemad/capybara-lightpanda/blob/main/examples/rails_minitest_example.rb) — Rails system test with Minitest
  - [`rails_rspec_example.rb`](https://github.com/navidemad/capybara-lightpanda/blob/main/examples/rails_rspec_example.rb) — Rails system spec with RSpec
  - [`rails_turbo_minitest_example.rb`](https://github.com/navidemad/capybara-lightpanda/blob/main/examples/rails_turbo_minitest_example.rb) — Rails + Turbo Drive/Frames with Minitest
  - [`rails_turbo_rspec_example.rb`](https://github.com/navidemad/capybara-lightpanda/blob/main/examples/rails_turbo_rspec_example.rb) — Rails + Turbo Drive/Frames with RSpec
- [Issues](https://github.com/navidemad/capybara-lightpanda/issues) — bug reports and feature requests
- [Lightpanda upstream](https://github.com/lightpanda-io/browser) — the browser that powers this driver
