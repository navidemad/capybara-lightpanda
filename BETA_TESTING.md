# Beta testing capybara-lightpanda

`capybara-lightpanda` is `0.1.0` — public beta. Real Rails suites are how we find the edges. This guide is the shortest path from "I'm curious" to "I have data and an opinion."

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

Install the binary once:

```bash
# macOS
brew install lightpanda-io/lightpanda/lightpanda

# Linux x86_64
curl -L -o /usr/local/bin/lightpanda \
  https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-x86_64-linux
chmod +x /usr/local/bin/lightpanda
```

Run one suite:

```bash
BROWSER=lightpanda bundle exec rails test test/system/
# or
BROWSER=lightpanda bundle exec rspec spec/system/
```

**Rollback is the env var.** Drop `BROWSER=lightpanda` and your suite returns to whatever driver you had before. `Gemfile.lock` is the only persistent change.

## What we expect to fail (don't file these)

These are browser-level limitations of Lightpanda itself, not bugs in the gem. The driver raises `Capybara::NotImplementedError` so you can `skip` cleanly.

- **Real screenshots** — Lightpanda has no compositor. `page.save_screenshot` returns a hardcoded 1920×1080 PNG.
- **Visual regression / pixel tests** — same reason; keep these on Cuprite.
- **Scroll, resize, full `getComputedStyle`** — no layout engine.
- **File uploads** (`input[type=file]`) — not yet implemented upstream ([lightpanda#2175](https://github.com/lightpanda-io/browser/issues/2175)).
- **Service Workers, Web Workers** — not yet implemented ([lightpanda#2017](https://github.com/lightpanda-io/browser/issues/2017)).
- **WebAuthn / passkeys** — not implemented.
- **`accept_modal(:confirm | :prompt)` overriding the JS return value** — Lightpanda auto-dismisses dialogs; the gem captures the message but cannot influence the JS-side return. `accept_modal(:alert)` and `dismiss_modal(:confirm | :prompt)` work.

A clean way to skip those in a mixed suite:

```ruby
def skip_on_lightpanda(reason)
  skip(reason) if ENV["BROWSER"] == "lightpanda"
end

it "uploads an avatar", :file_upload do
  skip_on_lightpanda "lightpanda: input[type=file] not implemented"
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
- Breaking changes between `0.1.x` and `1.0` will land in `CHANGELOG.md` with migration notes — no silent renames.

## What's coming

The known matrix of in-flight upstream work that affects this gem is tracked in [`.claude/rules/lightpanda-io.md`](./.claude/rules/lightpanda-io.md). Highlights:

- **PR #2244** (filed by us) — once merged, we can drop the gem-side `#id` selector polyfill that works around a CSS-engine bug exposed by Turbo Drive's body-swap pattern.
- **PR #2241** — bounded per-tick memory growth for long-lived sessions on JS-heavy SPAs.
- **PR #2078** (WIP) — Web Worker support; closes [#2017](https://github.com/lightpanda-io/browser/issues/2017).

## What's _not_ on the roadmap

- A pixel-rendering layer. Lightpanda is headless by design. If you need real rendering, keep Cuprite for those specs and run both side-by-side — that's the supported path.
- Replacing Cuprite. The dual-driver pattern is the recommendation.

Thanks for testing. Real numbers from real suites are what gets us to `1.0`.
