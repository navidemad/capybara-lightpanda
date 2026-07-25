---
title: "Documentation"
description: "Install, configure, and run capybara-lightpanda — the Capybara driver for the Lightpanda headless browser."
---

## Quick start { #install }

### 1. Add the gem

```ruby
# Gemfile
group :test do
  gem "capybara-lightpanda"
end
```

```bash
bundle install
```

### 2. Register the driver

```ruby
# spec/support/capybara.rb (or test/support/capybara.rb)
require "capybara-lightpanda"

Capybara::Lightpanda.configure do |config|
  config.host = "127.0.0.1"
  config.timeout = 15
end

Capybara.default_driver = :lightpanda
Capybara.javascript_driver = :lightpanda
```

Rails system tests don't read `Capybara.javascript_driver` — use `driven_by :lightpanda`.

That's it. There is **no separate browser install step**: on first use the gem
downloads the Lightpanda binary into `~/.cache/lightpanda/`
(`$XDG_CACHE_HOME/lightpanda/` when set), boots `lightpanda serve` on an
ephemeral port, and connects over CDP.

Two things follow from that, and both surprise people:

- A `lightpanda` on your `PATH` — from Homebrew, or a binary you dropped in
  `/usr/local/bin` — is **not** used. Point `browser_path` at it if you want the
  gem to run your copy instead of its own.
- The download tracks the rolling `nightly` tag and refreshes every 24 h. Fine
  locally, wrong for CI — [pin a release](#pinning).

## Configuration { #configuration }

```ruby
Capybara::Lightpanda.configure do |config|
  config.host = "127.0.0.1"   # Lightpanda bind host
  config.port = 0             # CDP port; 0 = OS-assigned ephemeral (pin e.g. 9222 for external tooling)
  config.timeout = 15         # navigation/command timeout (seconds)
  config.process_timeout = 10 # browser startup timeout
  config.browser_path = nil   # path to your own lightpanda binary; nil = the gem manages one
end
```

| Option | Default | Notes |
|---|---|---|
| `host` | `"127.0.0.1"` | Bind address for the CDP server |
| `port` | `0` | `0` = OS-assigned ephemeral port per worker — parallel suites work with zero config. Pin a fixed port for external tooling |
| `timeout` | `15` | Per-CDP-command timeout, also covers navigation polling |
| `process_timeout` | `10` | Wait this long for `lightpanda serve` to start before failing |
| `handshake_timeout` | `5` | Budget for the WebSocket TCP + Upgrade handshake alone. Separate from `timeout` because a handshake either lands in a few hundred ms or never |
| `browser_path` | `nil` | Path to a binary **you** manage. When `nil` the gem downloads and refreshes its own copy under `~/.cache/lightpanda/` — it does not look at `PATH` |
| `window_size` | `[1920, 1080]` | Drives `window.innerWidth`/`innerHeight` and what `@media` / `matchMedia` evaluate against. JS-visible viewport only — no reflow (see [limitations](#limits)). The default mirrors Lightpanda's native viewport, so leaving it alone changes nothing |
| `save_path` | `Capybara.save_path` | Where downloaded files land. Downloads stay off when both are `nil` |
| `logger` | `nil` | An IO (or `Capybara::Lightpanda::Logger`) that receives raw CDP traffic. `LIGHTPANDA_DEBUG=1` wires `$stdout` |
| `headless` | `true` | Accepted for Cuprite drop-in compatibility, and inert — headless is the only mode Lightpanda has |

### Pinning the browser version { #pinning }

By default the driver tracks Lightpanda's rolling `nightly` tag and refreshes it
once every 24 hours. That is convenient for local exploration and wrong for CI:
the browser can change under a suite that didn't change a single line, and
nightly builds are not archived, so you cannot go back to the one that was green
yesterday.

For any shared or CI environment, pin a tagged release:

```ruby
# spec/support/capybara.rb · or test/support/capybara.rb
Capybara::Lightpanda::Binary.configure do |binary|
  binary.required_version = "0.3.5"   # a tag from lightpanda-io/browser/releases
end
```

A pin is downloaded once into its own version-scoped file
(`~/.cache/lightpanda/lightpanda-0.3.5`), is never refreshed on age, and is
never satisfied by a nightly left over from an earlier run. Cache that directory
in CI and the browser becomes as reproducible as your `Gemfile.lock`.

The driver enforces a floor on both channels and refuses to start below it —
nightly build ≥ 8160, or release ≥ 0.3.5. The error names the version it found
and how to move off it.

Two supporting knobs:

| Knob | Use |
|---|---|
| `browser_path` (driver option) | You manage the binary yourself — a Docker layer, a vendored artifact. The gem never downloads |
| `LIGHTPANDA_CACHE_TIME=0` (env) | Treat whatever is already cached as fresh forever. Pair with a pre-provisioning step when the suite blocks outbound HTTP (VCR/WebMock) |

> Suites that stub HTTP need the binary fetched **before** the stubs load, from a
> process with no WebMock/VCR in it:
> `bundle exec ruby -r capybara-lightpanda -e 'puts Capybara::Lightpanda::Binary.update'`

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
| HTTP response — `status_code`, `response_headers` | ✓ — from `Network.responseReceived` |
| Frames — `within_frame`, scoped finding | ✓ |
| Keyboard — `send_keys` with modifiers | ✓ |
| Downloads — `Content-Disposition: attachment` responses | ✓ — streamed to `save_path` (build ≥7545) |
| Drag-and-drop — `Element#drop` (files or typed data onto a dropzone) | ✓ — geometry-free `DataTransfer` + `DragEvent` (build ≥6699). Coordinate `drag_to` / `drag_by` are not supported |
| Windows — `current_window`, `resize_to`, `maximize` | ✓ single window — see [limitations](#limits) |

## Beyond the Capybara DSL { #driver-api }

Everything below hangs off `page.driver` and mirrors the Cuprite/Ferrum spelling
where one exists.

### Downloads

Capture is on automatically whenever a destination exists — the `save_path`
driver option, else `Capybara.save_path`. The trigger is the
`Content-Disposition: attachment` header, **not** the MIME type, so a
`send_file` / `send_data` action downloads while a bare `text/csv` response
renders as an ordinary (empty) navigation.

```ruby
click_link "Export CSV"
page.driver.wait_for_download(timeout: 10)   # blocks, returns the file list
page.driver.downloads                        # => ["/…/tmp/downloads/export.csv"]
```

### Network inspection

```ruby
page.driver.wait_for_network_idle(timeout: 5)  # true, or false on timeout
page.driver.network.traffic                    # [{request_id:, url:, method:, response: …}, …]
page.driver.network.pending_connections        # in-flight count
page.driver.network.clear

page.driver.headers = { "X-Tenant" => "acme" } # survives reset!
page.driver.add_headers("Accept-Language" => "fr")
```

Header overrides ride `Network.setExtraHTTPHeaders`. A `User-Agent` set this way
is honored, but Lightpanda rejects any value containing `Mozilla` by design — so
you can label the driver, not disguise it as Chrome.

### Console logs

No custom logger class needed. Messages are ring-buffered (cap 1,000, cleared on
reset, driver-internal Turbo sentinels excluded):

```ruby
errors = page.driver.browser.console_logs.select { |m| m[:type] == "error" }
assert_empty errors
```

Lightpanda reports both `console.log` and `console.warn` as type `"info"` —
filter on `:text` when you need to tell them apart. Selenium-shaped helpers that
shared Rails suites copy around work too: `browser.logs.get(:browser)` returns
`LogEntry` structs with Selenium severity strings, and
`browser.execute_async_script` is accepted (the axe-core matchers call it).

### Raw CDP escape hatch

For Lightpanda's `LP.*` extensions and anything else not worth a DSL method:

```ruby
markdown = page.driver.with_lightpanda_browser do |browser|
  browser.page_command("LP.getMarkdown")
end

# Same idea one level down, on an element:
id = find("#widget").with_lightpanda_node { |node| node.remote_object_id }
```

## Turbo Rails { #turbo }

The driver handles Turbo-enabled Rails apps transparently.

| Feature | Status | Mechanism |
|---|---|---|
| **Turbo Frames** | Native | Lazy-load (`src=`) and scoped link navigation use Turbo's existing `fetch` + `innerHTML` swap |
| **Turbo Drive** | Native | Lightpanda's `body.replaceWith` works since v0.2.9; `#id` lookups survive the snapshot+swap pattern natively |
| **Form submission** | Native | Clicks dispatch a real `MouseEvent` (Turbo's interceptors guard on `instanceof MouseEvent`), and Lightpanda runs the submission default action itself. The `fetch()` + `document.write()` swap the driver used to need was retired once upstream landed native form submission |
| **Turbo Streams** | Works | Page-initiated WebSockets send `Origin`, so ActionCable's forgery check passes and `turbo-cable-stream-source` reaches `[connected]`; `<template>` + `DOMParser` + `importNode` back the stream-application path. Covered by API probes and real-app beta testing, not yet by an end-to-end Stream spec in this gem's CI |

## Known limitations { #limits }

These are upstream Lightpanda limits, not driver bugs:

| Surface | Status |
|---|---|
| Screenshots | No compositor, so there is nothing to capture. `save_screenshot` (and its `render` alias) is accepted and writes a blank image rather than raising, so Rails' screenshot-on-failure teardown doesn't bury the real failure |
| `scroll_to` | No-op. Lightpanda tracks a scroll position but `getBoundingClientRect` isn't scroll-aware, so `:top` / `:center` / element-relative alignment have no meaning |
| `resize` | Wired — `page.current_window.resize_to(w, h)` drives the same viewport `window_size` does. **Resize, then visit**: the cascade is fixed at parse time, so `@media` rules don't re-resolve for a document already on screen |
| Element geometry | `getBoundingClientRect` is synthesized, not measured — zero for non-rendered elements. So `obscured?` outside the viewport, spatial finders (`near:`, `above:`) and pixel assertions can't work |
| `window.getComputedStyle()` | Partial — CSSOM-backed values resolve (inline styles, `<style>` + external stylesheet rules, `checkVisibility`); full cascade-resolved lookups don't |
| CSS: external `<link>`, `@media`, `matchMedia` | Fetched, parsed, and evaluated against the configured `window_size` — responsive variants resolve at the width you set. What's absent is reflow, not the media query |
| User agent | `Lightpanda/1.0` — no Chrome/Safari token, and Mozilla-styled UA overrides are rejected by design. App-side UA bot detection flags the driver as a bot; allowlist `Lightpanda` in your test environment |
| Complex Stimulus controllers | Some may not execute fully |

External `<link rel="stylesheet">` files are fetched and parsed by default — the driver always passes `--enable-external-stylesheets` — so linked CSS contributes to the cascade and `checkVisibility` / `getComputedStyle` reflect it. `@media`-gated duplicates (mobile/desktop CTA variants) now collapse to a single visible variant instead of raising `Capybara::Ambiguous`. Breakpoints resolve at whatever `window_size` you configure, so a suite that runs mobile-width specs can register a second driver at `[375, 812]`. The catch is that the viewport is JS-visible only: nothing reflows, so a spec that asserts on pixel-level layout, scrolling, or that an element is visually obscured still belongs on Cuprite — that's what the dual-driver pattern above is for.

## How it works { #internals }

| Component | Responsibility |
|---|---|
| `Capybara::Lightpanda::Browser` | High-level page API; falls back to `document.readyState` polling when `Page.loadEventFired` is unreliable |
| `Capybara::Lightpanda::Client` | CDP command dispatch over WebSocket with timeouts and event subscription |
| `Capybara::Lightpanda::Driver` | The Capybara driver — registers as `:lightpanda`, exposes `set_cookie` / `clear_cookies` / `remove_cookie` |
| `Capybara::Lightpanda::Node` | DOM operations via `Runtime.callFunctionOn` with object-id binding |
| `Capybara::Lightpanda::Cookies` | `Enumerable` over `Network.getAllCookies` (every origin in the context), plus `setCookie` / `deleteCookies` / bulk `clearBrowserCookies`, and a YAML `store` / `load` round-trip |
| `Capybara::Lightpanda::Network` | Counts in-flight requests from `Network.requestWillBeSent` / `responseReceived` — backs `status_code`, `response_headers`, `wait_for_network_idle`, and the header overrides |
| `lib/capybara/lightpanda/javascripts/*.js` | The injected `_lightpanda` bundle, split by concern — `turbo.js` (Turbo activity tracking) and `predicates.js` (`isVisible`, `isObscured`, `isDisabled`, `isContentEditable`, `visibleText`), wired by `attach.js` and assembled into one IIFE by `AutoScripts`, then registered once per session via `Page.addScriptToEvaluateOnNewDocument` |

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
