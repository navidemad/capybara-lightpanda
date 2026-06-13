#!/usr/bin/env bash
# Compare two coverage runs and show which tests changed status — the point of
# tracking: did Lightpanda coverage improve (more passing) between two runs?
#
# Usage:
#   script/real-app-coverage/diff.sh OLD.json NEW.json
#   script/real-app-coverage/diff.sh                 # auto: 2nd-newest vs newest
#
# Prints, grouped:
#   FIXED      — failing/erroring before, passing now   (improvement)
#   REGRESSED  — passing before, failing/erroring now    (regression)
#   NEW        — present only in the new run
#   GONE       — present only in the old run
# plus a one-line headline count delta.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"

if [ "$#" -eq 2 ]; then
  OLD="$1"; NEW="$2"
else
  NEW="$(ls -1t "$RESULTS_DIR"/*.json 2>/dev/null | grep -v latest.json | sed -n 1p || true)"
  OLD="$(ls -1t "$RESULTS_DIR"/*.json 2>/dev/null | grep -v latest.json | sed -n 2p || true)"
  [ -n "$OLD" ] && [ -n "$NEW" ] || { echo "need two runs in $RESULTS_DIR (or pass OLD.json NEW.json)"; exit 1; }
fi

[ -f "$OLD" ] || { echo "no such file: $OLD"; exit 1; }
[ -f "$NEW" ] || { echo "no such file: $NEW"; exit 1; }

ruby -rjson -e '
  old_file, new_file = ARGV
  load_run = ->(p) {
    d = JSON.parse(File.read(p))
    map = {}
    d["results"].each { |r| map["#{r["klass"]}##{r["name"]}"] = r["status"] }
    [d["meta"], map]
  }
  old_meta, old = load_run.(old_file)
  new_meta, neu = load_run.(new_file)

  good = ->(s) { s == "pass" }  # skip counts as neither fixed nor regressed
  keys = (old.keys | neu.keys).sort

  fixed, regressed, new_tests, gone = [], [], [], []
  keys.each do |k|
    o, n = old[k], neu[k]
    if o.nil?      then new_tests << "#{k}  (#{n})"
    elsif n.nil?   then gone << "#{k}  (was #{o})"
    elsif !good.(o) && good.(n) then fixed << k
    elsif good.(o) && !good.(n) then regressed << "#{k}  (now #{n})"
    end
  end

  c = ->(code, s) { "\e[#{code}m#{s}\e[0m" }
  section = ->(title, code, items) {
    puts c.(code, "#{title} (#{items.size})")
    items.each { |i| puts "  #{i}" }
    puts
  }

  puts c.("1;36", "OLD #{File.basename(old_file)}  pass=#{old_meta["pass"]} fail=#{old_meta["fail"]} error=#{old_meta["error"]} skip=#{old_meta["skip"]}  build=#{old_meta["browser_build"]}")
  puts c.("1;36", "NEW #{File.basename(new_file)}  pass=#{new_meta["pass"]} fail=#{new_meta["fail"]} error=#{new_meta["error"]} skip=#{new_meta["skip"]}  build=#{new_meta["browser_build"]}")
  delta = new_meta["pass"].to_i - old_meta["pass"].to_i
  sign = delta >= 0 ? "+#{delta}" : delta.to_s
  puts c.(delta >= 0 ? "1;32" : "1;31", "pass delta: #{sign}")
  puts

  section.("FIXED",     "1;32", fixed)
  section.("REGRESSED", "1;31", regressed)
  section.("NEW",       "1;33", new_tests)
  section.("GONE",      "1;90", gone)
' "$OLD" "$NEW"
