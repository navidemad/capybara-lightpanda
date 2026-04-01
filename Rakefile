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

require "rubocop/rake_task"
RuboCop::RakeTask.new

namespace :examples do
  desc "Run plain Rails examples (Minitest + RSpec)"
  task :plain do
    %w[rails_minitest_example.rb rails_rspec_example.rb].each do |file|
      path = File.join("examples", file)
      puts "\n=== #{file} ==="
      sh "ruby #{path}" do |ok, _|
        abort "#{file} failed" unless ok
      end
    end
  end

  desc "Run Turbo Rails examples (Minitest + RSpec) — requires network for CDN"
  task :turbo do
    %w[rails_turbo_minitest_example.rb rails_turbo_rspec_example.rb].each do |file|
      path = File.join("examples", file)
      puts "\n=== #{file} ==="
      sh "ruby #{path}" do |ok, _|
        abort "#{file} failed" unless ok
      end
    end
  end

  desc "Run all examples"
  task all: %i[plain turbo]
end

task default: %i[spec:unit rubocop]
task test: :spec
