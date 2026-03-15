# CLAUDE.md

## Project Overview

Capybara driver for the Lightpanda headless browser. Builds on the `lightpanda` gem (CDP client) the same way Cuprite builds on Ferrum.

```
Capybara → capybara-lightpanda (driver) → lightpanda (CDP client) → Lightpanda browser (Zig/V8)
```

## Stack

- **Ruby** >= 3.1
- **Dependencies**: `capybara` >= 3.0, `lightpanda` >= 0.1.0
- **Protocol**: CDP (Chrome DevTools Protocol)
- **License**: MIT

## Structure

```
lib/
  capybara-lightpanda.rb                  # Entry point, config, driver registration, applies prepends
  capybara/lightpanda/
    driver.rb                             # Capybara::Driver::Base implementation
    node.rb                               # Capybara::Driver::Node implementation (DOM interactions via JS)
    browser_ext.rb                        # Prepend on Lightpanda::Browser — go_to readyState fallback
    cookies_ext.rb                        # Prepend on Lightpanda::Cookies — clear fallback
    xpath_polyfill.rb                     # JS polyfill for document.evaluate / XPathResult
    version.rb                            # Gem version
```

## Architecture Decisions

### Why prepend instead of subclass

`BrowserExt` and `CookiesExt` use `Module#prepend` on `Lightpanda::Browser` and `Lightpanda::Cookies` because the Driver receives browser instances from the `lightpanda` gem's own classes. Subclassing would require overriding the instantiation chain.

### Why a separate Driver/Node instead of reusing lightpanda's

The `lightpanda` gem includes its own `Lightpanda::Capybara::Driver` and `Node`, but they lack cookie methods, XPath injection, and reliable navigation. Rather than monkey-patching a foreign driver class, we provide a clean implementation under `Capybara::Lightpanda::Driver`.

### XPath polyfill scope

Lightpanda doesn't implement `XPathResult` or `document.evaluate`. The polyfill does a simplified XPath → CSS conversion covering ~80% of Capybara's generated XPath. It's re-injected after every `visit` because the JS context is lost between page navigations.

## Key Lightpanda Browser Limitations

These are browser-level limitations, not fixable in this gem:

- No rendering engine → no screenshots, no `getComputedStyle`, no scroll/resize
- `Page.loadEventFired` may never fire on complex JS pages (lightpanda-io/browser#1801, #1832)
- `Network.clearBrowserCookies` crashes the CDP WebSocket connection (InvalidParams + connection reset)
- `XPathResult` not implemented (polyfilled by this gem)

## Commands

```bash
# Install dependencies
bundle install

# Run tests (when added)
bundle exec rake test

# Lint
bundle exec rubocop

# Build gem
gem build capybara-lightpanda.gemspec

# Install locally
gem install capybara-lightpanda-*.gem
```

## Code Conventions

- Double quotes for strings
- Trailing commas on multi-line hashes/arrays
- 120 char line width
- RuboCop with `.rubocop.yml` config

## Testing This Gem

To test against a real Rails app:

```ruby
# In the Rails app's Gemfile
gem "capybara-lightpanda", path: "../capybara-lightpanda"

# In test config
require "capybara-lightpanda"
Capybara::Lightpanda.configure do |config|
  config.timeout = 15
end
Capybara.default_driver = :lightpanda
```

```bash
# Lightpanda browser must be running or installed
BROWSER=lightpanda bundle exec rails test test/system/
```

## Upstream Issues Filed

| Issue | Repo | Description |
|-------|------|-------------|
| [#6](https://github.com/marcoroth/lightpanda-ruby/issues/6) | lightpanda-ruby | Page.navigate timeout on complex JS pages |
| [#7](https://github.com/marcoroth/lightpanda-ruby/issues/7) | lightpanda-ruby | XPath polyfill needed for Capybara |
| [#8](https://github.com/marcoroth/lightpanda-ruby/issues/8) | lightpanda-ruby | Cookies#clear crashes CDP connection |
| [#9](https://github.com/marcoroth/lightpanda-ruby/issues/9) | lightpanda-ruby | Missing set_cookie/clear_cookies on driver |
