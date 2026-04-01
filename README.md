# Capybara::Lightpanda

A [Capybara](https://github.com/teamcapybara/capybara) driver for [Lightpanda](https://lightpanda.io/), the fast headless browser built in Zig.

This gem provides a **self-contained, production-ready** Capybara driver with a built-in CDP client. No external browser-client gem required — just install and go:

- **Reliable navigation** — falls back to `document.readyState` polling when `Page.loadEventFired` doesn't fire (a known Lightpanda limitation on pages with complex JS)
- **XPath polyfill** — auto-injected after each navigation so Capybara's internal XPath selectors work (`find`, `click_on`, `fill_in`, `assert_selector`, etc.)
- **Cookie management** — `set_cookie`, `clear_cookies`, `remove_cookie` on the driver + graceful fallback when `Network.clearBrowserCookies` crashes the CDP connection
- **Drop-in Capybara integration** — registers a `:lightpanda` driver, configure and go

## Architecture

Similar to how [Cuprite](https://github.com/rubycdp/cuprite) builds on [Ferrum](https://github.com/rubycdp/ferrum), but as a single gem:

```
Capybara  →  capybara-lightpanda (driver + CDP client)  →  Lightpanda browser
```

## Installation

### 1. Install the Lightpanda browser

```bash
# macOS
brew install lightpanda-io/lightpanda/lightpanda

# Linux (Debian/Ubuntu) — see https://lightpanda.io/docs/
```

### 2. Add the gem

```ruby
# Gemfile
group :test do
  gem "capybara-lightpanda"
end
```

```bash
bundle install
```

## Usage

### Basic setup

```ruby
# test/support/capybara.rb or spec/support/capybara.rb
require "capybara-lightpanda"

Capybara::Lightpanda.configure do |config|
  config.host = "127.0.0.1"
  config.port = 9222
  config.timeout = 15
  config.browser_path = "/usr/local/bin/lightpanda" # optional, auto-detected
end

Capybara.default_driver = :lightpanda
Capybara.javascript_driver = :lightpanda
```

### Dual-driver setup (recommended)

Run most tests with Chrome, use Lightpanda for fast DOM-only tests:

```ruby
if ENV["BROWSER"] == "lightpanda"
  require "capybara-lightpanda"

  Capybara::Lightpanda.configure do |config|
    config.timeout = 15
  end

  Capybara.default_driver = :lightpanda
  Capybara.javascript_driver = :lightpanda
else
  # Your existing Chrome/Cuprite setup
  Capybara.default_driver = :cuprite
end
```

```bash
# Run with Lightpanda
BROWSER=lightpanda bundle exec rails test test/system/

# Run with Chrome (default)
bundle exec rails test test/system/
```

### Setting cookies (e.g. login helper)

```ruby
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  def login_as(user)
    session = user.sessions.first_or_create!
    cookie_jar = ActionDispatch::TestRequest.create({ "REQUEST_METHOD" => "GET" }).cookie_jar
    cookie_jar.signed[:session_id] = { value: session.id }

    page.driver.set_cookie(
      "session_id",
      cookie_jar[:session_id],
      domain: "127.0.0.1",
      httpOnly: true,
      secure: false,
    )
  end
end
```

## What works

- Navigation (`visit`, `click_link`, `go_back`, `go_forward`, `refresh`)
- JavaScript execution (V8 engine) — `evaluate_script`, `execute_script`, `evaluate_async_script`
- Forms — `fill_in`, `click_button`, `select`, `choose`, `check`, `uncheck`
- Finding — `find`, `all`, `within`, CSS and XPath selectors
- Matchers — `assert_selector`, `assert_text`, `assert_current_path`, `has_field?`, `has_select?`
- Cookies — set/get/clear/remove via CDP
- Frames — `within_frame`, scoped finding
- Keyboard — `send_keys` with modifiers and special keys
- Network — traffic tracking, custom headers, idle waiting

### Turbo Rails support

The gem handles Turbo-enabled Rails apps transparently:

| Feature | Status | How |
|---------|--------|-----|
| **Turbo Frames** | Works natively | Lazy-loading (`src=`), scoped link navigation |
| **Turbo Drive** | Auto-disabled | Gem disables Drive (body replacement fails in Lightpanda) — standard link navigation restored |
| **Form submission** | Auto-handled | When Turbo is present, forms submit via `fetch()` + `document.write()` to bypass Turbo's interception |
| **Turbo Streams** | Not supported | Depends on Turbo's fetch pipeline which Lightpanda can't render |

**Root cause**: Lightpanda's `document.body` is read-only — Turbo Drive's body replacement and frame form responses can't be applied. The gem works around this automatically.

## Known limitations

These are Lightpanda browser limitations, not driver limitations:

| Feature | Status |
|---------|--------|
| Screenshots | Not supported (no rendering engine) |
| `window.getComputedStyle()` | Returns defaults (no CSS engine) |
| `scroll_to`, `resize` | No layout engine |
| Complex Stimulus controllers | Some may not execute fully |
| XPath axes/functions | Polyfill covers ~80% of Capybara usage |
| File uploads | Not yet supported |
| Turbo Streams | Not supported (Turbo's fetch-then-render pipeline) |

## Benchmark

Tested on a Rails 8.1 app (Turbo + Stimulus), 24 DOM-only tests:

| Driver | Tests | Time | Speed |
|--------|-------|------|-------|
| **Lightpanda** | 24/24 pass | 6.89s | 3.48 tests/s |
| **Chrome** | 24/24 pass | 7.09s | 3.38 tests/s |

Lightpanda's advantage is expected to grow on larger suites due to faster startup and lower memory usage.

## Configuration

```ruby
Capybara::Lightpanda.configure do |config|
  config.host = "127.0.0.1"       # Lightpanda bind host
  config.port = 9222              # Lightpanda CDP port
  config.timeout = 15             # Navigation/command timeout (seconds)
  config.process_timeout = 10     # Browser process startup timeout
  config.browser_path = nil       # Path to lightpanda binary (auto-detected)
end
```

### Dynamic port (parallel tests)

```ruby
def available_port
  server = TCPServer.new("127.0.0.1", 0)
  port = server.addr[1]
  server.close
  port
end

Capybara::Lightpanda.configure do |config|
  config.port = ENV.fetch("LIGHTPANDA_PORT", available_port).to_i
end
```

## How it works

| Component | Description |
|-----------|-------------|
| `Browser` | High-level API with readyState polling fallback when `Page.loadEventFired` never fires |
| `Cookies` | Catches `BrowserError` from unsupported `Network.clearBrowserCookies`, deletes cookies individually |
| `XPathPolyfill` | Provides `document.evaluate` + `XPathResult` shim for Capybara's XPath selectors |
| `Client` | CDP command dispatch over WebSocket with timeout and event subscription |
| `Driver` | Complete Capybara driver with `set_cookie`, `clear_cookies`, `remove_cookie` |
| `Node` | DOM interactions via JavaScript evaluation |

## Credits

- [Lightpanda](https://lightpanda.io/) — the headless browser
- [Capybara](https://github.com/teamcapybara/capybara) — the test framework
- Inspired by the [Cuprite](https://github.com/rubycdp/cuprite) / [Ferrum](https://github.com/rubycdp/ferrum) architecture and [`lightpanda-ruby`](https://github.com/marcoroth/lightpanda-ruby)

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/navidemad/capybara-lightpanda).

## License

[MIT License](LICENSE.txt)
