# frozen_string_literal: true

require "English"
require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rake/testtask"

load File.expand_path("lib/capybara/lightpanda/tasks/binary.rake", __dir__)

# RSpec is retained solely for the Capybara shared-spec battery, which is
# distributed in RSpec format by the capybara gem itself. Local tests live
# under test/ and use Minitest::Spec.
RSpec::Core::RakeTask.new("spec:shared") do |t|
  t.pattern = "spec/features/session_spec.rb"
end

namespace :spec do
  desc "Run shared specs across N parallel workers (default: Etc.nprocessors / 2, min 2)"
  task :"shared:parallel" do
    require "etc"
    require "fileutils"

    workers = ENV.fetch("RSPEC_WORKERS", [Etc.nprocessors / 2, 2].max).to_i
    log_dir = File.expand_path("tmp/spec_parallel", __dir__)
    FileUtils.rm_rf(log_dir)
    FileUtils.mkdir_p(log_dir)

    puts "Running spec:shared across #{workers} workers (logs: #{log_dir})"
    start = Time.now

    pids = (0...workers).map do |idx|
      log_file = File.join(log_dir, "worker_#{idx}.log")
      env = { "RSPEC_WORKER_COUNT" => workers.to_s, "RSPEC_WORKER_INDEX" => idx.to_s }
      pid = Process.spawn(env, "bundle exec rspec spec/features/session_spec.rb",
                          out: log_file, err: %i[child out])
      puts "  worker #{idx}: pid=#{pid} log=#{log_file}"
      pid
    end

    statuses = pids.map do |pid|
      _, status = Process.waitpid2(pid)
      status
    end
    elapsed = Time.now - start

    puts "\n=== Parallel run: #{elapsed.round(1)}s wall clock ==="
    failed = false
    statuses.each_with_index do |status, idx|
      log = File.read(File.join(log_dir, "worker_#{idx}.log"))
      summary = log.lines.grep(/^\d+ examples?, /).last&.strip || "(no summary)"
      mark = status.success? ? "ok" : "FAIL"
      puts "  worker #{idx} [#{mark}, exit=#{status.exitstatus}]: #{summary}"
      failed ||= !status.success?
    end

    abort "spec:shared:parallel: one or more workers failed" if failed
  end
end

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/features/driver_test.rb"]
  t.warning = false
end

namespace :test do
  Rake::TestTask.new(:unit) do |t|
    t.libs << "lib" << "test"
    t.test_files = FileList["test/unit/*_test.rb"]
    t.warning = false
  end

  Rake::TestTask.new(:all) do |t|
    t.libs << "lib" << "test"
    t.test_files = FileList["test/**/*_test.rb"]
    t.warning = false
  end

  desc "Run the Bun harness for the injected _lightpanda predicate logic (test/js/). " \
       "Skips with a notice if Bun isn't installed — it's a dev-only tool, not a gem dependency."
  task :js do
    js_dir = File.expand_path("test/js", __dir__)
    bun = `command -v bun`.strip
    if bun.empty?
      warn "test:js: bun not found on PATH — skipping JS harness. " \
           "Install bun (https://bun.sh) to run the predicate unit tests."
      next
    end

    # `bun install` is idempotent and fast; ensures happy-dom is present on a
    # clean checkout before the first `bun test`.
    sh("bun", "install", "--cwd", js_dir) { |ok, _| abort "test:js: bun install failed" unless ok }

    # `bun test` exits 0 when it matches NO files, so a renamed/moved suite
    # would pass silently with zero coverage. Capture output and require that
    # tests actually ran.
    output = IO.popen(["bun", "test", "--cwd", js_dir], err: %i[child out], &:read)
    puts output
    abort "test:js: JS predicate tests failed" unless $CHILD_STATUS.success?
    abort "test:js: bun matched no test files (suite renamed or missing?)" unless output =~ /Ran \d+ tests?/
  end

  desc "Run test files one at a time, recording pass/fail in tmp/test_progress.json. " \
       "Skips files already passing. Env: CLEAR=1 resets progress, FAIL_FAST=1 stops on first failure, " \
       "ONLY=<glob> restricts the file set."
  task :incremental do
    require "json"
    require "fileutils"
    require "digest"
    require "time"

    progress_path = "tmp/test_progress.json"
    logs_dir = "tmp/test_logs"
    FileUtils.mkdir_p(logs_dir)

    pattern = ENV["ONLY"] || "test/**/*_test.rb"
    files = Dir[pattern]
    abort "No test files matched #{pattern}" if files.empty?

    if ENV["CLEAR"] == "1" && File.exist?(progress_path)
      File.delete(progress_path)
      puts "Cleared #{progress_path}"
    end

    progress = File.exist?(progress_path) ? JSON.parse(File.read(progress_path)) : {}

    lib_files = Dir["lib/**/*"].select { |p| File.file?(p) }.sort
    lib_sha = Digest::SHA1.hexdigest(
      lib_files.map { |p| "#{p}:#{Digest::SHA1.file(p).hexdigest}" }.join("\n")
    )

    save = lambda do
      FileUtils.mkdir_p(File.dirname(progress_path))
      File.write(progress_path, "#{JSON.pretty_generate(progress)}\n")
    end

    failed = []
    skipped = []
    ran = []
    total = files.size
    run_started = Time.now

    puts "test:incremental — #{total} file(s) to consider"
    puts "  pattern:        #{pattern}"
    puts "  progress file:  #{progress_path}"
    puts "  log dir:        #{logs_dir}"
    puts "  fail_fast:      #{ENV['FAIL_FAST'] == '1'}"
    puts ""

    files.each_with_index do |file, idx|
      pos = "[#{idx + 1}/#{total}]"
      sha = Digest::SHA1.hexdigest("#{Digest::SHA1.file(file).hexdigest}:#{lib_sha}")
      entry = progress[file]
      if entry && entry["status"] == "passed" && entry["sha"] == sha
        skipped << file
        puts "#{pos} SKIP   #{file}  (passed #{entry['ran_at']}, #{entry['duration']}s)"
        next
      end
      reason =
        if entry.nil?                    then "never run"
        elsif entry["sha"] != sha        then "file changed"
        elsif entry["status"] == "failed" then "previously failed (rerun whole file)"
        else "stale: #{entry['status']}"
        end

      log_path = File.join(logs_dir, "#{file.tr('/', '_')}.log")
      puts ""
      puts "#{pos} RUN    #{file}  (#{reason})"
      puts "         log → #{log_path}"
      started = Time.now
      summary_line = nil
      ruby_cmd = ["bundle", "exec", "ruby", "-Ilib", "-Itest", file]
      ok = File.open(log_path, "w") do |log|
        IO.popen([*ruby_cmd, { err: %i[child out] }]) do |io|
          io.each_line do |line|
            $stdout.write(line)
            $stdout.flush
            log.write(line)
            summary_line = line.strip if line =~ /\A\d+ runs?,/
          end
        end
        $CHILD_STATUS.success?
      end
      duration = (Time.now - started).round(2)

      progress[file] = {
        "status" => ok ? "passed" : "failed",
        "sha" => sha,
        "duration" => duration,
        "log" => log_path,
        "ran_at" => Time.now.iso8601,
        "summary" => summary_line,
      }
      save.call
      ran << file
      status_tag = ok ? "PASS" : "FAIL"
      puts "#{pos} #{status_tag}   #{file}  (#{duration}s)  #{summary_line}"
      passed_so_far = ran.size - failed.size
      failed_so_far = failed.size + (ok ? 0 : 1)
      remaining = total - idx - 1
      puts "         running totals — passed: #{passed_so_far}  failed: #{failed_so_far}  " \
           "skipped: #{skipped.size}  remaining: #{remaining}"
      next if ok

      failed << file
      if ENV["FAIL_FAST"] == "1"
        puts "FAIL_FAST=1 — stopping after first failure."
        break
      end
    end

    elapsed = (Time.now - run_started).round(2)

    puts "\n========== test:incremental summary =========="
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

    abort "test:incremental: #{failed.size} file(s) failed" unless failed.empty?
  end
end

desc "Run the full test suite (Minitest test:all + RSpec spec:shared)"
task suite: %w[test:all spec:shared]

require "rubocop/rake_task"
RuboCop::RakeTask.new

namespace :examples do
  # Bundler clears BUNDLE_* inside with_unbundled_env, so re-set BUNDLE_PATH there
  # to redirect `bundler/inline` installs into a stable, cacheable directory.
  # EXAMPLES_BUNDLE_PATH overrides the local default (set by CI to a cached path).
  examples_bundle_path = ENV.fetch("EXAMPLES_BUNDLE_PATH") do
    File.expand_path("tmp/example-bundles", __dir__)
  end

  desc "Run plain Rails examples (Minitest + RSpec)"
  task :plain do
    %w[rails_minitest_example.rb rails_rspec_example.rb].each do |file|
      path = File.join("examples", file)
      puts "\n=== #{file} ==="
      Bundler.with_unbundled_env do
        ENV["BUNDLE_PATH"] = examples_bundle_path
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
        ENV["BUNDLE_PATH"] = examples_bundle_path
        sh "ruby #{path}" do |ok, _|
          abort "#{file} failed" unless ok
        end
      end
    end
  end

  desc "Run all examples"
  task all: %i[plain turbo]
end

task default: %i[test:js test:unit rubocop]
