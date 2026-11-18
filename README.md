# Capybara::Lightpanda

[![Gem version](https://img.shields.io/gem/v/capybara-lightpanda?logo=rubygems&logoColor=white&label=gem)](https://rubygems.org/gems/capybara-lightpanda)
[![Total downloads](https://img.shields.io/gem/dt/capybara-lightpanda?label=downloads)](https://rubygems.org/gems/capybara-lightpanda)
[![Tests](https://img.shields.io/github/actions/workflow/status/navidemad/capybara-lightpanda/ci.yml?branch=main&logo=github&label=tests)](https://github.com/navidemad/capybara-lightpanda/actions/workflows/ci.yml)

A [Capybara](https://github.com/teamcapybara/capybara) driver for [Lightpanda](https://lightpanda.io/), a headless browser written in Zig.

You keep the Capybara DSL you already use. You do not install Chromium, and your tests do not start it. Each test worker uses about 17 MB of memory. With Chrome, a worker uses about 280 MB. We measured this on a Rails 8.1 app with 24 system tests. Both drivers took about 7 seconds.

The gem includes its own CDP client, so you do not need another browser gem. Every week, CI runs the driver against the tests of [seven real Rails apps](https://navidemad.github.io/capybara-lightpanda/docs/#validation).

```ruby
# Gemfile
gem "capybara-lightpanda", group: :test

# test/application_system_test_case.rb
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :lightpanda
end
```

> [!IMPORTANT]
> Lightpanda does not compute page layout. Tests that need screenshots, pixel positions or real scrolling will fail. See [Limits](#limits).

**[Documentation](https://navidemad.github.io/capybara-lightpanda/docs/)** — configuration · setup recipes · Turbo Rails · known limitations · troubleshooting

## Install

A Rails app only needs the two snippets above. Run `bundle install`. The gem registers the driver under the name `:lightpanda`. The gem downloads the Lightpanda browser the first time you run a test.

With RSpec, or with Capybara outside Rails, use this instead:

```ruby
# spec/support/capybara.rb
require "capybara-lightpanda"

Capybara.javascript_driver = :lightpanda

# rspec-rails system specs pick their driver through driven_by:
RSpec.configure do |config|
  config.before(:each, type: :system) { driven_by :lightpanda }
end
```

> [!NOTE]
> Lightpanda runs on Linux and macOS, on `x86_64` and `arm64`. On Windows, use WSL2. On Linux `arm64`, the browser needs glibc 2.38 or newer. Debian 12 and Ubuntu 22.04 are too old for it. Use Ubuntu 24.04 or Debian 13.

## Configure

Every option has a default value. Change only the options you need:

```ruby
Capybara::Lightpanda.configure do |config|
  config.window_size = [375, 812] # what @media / matchMedia evaluate against (default 1920×1080)
  config.timeout = 30             # per-command and navigation timeout, in seconds (default 15)
end
```

The documentation lists [all options](https://navidemad.github.io/capybara-lightpanda/docs/#configuration).

Each version of the gem downloads one Lightpanda release, currently 1.0.4. We test the gem against that release. The browser changes only when you upgrade the gem. To use another release, see [Choosing the browser version](https://navidemad.github.io/capybara-lightpanda/docs/#pinning).

> [!TIP]
> Does your test suite block HTTP requests with VCR or WebMock? Then download the browser before the tests start. Run `bundle exec capybara-lightpanda install` in `bin/setup` and in CI.

## Limits

Lightpanda loads your stylesheets and applies them. Media queries use the `window_size` you set. But Lightpanda does not compute layout, so elements have no real position or size.

Tests that need one of these things will fail:

- pixel positions (`getBoundingClientRect` returns approximate values)
- real scrolling
- screenshots
- a second browser tab or window
- a menu that only CSS `:hover` opens

The documentation has the [full list of limits](https://navidemad.github.io/capybara-lightpanda/docs/#limits).

## Examples

The [`examples/`](examples/) folder has small Rails apps. Each app is one file that you can run:

- [Minitest](examples/rails_minitest_example.rb) and [RSpec](examples/rails_rspec_example.rb)
- Turbo Drive and Turbo Frames, with [Minitest](examples/rails_turbo_minitest_example.rb) and [RSpec](examples/rails_turbo_rspec_example.rb)
- [A dropdown menu](examples/rails_dropdown_minitest_example.rb) that opens on click

## Upgrading

A new version of the gem can require a newer Lightpanda. If your browser is too old, the driver stops and tells you which version it found. Read [CHANGELOG.md](CHANGELOG.md) before you upgrade.

## Credits

- [Lightpanda](https://lightpanda.io/) is the headless browser.
- [Capybara](https://github.com/teamcapybara/capybara) is the test framework.
- [Ferrum](https://github.com/rubycdp/ferrum) and [`lightpanda-ruby`](https://github.com/marcoroth/lightpanda-ruby) inspired the design.

We adapted some code patterns from these MIT-licensed projects. [NOTICE.md](NOTICE.md) names them and keeps their copyright notices.

## Contributing

We welcome bug reports and pull requests on [GitHub](https://github.com/navidemad/capybara-lightpanda). [BETA_TESTING.md](BETA_TESTING.md) explains how to try the gem and how to send useful feedback.

Where to find things in this repository:

- `lib/` is the driver and its CDP client.
- `test/` is the Minitest suite. `spec/` runs the shared tests that the Capybara gem provides.
- `examples/` has the Rails apps listed above.
- `docs/` is the source of the website. It is not part of the gem.
- `script/real-app/` reproduces a failure from the weekly real-app CI run on your machine.
- [STATE_MACHINES.md](STATE_MACHINES.md) describes how the driver tracks the browser, the connection and page navigation.

## License

[MIT License](LICENSE.txt)
