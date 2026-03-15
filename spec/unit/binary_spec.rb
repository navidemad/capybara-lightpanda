# frozen_string_literal: true

require "bundler/setup"
require "capybara/lightpanda/errors"
require "capybara/lightpanda/binary"

RSpec.describe Capybara::Lightpanda::Binary do
  describe ".platform_binary" do
    it "returns the correct binary name for the current platform" do
      name = described_class.platform_binary
      expect(name).to match(/\Alightpanda-(x86_64-linux|aarch64-macos)\z/)
    end
  end

  describe ".default_binary_path" do
    it "returns a path under the cache directory" do
      path = described_class.default_binary_path
      expect(path).to end_with("lightpanda/lightpanda")
    end

    it "respects XDG_CACHE_HOME" do
      original = ENV.fetch("XDG_CACHE_HOME", nil)
      ENV["XDG_CACHE_HOME"] = "/tmp/test-cache"
      expect(described_class.default_binary_path).to eq("/tmp/test-cache/lightpanda/lightpanda")
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
      expect(described_class::PLATFORMS[%w[x86_64 linux]]).to eq("lightpanda-x86_64-linux")
      expect(described_class::PLATFORMS[%w[aarch64 darwin]]).to eq("lightpanda-aarch64-macos")
      expect(described_class::PLATFORMS[%w[arm64 darwin]]).to eq("lightpanda-aarch64-macos")
    end

    it "is frozen" do
      expect(described_class::PLATFORMS).to be_frozen
    end
  end
end
