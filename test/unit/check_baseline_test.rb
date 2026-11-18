# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# The real-apps gate compares each target's failures with its baseline.
# WHY THIS MATTERS: a baseline names examples, not failures. GoodJob carries 14
# known failures out of 25, each with a diagnosed cause. Without STRICT_CAUSES a
# known example that started failing for an unrelated reason (a broken page, an
# ElementNotFound) passed the gate and only showed as "UNATTRIBUTED"; with it,
# the job fails. The diagnosed failures must still pass, with their hints.
describe "real-apps check_baseline.rb" do
  root = File.expand_path("../..", __dir__)
  script = File.join(root, ".github/real-apps/check_baseline.rb")
  aggregate = File.join(root, ".github/real-apps/aggregate_baseline.rb")
  baseline = File.readlines(File.join(root, ".github/real-apps/baselines/goodjob.txt"), chomp: true)
  drag = baseline.find { |key| key.include?("dragging the index chart") }
  columns = baseline.find { |key| key.include?("column aligned") }
  dst = baseline.find { |key| key.include?("DST gap") }

  report = lambda do |failures|
    examples = failures.map do |key, message|
      file, description = key.split(" # ", 2)
      { "status" => "failed", "file_path" => file, "full_description" => description,
        "exception" => { "message" => message }, }
    end
    { "summary" => { "example_count" => 25, "errors_outside_of_examples_count" => 0 }, "examples" => examples }
  end

  diagnosed = report.call(
    [[drag, "undefined method 'mouse' for Capybara::Lightpanda::Browser. Coordinate mouse input needs " \
            "rendered layout. Run this example with Cuprite (Chrome).",],
     [columns, "expected: [] got: [\"header 0,480,2400 vs body 0,480,1440\"]"],
     [dst, "Lightpanda did not apply timezone \"America/New_York\". Set timezone: at launch"],]
  )
  unrelated = report.call([[drag, "Capybara::ElementNotFound: Unable to find css \".chart\""]])

  run = lambda do |payload, env = {}|
    Dir.mktmpdir do |dir|
      path = File.join(dir, "report.json")
      File.write(path, JSON.generate(payload))
      out, status = Open3.capture2e({ "GITHUB_STEP_SUMMARY" => nil, "GITHUB_WORKSPACE" => nil }.merge(env),
                                    RbConfig.ruby, script, "goodjob", path)
      [out, status.exitstatus]
    end
  end

  it "keeps the diagnosed failures green in strict mode, with the Cuprite hints" do
    out, code = run.call(diagnosed, "STRICT_CAUSES" => "1")

    assert_equal 0, code, out
    assert_match(/goodjob-chart-drag .* — Run chart drags .* with Cuprite/, out)
    assert_match(/goodjob-chart-rendering .* — Run rendered alignment/, out)
    refute_match(/undiagnosed/, out)
  end

  it "lets an unrelated failure of a known example pass only outside strict mode" do
    _, lenient = run.call(unrelated)
    out, strict = run.call(unrelated, "STRICT_CAUSES" => "1")

    assert_equal 0, lenient
    assert_equal 1, strict
    assert_includes out, "undiagnosed reason"
    assert_includes out, drag
    refute_match(/Cuprite/, out)
  end

  it "reports undiagnosed failures in JSON mode for the roll-up" do
    out, code = run.call(unrelated, "STRICT_CAUSES" => "1", "CHECK_FORMAT" => "json")

    assert_equal 1, code
    assert_equal [drag], JSON.parse(out).fetch("unexplained")
  end

  it "names the targets that produced no report in the roll-up" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "rspec-report-goodjob"))
      File.write(File.join(dir, "rspec-report-goodjob", "rspec-report.json"), JSON.generate(diagnosed))
      out, = Open3.capture2e({ "GITHUB_STEP_SUMMARY" => nil, "EXPECTED_TARGETS" => "forem,goodjob,campfire" },
                             RbConfig.ruby, aggregate, dir)

      assert_includes out, "Not run in this workflow run (no report):** forem, campfire"
    end
  end
end
