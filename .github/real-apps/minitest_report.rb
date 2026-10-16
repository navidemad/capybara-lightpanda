# frozen_string_literal: true

# Minitest reporter that writes the subset of RSpec's JSON report that
# check_baseline.rb reads, so a Minitest target (Campfire) goes through the same
# baseline comparison, causes.yml attribution and aggregate roll-up as the RSpec
# ones without a second code path.
#
# Loaded by the target's patch, not RUBYOPT: the patch's system test case does
#
#   require "__CAPYBARA_LIGHTPANDA_PATH__/.github/real-apps/minitest_report.rb" if ENV["REAL_APPS_REPORT"]
#
# so it is required after Bundler has activated the app's own minitest. A RUBYOPT
# `-r` would require minitest before Bundler.setup and activate whichever copy is
# newest on the machine. Minitest 6 no longer discovers `minitest/*_plugin.rb`
# files on its own, so the plugin registers itself through `extensions`.
#
# Output path: ENV["REAL_APPS_REPORT"]. Shape, as check_baseline.rb reads it:
#   { "summary"  => { "example_count", "failure_count", "pending_count",
#                     "errors_outside_of_examples_count" },
#     "examples" => [ { "file_path", "line_number", "full_description",
#                       "status", "exception" => { "class", "message" } } ] }
#
# file_path is "./"-relative like RSpec's, and full_description is
# "Class#test_name", which is what a baseline line keys on. A run that dies
# while loading test files never reaches Minitest.run, so no report is written
# and check_baseline.rb fails the job on the missing file, the same way it does
# for an RSpec boot failure.

require "json"
require "minitest"

module RealAppsReport
  class Reporter < Minitest::AbstractReporter
    def initialize(path)
      super()
      @path = path
      @examples = []
    end

    def record(result)
      file, line = result.source_location
      @examples << {
        "file_path" => relative(file),
        "line_number" => line,
        "full_description" => "#{result.klass}##{result.name}",
        "status" => status(result),
        "exception" => exception(result),
      }.compact
    end

    def report
      counts = @examples.map { |e| e["status"] }.tally
      summary = {
        "example_count" => @examples.size,
        "failure_count" => counts.fetch("failed", 0),
        "pending_count" => counts.fetch("pending", 0),
        "errors_outside_of_examples_count" => 0,
      }
      File.write(@path, JSON.pretty_generate("summary" => summary, "examples" => @examples))
    end

    private

    def status(result)
      if result.skipped? then "pending"
      elsif result.passed? then "passed"
      else "failed"
      end
    end

    def exception(result)
      failure = result.failures.first
      return if failure.nil? || result.skipped?

      error = failure.respond_to?(:error) ? failure.error : failure
      { "class" => error.class.name, "message" => error.message.to_s }
    end

    def relative(file)
      return file.to_s if file.nil? || !file.start_with?("#{Dir.pwd}/")

      "./#{file.delete_prefix("#{Dir.pwd}/")}"
    end
  end
end

module Minitest # rubocop:disable Style/OneClassPerFile -- the plugin hook must live on Minitest
  def self.plugin_real_apps_report_init(_options)
    path = ENV.fetch("REAL_APPS_REPORT", "")
    reporter << RealAppsReport::Reporter.new(path) unless path.empty?
  end
end

Minitest.extensions << "real_apps_report" unless Minitest.extensions.include?("real_apps_report")
