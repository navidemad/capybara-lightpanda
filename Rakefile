# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec) do |t|
  t.pattern = "spec/features/driver_spec.rb"
end

RSpec::Core::RakeTask.new("spec:shared") do |t|
  t.pattern = "spec/features/session_spec.rb"
end

RSpec::Core::RakeTask.new("spec:all") do |t|
  t.pattern = "spec/**/*_spec.rb"
end

RSpec::Core::RakeTask.new("spec:unit") do |t|
  t.pattern = "spec/unit/**/*_spec.rb"
end

namespace :spec do
  desc "Run spec files one at a time, recording pass/fail in tmp/spec_progress.json. " \
       "Skips files already passing. Env: CLEAR=1 resets progress, FAIL_FAST=1 stops on first failure, " \
       "ONLY=<glob> restricts the file set."
  task :incremental do
    require "json"
    require "fileutils"
    require "digest"
    require "time"

    progress_path = "tmp/spec_progress.json"
    logs_dir = "tmp/spec_logs"
    FileUtils.mkdir_p(logs_dir)

    pattern = ENV["ONLY"] || "spec/**/*_spec.rb"
    files = Dir[pattern].sort
    abort "No spec files matched #{pattern}" if files.empty?

    if ENV["CLEAR"] == "1" && File.exist?(progress_path)
      File.delete(progress_path)
      puts "Cleared #{progress_path}"
    end

    progress = File.exist?(progress_path) ? JSON.parse(File.read(progress_path)) : {}

    save = lambda do
      FileUtils.mkdir_p(File.dirname(progress_path))
      File.write(progress_path, JSON.pretty_generate(progress) + "\n")
    end

    failed = []
    skipped = []
    ran = []
    total = files.size
    run_started = Time.now

    puts "spec:incremental — #{total} file(s) to consider"
    puts "  pattern:        #{pattern}"
    puts "  progress file:  #{progress_path}"
    puts "  log dir:        #{logs_dir}"
    puts "  fail_fast:      #{ENV['FAIL_FAST'] == '1'}"
    puts ""

    files.each_with_index do |file, idx|
      pos = "[#{idx + 1}/#{total}]"
      sha = Digest::SHA1.file(file).hexdigest
      entry = progress[file]
      if entry && entry["status"] == "passed" && entry["sha"] == sha
        skipped << file
        puts "#{pos} SKIP   #{file}  (passed #{entry['ran_at']}, #{entry['duration']}s)"
        next
      end
      only_failures = entry && entry["status"] == "failed" && entry["sha"] == sha
      reason =
        if entry.nil?                    then "never run"
        elsif entry["sha"] != sha        then "file changed"
        elsif entry["status"] == "failed" then "previously failed (--only-failures)"
        else                                  "stale: #{entry['status']}"
        end

      log_path = File.join(logs_dir, file.tr("/", "_") + ".log")
      puts ""
      puts "#{pos} RUN    #{file}  (#{reason})"
      puts "         log → #{log_path}"
      started = Time.now
      summary_line = nil
      rspec_cmd = ["bundle", "exec", "rspec", file, "--format", "documentation"]
      rspec_cmd << "--only-failures" if only_failures
      ok = File.open(log_path, "w") do |log|
        IO.popen([*rspec_cmd, err: %i[child out]]) do |io|
          io.each_line do |line|
            $stdout.write(line)
            $stdout.flush
            log.write(line)
            summary_line = line.strip if line =~ /\A\d+ examples?,/
          end
        end
        $?.success?
      end
      duration = (Time.now - started).round(2)

      progress[file] = {
        "status" => ok ? "passed" : "failed",
        "sha" => sha,
        "duration" => duration,
        "log" => log_path,
        "ran_at" => Time.now.iso8601,
        "summary" => summary_line
      }
      save.call
      ran << file
      status_tag = ok ? "PASS" : "FAIL"
      puts "#{pos} #{status_tag}   #{file}  (#{duration}s)  #{summary_line}"
      puts "         running totals — passed: #{ran.size - failed.size}  failed: #{failed.size + (ok ? 0 : 1)}  skipped: #{skipped.size}  remaining: #{total - idx - 1}"
      next if ok

      failed << file
      if ENV["FAIL_FAST"] == "1"
        puts "FAIL_FAST=1 — stopping after first failure."
        break
      end
    end

    elapsed = (Time.now - run_started).round(2)

    puts "\n========== spec:incremental summary =========="
    puts "Total files:     #{files.size}"
    puts "Skipped (green): #{skipped.size}"
    puts "Ran:             #{ran.size}"
    puts "Passed this run: #{ran.size - failed.size}"
    puts "Failed:          #{failed.size}"
    puts "Wallclock:       #{elapsed}s"
    failed.each { |f| puts "  x #{f}  (log: #{progress[f]['log']})  #{progress[f]['summary']}" }
    progress.each do |f, e|
      next if files.include?(f)

      puts "  ? #{f} stale entry (no longer matches pattern, status=#{e['status']})"
    end
    puts "Progress file:  #{progress_path}"

    abort "spec:incremental: #{failed.size} file(s) failed" unless failed.empty?
  end
end

require "rubocop/rake_task"
RuboCop::RakeTask.new

namespace :examples do
  desc "Run plain Rails examples (Minitest + RSpec)"
  task :plain do
    %w[rails_minitest_example.rb rails_rspec_example.rb].each do |file|
      path = File.join("examples", file)
      puts "\n=== #{file} ==="
      Bundler.with_unbundled_env do
        sh "ruby #{path}" do |ok, _|
          abort "#{file} failed" unless ok
        end
      end
    end
  end

  desc "Run Turbo Rails examples (Minitest + RSpec) — requires network for CDN"
  task :turbo do
    %w[rails_turbo_minitest_example.rb rails_turbo_rspec_example.rb].each do |file|
      path = File.join("examples", file)
      puts "\n=== #{file} ==="
      Bundler.with_unbundled_env do
        sh "ruby #{path}" do |ok, _|
          abort "#{file} failed" unless ok
        end
      end
    end
  end

  desc "Run all examples"
  task all: %i[plain turbo]
end

task default: %i[spec:unit rubocop]
task test: :spec
