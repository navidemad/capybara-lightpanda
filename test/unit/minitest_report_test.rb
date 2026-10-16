# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "tmpdir"
require_relative "../../.github/real-apps/minitest_report"

# The real-apps job compares a Minitest target (Campfire) through
# check_baseline.rb, which only understands RSpec's JSON report. These tests pin
# the three things that comparison depends on, using check_baseline.rb's own
# key formula: a baseline line must match the key built from the report, an
# errored test must count as failed and keep the underlying exception's message
# (causes.yml matches on text like "ClipboardEvent is not defined"), and a
# skipped test must never count as failed.
class MinitestReportTest < Minitest::Test
  def test_failure_key_matches_a_baseline_line
    example = report_for(result(failure: Minitest::Assertion.new("expected to find css")))

    assert_equal "./test/system/composer_test.rb # ComposerTest#test_sends", baseline_key(example)
    assert_equal "failed", example["status"]
  end

  def test_error_is_failed_and_carries_the_raised_exception_message
    error = Minitest::UnexpectedError.new(StandardError.new("ReferenceError: ClipboardEvent is not defined"))
    example = report_for(result(failure: error))

    assert_equal "failed", example["status"]
    assert_equal "StandardError", example.dig("exception", "class")
    assert_includes example.dig("exception", "message"), "ClipboardEvent is not defined"
  end

  def test_skip_is_pending_not_failed
    example = report_for(result(failure: Minitest::Skip.new("needs streaming")))

    assert_equal "pending", example["status"]
    refute example.key?("exception")
  end

  def test_pass_has_no_exception
    example = report_for(result)

    assert_equal "passed", example["status"]
    refute example.key?("exception")
  end

  private

  def result(failure: nil)
    Minitest::Result.new("test_sends").tap do |r|
      r.klass = "ComposerTest"
      r.source_location = [File.join(Dir.pwd, "test/system/composer_test.rb"), 9]
      r.failures = failure ? [failure] : []
    end
  end

  def report_for(result)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "report.json")
      reporter = RealAppsReport::Reporter.new(path)
      reporter.record(result)
      reporter.report
      report = JSON.parse(File.read(path))

      assert_equal 1, report.dig("summary", "example_count")
      report.fetch("examples").first
    end
  end

  # check_baseline.rb's key for a failed example.
  def baseline_key(example)
    "#{example['file_path']} # #{example['full_description']}"
  end
end
