# Beta testing capybara-lightpanda

<!-- version-bearing — keep in sync with lib/capybara/lightpanda/version.rb -->
`capybara-lightpanda` is `0.6.0` — public beta. Real Rails suites are how we find the edges. This guide is the shortest path from "I'm curious" to "I have data and an opinion."

## TL;DR — try it in 5 minutes

```ruby
# Gemfile (test group)
gem "capybara-lightpanda"
```

```ruby
# spec/support/capybara.rb · or test/support/capybara.rb
if ENV["BROWSER"] == "lightpanda"
  require "capybara-lightpanda"
  Capybara.javascript_driver = :lightpanda
end
```

**Rails system tests don't read `Capybara.javascript_driver`** — `ActionDispatch::SystemTestCase` (and RSpec system specs) pick their driver through `driven_by`. Gate it the same way:

```ruby
# minitest — test/application_system_test_case.rb
driven_by ENV["BROWSER"] == "lightpanda" ? :lightpanda : :selenium_chrome_headless

# RSpec — spec/support/system.rb
config.before(:each, type: :system) do
  driven_by ENV["BROWSER"] == "lightpanda" ? :lightpanda : :selenium_chrome_headless
end
```

**Binary install is optional.** By default the gem auto-downloads the nightly Lightpanda binary into `~/.cache/lightpanda/lightpanda` on first use. If you'd rather manage it yourself (or your test setup blocks outbound HTTP via VCR/WebMock), install it ahead of time and the gem will pick it up from `PATH`:

```bash
# macOS
brew install lightpanda-io/browser/lightpanda

# Linux x86_64
curl -L -o /usr/local/bin/lightpanda \
  https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-x86_64-linux
chmod +x /usr/local/bin/lightpanda
```

WebMock/VCR intercepts the auto-download because it runs as plain `Net::HTTP` inside the test process. If you'd rather not install a binary, trigger the download once from an unstubbed process and the cached copy is used from then on:

```bash
bundle exec ruby -r capybara-lightpanda -e 'puts Capybara::Lightpanda::Binary.update'
```

Run one suite:

```bash
BROWSER=lightpanda bundle exec rails test test/system/
# or
BROWSER=lightpanda bundle exec rspec spec/system/
```

**Rollback is the env var.** Drop `BROWSER=lightpanda` and your suite returns to whatever driver you had before. `Gemfile.lock` is the only persistent change.

## Parallel test suites

Each worker needs its own Lightpanda port — sharing the default kills the second worker with `ProcessTimeoutError: port 9222 is already in use`. Pass `port: 0` and the OS assigns a free ephemeral port to every worker; the gem reads the actual address back from Lightpanda's startup output:

```ruby
Capybara.register_driver(:lightpanda) do |app|
  Capybara::Lightpanda::Driver.new(app, port: 0)
end
```

Re-registering `:lightpanda` overrides the gem's default registration, so `Capybara.javascript_driver = :lightpanda` and `driven_by(:lightpanda)` both keep working. If you'd rather have deterministic ports per worker, `parallel_tests` exposes `TEST_ENV_NUMBER`:

```ruby
Capybara::Lightpanda::Driver.new(app, port: 9222 + ENV["TEST_ENV_NUMBER"].to_i)
```

## What we expect to fail (don't file these)

These are browser-level limitations of Lightpanda itself, not bugs in the gem. The driver raises `Capybara::NotImplementedError` so you can `skip` cleanly.

- **Real screenshots** — Lightpanda has no compositor. `page.save_screenshot` returns a hardcoded 1920×1080 PNG.
- **Visual regression / pixel tests** — same reason; keep these on Cuprite.
- **Scroll, resize, full `getComputedStyle`** — no layout engine.
- **Service Workers, SharedWorker** — not implemented; Web Worker support is partial ([lightpanda#2017](https://github.com/lightpanda-io/browser/issues/2017)).
- **WebAuthn / passkeys** — not implemented.
- **Coordinate-based `drag_to` / `drag_by`** — no layout engine, no coordinates. HTML5 `Element#drop` (dropping files or data onto a dropzone) works since `0.6.0`.
- **JS dialogs fired outside Capybara's modal wrappers** — the gem pre-arms the dialog response before the triggering action, so `accept_confirm` / `dismiss_confirm` / `accept_prompt` & co. work, including the JS-side `confirm`/`prompt` return values. A dialog that opens *outside* one of those wrappers is auto-dismissed by Lightpanda.

A clean way to skip those in a mixed suite:

```ruby
def skip_on_lightpanda(reason)
  skip(reason) if ENV["BROWSER"] == "lightpanda"
end

it "matches the dashboard screenshot", :visual do
  skip_on_lightpanda "lightpanda: no compositor — screenshots are stubbed"
  # ...
end
```

## What we'd love to hear

When you file feedback, three signals matter most:

1. **Auth flows** — sign-in, sign-up, password reset, 2FA, magic links. End-to-end.
2. **Turbo Stream / Turbo Frame divergences** — anything that behaves differently than Cuprite, especially around morphing (`turbo-rails` ≥ 8.0).
3. **CI memory headroom** — how much did you free up, and could you raise parallelism on the same runner?

## How to file

- **Something broke** → [Beta feedback issue template](https://github.com/navidemad/capybara-lightpanda/issues/new?template=beta-feedback.yml). Repro snippet + Cuprite parity check is the gold standard.
- **It worked** → [Beta success template](https://github.com/navidemad/capybara-lightpanda/issues/new?template=it-worked.yml). Numbers if you measured. Optional public credit.
- **Want to talk first** → [Discussions](https://github.com/navidemad/capybara-lightpanda/discussions). Drop your suite size + Rails/Turbo versions in the intake thread.
- **Bug is upstream** (CDP method missing, JS API not implemented) → [lightpanda-io/browser](https://github.com/lightpanda-io/browser/issues). Cross-link from your issue here so we can track.

## Maintainer pact

- **Triage within 48 hours** for `beta-feedback`-tagged issues.
- If a workaround exists, you'll get it the same day.
- If it's a Lightpanda-side bug, I'll file or cross-link upstream and tell you which PR / issue to watch.
- Breaking changes between `0.x` and `1.0` will land in `CHANGELOG.md` with migration notes — no silent renames.

## What's coming

The known matrix of in-flight upstream work that affects this gem is tracked in [`.claude/rules/lightpanda-io.md`](./.claude/rules/lightpanda-io.md). Highlights:

- **[#2017](https://github.com/lightpanda-io/browser/issues/2017)** — SharedWorker and the remaining Web Worker APIs (partial Worker support landed in PR #2078).
- **[#1801](https://github.com/lightpanda-io/browser/issues/1801)** — `Page.loadEventFired` may never fire on JS-heavy pages; the gem's `readyState` polling fallback covers it, at the cost of some latency.
- **[#2173](https://github.com/lightpanda-io/browser/issues/2173)** — browser crash navigating to some React apps over CDP; the gem auto-reconnects, but heavy SPA suites may still surface `DeadBrowserError`.

## What's _not_ on the roadmap

- A pixel-rendering layer. Lightpanda is headless by design. If you need real rendering, keep Cuprite for those specs and run both side-by-side — that's the supported path.
- Replacing Cuprite. The dual-driver pattern is the recommendation.

Thanks for testing. Real numbers from real suites are what gets us to `1.0`.
