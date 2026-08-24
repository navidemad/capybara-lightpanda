---
title: "Documentation"
description: "Install, configure, and run capybara-lightpanda — the Capybara driver for the Lightpanda headless browser."
---

## Quick start { #install }

### Requirements

| | |
|---|---|
| **Ruby** | ≥ 3.3 — CI covers 3.3 and 4.0 |
| **Capybara** | ≥ 3.0, < 5 |
| **Platforms** | Linux `x86_64` · Linux `aarch64` · macOS Apple Silicon · macOS Intel |
| **Windows** | WSL2 only — Lightpanda publishes no native Windows build |

Anything else raises `UnsupportedPlatformError` at boot, naming the platform it
detected, rather than failing somewhere deep in your suite. Nothing else is
needed — no Chrome, no chromedriver, no Node.

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
provisions the Lightpanda binary itself — downloaded into `~/.cache/lightpanda/`
(`$XDG_CACHE_HOME/lightpanda/` when set) — then boots `lightpanda serve` on an
ephemeral port and connects over CDP.

Two things follow from that, and both surprise people:

- A `lightpanda` already on your `PATH` — Homebrew's, or one you dropped in
  `/usr/local/bin` — is preferred over re-downloading, but only while you're
  unpinned *and* the cached copy is missing or stale. It's a deliberate fallback
  (it keeps VCR/WebMock suites from firing surprise HTTP at github.com), not a
  lookup order to lean on: a warm cache wins over `PATH`, and a pin skips `PATH`
  entirely. Set `browser_path` to the binary you want used unconditionally.
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
| `browser_path` | `nil` | Path to a binary **you** manage — used unconditionally. When `nil` the gem downloads and refreshes its own copy under `~/.cache/lightpanda/`, falling back to a `lightpanda` on `PATH` while that cache is cold or stale (see [quick start](#install)) |
| `window_size` | `[1920, 1080]` | Drives `window.innerWidth`/`innerHeight` and what `@media` / `matchMedia` evaluate against. JS-visible viewport only — no reflow (see [limitations](#limits)). The default mirrors Lightpanda's native viewport, so leaving it alone changes nothing |
| `save_path` | `Capybara.save_path` | Where downloaded files land. Downloads stay off when both are `nil` |
| `logger` | `nil` | An IO (or `Capybara::Lightpanda::Logger`) that receives raw CDP traffic. `LIGHTPANDA_DEBUG=1` wires `$stdout` |
| `raise_on_unhandled_modal` | `false` | A JS dialog that opens with no `accept_*`/`dismiss_*` wrapper in flight is resolved by Lightpanda's default (confirm → cancel, prompt → `null`, alert → dismissed), so a runaway `confirm` cancels the action and the spec still passes. `false` prints a warning naming the dialog text; `true` raises `Capybara::Lightpanda::UnhandledModalError` from the click or `visit` that opened it |
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
  binary.required_version = "0.3.7"   # a tag from lightpanda-io/browser/releases
end
```

A pin is downloaded once into its own version-scoped file
(`~/.cache/lightpanda/lightpanda-0.3.7`), is never refreshed on age, and is
never satisfied by a nightly left over from an earlier run. Cache that directory
in CI and the browser becomes as reproducible as your `Gemfile.lock`.

The driver enforces a floor on both channels and refuses to start below it —
nightly build ≥ 8448, or release ≥ 0.3.7. The error names the version it found
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

### What belongs on which driver

Route by what the spec *asserts*, not by what it touches. A spec belongs on
Cuprite (or whatever full browser you run today) when it depends on:

- screenshots or visual-regression comparison
- pixel geometry — `rect`, spatial finders (`near:`, `above:`), `obscured?` for
  off-viewport elements
- scrolling as an assertion (infinite scroll, sticky-header behavior)
- a second tab or window — `open_new_window`, `within_window`, OAuth popups
- UI revealed purely by CSS `:hover`
- coordinate (non-HTML5) drag — `drag_by`, or `drag_to` on sources that aren't
  HTML5-draggable (mouse-driven libraries like SortableJS in fallback mode)

Everything else — navigation, forms, Turbo, AJAX, auth, file upload and
download, iframes, `@media`-gated responsive variants — runs on Lightpanda. In
the suites we've measured that's the large majority, which is where the memory
and parallelism win comes from.

### Dual driver, per spec { #dual-per-spec }

The steady state: both drivers registered, each spec routed by metadata. This is
what the homepage means by "route the minority to Cuprite."

RSpec system specs — opt out with `visual: true`:

```ruby
# spec/support/capybara.rb
require "capybara-lightpanda"

RSpec.configure do |config|
  config.before(:each, type: :system) do |example|
    driven_by(example.metadata[:visual] ? :cuprite : :lightpanda)
  end
end
```

```ruby
it "renders the chart", :visual do   # → Cuprite
it "creates an invoice" do           # → Lightpanda
```

Plain Capybara feature specs (no Rails system-test layer) switch the driver
directly, and must reset it afterwards or the choice leaks into the next
example:

```ruby
RSpec.configure do |config|
  config.before(:each, type: :feature) do |example|
    Capybara.current_driver = example.metadata[:visual] ? :cuprite : :lightpanda
  end
  config.after(:each, type: :feature) { Capybara.use_default_driver }
end
```

Rails + Minitest routes by base class instead of metadata:

```ruby
# test/application_system_test_case.rb
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :lightpanda
end

# The handful that need real pixels inherit from this one instead.
class VisualSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :cuprite
end
```

### Dual driver, whole suite (A/B the two)

For the first evaluation run — flip the entire suite with an env var and compare
results and wall-clock against your current driver, without touching a single
spec:

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
| Drag-and-drop — `Element#drop` (files or typed data onto a dropzone) | ✓ — geometry-free `DataTransfer` + `DragEvent` (build ≥6699). Files are handed to the browser through `DOM.setFileInputFiles` (read off disk on the Lightpanda host, like `attach_file`), so there is no payload-size ceiling in the driver |
| Drag-and-drop — `Element#drag_to` (HTML5) | ✓ — the same DragEvent simulation Capybara's Selenium driver uses (`dragstart` → `dragenter` → `dragover` → `drop`/`dragend`, one shared `DataTransfer`, `drop_modifiers` supported). A source that isn't HTML5-draggable would need real mouse dragging, which raises `NotImplementedError` (pass `html5: true` to force the simulation). Coordinate `drag_by` is not supported |
| Hover — `hover` | ~ — fires `mouseover` + `mouseenter`, so JS-driven menus open. CSS `:hover` reveals can't work (see [limitations](#limits)) |
| Windows — `current_window`, `resize_to`, `maximize` | ✓ **one window only.** `open_new_window` / `close_window` / a second tab raise `NotSupportedByDriverError` (see [limitations](#limits)) |

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

page.driver.headers = { "X-Tenant" => "acme" } # cleared by reset! — set per session
page.driver.add_headers("Accept-Language" => "fr")
```

Header overrides ride `Network.setExtraHTTPHeaders`. A `User-Agent` set this way
is honored, but Lightpanda rejects any value containing `Mozilla` by design — so
you can label the driver, not disguise it as Chrome.

`reset!` disposes the whole `BrowserContext`, which takes the header overrides
with it — the fresh context never received them, so the driver drops its copy
rather than report headers the browser stopped sending. Set them in a `before`
hook, not once for the suite.

### Console logs

No custom logger class needed. Messages are ring-buffered (cap 1,000, cleared on
reset, driver-internal Turbo sentinels excluded):

```ruby
errors = page.driver.browser.console_logs.select { |m| m[:type] == "error" }
assert_empty errors
```

`:type` is the CDP wire name of the console method — `"log"`, `"info"`,
`"warning"` (not `"warn"`), `"error"`, `"debug"` — so filtering by severity works
directly on every build this gem supports.

The buffer holds explicit `console.*` calls only. An **uncaught** exception is a
different thing and lands in its own buffer.

### Page errors

An exception that escapes page JS never reaches `console_logs`, and on most CDP
stacks it wouldn't: Chrome reports it as `Runtime.exceptionThrown`, and
Playwright and Puppeteer surface it as `pageerror`, separate from `console`. So
the driver keeps them apart too:

```ruby
page.driver.browser.page_errors
# => [{kind: "error", message: "Cannot read properties of undefined (reading 'id')",
#      url: "http://app.test/assets/taxonomy.js", line: 94, column: 22,
#      stack: "TypeError: …", timestamp: 1753449600.0}]
```

`kind` is `"error"` or `"unhandledrejection"`. Same lifecycle as `console_logs`:
capped at 1,000, cleared on reset, and `clear_page_errors` empties it mid-test.

This matters more here than on other drivers, because Lightpanda implements no
`Runtime.exceptionThrown` at all — without this the exception reaches *nothing*.
A handler dying on a `TypeError` leaves every buffer empty while the page quietly
stops doing what it was going to do, and the failure surfaces somewhere else
entirely as `ElementNotFound` on whatever the handler was supposed to produce.
That is a genuinely expensive hour when you don't know to look for it.

The capture is a passive `window` listener injected with the driver's own
bundle, so know what it can't see: an exception a framework catches itself never
reaches `window` (Stimulus routes action errors through its own `handleError`),
and a cross-origin script collapses to `"Script error."` with no detail. Partial,
but the alternative is nothing at all. It disappears the day upstream emits the
event, without the API changing.

Selenium-shaped helpers that
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
| CSS `:hover` | Never matches — there is no pointer, so no hover state enters the cascade. `hover` *does* dispatch real `mouseover` + `mouseenter` events, so a menu opened by a JS listener (every Stimulus `mouseenter->` action, Floating UI, tippy) works; one revealed only by a `:hover` CSS rule does not. A dropdown that "isn't there" after `hover` is usually this |
| Tabs and windows | One window per session. `open_new_window` / `close_window` raise `NotSupportedByDriverError` and `switch_to_window` raises `NoSuchPageError` — upstream serves a single target per CDP connection ([browser#1962](https://github.com/lightpanda-io/browser/issues/1962)). Drive a second page in its own Capybara session, or route those specs to Cuprite |
| Shadow DOM | `shadow_root` and `tag_name` on a root work, and finding inside an open shadow root works. `Node#path` doesn't cross shadow boundaries, so Capybara's `:shadow_dom` shared specs stay opted out — treat shadow DOM as usable but not certified |
| Element geometry | `getBoundingClientRect` is synthesized, not measured — zero for non-rendered elements. So `obscured?` outside the viewport, spatial finders (`near:`, `above:`) and pixel assertions can't work |
| `window.getComputedStyle()` | Partial — CSSOM-backed values resolve (inline styles, `<style>` + external stylesheet rules, `checkVisibility`); full cascade-resolved lookups don't |
| CSS: external `<link>`, `@media`, `matchMedia` | Fetched, parsed, and evaluated against the configured `window_size` — responsive variants resolve at the width you set. What's absent is reflow, not the media query |
| User agent | `Lightpanda/1.0` — no Chrome/Safari token, and Mozilla-styled UA overrides are rejected by design. App-side UA bot detection flags the driver as a bot; allowlist `Lightpanda` in your test environment |
| Complex Stimulus controllers | Some may not execute fully |

External `<link rel="stylesheet">` files are fetched and parsed by default — the driver always passes `--enable-external-stylesheets` — so linked CSS contributes to the cascade and `checkVisibility` / `getComputedStyle` reflect it. `@media`-gated duplicates (mobile/desktop CTA variants) now collapse to a single visible variant instead of raising `Capybara::Ambiguous`. Breakpoints resolve at whatever `window_size` you configure, so a suite that runs mobile-width specs can register a second driver at `[375, 812]`. The catch is that the viewport is JS-visible only: nothing reflows, so a spec that asserts on pixel-level layout, scrolling, or that an element is visually obscured still belongs on Cuprite — that's what the dual-driver pattern above is for.

## Validated against real apps { #validation }

Capability tables are self-reported, so here is the other kind of evidence: CI
patches six production Rails codebases to run *their own* specs on this driver,
against a pinned upstream SHA, weekly and on demand. Each was on a different
driver before the swap, so
[the patches](https://github.com/navidemad/capybara-lightpanda/tree/main/.github/real-apps/patches)
double as worked migration examples — including the Gemfile and driver-registration
diff for a Selenium, Cuprite and Playwright starting point.

| App | Migrated from | Specs exercised | Known failures |
|---|---|---|---|
| [mastodon](https://github.com/mastodon/mastodon) | Playwright | `home`, `log_in`, `log_out` system specs | **0** |
| [alonetone](https://github.com/sudara/alonetone) | Playwright | `pages`, `account_requests`, `users` features | **0** |
| [spree](https://github.com/spree/spree) | Selenium | admin: getting-started, settings, API keys, … | 1 |
| [forem](https://github.com/forem/forem) | Cuprite | `homepage`, `comments`, `articles`, `authentication` system specs | 11 |
| [decidim](https://github.com/decidim/decidim) | Selenium | `accesslist`, `account` system specs | 16 |
| [solidus](https://github.com/solidusio/solidus) | Selenium | all of `spec/features/admin` | 68 |

These are deliberate spec subsets, not whole suites — chosen to cover the
interactive surface without a 40-minute job. Every known failure is catalogued in
[`causes.yml`](https://github.com/navidemad/capybara-lightpanda/blob/main/.github/real-apps/causes.yml)
with its mechanism, a confidence level (`confirmed` / `likely` / `unknown`) and a
link to the upstream gap. A failure matching *no* recorded cause fails the job,
so an unexplained regression can't hide inside an accepted baseline.

Read the table as a shape rather than a score. Solidus's count is dominated by a
single mechanism: its admin Tabs component measures `offsetWidth` to decide
whether to collapse tabs into a `:hover` dropdown, and against synthetic geometry
it always concludes "overflowed", hiding most tabs behind a menu that `:hover`
can't open. One missing capability, dozens of failures. That's the profile to
expect — failures cluster onto a few root causes instead of scattering, which is
also why triaging your own suite goes faster than the raw count suggests.

## Troubleshooting { #troubleshooting }

| Symptom | What it means |
|---|---|
| `UnsupportedPlatformError: Unsupported platform: …` | No upstream binary for that arch/OS pair — see [requirements](#install). Windows needs WSL2 |
| `BinaryError: Lightpanda <version> is too old` | The cached or pinned binary is under the gem's floor. The message names the version it found and the exact command to move off it |
| `PortInUseError: … port N is already in use` | An earlier Lightpanda still holds the port. The driver reclaims it via `lsof` when available; leaving `port = 0` (the default) sidesteps this entirely, including under parallel workers |
| Binary download fails, or a `WebMock`/`VCR` error during it | The first-run download is being caught by your HTTP stubs. Pre-provision from an unstubbed process — `bundle exec ruby -r capybara-lightpanda -e 'puts Capybara::Lightpanda::Binary.update'` — then set `LIGHTPANDA_CACHE_TIME=0` so the warm copy is never refreshed mid-suite |
| `DeadBrowserError` | The browser process died mid-command, usually an upstream crash on the page under test. The driver respawns and retries once; a reproducible one is worth an issue with the URL |
| `NoExecutionContextError` | The JS context was swapped mid-command — a child iframe navigating invalidates the main frame's context upstream. The driver retries on context re-creation and Capybara reloads the element, so persistent cases mean the page churns iframes faster than the retry window |
| `ElementNotFound` on a menu item after `hover` | CSS `:hover` reveals nothing here. JS-driven menus do open (`mouseover` + `mouseenter` are dispatched); a `:hover`-only menu needs Cuprite. See [limitations](#limits) |
| `ElementNotFound` on a menu item after `click` | Often the menu closed itself: a `click@window->close` listener registered up front sees the opening click bubble and closes in the same dispatch. The [dropdown example](#examples) reproduces this and the variant that works |
| Something is slow, or hangs on one page | `LIGHTPANDA_DEBUG=1` streams raw CDP traffic to `$stdout`, and `page.driver.browser.console_logs` surfaces page-side JS errors. `page.driver.network.traffic` shows what never came back |

Not listed here? [Open an issue](https://github.com/navidemad/capybara-lightpanda/issues)
with the URL or a minimal spec — beta-tagged issues are triaged within 48 h, and
[BETA_TESTING.md](https://github.com/navidemad/capybara-lightpanda/blob/main/BETA_TESTING.md)
covers what to include.

## How it works { #internals }

| Component | Responsibility |
|---|---|
| `Capybara::Lightpanda::Browser` | High-level page API; falls back to `document.readyState` polling when `Page.loadEventFired` is unreliable |
| `Capybara::Lightpanda::Client` | CDP command dispatch over WebSocket with timeouts and event subscription |
| `Capybara::Lightpanda::Driver` | The Capybara driver — registers as `:lightpanda`, exposes `set_cookie` / `clear_cookies` / `remove_cookie` |
| `Capybara::Lightpanda::Node` | DOM operations via `Runtime.callFunctionOn` with object-id binding |
| `Capybara::Lightpanda::Cookies` | `Enumerable` over `Network.getAllCookies` (every origin in the context), plus `setCookie` / `deleteCookies` / bulk `clearBrowserCookies`, and a YAML `store` / `load` round-trip |
| `Capybara::Lightpanda::Network` | Counts in-flight requests from `Network.requestWillBeSent` / `responseReceived` — backs `status_code`, `response_headers`, `wait_for_network_idle`, and the header overrides |
| `lib/capybara/lightpanda/javascripts/*.js` | The injected `_lightpanda` bundle, split by concern — `turbo.js` (Turbo activity tracking), `errors.js` (uncaught-exception capture behind `page_errors`) and `predicates.js` (`isVisible`, `isObscured`, `isDisabled`, `isContentEditable`, `visibleText`), wired by `attach.js` and assembled into one IIFE by `AutoScripts`, then registered once per session via `Page.addScriptToEvaluateOnNewDocument` |

The driver speaks the same CDP dialect Cuprite and Ferrum use, so most patterns from those projects translate directly. Where Lightpanda diverges from Chromium, the driver papers over it.

## Examples { #examples }

Runnable Rails demos in the repo, covering both **RSpec** and **Minitest**, with and without **Turbo**:

- [`rails_minitest_example.rb`](https://github.com/navidemad/capybara-lightpanda/blob/main/examples/rails_minitest_example.rb) — system test with Minitest
- [`rails_rspec_example.rb`](https://github.com/navidemad/capybara-lightpanda/blob/main/examples/rails_rspec_example.rb) — system spec with RSpec
- [`rails_turbo_minitest_example.rb`](https://github.com/navidemad/capybara-lightpanda/blob/main/examples/rails_turbo_minitest_example.rb) — Turbo Drive + Frames with Minitest
- [`rails_turbo_rspec_example.rb`](https://github.com/navidemad/capybara-lightpanda/blob/main/examples/rails_turbo_rspec_example.rb) — Turbo Drive + Frames with RSpec
- [`rails_dropdown_minitest_example.rb`](https://github.com/navidemad/capybara-lightpanda/blob/main/examples/rails_dropdown_minitest_example.rb) — a click-to-open dropdown, in the variant that works and the variant that closes itself on the opening click. Run it when a menu item comes back `ElementNotFound`

## Reference { #reference }

- [README on GitHub](https://github.com/navidemad/capybara-lightpanda/blob/main/README.md)
- [CHANGELOG](https://github.com/navidemad/capybara-lightpanda/blob/main/CHANGELOG.md)
- [Issues](https://github.com/navidemad/capybara-lightpanda/issues)
- [Lightpanda upstream](https://github.com/lightpanda-io/browser) — the browser that powers this driver
