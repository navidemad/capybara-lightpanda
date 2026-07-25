# shellcheck shell=bash
# Shared helpers for boot.sh / spec.sh. Not executable on its own.
#
# Kept bash-3.2 compatible (macOS ships /bin/bash 3.2): no associative arrays,
# no `readarray`, no `${!prefix@}`.

log() { printf '\033[1;34m[real-app]\033[0m %b\n' "$*"; }
die() { printf '\033[1;31m[real-app] %b\033[0m\n' "$*" >&2; exit 1; }

checksum() { shasum -a 256 "$1" | cut -d' ' -f1; }

# --- target config -----------------------------------------------------------

# Sets RA_* (from targets.rb, which reads the CI matrix) and ROOT.
load_target() {
  command -v ruby >/dev/null || die "ruby not on PATH — needed to read the CI matrix"

  # Must precede targets.rb: Forem's DATABASE_URL is derived from the resolved
  # Postgres credentials, so the role has to be settled before the config is
  # generated.
  resolve_postgres_role

  local config
  config="$(ruby "$SCRIPT_DIR/targets.rb" "$1")" || exit 1
  eval "$config"

  ROOT="$REAL_APP_HOME/$RA_NAME"
  mkdir -p "$ROOT"
}

# Export the target's env, letting anything already exported win — that is how
# PGUSER/PGPASSWORD/REDIS_URL overrides reach the app without editing targets.rb.
apply_env() {
  local line key value
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    key="${line%%=*}"
    value="${line#*=}"
    # `+x`, not `:-`: a variable exported as EMPTY still counts as chosen —
    # resolve_postgres_role's fallback exports PGPASSWORD="" for a passwordless
    # local role, and re-filling it with CI's "postgres" would undo that.
    if [ -z "${!key+x}" ]; then export "$key=$value"; fi
  done <<< "$RA_ENV"

  # Spree/Solidus run specs from a directory below the Gemfile (spec_dir !=
  # work_dir). Bundler would find it by walking up, but being explicit keeps a
  # stray Gemfile in an intermediate directory from hijacking the run.
  export BUNDLE_GEMFILE="$APP/$RA_WORK_DIR/Gemfile"
}

# Postgres.app (the common macOS install) creates a superuser named after the
# login user rather than `postgres`, so CI's postgres/postgres credentials fail
# with a role error deep inside db:create. Probe both and export what works.
# Silent by design: targets that don't need Postgres shouldn't hear about it,
# and the preflight in boot.sh is what reports an unreachable server.
resolve_postgres_role() {
  [ -n "${PGUSER:-}" ] && return 0
  command -v psql >/dev/null || return 0

  local host="${PGHOST:-localhost}" port="${PGPORT:-5432}"
  if PGPASSWORD="${PGPASSWORD:-postgres}" psql -h "$host" -p "$port" -U postgres \
       -d template1 -tAc 'select 1' >/dev/null 2>&1; then
    export PGUSER="postgres" PGPASSWORD="${PGPASSWORD:-postgres}"
  elif psql -h "$host" -p "$port" -U "$USER" -d template1 -tAc 'select 1' >/dev/null 2>&1; then
    export PGUSER="$USER" PGPASSWORD=""
    export DB_USER="$USER" DB_PASS=""
  fi
  return 0
}

# --- step markers -------------------------------------------------------------
# Cheap re-runs come from these: each expensive step leaves a marker under
# $ROOT/.state and is skipped next time. FORCE=<step> (or FORCE=all) redoes one.

step_done() {
  local step="$1"
  if [ "${FORCE:-}" = "all" ] || [ "${FORCE:-}" = "${step%%-*}" ]; then
    return 1
  fi
  [ -f "$STATE/$step" ]
}

mark_done() { touch "$STATE/$1"; }

# --- toolchain ----------------------------------------------------------------
# TOOL_PREFIX pins the target's Ruby (and Node) for every command run inside the
# app, without writing a .tool-versions into the checkout — the app is not to be
# modified beyond its patch.

TOOL_PREFIX=""

ensure_toolchain() {
  local tools="ruby@$RA_RUBY"
  if [ -n "$RA_NODE" ]; then tools="$tools node@$RA_NODE"; fi

  if command -v mise >/dev/null; then
    local tool
    for tool in $tools; do
      if ! mise_has "$tool"; then
        [ "${SKIP_RUBY_INSTALL:-}" = "1" ] && die "$tool is not installed (SKIP_RUBY_INSTALL=1 set)"
        log "installing $tool via mise (one-time; a Ruby build takes several minutes)"
        mise install "$tool"
      fi
    done
    TOOL_PREFIX="mise exec $tools --"
  else
    # No version manager: accept whatever is on PATH if it matches, since
    # forcing an install is worse than running on a compatible ambient Ruby.
    local have
    have="$(ruby -e 'print RUBY_VERSION')"
    case "$have" in
      "$RA_RUBY"|"$RA_RUBY".*) ;;
      *) die "$RA_NAME wants Ruby $RA_RUBY, PATH has $have, and mise is not installed" ;;
    esac
    TOOL_PREFIX=""
  fi

  log "toolchain   $(tool_exec ruby -v | cut -d' ' -f1-2)${RA_NODE:+, node $(tool_exec node -v)}"
}

mise_has() {
  local tool="${1#*@}" name="${1%@*}" escaped
  escaped="${tool//./\\.}"
  mise ls "$name" 2>/dev/null | awk '{print $2}' | grep -qE "^${escaped}(\\.|$)"
}

# Run a command under the target's toolchain (no app cwd/env).
tool_exec() {
  if [ -n "$TOOL_PREFIX" ]; then
    $TOOL_PREFIX "$@"
  else
    "$@"
  fi
}

# Run a command in the app's work_dir with the target's toolchain and env.
in_app() {
  (
    cd "$APP/$RA_WORK_DIR" || exit 1
    apply_env
    tool_exec "$@"
  )
}

# --- javascript deps ----------------------------------------------------------
# Ported from the workflow's "Enable corepack" + "Yarn install" steps.

install_js_deps() {
  if [ ! -f "$APP/$RA_WORK_DIR/package.json" ]; then
    log "node        no package.json — skipping"
    return 0
  fi

  # corepack ships with the Node versions the matrix pins, so running it under
  # TOOL_PREFIX works even when the machine's own `node` is too new to bundle it.
  in_app corepack enable >/dev/null 2>&1 || log "node        corepack enable failed — continuing with PATH yarn"

  if grep -q '"packageManager"' "$APP/$RA_WORK_DIR/package.json"; then
    in_app yarn install --immutable
  elif [ -f "$APP/$RA_WORK_DIR/yarn.lock" ]; then
    in_app yarn install --frozen-lockfile || in_app yarn install
  else
    log "node        package.json without yarn.lock — skipping (assume npm/none)"
  fi
}

# --- native build prerequisites -----------------------------------------------
# Gems whose C/Rake extension needs a system library the Ubuntu runner already
# has. Checked before `bundle install` so the failure names the missing package
# instead of arriving as a rake backtrace from inside a gem's ext/ directory.

check_native_deps() {
  local dep
  for dep in $RA_NATIVE; do
    case "$dep" in
      shared-mime-info) check_freedesktop_mime_db ;;
    esac
  done
}

# mimemagic 0.3.x (kt-paperclip → solidus/spree) hard-fails its build without
# freedesktop.org.xml. The gem also offers USE_FREEDESKTOP_PLACEHOLDER=true to
# skip it — deliberately NOT used here: the placeholder changes content-type
# sniffing, and the file-upload specs that would notice are exactly the ones
# sitting in these targets' baselines. A local run has to fail the way CI fails.
check_freedesktop_mime_db() {
  [ -n "${FREEDESKTOP_MIME_TYPES_PATH:-}" ] && return 0

  local dir
  for dir in /usr/local /opt/homebrew /opt/local /usr; do
    if [ -f "$dir/share/mime/packages/freedesktop.org.xml" ]; then return 0; fi
  done

  die "$RA_NAME needs the freedesktop MIME database (mimemagic, via kt-paperclip).\n" \
      "  Ubuntu runners have it preinstalled; on macOS: brew install shared-mime-info"
}

# --- bundler build flags ------------------------------------------------------
# Mastodon's idn-ruby needs a native lib CI installs with apt; locally it is
# Homebrew's, whose prefix is resolved here.

configure_bundle_build() {
  local config="$RA_BUNDLE_CONFIG" prefix
  case "$config" in
    *__LIBIDN_PREFIX__*)
      command -v brew >/dev/null || die "$RA_NAME needs libidn; install Homebrew or set the bundle config by hand"
      prefix="$(brew --prefix libidn 2>/dev/null || true)"
      [ -n "$prefix" ] && [ -d "$prefix" ] || die "libidn not found — \`brew install libidn\`"
      config="${config//__LIBIDN_PREFIX__/$prefix}"
      ;;
  esac
  log "bundle config set $config"
  # The config is a name/value pair, so the split is deliberate.
  # shellcheck disable=SC2086
  in_app bundle config set $config
}

# --- lightpanda binary --------------------------------------------------------

provision_lightpanda() {
  local ok="" attempt out
  for attempt in 1 2 3; do
    # Piping into sed would mask ruby's exit status behind sed's, so capture.
    # The single-quoted body is a Ruby script; shell expansion is not wanted.
    # shellcheck disable=SC2016
    if out="$(ruby -I "$GEM_DIR/lib" \
                -r capybara/lightpanda/errors -r capybara/lightpanda/binary \
                -e 'path = Capybara::Lightpanda::Binary.update
                    puts "#{path} — #{`#{path} version`.lines.first&.strip}"' 2>&1)"; then
      log "lightpanda  $out"
      ok=1
      break
    fi
    printf '%s\n' "$out" >&2
    log "lightpanda provisioning attempt $attempt failed; retrying in 5s"
    sleep 5
  done
  [ -n "$ok" ] || die "could not provision the Lightpanda binary after 3 attempts"
}
