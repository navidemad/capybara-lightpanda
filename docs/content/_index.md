---
title: "Capybara::Lightpanda"
---

## Migrate from Cuprite

`cuprite` drives Chromium over the Chrome DevTools Protocol. Solid, but every test boots a multi-process rendering engine you don't need for headless work. Swap it for `capybara-lightpanda` — same Capybara semantics, no Chromium.

```ruby
# Gemfile — before
group :test do
  gem "cuprite"
end

# Gemfile — after
group :test do
  gem "capybara-lightpanda"
end
```

Then in `test/application_system_test_case.rb` (Rails 7+ / Rails 8):

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

## Compatibility

| Component   | Version                                        |
|-------------|------------------------------------------------|
| Ruby        | ≥ 3.1                                          |
| Rails       | 7.x, **8.x** (Turbo + Stimulus + Solid stack)  |
| Capybara    | ≥ 3.40                                         |
| Lightpanda  | ≥ 0.2.6 (0.2.9 recommended)                    |
| Platforms   | macOS aarch64, Linux x86_64, Linux aarch64     |

## In your test suite

Rails 8.1 app, Turbo + Stimulus, 24 DOM-only system tests:

| Driver         | Tests       | Time   | Speed         |
|----------------|-------------|--------|---------------|
| **Lightpanda** | 24 / 24     | 6.89s  | 3.48 tests/s  |
| **Chrome**     | 24 / 24     | 7.09s  | 3.38 tests/s  |

Identical results, lower wall-clock — and the gap widens dramatically on bigger suites and constrained CI runners (where Chrome's 2 GB headroom matters most).

## Documentation

- [README](https://github.com/navidemad/capybara-lightpanda/blob/main/README.md) — installation, configuration, full API
- [CHANGELOG](https://github.com/navidemad/capybara-lightpanda/blob/main/CHANGELOG.md) — release notes
- [Examples](https://github.com/navidemad/capybara-lightpanda/tree/main/examples) — runnable Rails + RSpec demos
- [Issues](https://github.com/navidemad/capybara-lightpanda/issues) — bug reports and feature requests
- [Lightpanda upstream](https://github.com/lightpanda-io/browser) — the browser that powers this driver
