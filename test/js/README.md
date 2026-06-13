# JS predicate harness (Bun)

Fast, dev-only unit tests for the DOM predicate logic that ships in the
injected `_lightpanda` bundle (`lib/capybara/lightpanda/javascripts/`). Runs in
~0.1s, so you don't have to wait on the 2–6 minute Capybara battery to check a
change to `visibleText`, `isContentEditable`, `isDisabled`, etc.

This directory is **not part of the gem** — the gemspec packages `lib/**` only,
so nothing here (including `node_modules/`) is published to RubyGems.

## Run

```bash
bundle exec rake test:js     # from the repo root — installs deps, runs the suite
# or directly:
cd test/js && bun install && bun test
```

`rake test:js` skips with a notice (not a failure) if Bun isn't installed, so
contributors without Bun can still run `rake default`.

## How it works

The loader (`load.ts`) reads the **shipped** `predicates.js` text and evaluates
it with `new Function(...)` against a [happy-dom](https://github.com/capricorn86/happy-dom)
`Window`. `new Function` parses its body as a classic script — the same mode
the browser uses for the injected IIFE — so the tests exercise the exact bytes
that get injected, with no build step and no second copy of the logic. The
predicate names are derived from the source, and `load.test.ts` asserts the
exposed surface matches what `attach.js` wires onto `window._lightpanda`, so a
predicate can't be added to the bundle (or wired) without test coverage.

happy-dom has no real layout and no `checkVisibility()`, so the tests target
the gem's own logic (whitespace/block rules, ancestor walks, the real
`visibility:hidden` short-circuits) and leave deep hit-testing to the Capybara
battery.

## Bun

Install Bun via any official method — the Zig→Rust core rewrite (merged
2026-05-14) did not change installation or the `bun test` CLI:

```bash
curl -fsSL https://bun.com/install | bash   # macOS / Linux
brew install oven-sh/bun/bun                 # Homebrew
# or via mise — the repo's mise.toml pins bun to match .bun-version
```

The version is pinned three ways that all agree: `.bun-version`,
`package.json`'s `packageManager` field, and the repo `mise.toml`. CI reads
`.bun-version` via `oven-sh/setup-bun@v2`. `bun.lock` (text format) is committed
for reproducible installs.
