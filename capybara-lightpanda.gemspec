# frozen_string_literal: true

require_relative "lib/capybara/lightpanda/version"

Gem::Specification.new do |spec|
  spec.name = "capybara-lightpanda"
  spec.version = Capybara::Lightpanda::VERSION
  spec.authors = ["Navid Emad"]
  spec.email = ["design.navid@gmail.com"]

  spec.summary = "Capybara driver for the Lightpanda headless browser"
  spec.description = "A Capybara driver for Lightpanda, the fast headless browser built in Zig. " \
                     "Provides a production-ready driver with XPath polyfill, reliable navigation, " \
                     "and cookie management — ready for real-world Rails test suites."
  spec.homepage = "https://github.com/navidemad/capybara-lightpanda"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/releases"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"

  spec.files = Dir["lib/**/*", "LICENSE.txt", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "capybara", ">= 3.0"
  spec.add_dependency "concurrent-ruby", "~> 1.3"
  spec.add_dependency "websocket-driver", "~> 0.8"
end
