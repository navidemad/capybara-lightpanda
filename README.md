# Capybara::Lightpanda

[![Gem version](https://img.shields.io/gem/v/capybara-lightpanda?logo=rubygems&logoColor=white&label=gem)](https://rubygems.org/gems/capybara-lightpanda)
[![Total downloads](https://img.shields.io/gem/dt/capybara-lightpanda?label=downloads)](https://rubygems.org/gems/capybara-lightpanda)
[![Tests](https://img.shields.io/github/actions/workflow/status/navidemad/capybara-lightpanda/ci.yml?branch=main&logo=github&label=tests)](https://github.com/navidemad/capybara-lightpanda/actions/workflows/ci.yml)

A [Capybara](https://github.com/teamcapybara/capybara) driver for [Lightpanda](https://lightpanda.io/), a headless browser made with Zig.

You write the same Capybara tests as before. You do not need Chromium. Each test worker needs about 17 MB of memory. With Chrome, each one needs about 280 MB. We saw this on a Rails 8.1 app with 24 system tests. The two drivers took the same time, about 7 seconds.

The gem comes with its own CDP client, so you do not need another browser gem. Each week, we run the driver on the tests of [seven real Rails apps](https://navidemad.github.io/capybara-lightpanda/docs/#validation).

```ruby
# Gemfile
gem "capybara-lightpanda", group: :test

# test/application_system_test_case.rb
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :lightpanda
end
```

> [!IMPORTANT]
> Lightpanda does not draw the page. Tests that need screenshots, pixel positions or real scrolling will fail. See [Limits](#limits).

Read the [docs](https://navidemad.github.io/capybara-lightpanda/docs/) for setup, options, Turbo, limits and help with errors.

## Install

A Rails app only needs the code above. Run `bundle install`. The gem adds a driver with the name `:lightpanda`. The first time you run a test, the gem gets the Lightpanda browser for you.

Do you use RSpec, or Capybara without Rails? Then use this code:

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
> Lightpanda works on Linux and macOS, on `x86_64` and `arm64`. On Windows, use WSL2. On Linux `arm64`, the browser needs glibc 2.38 or above. Debian 12 and Ubuntu 22.04 are too old for it. Use Ubuntu 24.04 or Debian 13.

## Configure

Each option has a default value. Change only what you need:

```ruby
Capybara::Lightpanda.configure do |config|
  config.window_size = [375, 812] # what @media / matchMedia evaluate against (default 1920×1080)
  config.timeout = 30             # per-command and navigation timeout, in seconds (default 15)
end
```

The docs list [all the options](https://navidemad.github.io/capybara-lightpanda/docs/#configuration).

Each gem version gets one Lightpanda version. Today it is 1.0.4. We test the gem with that one. The browser changes only when you change the gem version. You can also [choose another browser version](https://navidemad.github.io/capybara-lightpanda/docs/#pinning).

> [!TIP]
> Do your tests block HTTP calls with VCR or WebMock? Then get the browser before the tests start. Run `bundle exec capybara-lightpanda install` in `bin/setup` and in CI.

## Limits

Lightpanda reads your CSS and uses it. Media queries use the `window_size` you set. But Lightpanda does not draw the page, so an element has no real place or size.

Tests that need one of these things will fail:

- pixel positions (`getBoundingClientRect` gives rough numbers)
- real scrolling
- screenshots
- a second browser tab or window
- a menu that only CSS `:hover` can open

The docs have the [full list of limits](https://navidemad.github.io/capybara-lightpanda/docs/#limits).

## Examples

The [`examples/`](examples/) folder has small Rails apps. Each app is one file that you can run:

- [Minitest](examples/rails_minitest_example.rb) and [RSpec](examples/rails_rspec_example.rb)
- Turbo Drive and Turbo Frames, with [Minitest](examples/rails_turbo_minitest_example.rb) and [RSpec](examples/rails_turbo_rspec_example.rb)
- [A menu](examples/rails_dropdown_minitest_example.rb) that you open with a click

## Upgrading

A new gem version can need a new Lightpanda version. If your browser is too old, the driver will stop. It will tell you which version you have. Read [CHANGELOG.md](CHANGELOG.md) before you change the gem version.

## Credits

- [Lightpanda](https://lightpanda.io/) is the headless browser.
- [Capybara](https://github.com/teamcapybara/capybara) is the test tool.
- [Ferrum](https://github.com/rubycdp/ferrum) and [`lightpanda-ruby`](https://github.com/marcoroth/lightpanda-ruby) gave us ideas for the design.

We took some code ideas from these projects. They use the MIT license. [NOTICE.md](NOTICE.md) has the list and the copyright notices.

## Contributing

Please send bug reports and pull requests on [GitHub](https://github.com/navidemad/capybara-lightpanda). [BETA_TESTING.md](BETA_TESTING.md) shows how to try the gem and how to tell us what you find.

Where to find things in this repo:

- `lib/` has the driver and its CDP client.
- `test/` has our tests. `spec/` runs the tests that come with the Capybara gem.
- `examples/` has the Rails apps from the list above.
- `docs/` has the website. It is not part of the gem.
- `script/real-app/` lets you run a real-app test from CI on your own computer.
- [STATE_MACHINES.md](STATE_MACHINES.md) shows how the driver follows the browser, the connection and each page load.

Run `bundle exec rake readme:readability` after you change this file. It checks that the text is still easy to read.

## License

[MIT License](LICENSE.txt)
