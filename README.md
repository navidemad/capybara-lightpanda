<div align="center">

# Capybara::Lightpanda

[![Gem version](https://img.shields.io/gem/v/capybara-lightpanda?logo=rubygems&logoColor=white&label=gem)](https://rubygems.org/gems/capybara-lightpanda)
[![Total downloads](https://img.shields.io/gem/dt/capybara-lightpanda?label=downloads)](https://rubygems.org/gems/capybara-lightpanda)
[![Tests](https://img.shields.io/github/actions/workflow/status/navidemad/capybara-lightpanda/ci.yml?branch=main&logo=github&label=tests)](https://github.com/navidemad/capybara-lightpanda/actions/workflows/ci.yml)
[![Rails compatible](https://img.shields.io/badge/Rails-compatible-CC0000?logo=rubyonrails&logoColor=white)](https://rubyonrails.org/)
[![Turbo friendly](https://img.shields.io/badge/Turbo-friendly-CC0000?logo=hotwire&logoColor=white)](https://turbo.hotwired.dev/)

A [Capybara](https://github.com/teamcapybara/capybara) driver for [Lightpanda](https://lightpanda.io/), the fast headless browser built in Zig.<br>
Self-contained — built-in CDP client, no external browser-client gem required.

<strong>Capybara</strong>&nbsp;&nbsp;→&nbsp;&nbsp;<code>capybara-lightpanda</code>&nbsp;&nbsp;→&nbsp;&nbsp;<a href="https://lightpanda.io/"><img src="docs/static/img/lightpanda-logo.svg" alt="Lightpanda" height="22" valign="middle"></a>&nbsp;<a href="https://github.com/lightpanda-io/browser/stargazers"><img src="https://img.shields.io/github/stars/lightpanda-io/browser?logo=github&label=stars" alt="GitHub stars" valign="middle"></a>

[![Capybara::Lightpanda — faster system tests for Rails, without Chromium](docs/static/img/banner.png)](https://navidemad.github.io/capybara-lightpanda/)
<sub><em>Configuration · dual-driver setups · Turbo Rails · capability matrix · beta-testing guide</em></sub>

[![Read the docs](https://img.shields.io/badge/https%3A%2F%2Fnavidemad.github.io%2Fcapybara--lightpanda-→%20Visit%20the%20website-1F2937?style=for-the-badge)](https://navidemad.github.io/capybara-lightpanda/)

</div>

## Requirements

| | |
|---|---|
| **Ruby** | ≥ 3.3 — CI covers 3.3 and 4.0 |
| **Capybara** | ≥ 3.0, < 5 |
| **Platforms** | Linux `x86_64` · Linux `aarch64` · macOS Apple Silicon · macOS Intel · Windows through WSL2 (no native Windows build upstream) |

An unsupported host raises `UnsupportedPlatformError` at boot, naming what it detected — it never fails halfway through a suite.

## Install

Add this to your `Gemfile` and run `bundle install`:

```ruby
group :test do
  gem "capybara-lightpanda"
end
```

In your test setup:

```ruby
require "capybara-lightpanda"
Capybara.javascript_driver = :lightpanda

# Rails system tests don't read Capybara.javascript_driver — use driven_by:
driven_by :lightpanda
```

> [!TIP]
> The Lightpanda binary is auto-downloaded on first use — no separate install step needed.

> [!IMPORTANT]
> Lightpanda is a headless agentic browser, not a layout engine. External `<link rel="stylesheet">` **are** fetched and applied (the gem enables this by default), and `@media` / `window.matchMedia()` evaluate against the `window_size` you configure — so a mobile-only CTA gated by `@media (max-width: …)` resolves at the width you ask for. What's missing is *layout*: nothing reflows, `getBoundingClientRect` stays synthetic, and there is no real scroll. Specs that assert on pixel geometry, scrolling, or screenshots — plus the two that catch people out, a second browser tab and a menu revealed purely by CSS `:hover` — should stay on Cuprite (or whichever full-browser driver you were already using). The [per-spec dual-driver setup](https://navidemad.github.io/capybara-lightpanda/docs/#dual-per-spec) routes that minority to Cuprite and the structural majority to Lightpanda for speed.

> [!TIP]
> For reproducible CI, pin the browser: `Capybara::Lightpanda::Binary.required_version = "0.4.0"` (the tagged release the gem's current floor is pinned to — nightly build 9058 is that release's commit). Without a pin the driver tracks Lightpanda's rolling `nightly` tag, which moves under you. See [Pinning the browser version](https://navidemad.github.io/capybara-lightpanda/docs/#pinning).

## Credits

- [Lightpanda](https://lightpanda.io/) — the headless browser
- [Capybara](https://github.com/teamcapybara/capybara) — the test framework
- Inspired by the [Cuprite](https://github.com/rubycdp/cuprite) / [Ferrum](https://github.com/rubycdp/ferrum) architecture and [`lightpanda-ruby`](https://github.com/marcoroth/lightpanda-ruby)

Patterns adapted from these MIT-licensed projects (cookies API, frame switching, node call/error conventions, retry/event utilities) are acknowledged with the original copyright notices in [NOTICE.md](NOTICE.md).

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/navidemad/capybara-lightpanda).<br>
For beta-testing tips and how to file useful feedback, see [BETA_TESTING.md](BETA_TESTING.md).

## License

[MIT License](LICENSE.txt)
