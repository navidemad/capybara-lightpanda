# frozen_string_literal: true

# Rolls the per-target baseline comparisons up into one summary, so a single
# view answers "did this commit fix (or regress) any known failures, across
# every real-app target?" — without opening each matrix job individually.
#
# Usage: ruby aggregate_baseline.rb <reports_dir>
#
# <reports_dir> holds the downloaded rspec-report-<target> artifacts, one per
# subdirectory (the layout `actions/download-artifact` produces without a
# `name:` filter): <reports_dir>/rspec-report-<target>/rspec-report.json.
#
# For each report found, this re-runs check_baseline.rb in CHECK_FORMAT=json
# mode so the roll-up shares that script's comparison logic (normalize + diff)
# rather than re-deriving it. The combined table + fixed/new lists are written
# to $GITHUB_STEP_SUMMARY (and stdout as a fallback for local runs).
#
# Exit code mirrors the matrix: 1 if any target has NEW failures, else 0. The
# aggregate job is informational (the per-target gate already failed the run),
# but a non-zero exit keeps the roll-up honest if it's ever used as a gate.

require "json"
require "shellwords"

reports_dir = ARGV[0] or abort "usage: aggregate_baseline.rb <reports_dir>"
abort "reports dir not found: #{reports_dir}" unless File.directory?(reports_dir)

check_script = File.expand_path("check_baseline.rb", __dir__)

# Each artifact unpacks to rspec-report-<target>/rspec-report.json. Derive the
# target name from the directory rather than the file so it stays correct even
# if the report filename ever changes.
reports = Dir.glob(File.join(reports_dir, "rspec-report-*", "rspec-report.json"))
abort "no rspec-report-*/rspec-report.json under #{reports_dir}" if reports.empty?

results = reports.map do |report_path|
  target = File.basename(File.dirname(report_path)).delete_prefix("rspec-report-")
  json = `CHECK_FORMAT=json ruby #{check_script.shellescape} #{target.shellescape} #{report_path.shellescape}`
  parsed =
    begin
      JSON.parse(json)
    rescue JSON::ParserError
      nil
    end
  # A target whose report was missing/empty/crashed makes check_baseline.rb
  # abort (stderr, no JSON on stdout) — surface it as an error row rather than
  # dropping it silently.
  parsed || { "target" => target, "error" => true }
end

errored, ok = results.partition { |r| r["error"] }
total_new = ok.sum { |r| r["new"].size }
total_fixed = ok.sum { |r| r["fixed"].size }

lines = []
lines << "# Real-apps baseline roll-up"
lines << ""
lines << "**#{total_fixed} fixed**, **#{total_new} new failures** across #{ok.size} target(s)."
lines << ""
lines << "| Target | Examples | Failed | Baseline | New | Fixed |"
lines << "| --- | --: | --: | --: | --: | --: |"
ok.each do |r|
  fixed_cell = r["fixed"].empty? ? "0" : "✅ #{r['fixed'].size}"
  new_cell = r["new"].empty? ? "0" : "❌ #{r['new'].size}"
  lines << "| #{r['target']} | #{r['examples']} | #{r['failed']} | #{r['baseline']} | #{new_cell} | #{fixed_cell} |"
end
errored.each { |r| lines << "| #{r['target']} | — | — | — | ⚠️ report missing/crashed | — |" }

fixed_targets = ok.select { |r| r["fixed"].any? }
unless fixed_targets.empty?
  lines << ""
  lines << "## ✅ Fixed since baseline — refresh these baselines to lock in"
  fixed_targets.each do |r|
    lines << ""
    lines << "**#{r['target']}** (`.github/real-apps/baselines/#{r['target']}.txt`)"
    r["fixed"].each { |k| lines << "- #{k}" }
  end
end

new_targets = ok.select { |r| r["new"].any? }
unless new_targets.empty?
  lines << ""
  lines << "## ❌ New failures (regressions, not in baseline)"
  new_targets.each do |r|
    lines << ""
    lines << "**#{r['target']}**"
    r["new"].each { |k| lines << "- #{k}" }
  end
end

output = "#{lines.join("\n")}\n"
File.write(ENV["GITHUB_STEP_SUMMARY"], output, mode: "a") if ENV["GITHUB_STEP_SUMMARY"]
puts output

exit(total_new.zero? ? 0 : 1)
