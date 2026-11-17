# frozen_string_literal: true

require_relative "../test_helper"
require "socket"
require "capybara/lightpanda/errors"
require "capybara/lightpanda/binary"

describe Capybara::Lightpanda::Binary do
  # Class-level config bleeds across tests; snapshot and restore.
  before do
    @snapshot = %i[@required_version @cache_time @install_dir @logger
                   @proxy_addr @proxy_port @proxy_user @proxy_pass].to_h do |ivar|
      [ivar, Capybara::Lightpanda::Binary.instance_variable_get(ivar)]
    end
    @env_version = ENV.delete("LIGHTPANDA_VERSION")
    # Most of this file exercises the rolling-nightly cache (age, PATH, stale
    # fallback), which is opt-in now. The default-release behavior has its own
    # describe blocks, which reset this to nil.
    Capybara::Lightpanda::Binary.required_version = "nightly"
  end

  after do
    @snapshot.each do |ivar, value|
      Capybara::Lightpanda::Binary.instance_variable_set(ivar, value)
    end
    ENV["LIGHTPANDA_VERSION"] = @env_version if @env_version
    ENV.delete("LIGHTPANDA_VERSION") unless @env_version
  end

  def fake_binary(path, version_output = nil)
    body = version_output ? "#!/bin/sh\necho '#{version_output}'\n" : "fake"
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end

  # The default exists so that upgrading the gem moves the browser with it:
  # a floor bump used to leave yesterday's cached nightly in place, and the
  # suite died at driver start until someone re-provisioned by hand.
  describe "default version" do
    before { Capybara::Lightpanda::Binary.required_version = nil }

    it "downloads the release the gem ships with, into a version-scoped file" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir
      default = Capybara::Lightpanda::Binary::DEFAULT_VERSION

      assert_equal default, Capybara::Lightpanda::Binary.required_version
      assert_equal File.join(dir, "lightpanda-#{default}"), Capybara::Lightpanda::Binary.install_path
    end

    # A default below the floor would make a fresh install download a binary
    # Process#start then refuses — every new user's first run would fail.
    it "is never below the release floor the driver enforces" do
      require "capybara/lightpanda/process"

      assert_operator Gem::Version.new(Capybara::Lightpanda::Binary::DEFAULT_VERSION), :>=,
                      Capybara::Lightpanda::Process::MINIMUM_RELEASE
    end

    # The whole point of scoping the file by version: the binary cached for
    # the previous gem version must not satisfy the new one.
    it "ignores the binary cached for another release and fetches its own" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir
      fake_binary(File.join(dir, "lightpanda-0.0.1"))
      fake_binary(File.join(dir, "lightpanda"))
      wanted = Capybara::Lightpanda::Binary.install_path

      Capybara::Lightpanda::Binary.stubs(:system_binary_path).returns(nil)
      Capybara::Lightpanda::Binary.expects(:download).once.returns(wanted)

      assert_equal wanted, Capybara::Lightpanda::Binary.update
    end

    it "never refreshes its cached release on age" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir
      Capybara::Lightpanda::Binary.cache_time = 60
      path = fake_binary(Capybara::Lightpanda::Binary.install_path)
      File.utime(Time.now - 86_400, Time.now - 86_400, path)

      Capybara::Lightpanda::Binary.expects(:download).never
      assert_equal path, Capybara::Lightpanda::Binary.update
    end

    # Unlike an explicit pin, the default is not a version contract: a user
    # who installed Lightpanda themselves (Homebrew) keeps using it, and a
    # suite under VCR/WebMock fires no HTTP at github.com.
    it "prefers a lightpanda on PATH over downloading" do
      Capybara::Lightpanda::Binary.install_dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.stubs(:system_binary_path).returns("/opt/homebrew/bin/lightpanda")

      Capybara::Lightpanda::Binary.expects(:download).never
      assert_equal "/opt/homebrew/bin/lightpanda", Capybara::Lightpanda::Binary.update
    end

    it "follows LIGHTPANDA_VERSION, and an explicit required_version over it" do
      Capybara::Lightpanda::Binary.install_dir = Dir.mktmpdir
      ENV["LIGHTPANDA_VERSION"] = "nightly"

      assert_nil Capybara::Lightpanda::Binary.pinned_version
      assert Capybara::Lightpanda::Binary.install_path.end_with?("/lightpanda")

      Capybara::Lightpanda::Binary.required_version = "1.2.3"
      assert Capybara::Lightpanda::Binary.install_path.end_with?("/lightpanda-1.2.3")
    end

    # Under VCR the blocked download surfaces as VCR's own error, which says
    # nothing about Lightpanda. The warning is what tells the user to
    # provision from outside the test process.
    it "names the provisioning command when the download is blocked" do
      Capybara::Lightpanda::Binary.install_dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.stubs(:system_binary_path).returns(nil)
      Capybara::Lightpanda::Binary.expects(:download).raises(StandardError, "real HTTP connections are disabled")

      _out, err = capture_io do
        assert_raises(StandardError) { Capybara::Lightpanda::Binary.update }
      end

      assert_includes err, "real HTTP connections are disabled"
      assert_includes err, Capybara::Lightpanda::Binary::PROVISION_HINT
    end
  end

  # Freshness used to be age alone, so a nightly cached an hour before a floor
  # bump stayed "fresh" for a day and the driver refused to start on it.
  describe ".update with a cached nightly below the floor" do
    before { require "capybara/lightpanda/process" }

    it "re-downloads even though the file is younger than cache_time" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir
      Capybara::Lightpanda::Binary.cache_time = 86_400
      path = fake_binary(File.join(dir, "lightpanda"), "1.0.0-nightly.100+abcdef012")

      Capybara::Lightpanda::Binary.stubs(:system_binary_path).returns(nil)
      Capybara::Lightpanda::Binary.expects(:download).once.returns(path)

      assert_equal path, Capybara::Lightpanda::Binary.update
    end

    it "keeps a fresh nightly that clears the floor" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir
      Capybara::Lightpanda::Binary.cache_time = 86_400
      floor = Capybara::Lightpanda::Process::MINIMUM_NIGHTLY_BUILD
      path = fake_binary(File.join(dir, "lightpanda"), "1.0.0-nightly.#{floor}+abcdef012")

      Capybara::Lightpanda::Binary.expects(:download).never
      assert_equal path, Capybara::Lightpanda::Binary.update
    end
  end

  # `install` is what bin/setup and CI run to fill the cache ahead of the
  # suite, so it must write there even when PATH already has a lightpanda.
  describe ".install" do
    before { Capybara::Lightpanda::Binary.required_version = nil }

    it "downloads into the cache even when PATH has lightpanda" do
      Capybara::Lightpanda::Binary.install_dir = Dir.mktmpdir
      wanted = Capybara::Lightpanda::Binary.install_path
      Capybara::Lightpanda::Binary.stubs(:system_binary_path).returns("/opt/homebrew/bin/lightpanda")
      Capybara::Lightpanda::Binary.expects(:download).once.returns(wanted)

      assert_equal wanted, Capybara::Lightpanda::Binary.install
    end

    it "does nothing when the release is already cached, unless forced" do
      Capybara::Lightpanda::Binary.install_dir = Dir.mktmpdir
      path = fake_binary(Capybara::Lightpanda::Binary.install_path)

      Capybara::Lightpanda::Binary.expects(:download).once.returns(path)

      assert_equal path, Capybara::Lightpanda::Binary.install
      assert_equal path, Capybara::Lightpanda::Binary.install(force: true)
    end
  end

  describe ".platform_binary" do
    it "returns the correct binary name for the current platform" do
      name = Capybara::Lightpanda::Binary.platform_binary
      assert_match(/\Alightpanda-(x86_64|aarch64)-(linux|macos)\z/, name)
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
    # Every combination upstream publishes must be mapped. Intel macOS and
    # arm64 Linux were missing until 2026-07-25, which hard-blocked Intel
    # MacBooks and Graviton runners with UnsupportedPlatformError even though
    # the release carried a binary for them. Names must match the release asset
    # names exactly — they're interpolated straight into the download URL.
    it "maps every architecture upstream ships a binary for" do
      assert_equal "lightpanda-x86_64-linux", Capybara::Lightpanda::Binary::PLATFORMS[%w[x86_64 linux]]
      assert_equal "lightpanda-aarch64-linux", Capybara::Lightpanda::Binary::PLATFORMS[%w[aarch64 linux]]
      assert_equal "lightpanda-x86_64-macos", Capybara::Lightpanda::Binary::PLATFORMS[%w[x86_64 darwin]]
      assert_equal "lightpanda-aarch64-macos", Capybara::Lightpanda::Binary::PLATFORMS[%w[aarch64 darwin]]
    end

    # normalize_arch folds arm64 -> aarch64 before the lookup, so these rows are
    # unreachable in practice; assert them so a future normalize_arch change
    # can't silently strand arm64 hosts.
    it "keeps the defensive arm64 aliases" do
      assert_equal "lightpanda-aarch64-macos", Capybara::Lightpanda::Binary::PLATFORMS[%w[arm64 darwin]]
      assert_equal "lightpanda-aarch64-linux", Capybara::Lightpanda::Binary::PLATFORMS[%w[arm64 linux]]
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

    # A pin must not share the rolling nightly's filename: `update` only tests
    # that a file exists at install_path, so a leftover nightly there would be
    # served as "the pin" and the pinned version would never be downloaded.
    it "scopes the filename by version when pinned" do
      Capybara::Lightpanda::Binary.install_dir = "/opt/bin"
      Capybara::Lightpanda::Binary.required_version = "0.3.5"

      assert_equal "/opt/bin/lightpanda-0.3.5", Capybara::Lightpanda::Binary.install_path
    end

    it "keeps distinct paths per pin so pins never collide" do
      Capybara::Lightpanda::Binary.install_dir = "/opt/bin"

      Capybara::Lightpanda::Binary.required_version = "0.3.5"
      pinned = Capybara::Lightpanda::Binary.install_path
      Capybara::Lightpanda::Binary.required_version = "0.3.4"

      refute_equal pinned, Capybara::Lightpanda::Binary.install_path
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

      path = File.join(dir, "lightpanda-0.3.0")
      File.write(path, "fake")
      File.chmod(0o755, path)

      Capybara::Lightpanda::Binary.expects(:download).never
      assert_equal path, Capybara::Lightpanda::Binary.update
    end

    # The regression that motivated version-scoped pin paths: a cache warmed by
    # an earlier unpinned run (every CI runner restoring a cache) used to satisfy
    # the pin, so the pinned release was never fetched and the suite silently
    # kept running the nightly.
    it "ignores a cached rolling-nightly binary and downloads the pin" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir

      nightly = File.join(dir, "lightpanda")
      File.write(nightly, "rolling nightly from a previous run")
      File.chmod(0o755, nightly)

      Capybara::Lightpanda::Binary.required_version = "0.3.5"
      sentinel = File.join(dir, "lightpanda-0.3.5")
      Capybara::Lightpanda::Binary.expects(:download).once.returns(sentinel)

      assert_equal sentinel, Capybara::Lightpanda::Binary.update
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

  # Release candidates (upstream #4480) are GitHub prereleases under their own
  # tag, e.g. 1.0.4-rc1, so pinning one must fetch from that tag's asset URL
  # and cache under its own filename, never the rolling nightly's.
  describe ".download with a release-candidate pin" do
    it "fetches the rc tag's asset into an rc-scoped path" do
      Dir.mktmpdir do |dir|
        Capybara::Lightpanda::Binary.install_dir = dir
        Capybara::Lightpanda::Binary.required_version = "1.0.4-rc1"
        Capybara::Lightpanda::Binary.stubs(:log)
        binary = Capybara::Lightpanda::Binary.platform_binary
        url = "#{Capybara::Lightpanda::Binary::GITHUB_RELEASE_URL}/1.0.4-rc1/#{binary}"
        Capybara::Lightpanda::Binary.expects(:download_file).with { |u, temp| u == url && File.write(temp, "x") }

        assert_equal File.join(dir, "lightpanda-1.0.4-rc1"), Capybara::Lightpanda::Binary.download
      end
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
        Capybara::Lightpanda::BinaryError, "Failed to download binary: 504 Gateway Time-out"
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

      # download raises BinaryError for HTTP failures (BinaryNotFoundError is
      # reserved for "no binary on disk/PATH" cases).
      Capybara::Lightpanda::Binary.expects(:download).raises(
        Capybara::Lightpanda::BinaryError, "Failed to download binary: 504 Gateway Time-out"
      )

      capture_io do
        assert_raises(Capybara::Lightpanda::BinaryError) do
          Capybara::Lightpanda::Binary.update
        end
      end
    ensure
      ENV["PATH"] = original_path
    end
  end

  # #download writes to a sibling temp file and renames it into place. These
  # drive the real HTTP path against a local socket rather than stubbing
  # download_file, because the bug lived in the file writing itself: writing
  # straight to the final path truncated the working binary the moment the
  # request started, and truncation preserves the mode bits, so the wreckage
  # still answered File.executable? => true. #update's stale-binary fallback
  # then returned that partial file and warned as if it were usable.
  describe ".download atomicity" do
    # Serves a response promising more bytes than it sends, then resets the
    # connection — SO_LINGER(on, 0) makes close send RST, so the client's
    # read_body raises Errno::ECONNRESET mid-transfer. Same technique as
    # web_socket_test.rb.
    #
    # Serving in a loop, rather than accepting once, is load-bearing.
    # Net::HTTP sets max_retries = 1 and GET is idempotent, so an RST that
    # lands before any response is transparently retried on a NEW connection.
    # A one-shot accept left that retry unanswered until the 60s read timeout,
    # so the test saw Net::ReadTimeout instead of ECONNRESET and the job grew
    # by two minutes. That is what reddened check (3.3) on main after #109
    # while check (4.0) stayed green: on 4.0 the headers won the race, the
    # failure landed mid-body, and mid-body failures aren't retried.
    def serve_truncated_download(server)
      Thread.new do
        loop { serve_one_truncated(server.accept) }
      rescue IOError, Errno::EBADF, Errno::EINVAL
        nil # with_download_server closed the listener; nothing left to serve
      end
    end

    def serve_one_truncated(sock)
      sock.readpartial(4096) # consume the GET
      sock.write("HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\n")
      sock.write("PARTIAL")
      sock.flush
      # SO_LINGER(0) discards whatever is still in the send buffer, so closing
      # immediately can leave the client with no response at all. Pause so the
      # headers land first: the interruption under test is mid-body.
      sleep 0.05
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
    rescue IOError, SystemCallError
      nil # client hung up first
    ensure
      sock.close
    end

    def with_download_server
      server = TCPServer.new("127.0.0.1", 0)
      accepter = serve_truncated_download(server)
      Capybara::Lightpanda::Binary.stubs(:platform_binary).returns("lightpanda-test")
      Capybara::Lightpanda::Binary.stubs(:release_url)
                                  .returns("http://127.0.0.1:#{server.addr[1]}")
      yield
    ensure
      # Close the listener first: it's what unblocks the accept loop. Joining
      # before closing would wait on a thread that never returns.
      server&.close
      accepter&.join
    end

    it "leaves the existing binary intact when the transfer is interrupted" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir
      path = File.join(dir, "lightpanda")
      File.write(path, "GOOD-COMPLETE-BINARY")
      File.chmod(0o755, path)

      with_download_server do
        assert_raises(Errno::ECONNRESET, EOFError) { Capybara::Lightpanda::Binary.download }
      end

      # Pre-fix this read returned "PARTIAL" — the working binary was gone.
      assert_equal "GOOD-COMPLETE-BINARY", File.read(path)
      assert File.executable?(path)
    end

    it "removes the partial temp file so it can never be mistaken for a binary" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir

      with_download_server do
        assert_raises(Errno::ECONNRESET, EOFError) { Capybara::Lightpanda::Binary.download }
      end

      assert_empty Dir.children(dir)
    end

    # The point of the rescue in #update is to serve a *usable* stale binary.
    # Pre-fix it could serve a truncated one, so assert the end-to-end
    # contract, not just #download in isolation.
    it "keeps update's stale-binary fallback usable after an interrupted refresh" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir
      Capybara::Lightpanda::Binary.cache_time = 60

      path = File.join(dir, "lightpanda")
      File.write(path, "GOOD-COMPLETE-BINARY")
      File.chmod(0o755, path)
      File.utime(Time.now - 3600, Time.now - 3600, path)

      Capybara::Lightpanda::Binary.stubs(:system_binary_path).returns(nil)

      result = nil
      err = nil
      with_download_server do
        _out, err = capture_io { result = Capybara::Lightpanda::Binary.update }
      end

      assert_equal path, result
      assert_includes err, "Binary download failed"
      # The fallback handed back the intact binary, not a 7-byte stump.
      assert_equal "GOOD-COMPLETE-BINARY", File.read(result)
    end

    it "renames a completed download into place as an executable" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir
      server = TCPServer.new("127.0.0.1", 0)
      accepter = Thread.new do
        sock = server.accept
        sock.readpartial(4096)
        sock.write("HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\nFRESH-BINARY")
        sock.close
      end
      Capybara::Lightpanda::Binary.stubs(:platform_binary).returns("lightpanda-test")
      Capybara::Lightpanda::Binary.stubs(:release_url)
                                  .returns("http://127.0.0.1:#{server.addr[1]}")

      result = Capybara::Lightpanda::Binary.download

      assert_equal File.join(dir, "lightpanda"), result
      assert_equal "FRESH-BINARY", File.read(result)
      assert File.executable?(result)
      # No .download-<pid> sibling left behind.
      assert_equal ["lightpanda"], Dir.children(dir)
    ensure
      accepter&.join
      server&.close
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

    # Re-provisioning a pinned binary re-downloads the same release and lands on
    # the identical "too old" error, so a pinned user must be told to move the
    # pin rather than sent around that loop.
    it "tells a pinned user to raise the pin instead of re-provisioning" do
      dir = Dir.mktmpdir
      Capybara::Lightpanda::Binary.install_dir = dir
      Capybara::Lightpanda::Binary.required_version = "0.3.0"

      hint = Capybara::Lightpanda::Binary.update_hint(Capybara::Lightpanda::Binary.install_path)

      assert_includes hint, "pinned to 0.3.0"
      refute_equal Capybara::Lightpanda::Binary::PROVISION_HINT, hint
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
