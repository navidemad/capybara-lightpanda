---
title: "Documentation"
description: "Install, configure, and run capybara-lightpanda — the Capybara driver for the Lightpanda headless browser."
---

## Quick start { #install }

### 1. Install the Lightpanda browser

```bash
# macOS
brew install lightpanda-io/lightpanda/lightpanda

# Linux — download the static binary from the release page
curl -L https://github.com/lightpanda-io/browser/releases/latest/download/lightpanda-x86_64-linux \
  -o /usr/local/bin/lightpanda
chmod +x /usr/local/bin/lightpanda
```

Verify the install:

```bash
lightpanda --version
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

### 3. Register the driver

```ruby
# spec/support/capybara.rb (or test/support/capybara.rb)
require "capybara-lightpanda"

Capybara::Lightpanda.configure do |config|
  config.host = "127.0.0.1"
  config.port = 9222
  config.timeout = 15
end

Capybara.default_driver = :lightpanda
Capybara.javascript_driver = :lightpanda
```

That's it. Run your suite and the driver will boot a Lightpanda process and connect over CDP.

## Configuration { #configuration }

```ruby
Capybara::Lightpanda.configure do |config|
  config.host = "127.0.0.1"   # Lightpanda bind host
  config.port = 9222          # CDP port
  config.timeout = 15         # navigation/command timeout (seconds)
  config.process_timeout = 10 # browser startup timeout
  config.browser_path = nil   # path to lightpanda binary; nil = auto-detect
end
```

| Option | Default | Notes |
|---|---|---|
| `host` | `"127.0.0.1"` | Bind address for the CDP server |
| `port` | `9222` | TCP port; use a dynamic port for parallel suites |
| `timeout` | `15` | Per-CDP-command timeout, also covers navigation polling |
| `process_timeout` | `10` | Wait this long for `lightpanda serve` to start before failing |
| `browser_path` | `nil` | If `nil`, the driver searches `PATH` and common Homebrew paths |

### Dynamic port for parallel tests

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

## Setup recipes { #setup }

### Single driver (Lightpanda everywhere)

For projects that don't depend on rendered visuals:

```ruby
require "capybara-lightpanda"

Capybara.default_driver = :lightpanda
Capybara.javascript_driver = :lightpanda
```

### Dual driver (Cuprite + Lightpanda)

Keep Cuprite for visual specs (anything that takes screenshots or asserts on pixels) and route the rest through Lightpanda:

```ruby
if ENV["BROWSER"] == "lightpanda"
  require "capybara-lightpanda"

  Capybara::Lightpanda.configure do |config|
    config.timeout = 15
  end

  Capybara.default_driver = :lightpanda
  Capybara.javascript_driver = :lightpanda
else
  # existing Cuprite setup
  Capybara.default_driver = :cuprite
end
```

```bash
# fast headless run
BROWSER=lightpanda bundle exec rspec spec/system/

# default (Chrome via Cuprite)
bundle exec rspec spec/system/
```

### Login helper via cookies

Set a session cookie before navigating, so you don't have to drive the login form on every spec:

```ruby
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  def login_as(user)
    session = user.sessions.first_or_create!
    cookie_jar = ActionDispatch::TestRequest
      .create({ "REQUEST_METHOD" => "GET" })
      .cookie_jar
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

## What works { #what-works }

| Capybara surface | Status |
|---|---|
| Navigation — `visit`, `click_link`, `go_back`, `go_forward`, `refresh` | ✓ |
| JavaScript — `evaluate_script`, `execute_script`, `evaluate_async_script` | ✓ (V8) |
| Forms — `fill_in`, `click_button`, `select`, `choose`, `check`, `uncheck` | ✓ |
| File uploads — `attach_file` | ✓ — `DOM.setFileInputFiles` + multipart submit (build ≥6672) |
| Finders — `find`, `all`, `within`, CSS + XPath | ✓ |
| Matchers — `assert_selector`, `assert_text`, `has_field?`, `has_select?` | ✓ |
| Cookies — `set_cookie`, `clear_cookies`, `remove_cookie` | ✓ |
| Frames — `within_frame`, scoped finding | ✓ |
| Keyboard — `send_keys` with modifiers | ✓ |

## Turbo Rails { #turbo }

The driver handles Turbo-enabled Rails apps transparently.

| Feature | Status | Mechanism |
|---|---|---|
| **Turbo Frames** | Native | Lazy-load (`src=`) and scoped link navigation use Turbo's existing `fetch` + `innerHTML` swap |
| **Turbo Drive** | Native | Lightpanda's `body.replaceWith` works since v0.2.9; `#id` lookups survive the snapshot+swap pattern natively |
| **Form submission** | Auto-handled | `fetch()` + `document.write()` shim bypasses Turbo's interception when needed |
| **Turbo Streams** | Not supported | Lightpanda lacks the rendering pipeline Streams depend on |

## Known limitations { #limits }

These are upstream Lightpanda limits, not driver bugs:

| Surface | Status |
|---|---|
| Screenshots | Not supported — no rendering engine |
| `scroll_to`, `resize` | No layout engine — no real scroll/resize; the viewport is fixed at 1920×1080 |
| `window.getComputedStyle()` | Partial — CSSOM-backed values resolve (inline styles, `<style>` + external stylesheet rules, `checkVisibility`); full cascade-resolved lookups don't |
| CSS: external `<link>`, `@media`, `matchMedia` | Now fetched, parsed, and evaluated — but against the fixed 1920×1080 viewport, so responsive variants always resolve at desktop width (no resize to other breakpoints) |
| Complex Stimulus controllers | Some may not execute fully |

External `<link rel="stylesheet">` files are fetched and parsed by default — the driver always passes `--enable-external-stylesheets` — so linked CSS contributes to the cascade and `checkVisibility` / `getComputedStyle` reflect it. `@media`-gated duplicates (mobile/desktop CTA variants) now collapse to a single visible variant instead of raising `Capybara::Ambiguous`. The catch is the viewport is fixed at 1920×1080 with no real layout, so everything resolves at desktop width. If a spec needs to switch breakpoints (resize to a mobile width) or asserts on pixel-level layout, keep it on Cuprite — that's what the dual-driver pattern above is for.

## How it works { #internals }

| Component | Responsibility |
|---|---|
| `Capybara::Lightpanda::Browser` | High-level page API; falls back to `document.readyState` polling when `Page.loadEventFired` is unreliable |
| `Capybara::Lightpanda::Client` | CDP command dispatch over WebSocket with timeouts and event subscription |
| `Capybara::Lightpanda::Driver` | The Capybara driver — registers as `:lightpanda`, exposes `set_cookie` / `clear_cookies` / `remove_cookie` |
| `Capybara::Lightpanda::Node` | DOM operations via `Runtime.callFunctionOn` with object-id binding |
| `Capybara::Lightpanda::Cookies` | Wraps `Network.getCookies` / `setCookie` / `deleteCookies` with safe fallbacks |
| `javascripts/index.js` | Turbo activity tracking + DOM visibility/state predicates (`isVisible`, `isObscured`, `isDisabled`, `isContentEditable`, `visibleText`) |

The driver speaks the same CDP dialect Cuprite and Ferrum use, so most patterns from those projects translate directly. Where Lightpanda diverges from Chromium, the driver papers over it.

## Examples { #examples }

Runnable Rails demos in the repo, covering both **RSpec** and **Minitest**, with and without **Turbo**:

- [`rails_minitest_example.rb`](https://github.com/navidemad/capybara-lightpanda/blob/main/examples/rails_minitest_example.rb) — system test with Minitest
- [`rails_rspec_example.rb`](https://github.com/navidemad/capybara-lightpanda/blob/main/examples/rails_rspec_example.rb) — system spec with RSpec
- [`rails_turbo_minitest_example.rb`](https://github.com/navidemad/capybara-lightpanda/blob/main/examples/rails_turbo_minitest_example.rb) — Turbo Drive + Frames with Minitest
- [`rails_turbo_rspec_example.rb`](https://github.com/navidemad/capybara-lightpanda/blob/main/examples/rails_turbo_rspec_example.rb) — Turbo Drive + Frames with RSpec

## Reference { #reference }

- [README on GitHub](https://github.com/navidemad/capybara-lightpanda/blob/main/README.md)
- [CHANGELOG](https://github.com/navidemad/capybara-lightpanda/blob/main/CHANGELOG.md)
- [Issues](https://github.com/navidemad/capybara-lightpanda/issues)
- [Lightpanda upstream](https://github.com/lightpanda-io/browser) — the browser that powers this driver
