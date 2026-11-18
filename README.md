# Capybara::Lightpanda

[![Gem version](https://img.shields.io/gem/v/capybara-lightpanda?logo=rubygems&logoColor=white&label=gem)](https://rubygems.org/gems/capybara-lightpanda)
[![Total downloads](https://img.shields.io/gem/dt/capybara-lightpanda?label=downloads)](https://rubygems.org/gems/capybara-lightpanda)
[![Tests](https://img.shields.io/github/actions/workflow/status/navidemad/capybara-lightpanda/ci.yml?branch=main&logo=github&label=tests)](https://github.com/navidemad/capybara-lightpanda/actions/workflows/ci.yml)
[![Rails compatible](https://img.shields.io/badge/Rails-compatible-CC0000?logo=rubyonrails&logoColor=white)](https://rubyonrails.org/)
[![Turbo friendly](https://img.shields.io/badge/Turbo-friendly-CC0000?logo=hotwire&logoColor=white)](https://turbo.hotwired.dev/)

A [Capybara](https://github.com/teamcapybara/capybara) driver for [Lightpanda](https://lightpanda.io/), the headless browser built in Zig. Same Capybara DSL, no Chromium to install, boot or keep in memory: ~17 MB per worker against ~280 MB for Chrome on a 24-test Rails 8.1 suite, at the same wall-clock time (6.89s vs 7.09s).

Self-contained: the CDP client is built in, no external browser-client gem required. The driver runs weekly against the specs of [seven production Rails apps](https://navidemad.github.io/capybara-lightpanda/docs/#validation).

**[Documentation](https://navidemad.github.io/capybara-lightpanda/docs/)** — configuration · setup recipes · Turbo Rails · known limitations · troubleshooting

## Install

Add this to your `Gemfile` and run `bundle install`:

```ruby
group :test do
  gem "capybara-lightpanda"
end
```

The driver registers itself as `:lightpanda`, and the Lightpanda binary is downloaded on first use — no separate install step.

**Rails system tests**

```ruby
# test/application_system_test_case.rb
require "test_helper"
require "capybara-lightpanda"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :lightpanda
end
```

**RSpec, or Capybara on its own**

```ruby
# spec/support/capybara.rb
require "capybara-lightpanda"

Capybara.javascript_driver = :lightpanda

# rspec-rails system specs don't read javascript_driver either:
RSpec.configure do |config|
  config.before(:each, type: :system) { driven_by :lightpanda }
end
```

## Configure

Every option has a working default; set only what you need:

```ruby
Capybara::Lightpanda.configure do |config|
  config.window_size = [375, 812] # what @media / matchMedia evaluate against (default 1920×1080)
  config.timeout = 30             # per-command and navigation timeout, in seconds (default 15)
end
```

All options are listed under [Configuration](https://navidemad.github.io/capybara-lightpanda/docs/#configuration).

> [!TIP]
> The gem downloads the Lightpanda release it was validated against (currently 1.0.4), so the browser only changes when you upgrade the gem. If your suite stubs HTTP (VCR/WebMock), run `bundle exec capybara-lightpanda install` in `bin/setup` and in CI before the tests. To pick another release or the rolling nightly, see [Choosing the browser version](https://navidemad.github.io/capybara-lightpanda/docs/#pinning).

## What won't pass

Lightpanda is a headless browser without a layout engine. External stylesheets are fetched and applied, and `@media` / `matchMedia` resolve at the `window_size` you configure — but nothing reflows. Specs that depend on any of these can't pass here:

- pixel geometry (`getBoundingClientRect` is synthetic)
- real scrolling
- screenshots
- a second browser tab or window
- a menu revealed purely by CSS `:hover`

See [known limitations](https://navidemad.github.io/capybara-lightpanda/docs/#limits) for the full list.

## Examples

Runnable single-file Rails demos live in [`examples/`](examples/): [Minitest](examples/rails_minitest_example.rb), [RSpec](examples/rails_rspec_example.rb), Turbo Drive + Frames ([Minitest](examples/rails_turbo_minitest_example.rb) · [RSpec](examples/rails_turbo_rspec_example.rb)), and a [click-to-open dropdown](examples/rails_dropdown_minitest_example.rb).

## Upgrading

A gem release can raise the minimum Lightpanda version it accepts; the driver refuses an older browser and names the version it found. Read [CHANGELOG.md](CHANGELOG.md) before bumping.

## Credits

- [Lightpanda](https://lightpanda.io/) — the headless browser
- [Capybara](https://github.com/teamcapybara/capybara) — the test framework
- Inspired by the [Ferrum](https://github.com/rubycdp/ferrum) architecture and [`lightpanda-ruby`](https://github.com/marcoroth/lightpanda-ruby)

Patterns adapted from these MIT-licensed projects (cookies API, frame switching, node call/error conventions, retry/event utilities) are acknowledged with the original copyright notices in [NOTICE.md](NOTICE.md).

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/navidemad/capybara-lightpanda).<br>
For beta-testing tips and how to file useful feedback, see [BETA_TESTING.md](BETA_TESTING.md).

## License

[MIT License](LICENSE.txt)
