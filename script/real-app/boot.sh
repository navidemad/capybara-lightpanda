#!/usr/bin/env bash
# Bring up one real-apps matrix target locally, so a single failing spec can be
# run and instrumented.
#
#   script/real-app/boot.sh solidus                 # provision only
#   script/real-app/boot.sh solidus -- spec/features/admin/orders/order_details_spec.rb
#   script/real-app/boot.sh --list                  # known targets
#
# Everything after `--` is forwarded to spec.sh (see that script for the run
# side). Provisioning is idempotent and step-marked: the checkout, the bundle,
# the dummy app and the database survive between runs, so a re-boot is seconds.
#
# This is the CI recipe in .github/workflows/real-apps.yml, ported step for step
# — same pinned SHA, same ruby/node, same work_dir/spec_dir split, same patch
# sed, same pre-provisioned Lightpanda binary. The traps the workflow comments
# record are carried over rather than rediscovered; each one is noted at the
# step that pays for it.
#
# Env knobs:
#   REAL_APP_HOME=...   where checkouts live (default ~/.cache/capybara-lightpanda/real-apps)
#   FORCE=<step|all>    redo a completed step: checkout, patch, bundle, node, db, pre_spec
#   SKIP_RUBY_INSTALL=1 don't let mise install a missing Ruby; fail instead
#   PGUSER=... PGPASSWORD=...   override the CI Postgres credentials (Postgres.app
#                               creates a role named after the login user)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEM_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAL_APP_HOME="${REAL_APP_HOME:-$HOME/.cache/capybara-lightpanda/real-apps}"

# shellcheck source=script/real-app/lib.sh
. "$SCRIPT_DIR/lib.sh"

[ $# -ge 1 ] || die "usage: $0 <target> [-- <rspec args>]   (try --list)"

if [ "$1" = "--list" ]; then
  ruby "$SCRIPT_DIR/targets.rb" --list
  exit 0
fi

TARGET="$1"
shift
if [ "${1:-}" = "--" ]; then shift; fi

load_target "$TARGET"

APP="$ROOT/target"
STATE="$ROOT/.state"
mkdir -p "$STATE"

log "target      $RA_NAME ($RA_REPO @ ${RA_SHA:0:12})"
log "workspace   $ROOT"
log "ruby/node   ${RA_RUBY}${RA_NODE:+ / node $RA_NODE}"
log "dirs        work=$RA_WORK_DIR spec=$RA_SPEC_DIR"
[ -n "$RA_NOTES" ] && log "note        $RA_NOTES"

# --- 1. Preflight ------------------------------------------------------------
# Services are checked BEFORE anything slow, because the failure they cause
# otherwise surfaces minutes later inside `rails db:create` as an adapter error.
command -v git >/dev/null || die "git not on PATH"

for service in $RA_SERVICES; do
  case "$service" in
    postgres)
      # The role was already resolved by load_target (Forem's DATABASE_URL is
      # derived from it), so only reachability is left to check here.
      if ! { command -v pg_isready >/dev/null && pg_isready -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" >/dev/null 2>&1; }; then
        die "$RA_NAME needs Postgres on ${PGHOST:-localhost}:${PGPORT:-5432} — start it (Postgres.app, or \`brew services start postgresql@16\`)"
      fi
      ;;
    redis)
      if ! { command -v redis-cli >/dev/null && redis-cli -u "${REDIS_URL:-redis://localhost:6379}" ping >/dev/null 2>&1; }; then
        die "$RA_NAME needs Redis at ${REDIS_URL:-redis://localhost:6379} — \`brew services start redis\`"
      fi
      ;;
    mysql)
      if ! { command -v mysqladmin >/dev/null && mysqladmin --protocol=tcp -h 127.0.0.1 -u root -proot ping >/dev/null 2>&1; }; then
        die "$RA_NAME needs MySQL on 127.0.0.1 with root/root (alonetone's database.example.yml) — \`brew install mysql && brew services start mysql\`"
      fi
      ;;
  esac
done
log "services    ${RA_SERVICES:-none required} — ok"

# --- 2. Checkout at the pinned SHA -------------------------------------------
# Fetching the single pinned commit (--depth 1 on the SHA) is what makes a cold
# boot cheap: 34 MB for Solidus instead of a full clone.
if ! step_done checkout || [ ! -d "$APP/.git" ]; then
  log "cloning $RA_REPO @ $RA_SHA"
  mkdir -p "$APP"
  git -C "$APP" rev-parse --git-dir >/dev/null 2>&1 || git -C "$APP" init -q
  git -C "$APP" remote get-url origin >/dev/null 2>&1 \
    || git -C "$APP" remote add origin "https://github.com/$RA_REPO.git"
  if ! git -C "$APP" fetch --depth 1 --no-tags origin "$RA_SHA" 2>/dev/null; then
    log "shallow fetch of the SHA was refused — falling back to a full fetch"
    git -C "$APP" fetch --no-tags origin
  fi
  git -C "$APP" checkout -q --force FETCH_HEAD
  mark_done checkout
else
  log "checkout    already at $(git -C "$APP" rev-parse --short HEAD) (FORCE=checkout to redo)"
fi

# --- 3. Apply the driver-swap patch ------------------------------------------
# Same substitution as the workflow's "Apply patch" step: the patch carries
# __CAPYBARA_LIGHTPANDA_PATH__ so it stays checkout-independent, and the Gemfile
# `path:` entry resolves to THIS gem checkout.
PATCH="$GEM_DIR/.github/real-apps/patches/$RA_NAME.patch"
[ -f "$PATCH" ] || die "missing patch: $PATCH"
PATCH_SUM="$(checksum "$PATCH")"

if ! step_done "patch-$PATCH_SUM"; then
  log "applying patch ($RA_NAME.patch → $GEM_DIR)"
  # Reset first so a re-apply after a patch edit starts from the pinned tree
  # rather than layering onto the previous version of the patch.
  git -C "$APP" checkout -q --force FETCH_HEAD
  sed "s|__CAPYBARA_LIGHTPANDA_PATH__|$GEM_DIR|g" "$PATCH" > "$ROOT/swap.patch"
  git -C "$APP" apply --reject --whitespace=fix "$ROOT/swap.patch"
  git -C "$APP" diff --name-only | sed 's/^/            patched: /'
  rm -f "$STATE"/patch-*
  mark_done "patch-$PATCH_SUM"
  # The Gemfile just changed under the previously installed bundle.
  rm -f "$STATE/bundle"
else
  log "patch       already applied (FORCE=patch to redo)"
fi

# --- 4. Toolchain -------------------------------------------------------------
# Ruby (and Node) are pinned per target exactly as the matrix pins them — Forem
# demands an exact patch level because its Gemfile reads .ruby-version and
# refuses a mismatch. mise supplies them without writing a version file into the
# checkout, which would count as modifying the app.
ensure_toolchain

# --- 5. Bundle ----------------------------------------------------------------
check_native_deps
if [ -n "$RA_BUNDLE_CONFIG" ]; then
  configure_bundle_build
fi

# No bundler cache keyed on the lockfile — the Gemfile changed in step 3, which
# is why CI sets `bundler-cache: false` too. `bundle check` is the honest test
# of whether an install is still needed.
if ! step_done bundle || ! in_app bundle check >/dev/null 2>&1; then
  log "bundle install (this is the slow one on a cold boot)"
  in_app bundle install --jobs 4 --retry 3
  mark_done bundle
else
  log "bundle      satisfied (FORCE=bundle to redo)"
fi

# --- 6. Node ------------------------------------------------------------------
if [ -n "$RA_NODE" ]; then
  if ! step_done node; then
    install_js_deps
    mark_done node
  else
    log "node        deps installed (FORCE=node to redo)"
  fi
fi

# --- 7. Database --------------------------------------------------------------
if [ "$RA_DB_CREATE" = "true" ]; then
  if ! step_done db; then
    log "rails db:create db:schema:load"
    in_app bundle exec rails db:create db:schema:load
    mark_done db
  else
    log "database    created (FORCE=db to redo)"
  fi
fi

# --- 8. Pre-spec hook ---------------------------------------------------------
# Solidus/Spree generate a dummy app here (minutes), Decidim generates and moves
# one, alonetone copies config and builds assets. All are expensive and all
# survive between runs, which is most of why re-running is cheap.
if [ -n "$RA_PRE_SPEC" ]; then
  if ! step_done pre_spec; then
    log "pre-spec: $RA_PRE_SPEC"
    in_app bash -c "$RA_PRE_SPEC"
    mark_done pre_spec
  else
    log "pre-spec    done (FORCE=pre_spec to redo)"
  fi
fi

# --- 9. Lightpanda binary -----------------------------------------------------
# Ported from the workflow's "Pre-provision Lightpanda binary" step, and for the
# same reason: the target suites run under WebMock/VCR with real connections
# disabled, so a lazy first-use download inside the spec run raises
# NetConnectNotAllowedError. Fetch it here, in a plain Ruby process with no
# WebMock loaded. spec.sh then sets LIGHTPANDA_CACHE_TIME=0 so the binary on
# disk is treated as fresh and never re-fetched mid-run.
provision_lightpanda

# --- Done ---------------------------------------------------------------------
echo
log "\033[1;32mbooted\033[0m — $RA_NAME is runnable."
log "run the CI subset:   script/real-app/spec.sh $RA_NAME"
log "run one example:     script/real-app/spec.sh $RA_NAME <spec-path> -e \"<example>\""
log "app checkout:        $APP"

if [ $# -gt 0 ]; then
  echo
  exec "$SCRIPT_DIR/spec.sh" "$RA_NAME" "$@"
fi
