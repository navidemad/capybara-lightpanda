#!/usr/bin/env bash
# Run specs in a target booted by boot.sh, with the gem's instruments attached.
#
#   script/real-app/spec.sh solidus                       # the CI subset for this target
#   script/real-app/spec.sh solidus spec/features/admin/orders/order_details_spec.rb \
#                           -e "should allow me to make a split"
#
# Every argument after the target goes to rspec verbatim, so `-e`, `:LINE`,
# `--seed`, `--fail-fast` all work.
#
# Each run writes to $ROOT/artifacts/<timestamp>/:
#   rspec.log                  the console output
#   report.json                rspec's JSON report (same shape CI compares)
#   NNNN-<example>.json        console_logs + network traffic + url/status per failure
#   NNNN-<example>.html        the page body at failure time
#
# and then compares the failures against .github/real-apps/baselines/<target>.txt
# so a local run says, in CI's own vocabulary, whether it reproduced the known
# failure or found a new one.
#
# Env knobs:
#   LIGHTPANDA_PROBE_ALWAYS=1  capture passing examples too
#   LIGHTPANDA_PROBE_HTML=0    skip the page-body dump
#   LIGHTPANDA_DEBUG=1         the gem's own CDP-level logging

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEM_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAL_APP_HOME="${REAL_APP_HOME:-$HOME/.cache/capybara-lightpanda/real-apps}"

# shellcheck source=script/real-app/lib.sh
. "$SCRIPT_DIR/lib.sh"

[ $# -ge 1 ] || die "usage: $0 <target> [rspec args…]"
TARGET="$1"
shift

load_target "$TARGET"
APP="$ROOT/target"
STATE="$ROOT/.state"

[ -d "$APP/.git" ] || die "$RA_NAME is not booted — run: script/real-app/boot.sh $RA_NAME"
[ -f "$STATE/bundle" ] || die "$RA_NAME has no bundle — run: script/real-app/boot.sh $RA_NAME"

ensure_toolchain

RUN="$ROOT/artifacts/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN"

# No args → the exact spec list the matrix runs for this target.
if [ $# -gt 0 ]; then
  SPECS=("$@")
else
  IFS=' ' read -r -a SPECS <<< "$RA_SPEC"
fi

log "running     rspec ${SPECS[*]}"
log "cwd         $APP/$RA_SPEC_DIR"
log "artifacts   $RUN"

set +e
(
  cd "$APP/$RA_SPEC_DIR" || exit 1
  apply_env
  # The binary was provisioned by boot.sh outside WebMock's reach; a cache time
  # of 0 marks whatever is on disk as fresh so nothing re-downloads mid-run —
  # including from examples that travel the clock past the freshness window.
  export LIGHTPANDA_CACHE_TIME=0
  export LIGHTPANDA_PROBE_DIR="$RUN"

  # `-r probe.rb` is the whole instrumentation: no Gemfile entry, no
  # spec_helper edit, nothing left behind in the app checkout.
  tool_exec bundle exec rspec \
    --require "$SCRIPT_DIR/probe.rb" \
    --format progress \
    --format json --out "$RUN/report.json" \
    "${SPECS[@]}"
) 2>&1 | tee "$RUN/rspec.log"
RSPEC_EXIT="${PIPESTATUS[0]}"
set -e

echo
log "rspec exit=$RSPEC_EXIT"

# --- Baseline comparison ------------------------------------------------------
# GITHUB_WORKSPACE is what check_baseline.rb anchors absolute file_paths on, so
# gem-sourced examples (shared groups living in a gem) normalize to the same
# `target/…` key CI records. That is why the checkout is at $ROOT/target.
if [ -f "$RUN/report.json" ]; then
  BASELINE_JSON="$(
    CHECK_FORMAT=json GITHUB_WORKSPACE="$ROOT" \
      ruby "$GEM_DIR/.github/real-apps/check_baseline.rb" "$RA_NAME" "$RUN/report.json" || true
  )"
  if [ -n "$BASELINE_JSON" ]; then
    # The single-quoted body is a Ruby script; shell expansion is not wanted.
    # shellcheck disable=SC2016
    printf '%s' "$BASELINE_JSON" | ruby -rjson -ryaml -e '
      r = JSON.parse($stdin.read)
      causes = YAML.safe_load_file(File.join(ARGV[0], ".github/real-apps/causes.yml"))
      known = r["attributions"] || {}
      confidence = ->(slug) { causes.dig(slug, "confidence") || "?" }
      puts "\e[1;34m[real-app]\e[0m baseline: #{r["failed"]} failed of #{r["examples"]} run " \
           "(#{r["new"].size} not in .github/real-apps/baselines/#{r["target"]}.txt)"
      r["new"].each { |k| puts "  \e[31mNEW  \e[0m #{k}" }
      unattributed = r["unattributed"] || []
      # Per-example detail is the point when diagnosing one spec; on a
      # full-subset run (68 known failures for solidus) it buries the NEW lines,
      # so collapse to the same per-cause tally check_baseline prints.
      if known.size + unattributed.size > 10
        known.values.tally.sort_by { |_, n| -n }.each do |slug, n|
          puts "  \e[33mknown\e[0m #{n.to_s.rjust(3)}  #{slug} (#{confidence.call(slug)})"
        end
        puts "  \e[33mknown\e[0m #{unattributed.size.to_s.rjust(3)}  no cause on file" unless unattributed.empty?
      else
        known.each { |key, slug| puts "  \e[33mknown\e[0m #{key}\n        cause: #{slug} (#{confidence.call(slug)})" }
        unattributed.each { |k| puts "  \e[33mknown\e[0m #{k}\n        cause: none on file — add one to causes.yml" }
      end
    ' "$GEM_DIR"
  fi
fi

# --- Probe artifacts ----------------------------------------------------------
if ls "$RUN"/*.json >/dev/null 2>&1; then
  echo
  log "probe artifacts:"
  for f in "$RUN"/[0-9]*.json; do
    [ -e "$f" ] || continue
    printf '            %s\n' "$f"
  done
fi

exit "$RSPEC_EXIT"
