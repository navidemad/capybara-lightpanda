# frozen_string_literal: true

# Per-example capture of the gem's own instruments — Browser#console_logs and
# Network#traffic — for a real-apps target, injected into the target's spec run
# with `rspec --require <this file>`.
#
# Same trick as script/real-app-coverage/json_reporter.rb (RUBYOPT-injected
# Minitest reporter): the app repo is never touched — no Gemfile entry, no
# spec_helper edit. RSpec's `--require` runs after Bundler and rspec-core are up
# but before the spec files load, so registering config hooks here puts them
# ahead of everything the app's spec_helper registers.
#
# WHY A DRIVER HOOK AND NOT JUST AN `after` HOOK
#
# `capybara/rspec` registers `config.after { Capybara.reset_sessions! }`, and
# config-level `after` hooks run in REVERSE registration order — so this file's
# hooks, registered first, run LAST, i.e. after the session was already reset.
# Driver#reset! disposes the BrowserContext and clears both buffers, so an
# after-hook-only probe would reliably capture two empty arrays.
#
# So the capture is anchored on `Driver#reset!` itself (prepended module), which
# runs while the page is still alive, and the after hook only sweeps up drivers
# that were never reset (a failure before Capybara's hook, a suite that resets
# elsewhere). Whichever fires first wins; the second is a no-op for that driver.
# `RSpec.current_example.exception` is already set by the time either runs, so
# the capture knows whether the example failed and can skip the expensive
# fields (current_url / title / body are CDP round-trips) on green examples.
#
# Env:
#   LIGHTPANDA_PROBE_DIR      where to write artifacts (required; else no-op)
#   LIGHTPANDA_PROBE_ALWAYS=1 also write artifacts for passing examples
#   LIGHTPANDA_PROBE_HTML=0   skip the page-body dump

require "json"
require "fileutils"

# rubocop:disable Metrics/ModuleLength, Metrics/ClassLength
# -- one self-contained file on purpose: it is passed to `rspec --require` by
#    absolute path, so splitting it would mean shipping a load path into the
#    target app's process.
module LightpandaProbe
  OUT_DIR = ENV.fetch("LIGHTPANDA_PROBE_DIR", nil)
  ALWAYS = ENV["LIGHTPANDA_PROBE_ALWAYS"] == "1"
  CAPTURE_HTML = ENV["LIGHTPANDA_PROBE_HTML"] != "0"
  MAX_LISTED = 5

  # Prepended onto Capybara::Lightpanda::Driver so the capture happens before
  # the BrowserContext is disposed. Must not itself spawn a browser: Driver#reset!
  # calls `browser`, which lazily creates one for a session that never started —
  # `browser_alive?` is the non-spawning guard.
  module DriverHook
    def reset!
      LightpandaProbe.record(self, phase: "pre-reset")
      super
    end
  end

  class << self
    attr_reader :written

    def install!
      return if @installed

      unless defined?(::Capybara::Lightpanda::Driver)
        warn "[lightpanda-probe] capybara-lightpanda is not loaded in this suite — probe disabled."
        return
      end

      ::Capybara::Lightpanda::Driver.prepend(DriverHook)
      FileUtils.mkdir_p(OUT_DIR)
      @installed = true
      @written = []
      @index = 0
      warn "[lightpanda-probe] armed — artifacts → #{OUT_DIR}"
    end

    def enabled? = @installed && !OUT_DIR.to_s.empty?

    # Keyed by driver identity, so the same driver captured twice in one example
    # (reset hook, then after-hook sweep) keeps the first — the earlier state.
    def start_example
      @records = {}.compare_by_identity
    end

    def record(driver, phase:)
      return unless enabled?
      return if @records.nil? || @records.key?(driver)
      return unless safe { driver.browser_alive? }

      @records[driver] = capture(driver, phase)
    rescue StandardError => e
      warn "[lightpanda-probe] capture failed (#{e.class}: #{e.message})"
    end

    def finish_example(example)
      return unless enabled?

      sweep_live_drivers
      failed = !example.exception.nil?
      return if @records.empty? || !(failed || ALWAYS)

      @index += 1
      @records.each_value.with_index { |data, i| flush(example, data, failed, i) }
    end

    private

    # Drivers that were never reset this example — e.g. an exception raised in a
    # `before` hook before Capybara had a session, or a suite that resets
    # somewhere other than the standard capybara/rspec hook.
    def sweep_live_drivers
      pool = ::Capybara.instance_variable_get(:@session_pool)
      return unless pool

      pool.each_value do |session|
        driver = safe { session.driver }
        record(driver, phase: "after-hook") if driver.is_a?(::Capybara::Lightpanda::Driver)
      end
    end

    def capture(driver, phase)
      browser = driver.browser
      base = {
        phase: phase,
        # Both buffers are plain Ruby arrays already in memory — reading them
        # costs nothing, so they are captured even for passing examples.
        console_logs: safe { browser.console_logs.map { |entry| entry.except(:args) } } || [],
        traffic: safe { browser.network.traffic } || [],
        status_code: safe { browser.status_code },
      }
      detailed? ? base.merge(page_state(driver, browser)) : base
    end

    # CDP round-trips: only worth paying for on the example being diagnosed.
    def page_state(driver, browser)
      {
        current_url: safe { browser.current_url },
        title: safe { browser.title },
        html: CAPTURE_HTML ? safe { driver.html } : nil,
      }
    end

    # Whether this example is already known to have failed. RSpec sets the
    # exception before after hooks run, so both capture sites see it.
    def detailed?
      ALWAYS || !::RSpec.current_example&.exception.nil?
    rescue StandardError
      false
    end

    # `nth` disambiguates the (rare) example that drove more than one session.
    def flush(example, data, failed, nth)
      suffix = nth.zero? ? "" : "-session#{nth + 1}"
      base = File.join(OUT_DIR, "#{format('%04d', @index)}-#{slug(example)}#{suffix}")
      html = data.delete(:html)

      payload = {
        example: example.full_description,
        location: example.location,
        status: failed ? "failed" : "passed",
        exception: exception_digest(example),
      }.merge(data)

      File.write("#{base}.json", JSON.pretty_generate(payload))
      File.write("#{base}.html", html) if html
      @written << "#{base}.json"

      print_digest(example, payload, base, html)
    end

    def exception_digest(example)
      error = example.exception
      return nil unless error

      { class: error.class.to_s, message: error.message.to_s.lines.first(8).join.strip }
    end

    def print_digest(example, payload, base, html)
      puts "\n#{color(35, '─── lightpanda probe ───')} #{example.full_description}"
      puts "  url      #{payload[:current_url] || '(not captured)'} [#{payload[:status_code] || '?'}]"
      print_console(payload[:console_logs])
      print_network(payload[:traffic])
      puts "  full     #{base}.json#{' (+ .html)' if html}"
      puts
    end

    def print_console(logs)
      errors = logs.select { |entry| entry[:type].to_s == "error" }
      puts "  console  #{logs.size} message(s), #{errors.size} error(s)"
      list(errors) { |entry| "#{color(31, "[#{entry[:type]}]")} #{truncate(entry[:text], 200)}" }
    end

    # Two shapes matter for the causes still open in causes.yml: a request that
    # came back >= 400 (the server refused) and a request with no response at
    # all (still in flight when the example gave up).
    def print_network(traffic)
      failures = traffic.select { |entry| entry.dig(:response, :status).to_i >= 400 }
      stalled = traffic.select { |entry| entry[:response].nil? }
      puts "  network  #{traffic.size} request(s), #{failures.size} >=400, #{stalled.size} without a response"
      list(failures) { |e| "#{color(31, e[:method])} #{truncate(e[:url], 160)} → #{e.dig(:response, :status)}" }
      list(stalled) { |e| "#{color(33, "#{e[:method]} (no response)")} #{truncate(e[:url], 160)}" }
    end

    def list(entries)
      entries.first(MAX_LISTED).each { |entry| puts "    #{yield(entry)}" }
    end

    def color(code, text) = "\e[#{code}m#{text}\e[0m"

    def truncate(text, limit)
      text = text.to_s.gsub(/\s+/, " ")
      text.length > limit ? "#{text[0, limit]}…" : text
    end

    def slug(example)
      example.full_description.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-")[0, 80].delete_suffix("-")
    end

    def safe
      yield
    rescue StandardError
      nil
    end
  end
end
# rubocop:enable Metrics/ModuleLength, Metrics/ClassLength

if LightpandaProbe::OUT_DIR.to_s.empty?
  warn "[lightpanda-probe] LIGHTPANDA_PROBE_DIR is unset — probe disabled."
else
  RSpec.configure do |config|
    # before(:suite) runs after the spec files (and therefore the app's
    # spec_helper) have loaded, which is the earliest point the driver class is
    # guaranteed to exist.
    config.before(:suite) { LightpandaProbe.install! }
    config.before { LightpandaProbe.start_example }
    config.after { |example| LightpandaProbe.finish_example(example) }

    config.after(:suite) do
      next if LightpandaProbe.written.nil? || LightpandaProbe.written.empty?

      puts "\n[lightpanda-probe] wrote #{LightpandaProbe.written.size} artifact(s) to #{LightpandaProbe::OUT_DIR}"
    end
  end
end
