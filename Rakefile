# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec) do |t|
  t.pattern = "spec/features/driver_spec.rb"
end

RSpec::Core::RakeTask.new("spec:shared") do |t|
  t.pattern = "spec/features/session_spec.rb"
end

RSpec::Core::RakeTask.new("spec:all") do |t|
  t.pattern = "spec/features/**/*_spec.rb"
end

task default: :spec
task test: :spec
