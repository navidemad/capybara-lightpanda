---
layout: default
title: Capybara::Lightpanda
---

# Capybara::Lightpanda

A [Capybara](https://github.com/teamcapybara/capybara) driver for [Lightpanda](https://lightpanda.io/), the fast headless browser built in Zig.

A **self-contained, production-ready** Capybara driver with a built-in CDP client. No external browser-client gem required — install and go.

[View on GitHub](https://github.com/navidemad/capybara-lightpanda){: .btn }
[View on RubyGems](https://rubygems.org/gems/capybara-lightpanda){: .btn }

## Why

- **Reliable navigation** — falls back to `document.readyState` polling when `Page.loadEventFired` doesn't fire
- **XPath polyfill** — auto-injected so Capybara's internal XPath selectors work (`find`, `click_on`, `fill_in`, `assert_selector`)
- **Cookie management** — `set_cookie`, `clear_cookies`, `remove_cookie` with graceful fallbacks
- **Drop-in Capybara integration** — registers a `:lightpanda` driver, configure and go
- **Turbo Rails** — Turbo Frames work natively; Turbo Drive runs natively via a gem-side `#id` selector polyfill

## Architecture

Similar to how [Cuprite](https://github.com/rubycdp/cuprite) builds on [Ferrum](https://github.com/rubycdp/ferrum), but as a single gem:

```
Capybara → capybara-lightpanda (driver + CDP client) → Lightpanda browser
```

## Quick start

```bash
# 1. Install the Lightpanda browser (macOS)
brew install lightpanda-io/lightpanda/lightpanda
```

```ruby
# 2. Add the gem
group :test do
  gem "capybara-lightpanda"
end
```

```ruby
# 3. Configure
require "capybara-lightpanda"

Capybara::Lightpanda.configure do |config|
  config.host = "127.0.0.1"
  config.port = 9222
  config.timeout = 15
end

Capybara.default_driver = :lightpanda
Capybara.javascript_driver = :lightpanda
```

## Benchmark

Rails 8.1 app (Turbo + Stimulus), 24 DOM-only tests:

| Driver | Tests | Time | Speed |
|--------|-------|------|-------|
| **Lightpanda** | 24/24 pass | 6.89s | 3.48 tests/s |
| **Chrome** | 24/24 pass | 7.09s | 3.38 tests/s |

## Documentation

- [README](https://github.com/navidemad/capybara-lightpanda/blob/main/README.md) — full installation, configuration, and usage
- [CHANGELOG](https://github.com/navidemad/capybara-lightpanda/blob/main/CHANGELOG.md) — release notes
- [Examples](https://github.com/navidemad/capybara-lightpanda/tree/main/examples) — runnable Rails + RSpec demos
- [Issues](https://github.com/navidemad/capybara-lightpanda/issues) — bug reports and feature requests

## License

[MIT License](https://github.com/navidemad/capybara-lightpanda/blob/main/LICENSE.txt)
