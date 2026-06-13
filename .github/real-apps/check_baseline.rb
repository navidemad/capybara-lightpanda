# frozen_string_literal: true

# Compares an rspec JSON report against the target's known-failure baseline.
#
# Usage: ruby check_baseline.rb <target> <report.json>
#
# Baseline: .github/real-apps/baselines/<target>.txt (relative to this file),
# one entry per line, sorted: "<file_path> # <full_description>". The file_path
# is workspace-relative — examples from a shared group in a gem report an
# absolute path that this script anchors on $GITHUB_WORKSPACE (see `normalize`).
#
# Exit 1 when:
#   - the report is missing/unreadable (rspec crashed before writing it)
#   - rspec recorded errors outside of examples, or ran 0 examples
#   - any example fails that is NOT in the baseline (a regression)
#
# Exit 0 otherwise. Baseline entries that now pass are reported as warnings —
# refresh the baseline file to lock in the improvement. To refresh: download
# the rspec-report-<target> artifact and re-run this script with REFRESH=1 and
# GITHUB_WORKSPACE set to the path the report's absolute file_paths were written
# under (the segment before `/target/…`). Don't hand-edit the file or pipe
# rspec's console "Failed examples" list into it — that yields `rspec <path>[id]`
# keys that never match the report.
#
# Targets are pinned to fixed SHAs in real-apps.yml, so file paths and
# descriptions are stable until a deliberate target bump (which is exactly
# when the baseline should be regenerated anyway).

require "json"

target = ARGV[0] or abort "usage: check_baseline.rb <target> <report.json>"
report_path = ARGV[1] or abort "usage: check_baseline.rb <target> <report.json>"

# Specs run from `target/<spec_dir>`, so rspec reports a `./`-relative path for
# examples defined under the dummy app but an ABSOLUTE path for examples pulled
# in from a shared example group living in a gem (e.g. decidim-dev's
# accessibility_examples.rb). Anchoring the absolute one on $GITHUB_WORKSPACE
# keeps the baseline key runner-independent (the prefix is /home/runner/work/…
# on hosted runners but differs elsewhere) and committable.
workspace = ENV.fetch("GITHUB_WORKSPACE", nil)
normalize = lambda do |path|
  return path.delete_prefix("#{workspace}/") if workspace && !workspace.empty?

  path
end

baseline_path = File.expand_path("baselines/#{target}.txt", __dir__)
abort "No baseline for '#{target}' (expected #{baseline_path})" unless File.exist?(baseline_path)

unless File.exist?(report_path)
  abort "rspec report not found at #{report_path} — the spec run crashed before writing it"
end

report = JSON.parse(File.read(report_path))
summary = report.fetch("summary")

if summary["errors_outside_of_examples_count"].to_i.positive?
  abort "rspec recorded #{summary['errors_outside_of_examples_count']} error(s) outside of examples (boot/load failure)"
end
abort "rspec ran 0 examples — suite did not start" if summary["example_count"].to_i.zero?

failed = report.fetch("examples")
               .select { |e| e["status"] == "failed" }
               .map { |e| "#{normalize.call(e['file_path'])} # #{e['full_description']}" }
               .sort.uniq
baseline = File.readlines(baseline_path, chomp: true).reject(&:empty?).sort.uniq

new_failures = failed - baseline
fixed = baseline - failed

# JSON mode: emit the comparison as one machine-readable object and skip the
# human-readable / step-summary output. The cross-target aggregate job
# (real-apps.yml) re-runs this per downloaded report so the roll-up shares this
# script's comparison logic rather than re-deriving it. Exit code is unchanged
# (1 on new failures) so the mode is also usable as a standalone gate.
if ENV["CHECK_FORMAT"] == "json"
  puts JSON.generate(
    "target" => target,
    "examples" => summary["example_count"].to_i,
    "failed" => failed.size,
    "baseline" => baseline.size,
    "new" => new_failures,
    "fixed" => fixed
  )
  exit(new_failures.empty? ? 0 : 1)
end

if ENV["REFRESH"] == "1"
  File.write(baseline_path, failed.empty? ? "" : "#{failed.join("\n")}\n")
  puts "Baseline refreshed: #{baseline_path} (#{failed.size} entries)"
  exit 0
end

puts "#{target}: #{summary['example_count']} examples, #{failed.size} failed " \
     "(baseline #{baseline.size}) — #{new_failures.size} new, #{fixed.size} fixed"

step_summary = []
step_summary << "## #{target}: #{failed.size} failed / baseline #{baseline.size}"

unless fixed.empty?
  puts "\nFixed since baseline (refresh #{File.basename(baseline_path)} to lock in):"
  fixed.each { |k| puts "  PASS #{k}" }
  step_summary << "\n**#{fixed.size} fixed** (refresh the baseline to lock in):"
  fixed.each { |k| step_summary << "- :white_check_mark: #{k}" }
end

unless new_failures.empty?
  puts "\nNEW failures (not in baseline):"
  new_failures.each { |k| puts "  FAIL #{k}" }
  step_summary << "\n**#{new_failures.size} NEW failures:**"
  new_failures.each { |k| step_summary << "- :x: #{k}" }
end

File.write(ENV["GITHUB_STEP_SUMMARY"], "#{step_summary.join("\n")}\n", mode: "a") if ENV["GITHUB_STEP_SUMMARY"]

exit 1 unless new_failures.empty?
