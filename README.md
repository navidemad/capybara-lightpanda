# Capybara::Lightpanda

[![Gem version](https://img.shields.io/gem/v/capybara-lightpanda?logo=rubygems&logoColor=white&label=gem)](https://rubygems.org/gems/capybara-lightpanda)
[![Total downloads](https://img.shields.io/gem/dt/capybara-lightpanda?label=downloads)](https://rubygems.org/gems/capybara-lightpanda)
[![Tests](https://img.shields.io/github/actions/workflow/status/navidemad/capybara-lightpanda/ci.yml?branch=main&logo=github&label=tests)](https://github.com/navidemad/capybara-lightpanda/actions/workflows/ci.yml)
[![Lightpanda stars](https://img.shields.io/github/stars/lightpanda-io/browser?logo=github&label=Lightpanda%20stars)](https://github.com/lightpanda-io/browser/stargazers)

A [Capybara](https://github.com/teamcapybara/capybara) driver for [Lightpanda](https://lightpanda.io/), a headless browser made with Zig.

- You write the same Capybara tests as before.
- You do not need Chromium.
- Each test worker needs about 17 MB of memory.<br>
  With Chrome, each one needs about 280 MB.
- The gem comes with its own CDP client.<br>
  You do not need another browser gem.

We saw these numbers on a Rails 8.1 app with 24 system tests.<br>
The two drivers took the same time, about 7 seconds.

Each week, we run the driver on the tests of [seven real Rails apps](https://navidemad.github.io/capybara-lightpanda/docs/#validation).

**[Read the docs on the website →](https://navidemad.github.io/capybara-lightpanda/docs/)**<br>
You will find all the options there, setup recipes, Turbo, and help with errors.

## Install

Add the gem to your `Gemfile`, then run `bundle install`:

```ruby
gem "capybara-lightpanda", group: :test
```

Then name the driver. Choose the part that fits your tests.

### Minitest

```ruby
# test/application_system_test_case.rb
require "capybara-lightpanda"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :lightpanda
end
```

### RSpec

```ruby
# spec/support/capybara.rb
require "capybara-lightpanda"

RSpec.configure do |config|
  config.before(:each, type: :system) { driven_by :lightpanda }
end
```

### Capybara without Rails

```ruby
require "capybara-lightpanda"

Capybara.default_driver = :lightpanda
Capybara.javascript_driver = :lightpanda
```

The first time you run a test, the gem gets the Lightpanda browser for you.

> [!TIP]
> Do your tests block HTTP calls with VCR or WebMock?<br>
> Then get the browser before the tests start.<br>
> Run `bundle exec capybara-lightpanda install` in `bin/setup` and in CI.

You can try the gem next to your current driver.<br>
[BETA_TESTING.md](BETA_TESTING.md) shows how to turn it on with one env var.<br>
To go back, drop the env var.

## Test it with your AI agent

Do you use an AI coding agent, such as Claude Code or Codex?<br>
Give it the prompt below.

- The agent tries the gem on your app.
- It keeps your current driver as the default.
- It writes a bug report with no private data.
- You read each report before the agent posts it.

Are you an AI agent? Then follow the same steps.

```text
Goal: find out if this Rails app can run its system tests with the
capybara-lightpanda gem, and report each real problem to the gem's authors.

Rules
- Work on a new git branch. Do not commit, push or open a pull request.
- Do not change the default driver. Lightpanda runs only when BROWSER=lightpanda.
- Do not post anything on GitHub until I say yes.
- Never copy secrets, customer data or private names into a report.

Step 1. Look
- Find the test framework (Minitest or RSpec), the current Capybara driver and
  the command that runs the system tests.
- If the full run takes more than 10 minutes, ask me which folder to run.

Step 2. Set up
- Add `gem "capybara-lightpanda"` to the test group of the Gemfile, then run
  `bundle install` and `bundle exec capybara-lightpanda install`.
- Minitest, in test/application_system_test_case.rb:
    driven_by ENV["BROWSER"] == "lightpanda" ? :lightpanda : <current driver>
- RSpec, in the support file that sets the driver:
    config.before(:each, type: :system) do
      driven_by ENV["BROWSER"] == "lightpanda" ? :lightpanda : <current driver>
    end
- More cases: https://github.com/navidemad/capybara-lightpanda/blob/main/BETA_TESTING.md

Step 3. Run
- Run the system tests with the current driver. Save the results and the time.
- Run them again with BROWSER=lightpanda. Save the results and the time.
- Keep only the tests that pass with the current driver and fail with
  Lightpanda. Run each one alone, one more time. Drop it if it now passes.

Step 4. Sort the failures
- Known limit, do not report: the test needs a screenshot, pixel positions,
  real scrolling, a second tab or window, or a menu that only CSS :hover opens.
  Full list: https://navidemad.github.io/capybara-lightpanda/docs/#limits
- Everything else is a real problem. For each one:
  - read the error, `page.driver.browser.console_logs` and
    `page.driver.browser.page_errors`;
  - cut the page and the test down to the smallest HTML and test that still fail;
  - check that this small test passes with the current driver.

Step 5. Write the reports, but do not post them
- One draft per real problem, with the fields of this form:
  https://github.com/navidemad/capybara-lightpanda/issues/new?template=beta-feedback.yml
- Give: what broke, the small repro, the error, the result with the current
  driver, and the versions of Rails, Ruby, Capybara, capybara-lightpanda and
  Lightpanda (`bundle exec capybara-lightpanda version`).
- Make each draft anonymous. Remove the app name, company name, names of
  people, emails, domains, URLs, tokens, keys and business data. Use
  placeholder names such as `Post`, `User` and `example.test`.
- No real problem? Then write one draft for this form instead, with the numbers:
  https://github.com/navidemad/capybara-lightpanda/issues/new?template=it-worked.yml

Step 6. Tell me
- A short table: tests run, passed with both drivers, failed only with
  Lightpanda (known limits and real problems), and the time for each driver.
- The drafts, ready to read.
- The files you changed, and the commands to undo everything.
Then wait for my answer.
```

## What to expect

Lightpanda runs your JavaScript, reads your CSS and works with Turbo.<br>
On the real Rails apps we test each week, almost all tests pass with no change.

Lightpanda has no layout engine.<br>
So a few kinds of tests still need your old driver:

- tests with screenshots
- tests with pixel positions or real scrolling
- tests with a second tab
- tests with a menu that only CSS `:hover` can open

You can keep both drivers in the same app.<br>
The docs have the [full list](https://navidemad.github.io/capybara-lightpanda/docs/#limits).

## Examples

The [`examples/`](examples/) folder has small Rails apps.<br>
Each app is one file that you can run:

- [Minitest](examples/rails_minitest_example.rb) and [RSpec](examples/rails_rspec_example.rb)
- Turbo Drive and Turbo Frames, with [Minitest](examples/rails_turbo_minitest_example.rb) and [RSpec](examples/rails_turbo_rspec_example.rb)
- [A menu](examples/rails_dropdown_minitest_example.rb) that you open with a click

## Upgrading

A new gem version can need a new Lightpanda version.<br>
If your browser is too old, the driver will stop.<br>
It will tell you which version you have.

Read [CHANGELOG.md](CHANGELOG.md) before you change the gem version.

## Credits

- [Lightpanda](https://lightpanda.io/) is the headless browser.
- [Capybara](https://github.com/teamcapybara/capybara) is the test framework.
- [Ferrum](https://github.com/rubycdp/ferrum) and [`lightpanda-ruby`](https://github.com/marcoroth/lightpanda-ruby) gave us ideas for the design.

We took some code ideas from these projects.<br>
They use the MIT license.<br>
[NOTICE.md](NOTICE.md) has the list and the copyright notices.

## Contributing

Please send bug reports and pull requests on [GitHub](https://github.com/navidemad/capybara-lightpanda).<br>
[BETA_TESTING.md](BETA_TESTING.md) shows how to try the gem and how to tell us what you find.

Where to find things in this repo:

- `lib/` has the driver and its CDP client.
- `test/` has our tests.
- `spec/` runs the tests that come with the Capybara gem.
- `examples/` has the Rails apps from the list above.
- `docs/` has the website. It is not part of the gem.
- `script/real-app/` lets you run a real-app test from CI on your own computer.
- [STATE_MACHINES.md](STATE_MACHINES.md) shows how the driver follows the browser, the connection and each page load.

Run `bundle exec rake readme:readability` after you change this file.<br>
It checks that the text is still easy to read.

## License

[MIT License](LICENSE.txt)
