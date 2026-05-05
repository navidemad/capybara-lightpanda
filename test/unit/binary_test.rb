# frozen_string_literal: true

require_relative "../test_helper"
require "capybara/lightpanda/errors"
require "capybara/lightpanda/binary"

describe Capybara::Lightpanda::Binary do
  describe ".platform_binary" do
    it "returns the correct binary name for the current platform" do
      name = Capybara::Lightpanda::Binary.platform_binary
      assert_match(/\Alightpanda-(x86_64-linux|aarch64-macos)\z/, name)
    end
  end

  describe ".default_binary_path" do
    it "returns a path under the cache directory" do
      path = Capybara::Lightpanda::Binary.default_binary_path
      assert path.end_with?("lightpanda/lightpanda"), "expected path to end with 'lightpanda/lightpanda', got #{path}"
    end

    it "respects XDG_CACHE_HOME" do
      original = ENV.fetch("XDG_CACHE_HOME", nil)
      ENV["XDG_CACHE_HOME"] = "/tmp/test-cache"
      assert_equal "/tmp/test-cache/lightpanda/lightpanda", Capybara::Lightpanda::Binary.default_binary_path
    ensure
      if original
        ENV["XDG_CACHE_HOME"] = original
      else
        ENV.delete("XDG_CACHE_HOME")
      end
    end
  end

  describe "PLATFORMS" do
    it "maps known architectures" do
      assert_equal "lightpanda-x86_64-linux", Capybara::Lightpanda::Binary::PLATFORMS[%w[x86_64 linux]]
      assert_equal "lightpanda-aarch64-macos", Capybara::Lightpanda::Binary::PLATFORMS[%w[aarch64 darwin]]
      assert_equal "lightpanda-aarch64-macos", Capybara::Lightpanda::Binary::PLATFORMS[%w[arm64 darwin]]
    end

    it "is frozen" do
      assert_predicate Capybara::Lightpanda::Binary::PLATFORMS, :frozen?
    end
  end
end
