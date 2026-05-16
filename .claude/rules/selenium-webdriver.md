# Selenium WebDriver (Ruby bindings)

Upstream repo: https://github.com/SeleniumHQ/selenium (tree `rb/`)
Role: W3C WebDriver Ruby client. Different protocol family from us (WebDriver / BiDi, not CDP), so most of the wire-level code doesn't transfer. What does transfer lives in `rb/lib/selenium/webdriver/common/` and `rb/lib/selenium/webdriver/support/` — ergonomic helpers that ship on top of *any* remote browser driver, ours included.

Maintained alongside `lightpanda-io.md` (browser upstream) and `ruby-cdp-peers.md` (Ferrum/Cuprite peers). Don't write a changelog — when a pattern is adopted, move it from "Outstanding" to "Adopted" inline.

**Last reviewed**: 2026-05-16 against selenium `main` HEAD `16de35bde8` (2026-05-15).

## Adopted

- **`Utils::Wait` block-poller** — `selenium/rb/lib/selenium/webdriver/common/wait.rb` ↔ `lib/capybara/lightpanda/utils/wait.rb`. Module-method form (`Utils::Wait.until(timeout:, interval:, ignore:, message:) { … }`) instead of Selenium's `Wait.new(...).until { … }` class form — matches our `Utils::Attempt.with_retry` shape and no callsite retains state across calls. Raises our existing `Capybara::Lightpanda::TimeoutError` instead of a Wait-private one to keep the error hierarchy flat. Used in `Network#wait_for_idle!`, `Browser#poll_ready_state` (readyState fallback), and `Browser#find_modal` — previously three hand-rolled `loop { … break if monotonic_time > deadline; sleep … }` blocks with bespoke deadline math.

## Outstanding adoption candidates

- **[tiny] `Support::Escaper.escape`** — `selenium/rb/lib/selenium/webdriver/support/escaper.rb` (~15 LOC). XPath-safe string-literal escaper that handles the both-quotes case via `concat(…, '"', …)`. We don't currently build XPath from user-supplied text (find paths route through `Document.evaluate` after PR #2305), so there's no immediate need — but a future `find_modal_by_text` or similar callsite would want it. Adopt at first use.
- **[tiny] `Logger.deprecate(old, new, reference:)`** — `selenium/rb/lib/selenium/webdriver/common/logger.rb`. Standardized deprecation message format with optional reference URL. Our `Lightpanda::Logger` is currently a 37-LOC `puts` wrapper. Adopt the next time we ship a deprecation (e.g. `MINIMUM_NIGHTLY_BUILD` floor bump that drops support for an older shape, or a method rename). Probably brings the `id:`/`ignore`/`allow` filter trio along — they're cheap and pair well.
- **[medium] `Support::Color`** — `selenium/rb/lib/selenium/webdriver/support/color.rb` (~140 LOC). Parses every CSS color format (`rgb()`/`rgba()`/`#hex`/`#hex3`/`hsl()`/`hsla()`) into a value object with `.rgb`/`.rgba`/`.hex`. Lightpanda's CSSOM is rich enough that `node.style("color")` returns parseable strings. Defer until a user actually wants color assertions; no current demand and Capybara doesn't have a color primitive either.

## Diverged on purpose

- **`Navigation` / `Timeouts` / `TargetLocator` / `Script`** (`selenium/rb/lib/selenium/webdriver/common/*.rb`) — W3C WebDriver façades that delegate to a `bridge` object. We don't have a bridge abstraction — Capybara *is* the public surface, with `Browser` as the lone CDP client. Wrapping CDP a second time in WebDriver-shaped façades adds no value.
- **`bidi/*` (W3C BiDi protocol)** — `selenium/rb/lib/selenium/webdriver/bidi/`. BiDi and CDP solve overlapping problems but use different wire formats and different JSON shapes; there's no clean "borrow this" without a parallel BiDi implementation.
- **`Keys::KEYS` Unicode-PUA codepoints** — `selenium/rb/lib/selenium/webdriver/common/keys.rb`. WebDriver's wire protocol expects PUA codepoints (`` = backspace) the remote end decodes. CDP's `Input.dispatchKeyEvent` takes `key`/`code`/`keyCode`/`text` triples directly — our `Keyboard::KEYS` (`lib/capybara/lightpanda/keyboard.rb`) is the right shape for that wire format and arguably nicer than the magic-codepoint indirection.
- **`Support::RelativeLocator`** (`above`, `below`, `near`, `left`, `right`, `distance`) — `selenium/rb/lib/selenium/webdriver/support/relative_locator.rb`. Builds spatial-relation locators evaluated by the remote end. Lightpanda has no layout/rendering engine, so coordinates and spatial relations don't apply. Same family of divergence as our missing `Mouse`/`Keyboard` coordinate abstractions vs. Ferrum.
- **`action_builder.rb` + `interactions/*`** — `selenium/rb/lib/selenium/webdriver/common/action_builder.rb` and `interactions/`. W3C Actions API for chained mouse/key/wheel sequences with `pointer_press`, `pointer_move`, `scroll_origin`, etc. Coordinate-based; doesn't apply to us. We dispatch clicks through JS (`Node#click` → `CLICK_JS`), matching the divergence already documented in `ruby-cdp-peers.md` against Ferrum's `Mouse`/`Keyboard`.
- **`Support::Select`** — `selenium/rb/lib/selenium/webdriver/support/select.rb` (~270 LOC). Programmatic API for `<select>` (`select_by(:text, …)`, `selected_options`, `select_all`, etc.). Capybara already covers select/unselect semantics in its core DSL (`#select`, `#unselect`), so bundling Selenium's Select would be redundant for our users.
- **`devtools/network_interceptor.rb` + `driver_extensions/has_network_interception.rb`** — Selenium's CDP-based request interceptor. Our `Network` class already mirrors Ferrum's traffic tracker (request/response events, `pending_connections`, `traffic`, `wait_for_idle`/`wait_for_idle!`); adding Selenium's interceptor on top wouldn't expand coverage.
- **`Support::Wait` class form** — see Adopted above. We use a module method (`Utils::Wait.until`) rather than `Wait.new(opts).until { … }`. Same primitive, simpler shape, no instance reuse pattern in our callsites.
