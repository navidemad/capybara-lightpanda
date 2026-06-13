# Real-app system-test coverage tracker

Run a real Rails app's full `test/system/` suite against the Lightpanda driver
and record per-test pass/fail as JSON, so you can diff runs over time and watch
Lightpanda coverage improve as the gem and the browser get better.

This tooling lives in the **capybara-lightpanda** repo but drives a separate,
private Rails app you point it at with `APP_DIR`. It changes nothing in that app
— the JSON reporter is injected at runtime via `RUBYOPT`, not added to its
Gemfile or test helper. The app's name and path are never hard-coded here.

## Files

| File | Purpose |
|---|---|
| `run.sh` | Orchestrator: rebuild browser from upstream `main`, warm fixtures, run the suite single-process, emit JSON. |
| `json_reporter.rb` | Minitest reporter injected via `RUBYOPT`; writes structured per-test JSON. No app-side changes. |
| `diff.sh` | Compare two runs — which tests got FIXED / REGRESSED / are NEW / GONE, plus a pass-count delta. |
| `results/` | Per-run `<timestamp>.json` + `.log` and a `latest.json` symlink. **Gitignored.** |

## Usage

Point `APP_DIR` at the Rails app under test (required — there is no default, so
the private app path stays out of this tracked script).

```bash
# Full suite. Rebuilds the browser from upstream main first (a few minutes),
# installs it into the gem's binary cache, then runs all of test/system/.
APP_DIR=/path/to/app script/real-app-coverage/run.sh

# Reuse whatever binary is already cached (skip the git-pull + zig build):
APP_DIR=/path/to/app SKIP_BUILD=1 script/real-app-coverage/run.sh

# A subset (any args are passed straight to `rails test`):
APP_DIR=/path/to/app script/real-app-coverage/run.sh test/system/cookie_consent_test.rb

# Compare the two most recent runs (or pass two explicit files):
script/real-app-coverage/diff.sh
script/real-app-coverage/diff.sh results/OLD.json results/NEW.json
```

## How it works / why these choices

- **Auto-build from `main`** — each run pulls and rebuilds
  `/Users/navid/code/browser`, so you test the freshest upstream, including
  fixes merged but not yet in a published nightly. The first build backs up your
  previously-cached binary to `~/.cache/lightpanda/lightpanda.published.bak`.
  Pass `SKIP_BUILD=1` to reuse the cached binary.
  - **Needs full Xcode, not just Command Line Tools.** A from-scratch V8 build
    (triggered when V8's gn config is stale) calls `xcodebuild`, which CLT-only
    machines can't satisfy (`tool 'xcodebuild' requires Xcode`). When the build
    fails, the script **falls back** to the most recent already-built binary
    (`zig-out/bin/lightpanda`, then the cached binary) so the run still produces
    results — just against an older build. To genuinely test the latest `main`,
    install full Xcode (`xcode-select --switch /Applications/Xcode.app`) so the
    rebuild succeeds, or use `SKIP_BUILD=1` with a binary you built elsewhere.
- **Single-process (`PARALLEL_WORKERS=0`)** — a real app typically parallelizes
  system tests by forking workers above 50 tests. The reporter aggregates results
  in one process's memory, so forks would each capture only their own slice.
  Single process keeps results complete and deterministic. Lightpanda is fast, so
  even a few-hundred-test suite runs in a few minutes.
- **Never stops on failure** — the whole suite runs to completion every time, so
  each JSON captures the full passing-count picture (not "stopped at first red").
- **JSON for diffing** — `diff.sh` reports exactly which tests flipped pass↔fail
  between two runs. `skip` counts as neither fixed nor regressed.

## Result JSON shape

```json
{
  "meta": {
    "generated_at": "2026-06-13T...Z",
    "total": 357, "pass": 300, "fail": 40, "error": 12, "skip": 5,
    "browser_build": "1.0.0-dev.6750+ab53f92a",
    "gem_version": "0.8.0"
  },
  "results": [
    { "klass": "CookieConsentTest", "name": "test_accept_all_cookies",
      "status": "pass", "time": 0.83, "message": "" }
  ]
}
```

## Overrides

| Env | Default | Meaning |
|---|---|---|
| `APP_DIR` | _(required)_ | The Rails app under test. No default — keeps the private app path out of this tracked script. |
| `SKIP_BUILD` | `0` | `1` = don't rebuild the browser; use the cached binary. |
| `BROWSER_DIR` | `/Users/navid/code/browser` | Lightpanda browser checkout to build. |
