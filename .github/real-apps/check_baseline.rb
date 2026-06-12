# frozen_string_literal: true

# Compares an rspec JSON report against the target's known-failure baseline.
#
# Usage: ruby check_baseline.rb <target> <report.json>
#
# Baseline: .github/real-apps/baselines/<target>.txt (relative to this file),
# one entry per line, sorted: "<file_path> # <full_description>".
#
# Exit 1 when:
#   - the report is missing/unreadable (rspec crashed before writing it)
#   - rspec recorded errors outside of examples, or ran 0 examples
#   - any example fails that is NOT in the baseline (a regression)
#
# Exit 0 otherwise. Baseline entries that now pass are reported as warnings —
# refresh the baseline file to lock in the improvement. To refresh: download
# the rspec-report-<target> artifact and run this script with REFRESH=1, or
# regenerate the file from the report:
#   jq -r '.examples[] | select(.status=="failed")
#          | "\(.file_path) # \(.full_description)"' report.json | sort -u
#
# Targets are pinned to fixed SHAs in real-apps.yml, so file paths and
# descriptions are stable until a deliberate target bump (which is exactly
# when the baseline should be regenerated anyway).

require "json"

target = ARGV[0] or abort "usage: check_baseline.rb <target> <report.json>"
report_path = ARGV[1] or abort "usage: check_baseline.rb <target> <report.json>"

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
               .map { |e| "#{e['file_path']} # #{e['full_description']}" }
               .sort.uniq
baseline = File.readlines(baseline_path, chomp: true).reject(&:empty?).sort.uniq

new_failures = failed - baseline
fixed = baseline - failed

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
