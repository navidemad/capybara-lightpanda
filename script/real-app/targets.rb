#!/usr/bin/env ruby
# frozen_string_literal: true

# Resolves one real-apps matrix target into shell assignments for boot.sh /
# spec.sh to `eval`.
#
#   ruby targets.rb --list          # target names, one per line
#   ruby targets.rb solidus         # RA_* assignments for `eval`
#
# The matrix itself is NOT duplicated here: it is read straight out of
# .github/workflows/real-apps.yml, which stays the single source of truth for
# the pinned SHA, ruby/node versions, work_dir/spec_dir, db_create, pre_spec and
# the spec subset. Duplicating it would drift the moment a target is re-pinned.
#
# What DOES live here is the small set of CI-shaped bits that cannot run
# verbatim on a dev machine (apt packages, `systemctl`, hosted-runner service
# containers) plus the job-level `env:` block the workflow sets outside the
# matrix. Each override records why it differs from CI.

require "yaml"
require "shellwords"

REPO_ROOT = File.expand_path("../..", __dir__)
WORKFLOW = File.join(REPO_ROOT, ".github/workflows/real-apps.yml")

# Job-level `env:` from real-apps.yml, ported verbatim. Notes preserved because
# they are load-bearing:
#
#   * DATABASE_URL is deliberately NOT here. Rails treats it as an absolute
#     override, which forces Solidus's sqlite dummy app to load the `pg` adapter
#     that isn't in its Gemfile. Only Forem sets it, in its own override below.
#   * PG*/DB_* are libpq and Mastodon defaults respectively; harmless for the
#     sqlite-only targets.
BASE_ENV = {
  "RAILS_ENV" => "test",
  "DISABLE_SPRING" => "1",
  "PGHOST" => "localhost",
  "PGPORT" => "5432",
  "PGUSER" => "postgres",
  "PGPASSWORD" => "postgres",
  "DB_HOST" => "localhost",
  "DB_PORT" => "5432",
  "DB_USER" => "postgres",
  "DB_PASS" => "postgres",
  "ES_ENABLED" => "false",
  "REDIS_URL" => "redis://localhost:6379",
}.freeze

# Postgres.app (the common macOS setup) creates a superuser named after the
# login user, not `postgres`, so the CI credentials are only a default here —
# exporting PGUSER/PGPASSWORD before calling boot.sh wins. Forem's DATABASE_URL
# is derived from whatever ends up resolved rather than hard-coded, otherwise it
# would silently disagree with the PG* vars the same run exports.
def pg
  {
    host: ENV["PGHOST"] || BASE_ENV["PGHOST"],
    port: ENV["PGPORT"] || BASE_ENV["PGPORT"],
    user: ENV["PGUSER"] || BASE_ENV["PGUSER"],
    password: ENV["PGPASSWORD"] || BASE_ENV["PGPASSWORD"],
  }
end

def forem_database_url(db)
  p = pg
  "postgresql://#{p[:user]}:#{p[:password]}@#{p[:host]}:#{p[:port]}/#{db}"
end

# Per-target deltas from the workflow. `services` drives boot.sh's preflight —
# CI starts Postgres and Redis containers for every matrix entry regardless of
# need, which a dev machine should not have to imitate, so this lists what the
# target actually requires to boot.
LOCAL_OVERRIDES = {
  "forem" => {
    "services" => "postgres redis",
    # Forem reads these through ApplicationConfig (env-backed). Ported from
    # the workflow's "Set per-target env overrides" step.
    "env" => {
      "DATABASE_URL" => forem_database_url("Forem_development"),
      "DATABASE_URL_TEST" => forem_database_url("Forem_test"),
      "DATABASE_NAME" => "Forem_development",
      "DATABASE_NAME_TEST" => "Forem_test",
      "APP_PROTOCOL" => "http://",
      "APP_DOMAIN" => "localhost:3000",
      "COMMUNITY_NAME" => "DEV(local)",
      "DEFAULT_EMAIL" => "yo@dev.to",
      "FOREM_OWNER_SECRET" => "secret",
      "SESSION_KEY" => "_Dev_Community_Session",
      "SESSION_EXPIRY_SECONDS" => "1209600",
    },
    "notes" => "Needs the exact Ruby patch in the matrix — Forem's Gemfile " \
               "reads .ruby-version and demands an exact match.",
  },
  # kt-paperclip pulls mimemagic, whose native build refuses to compile
  # without the freedesktop MIME database. Ubuntu runners ship it
  # (shared-mime-info is preinstalled); macOS does not.
  "solidus" => { "services" => "", "native" => "shared-mime-info" },
  "spree" => { "services" => "", "native" => "shared-mime-info" },
  "decidim" => { "services" => "postgres" },
  "mastodon" => {
    "services" => "postgres redis",
    # CI installs libidn11-dev via apt and points the idn-ruby native build at
    # /usr. On macOS that is Homebrew's libidn, resolved at boot time.
    "bundle_config" => "build.idn-ruby --with-idn-dir=__LIBIDN_PREFIX__",
    "notes" => "Native idn-ruby build needs libidn (brew install libidn).",
  },
  "alonetone" => {
    "services" => "mysql",
    # CI's pre_spec opens with `sudo systemctl start mysql.service` to start
    # the hosted runner's preinstalled MySQL. Locally that is the developer's
    # job (the preflight checks it is reachable), so the rest runs unchanged.
    "pre_spec" => "bin/rails setup:copy_config setup:touch_js db:create db:schema:load " \
                  "&& bin/rails dartsass:build && yarn build",
    "notes" => "MySQL app: expects root/root on 127.0.0.1 (alonetone's " \
               "database.example.yml test section).",
  },
}.freeze

def matrix
  workflow = YAML.safe_load_file(WORKFLOW, aliases: true)
  workflow.dig("jobs", "smoke", "strategy", "matrix", "include") ||
    abort("could not read jobs.smoke.strategy.matrix.include from #{WORKFLOW}")
end

def emit(key, value)
  puts "#{key}=#{Shellwords.escape(value.to_s)}"
end

target = ARGV[0] or abort("usage: targets.rb <target> | --list")

names = matrix.map { |e| e["name"] }

if target == "--list"
  puts names
  exit 0
end

entry = matrix.find { |e| e["name"] == target }
abort("unknown target #{target.inspect} — known: #{names.join(', ')}") unless entry

override = LOCAL_OVERRIDES.fetch(target, {})

emit("RA_NAME", entry["name"])
emit("RA_REPO", entry["repo"])
emit("RA_SHA", entry["sha"])
emit("RA_RUBY", entry["ruby"])
emit("RA_NODE", entry["node"])
emit("RA_WORK_DIR", entry["work_dir"])
emit("RA_SPEC_DIR", entry["spec_dir"])
emit("RA_DB_CREATE", entry["db_create"] ? "true" : "false")
emit("RA_PRE_SPEC", override["pre_spec"] || entry["pre_spec"] || "")
emit("RA_SPEC", entry["spec"])
emit("RA_SERVICES", override["services"] || "")
emit("RA_NATIVE", override["native"] || "")
emit("RA_BUNDLE_CONFIG", override["bundle_config"] || "")
emit("RA_NOTES", override["notes"] || "")
emit("RA_ENV", BASE_ENV.merge(override["env"] || {}).map { |k, v| "#{k}=#{v}" }.join("\n"))
