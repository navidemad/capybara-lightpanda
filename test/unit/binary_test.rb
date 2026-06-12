# frozen_string_literal: true

require_relative "../test_helper"
require "capybara/lightpanda/errors"
require "capybara/lightpanda/binary"

describe Capybara::Lightpanda::Binary do
  # Class-level config bleeds across tests; snapshot and restore.
  before do
    @snapshot = %i[@required_version @cache_time @install_dir @logger
                   @proxy_addr @proxy_port @proxy_user @proxy_pass].to_h do |ivar|
      [ivar, Capybara::Lightpanda::Binary.instance_variable_get(ivar)]
    end
  end

  after do
    @snapshot.each do |ivar, value|
      Capybara::Lightpanda::Binary.instance_variable_set(ivar, value)
    end
  end

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

  describe ".configure" do
    it "yields the Binary class for setting attributes" do
      Capybara::Lightpanda::Binary.configure do |b|
        b.required_version = "0.3.0"
        b.proxy_addr = "proxy.example"
        b.proxy_port = 8080
      end

      assert_equal "0.3.0", Capybara::Lightpanda::Binary.required_version
      assert_equal "proxy.example", Capybara::Lightpanda::Binary.proxy_addr
      assert_equal 8080, Capybara::Lightpanda::Binary.proxy_port
    end
  end

  describe ".cache_time" do
    it "defaults to 86_400 (24h)" do
      Capybara::Lightpanda::Binary.instance_variable_set(:@cache_time, nil)
      ENV.delete("LIGHTPANDA_CACHE_TIME")
      assert_equal 86_400, Capybara::Lightpanda::Binary.cache_time
    end

    it "is overridable via LIGHTPANDA_CACHE_TIME env" do
      Capybara::Lightpanda::Binary.instance_variable_set(:@cache_time, nil)
      ENV["LIGHTPANDA_CACHE_TIME"] = "3600"
      assert_equal 3600, Capybara::Lightpanda::Binary.cache_time
    ensure
      ENV.delete("LIGHTPANDA_CACHE_TIME")
    end

    it "is overridable via writer" do
      Capybara::Lightpanda::Binary.cache_time = 60
      assert_equal 60, Capybara::Lightpanda::Binary.cache_time
    end
  end

  describe ".install_dir / .install_path" do
    it "defaults install_path to default_binary_path" do
      assert_equal Capybara::Lightpanda::Binary.default_binary_path,
                   Capybara::Lightpanda::Binary.install_path
    end

    it "appends 'lightpanda' to a custom install_dir" do
      Capybara::Lightpanda::Binary.install_dir = "/opt/bin"
      assert_equal "/opt/bin/lightpanda", Capybara::Lightpanda::Binary.install_path
    end
  end

  describe ".remove" do
    it "returns nil when no binary present" do
      Capybara::Lightpanda::Binary.install_dir = Dir.mktmpdir
      assert_nil Capybara::Lightpanda::Binary.remove
    end

    it "deletes the cached binary and returns its path" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir
      path = File.join(dir, "lightpanda")
      File.write(path, "fake")

      result = Capybara::Lightpanda::Binary.remove
      assert_equal path, result
      refute_path_exists path
    end
  end

  describe ".current_version" do
    it "returns nil when no binary is installed" do
      Capybara::Lightpanda::Binary.install_dir = Dir.mktmpdir
      assert_nil Capybara::Lightpanda::Binary.current_version
    end
  end

  describe ".update with required_version pin" do
    it "returns the cached pinned binary without re-downloading" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir
      Capybara::Lightpanda::Binary.required_version = "0.3.0"

      path = File.join(dir, "lightpanda")
      File.write(path, "fake")
      File.chmod(0o755, path)

      Capybara::Lightpanda::Binary.expects(:download).never
      assert_equal path, Capybara::Lightpanda::Binary.update
    end

    it "delegates to download when pinned binary missing" do
      Capybara::Lightpanda::Binary.install_dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.required_version = "0.3.0"

      sentinel = "/tmp/sentinel-path"
      # Pinned mode must download even if PATH has lightpanda — the pin is
      # an explicit version contract that PATH-detection should not honor.
      Capybara::Lightpanda::Binary.stubs(:system_binary_path).returns("/opt/homebrew/bin/lightpanda")
      Capybara::Lightpanda::Binary.expects(:download).once.returns(sentinel)
      assert_equal sentinel, Capybara::Lightpanda::Binary.update
    end
  end

  describe ".update without required_version" do
    it "returns the cached binary when fresh" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir
      Capybara::Lightpanda::Binary.cache_time = 86_400

      path = File.join(dir, "lightpanda")
      File.write(path, "fake")
      File.chmod(0o755, path)

      Capybara::Lightpanda::Binary.expects(:download).never
      assert_equal path, Capybara::Lightpanda::Binary.update
    end

    it "re-downloads when the cached binary is older than cache_time" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir
      Capybara::Lightpanda::Binary.cache_time = 60

      path = File.join(dir, "lightpanda")
      File.write(path, "fake")
      File.chmod(0o755, path)
      File.utime(Time.now - 3600, Time.now - 3600, path)

      Capybara::Lightpanda::Binary.stubs(:system_binary_path).returns(nil)
      Capybara::Lightpanda::Binary.expects(:download).once.returns(path)
      assert_equal path, Capybara::Lightpanda::Binary.update
    end

    it "treats cache_time = 0 as 'always fresh'" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir
      Capybara::Lightpanda::Binary.cache_time = 0

      path = File.join(dir, "lightpanda")
      File.write(path, "fake")
      File.chmod(0o755, path)
      File.utime(Time.now - 999_999, Time.now - 999_999, path)

      Capybara::Lightpanda::Binary.expects(:download).never
      assert_equal path, Capybara::Lightpanda::Binary.update
    end

    it "uses lightpanda from PATH when cache is empty (brew install case)" do
      Capybara::Lightpanda::Binary.install_dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.cache_time = 86_400

      brew_dir = Dir.mktmpdir
      brew_path = File.join(brew_dir, "lightpanda")
      File.write(brew_path, "#!/bin/sh\necho fake\n")
      File.chmod(0o755, brew_path)

      original_path = ENV.fetch("PATH", nil)
      ENV["PATH"] = "#{brew_dir}#{File::PATH_SEPARATOR}#{original_path}"

      Capybara::Lightpanda::Binary.expects(:download).never
      assert_equal brew_path, Capybara::Lightpanda::Binary.update
    ensure
      ENV["PATH"] = original_path
    end

    it "uses lightpanda from PATH when the cache is stale" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir
      Capybara::Lightpanda::Binary.cache_time = 60

      stale = File.join(dir, "lightpanda")
      File.write(stale, "stale")
      File.chmod(0o755, stale)
      File.utime(Time.now - 3600, Time.now - 3600, stale)

      brew_dir = Dir.mktmpdir
      brew_path = File.join(brew_dir, "lightpanda")
      File.write(brew_path, "#!/bin/sh\necho fake\n")
      File.chmod(0o755, brew_path)

      original_path = ENV.fetch("PATH", nil)
      ENV["PATH"] = "#{brew_dir}#{File::PATH_SEPARATOR}#{original_path}"

      Capybara::Lightpanda::Binary.expects(:download).never
      assert_equal brew_path, Capybara::Lightpanda::Binary.update
    ensure
      ENV["PATH"] = original_path
    end

    it "falls back to download when neither cache nor PATH has lightpanda" do
      Capybara::Lightpanda::Binary.install_dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.cache_time = 86_400

      empty_dir = Dir.mktmpdir
      original_path = ENV.fetch("PATH", nil)
      ENV["PATH"] = empty_dir

      sentinel = "/tmp/sentinel-path"
      Capybara::Lightpanda::Binary.expects(:download).once.returns(sentinel)
      assert_equal sentinel, Capybara::Lightpanda::Binary.update
    ensure
      ENV["PATH"] = original_path
    end

    # A stale cache + a failed refresh (network blocked under WebMock/VCR,
    # GitHub 5xx, timeouts) must NOT hard-fail when a usable binary is already
    # on disk: a stale-but-present binary beats no browser at all. The
    # MINIMUM_NIGHTLY_BUILD floor still gates correctness in Process#start.
    it "falls back to the stale cached binary when the download fails" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir
      Capybara::Lightpanda::Binary.cache_time = 60

      path = File.join(dir, "lightpanda")
      File.write(path, "stale-but-usable")
      File.chmod(0o755, path)
      File.utime(Time.now - 3600, Time.now - 3600, path)

      Capybara::Lightpanda::Binary.stubs(:system_binary_path).returns(nil)
      Capybara::Lightpanda::Binary.expects(:download).raises(
        Capybara::Lightpanda::BinaryNotFoundError, "Failed to download binary: 504 Gateway Time-out"
      )

      result = nil
      _out, err = capture_io { result = Capybara::Lightpanda::Binary.update }

      assert_equal path, result
      # The fallback must be LOUD (Kernel.warn, not the opt-in debug logger):
      # a VCR-guarded suite lands here silently and otherwise only ever sees
      # a confusing MINIMUM_NIGHTLY_BUILD floor error later. The warning names
      # the original error and the unstubbed-process provision one-liner.
      assert_includes err, "Binary download failed"
      assert_includes err, "504 Gateway Time-out"
      assert_includes err, Capybara::Lightpanda::Binary::PROVISION_HINT
    end

    # Cold cache (no binary on disk) has nothing to fall back to — the download
    # error must surface so the caller knows there is no browser.
    it "propagates the download error when the cache is empty (cold cache)" do
      Capybara::Lightpanda::Binary.install_dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.cache_time = 86_400

      empty_dir = Dir.mktmpdir
      original_path = ENV.fetch("PATH", nil)
      ENV["PATH"] = empty_dir

      Capybara::Lightpanda::Binary.expects(:download).raises(
        Capybara::Lightpanda::BinaryNotFoundError, "Failed to download binary: 504 Gateway Time-out"
      )

      assert_raises(Capybara::Lightpanda::BinaryNotFoundError) do
        Capybara::Lightpanda::Binary.update
      end
    ensure
      ENV["PATH"] = original_path
    end
  end

  describe ".update_hint" do
    it "suggests brew upgrade when the binary is a Cellar-resolving symlink" do
      tmp = Dir.mktmpdir
      cellar = File.join(tmp, "Cellar", "lightpanda", "nightly", "bin")
      FileUtils.mkdir_p(cellar)
      target = File.join(cellar, "lightpanda")
      File.write(target, "fake")
      File.chmod(0o755, target)

      bin_dir = File.join(tmp, "bin")
      FileUtils.mkdir_p(bin_dir)
      symlink = File.join(bin_dir, "lightpanda")
      File.symlink(target, symlink)

      assert_equal "brew update && brew upgrade lightpanda",
                   Capybara::Lightpanda::Binary.update_hint(symlink)
    end

    it "suggests the require-the-gem one-liner when the binary is at the gem's install_path" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir
      path = File.join(dir, "lightpanda")

      # Not the rake tasks: in a Rails app the gem usually lives in the :test
      # Gemfile group, so `bundle exec rake lightpanda:binary:*` only exists
      # under RAILS_ENV=test — copied verbatim into a dev shell it fails with
      # "Don't know how to build task". The one-liner works from any env.
      assert_equal Capybara::Lightpanda::Binary::PROVISION_HINT,
                   Capybara::Lightpanda::Binary.update_hint(path)
    end

    it "falls back to a curl command for paths the gem doesn't recognize" do
      path = "/usr/local/bin/lightpanda"
      hint = Capybara::Lightpanda::Binary.update_hint(path)
      platform = Capybara::Lightpanda::Binary.platform_binary

      expected = "curl -sL https://github.com/lightpanda-io/browser/releases/download/nightly/" \
                 "#{platform} -o #{path} && chmod +x #{path}"
      assert_equal expected, hint
    end
  end

  describe ".logger" do
    it "returns nil by default" do
      Capybara::Lightpanda::Binary.instance_variable_set(:@logger, nil)
      original = ENV.delete("LIGHTPANDA_DEBUG")
      assert_nil Capybara::Lightpanda::Binary.logger
    ensure
      ENV["LIGHTPANDA_DEBUG"] = original if original
    end

    it "auto-creates a stderr logger when LIGHTPANDA_DEBUG is set" do
      Capybara::Lightpanda::Binary.instance_variable_set(:@logger, nil)
      ENV["LIGHTPANDA_DEBUG"] = "1"
      assert_instance_of Capybara::Lightpanda::Logger, Capybara::Lightpanda::Binary.logger
    ensure
      ENV.delete("LIGHTPANDA_DEBUG")
    end
  end
end
