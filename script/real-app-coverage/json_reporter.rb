# frozen_string_literal: true

# Minitest reporter that records every test result as structured JSON, injected
# into the target Rails app's test run via RUBYOPT="-r<this file>". It touches
# NOTHING in the app repo — no Gemfile entry, no test_helper edit. It hooks
# Minitest::CompositeReporter#record at the class level, so it captures results
# regardless of how Rails/ActiveSupport assembles its reporter chain.
#
# Requires single-process execution (PARALLEL_WORKERS=0): the RESULTS array
# lives in one process's memory, so forked parallel workers would each see only
# their own slice and the parent's after_run would write an incomplete file.
# run.sh always sets PARALLEL_WORKERS=0 for this reason.
#
# Output path comes from LIGHTPANDA_JSON_OUT. The emitted file is an object:
#   { "meta": {...}, "results": [ {klass, name, status, time, message}, ... ] }
# status is one of: pass | fail | error | skip.

require "minitest"
require "json"

module LightpandaCoverage
  RESULTS = [] # rubocop:disable Style/MutableConstant -- the reporter accumulates into it across the run
  OUT = ENV.fetch("LIGHTPANDA_JSON_OUT", "lightpanda_results.json")

  def self.classify(result)
    if result.skipped? then "skip"
    elsif result.error? then "error"
    elsif !result.passed? then "fail"
    else "pass"
    end
  end

  def self.first_failure_line(result)
    return "" if result.passed? || result.skipped?

    failure = result.failures.first
    return "" unless failure

    "#{failure.class}: #{failure.message.to_s.lines.first&.strip}"
  end
end

module Minitest # rubocop:disable Style/OneClassPerFile -- deliberately reopens Minitest to hook the reporter
  class CompositeReporter
    alias __lightpanda_orig_record record

    def record(result)
      LightpandaCoverage::RESULTS << {
        klass: result.klass,
        name: result.name,
        status: LightpandaCoverage.classify(result),
        time: result.time.round(3),
        message: LightpandaCoverage.first_failure_line(result),
      }
      __lightpanda_orig_record(result)
    end
  end
end

Minitest.after_run do
  counts = LightpandaCoverage::RESULTS.each_with_object(Hash.new(0)) do |r, h|
    h[r[:status]] += 1
  end

  payload = {
    meta: {
      generated_at: Time.now.utc.iso8601,
      total: LightpandaCoverage::RESULTS.size,
      pass: counts["pass"],
      fail: counts["fail"],
      error: counts["error"],
      skip: counts["skip"],
      browser_build: ENV.fetch("LIGHTPANDA_BUILD", nil),
      gem_version: ENV.fetch("LIGHTPANDA_GEM_VERSION", nil),
    },
    results: LightpandaCoverage::RESULTS.sort_by { |r| [r[:klass], r[:name]] },
  }

  File.write(LightpandaCoverage::OUT, JSON.pretty_generate(payload))
  warn "[lightpanda-coverage] wrote #{LightpandaCoverage::RESULTS.size} results " \
       "(#{counts['pass']} pass / #{counts['fail']} fail / #{counts['error']} error / " \
       "#{counts['skip']} skip) to #{LightpandaCoverage::OUT}"
end
