# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "mocha/minitest"
require "fileutils"
require "capybara"
require "capybara/minitest"
require "capybara-lightpanda"
require_relative "support/test_app"
require_relative "support/driver_setup"

PROJECT_ROOT = File.expand_path("..", __dir__) unless defined?(PROJECT_ROOT)

Capybara.save_path = File.join(PROJECT_ROOT, "spec", "tmp")

module Minitest
  class Spec
    include Capybara::Minitest::Assertions

    before do
      FileUtils.rm_rf(Capybara.save_path) if File.directory?(Capybara.save_path)
    end
  end
end
