#!/usr/bin/env bash
# Run a real Rails app's full system-test suite against the Lightpanda driver
# and record per-test pass/fail as JSON, so you can diff runs over time and see
# whether Lightpanda coverage is improving.
#
# Point it at the app under test with APP_DIR (a private Rails checkout that
# uses BROWSER=lightpanda to drive its `test/system/` suite via this gem).
#
# What it does, in order:
#   1. Rebuilds the Lightpanda browser from the latest upstream `main`
#      (git pull + zig build) and installs it into the gem's binary cache, so
#      every run tests the freshest upstream — including fixes merged but not
#      yet in a published nightly.
#   2. Warms the app's fixture_kit cache (required before system tests).
#   3. Runs `test/system/` single-process (PARALLEL_WORKERS=0) under
#      BROWSER=lightpanda, never stopping on failure, with a JSON reporter
#      injected via RUBYOPT (no changes to the app repo).
#   4. Writes results/<timestamp>.json and updates results/latest.json.
#
# Results live in this script's results/ dir, which is gitignored.
#
# Usage:
#   APP_DIR=/path/to/app script/real-app-coverage/run.sh                 # full test/system/ suite
#   APP_DIR=/path/to/app script/real-app-coverage/run.sh test/system/foo_test.rb   # subset
#   APP_DIR=/path/to/app SKIP_BUILD=1 script/real-app-coverage/run.sh    # reuse current cached binary
#
# Env knobs:
#   APP_DIR=...      The Rails app under test (REQUIRED — no default; keeps the
#                    private app name and path out of this tracked script).
#   SKIP_BUILD=1     Skip the browser git-pull/rebuild; use whatever is cached.
#   BROWSER_DIR=...  Override the lightpanda browser checkout (default below).

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
REPORTER="$SCRIPT_DIR/json_reporter.rb"

APP_DIR="${APP_DIR:-}"
BROWSER_DIR="${BROWSER_DIR:-/Users/navid/code/browser}"
CACHE_BIN="${XDG_CACHE_HOME:-$HOME/.cache}/lightpanda/lightpanda"

# Test scope: default to the whole system suite, or whatever args are passed.
TEST_SCOPE=("${@:-test/system/}")

log() { printf '\033[1;34m[coverage]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[coverage] %s\033[0m\n' "$*" >&2; exit 1; }

[ -n "$APP_DIR" ] || die "set APP_DIR to the Rails app under test (e.g. APP_DIR=/path/to/app $0)"
[ -d "$APP_DIR" ] || die "APP_DIR not found at $APP_DIR"
mkdir -p "$RESULTS_DIR"

# --- 1. Rebuild the browser from upstream main -----------------------------
if [ "${SKIP_BUILD:-0}" = "1" ]; then
  log "SKIP_BUILD=1 — using the already-cached binary"
else
  [ -d "$BROWSER_DIR/.git" ] || die "lightpanda browser checkout not found at $BROWSER_DIR (set BROWSER_DIR or SKIP_BUILD=1)"
  command -v zig >/dev/null 2>&1 || die "zig not on PATH — needed to build the browser (or pass SKIP_BUILD=1)"

  log "Pulling latest upstream main in $BROWSER_DIR"
  git -C "$BROWSER_DIR" fetch origin main --quiet
  git -C "$BROWSER_DIR" checkout main --quiet
  git -C "$BROWSER_DIR" pull --ff-only origin main --quiet

  log "Building lightpanda (zig build -Doptimize=ReleaseSafe) — this takes a few minutes"
  BUILT="$BROWSER_DIR/zig-out/bin/lightpanda"
  if ( cd "$BROWSER_DIR" && zig build -Doptimize=ReleaseSafe ); then
    [ -x "$BUILT" ] || die "build reported success but did not produce $BUILT"
    log "Installing fresh build into gem cache at $CACHE_BIN"
    mkdir -p "$(dirname "$CACHE_BIN")"
    # Keep a one-time backup of whatever was there before (e.g. a published nightly).
    [ -f "$CACHE_BIN" ] && [ ! -f "$CACHE_BIN.published.bak" ] && cp "$CACHE_BIN" "$CACHE_BIN.published.bak"
    cp "$BUILT" "$CACHE_BIN"
    touch "$CACHE_BIN"  # mark fresh so the gem uses it directly (no re-download)
  else
    # The browser's V8 step needs a full Xcode install (`xcodebuild`), not just
    # the Command Line Tools, to reconfigure from scratch. Rather than abort the
    # whole coverage run, fall back to the most recent usable binary so you still
    # get results — just against an older build. Pass SKIP_BUILD=1 to silence this.
    log "\033[1;31mzig build FAILED\033[0m — falling back to an already-built binary."
    log "  (A from-scratch V8 build needs full Xcode; CLT-only machines hit 'xcodebuild requires Xcode'.)"
    if [ -x "$BUILT" ]; then
      log "Using previously-built $BUILT and installing it into the cache"
      mkdir -p "$(dirname "$CACHE_BIN")"
      [ -f "$CACHE_BIN" ] && [ ! -f "$CACHE_BIN.published.bak" ] && cp "$CACHE_BIN" "$CACHE_BIN.published.bak"
      cp "$BUILT" "$CACHE_BIN"
      touch "$CACHE_BIN"
    elif [ -x "$CACHE_BIN" ]; then
      log "No zig-out binary; using whatever is already cached at $CACHE_BIN"
    else
      die "build failed and no fallback binary exists (no $BUILT, no $CACHE_BIN). Install full Xcode, or run with SKIP_BUILD=1 after providing a binary."
    fi
  fi
fi

[ -x "$CACHE_BIN" ] || die "no usable lightpanda binary at $CACHE_BIN"
BROWSER_BUILD="$("$CACHE_BIN" version 2>/dev/null | head -1)"
log "Browser build under test: $BROWSER_BUILD"

# --- 2. Warm the fixture_kit cache -----------------------------------------
log "Warming fixture_kit cache (RAILS_ENV=test)"
( cd "$APP_DIR" && RAILS_ENV=test bundle exec rails fixture_kit:warm >/dev/null 2>&1 ) \
  || log "fixture_kit:warm reported a non-zero exit — continuing (some setups warm lazily)"

GEM_VERSION="$(cd "$APP_DIR" && bundle exec ruby -e 'require "capybara-lightpanda"; print Capybara::Lightpanda::VERSION' 2>/dev/null || echo "unknown")"
log "capybara-lightpanda gem version: $GEM_VERSION"

# --- 3. Run the suite single-process with the JSON reporter injected --------
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_JSON="$RESULTS_DIR/$STAMP.json"
RAW_LOG="$RESULTS_DIR/$STAMP.log"

log "Running ${TEST_SCOPE[*]} (single-process, BROWSER=lightpanda, won't stop on failure)"
log "Full output → $RAW_LOG"

set +e
(
  cd "$APP_DIR" &&
  PARALLEL_WORKERS=0 \
  BROWSER=lightpanda \
  RUBYOPT="-r$REPORTER" \
  LIGHTPANDA_JSON_OUT="$OUT_JSON" \
  LIGHTPANDA_BUILD="$BROWSER_BUILD" \
  LIGHTPANDA_GEM_VERSION="$GEM_VERSION" \
  bundle exec rails test "${TEST_SCOPE[@]}"
) 2>&1 | tee "$RAW_LOG"
RUN_EXIT="${PIPESTATUS[0]}"
set -e

[ -f "$OUT_JSON" ] || die "reporter did not write $OUT_JSON — check $RAW_LOG"
ln -sf "$(basename "$OUT_JSON")" "$RESULTS_DIR/latest.json"

# --- 4. Summary -------------------------------------------------------------
log "Done. rails-test exit=$RUN_EXIT"
log "Results JSON: $OUT_JSON  (symlinked as results/latest.json)"
if command -v ruby >/dev/null 2>&1; then
  ruby -rjson -e '
    d = JSON.parse(File.read(ARGV[0]))["meta"]
    puts "\e[1;34m[coverage]\e[0m  total=#{d["total"]}  pass=#{d["pass"]}  fail=#{d["fail"]}  error=#{d["error"]}  skip=#{d["skip"]}"
    puts "\e[1;34m[coverage]\e[0m  build=#{d["browser_build"]}  gem=#{d["gem_version"]}"
  ' "$OUT_JSON"
fi

PREV="$(ls -1t "$RESULTS_DIR"/*.json 2>/dev/null | grep -v latest.json | sed -n 2p || true)"
if [ -n "$PREV" ]; then
  log "Compare against the previous run with:"
  printf '    %s/diff.sh %q %q\n' "$SCRIPT_DIR" "$PREV" "$OUT_JSON"
fi

# Mirror the rails-test exit code so CI / callers can detect a failing suite.
exit "$RUN_EXIT"
