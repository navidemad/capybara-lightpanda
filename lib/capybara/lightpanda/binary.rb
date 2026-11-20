# frozen_string_literal: true

require "fileutils"
require "net/http"
require "open3"
require "rbconfig"
require "uri"

module Capybara
  module Lightpanda
    class Binary
      GITHUB_RELEASE_URL = "https://github.com/lightpanda-io/browser/releases/download"

      # Upstream publishes all four arch/OS combinations on every channel —
      # verified 2026-07-26 against the `nightly` tag and release 0.3.6 (the
      # MINIMUM_RELEASE floor, so any acceptable pin carries them too). Intel
      # macOS and arm64 Linux were absent here and raised
      # UnsupportedPlatformError on machines upstream ships a binary for: Intel
      # MacBooks, and Graviton / arm64 CI runners. normalize_arch folds arm64 ->
      # aarch64, so the arm64 rows are unreachable defensive duplicates kept for
      # symmetry with the pre-existing arm64-darwin one.
      PLATFORMS = {
        %w[x86_64 linux] => "lightpanda-x86_64-linux",
        %w[aarch64 linux] => "lightpanda-aarch64-linux",
        %w[arm64 linux] => "lightpanda-aarch64-linux",
        %w[x86_64 darwin] => "lightpanda-x86_64-macos",
        %w[aarch64 darwin] => "lightpanda-aarch64-macos",
        %w[arm64 darwin] => "lightpanda-aarch64-macos",
      }.freeze

      DEFAULT_CACHE_TIME = 86_400

      # The release downloaded when nothing else is asked for. Each gem version
      # ships with the Lightpanda release it was validated against, so a
      # `bundle update` moves the browser with the driver: the pin's
      # version-scoped filename (see install_path) changes, the old cached file
      # no longer matches, and the new release is fetched. Tracking the rolling
      # nightly by default did the opposite — a floor bump left a cached
      # sub-floor binary in place and the suite died at driver start, while CI
      # ran whatever upstream published that morning.
      #
      # INVARIANT: never below Process::MINIMUM_RELEASE (binary_test pins it),
      # or a fresh install would download a binary the driver then refuses.
      DEFAULT_VERSION = "1.0.5"

      # required_version value (or LIGHTPANDA_VERSION) that opts back into the
      # rolling `nightly` tag.
      NIGHTLY = "nightly"

      # Command that provisions the binary from a process with no HTTP stubbing
      # loaded (VCR/WebMock guard the test process itself). An executable
      # rather than a rake task or a `ruby -r` one-liner: the rake tasks only
      # exist under RAILS_ENV=test in a Rails app, and the executable works
      # from bin/setup, a CI step and a dev shell alike. --force re-downloads
      # even when a file is already cached.
      PROVISION_HINT = "bundle exec capybara-lightpanda install --force"

      class << self
        # The Lightpanda version to download: a release tag ("1.0.4",
        # "1.0.5-rc1") or "nightly" for the rolling tag. Unset (nil), it falls
        # back to LIGHTPANDA_VERSION, then to DEFAULT_VERSION. The version only
        # picks the download — the gem's floor is still enforced at process
        # start.
        attr_writer :required_version

        def required_version
          version = @required_version.to_s
          version = ENV.fetch("LIGHTPANDA_VERSION", "") if version.empty?
          version.empty? ? DEFAULT_VERSION : version
        end

        def nightly?
          required_version == NIGHTLY
        end

        # The release tag in effect, nil on the rolling nightly.
        def pinned_version
          nightly? ? nil : required_version
        end

        # True when the user (or the environment) chose the version, as opposed
        # to inheriting DEFAULT_VERSION.
        def explicit_version?
          !@required_version.to_s.empty? || !ENV.fetch("LIGHTPANDA_VERSION", "").empty?
        end

        # Seconds before a cached unpinned binary is re-downloaded. Pinned
        # binaries are never refreshed on age (they're pinned).
        attr_writer :cache_time, :install_dir, :logger
        attr_accessor :proxy_addr, :proxy_port, :proxy_user, :proxy_pass

        def cache_time
          @cache_time ||= Integer(ENV.fetch("LIGHTPANDA_CACHE_TIME", DEFAULT_CACHE_TIME))
        end

        def install_dir
          @install_dir ||= File.dirname(default_binary_path)
        end

        def logger
          return @logger if defined?(@logger) && @logger
          return nil unless ENV["LIGHTPANDA_DEBUG"]

          @logger = Capybara::Lightpanda::Logger.new($stderr.tap { |s| s.sync = true })
        end

        def configure
          yield self
        end

        # Canonical entrypoint: return the path of a usable binary, downloading
        # one if needed.
        #
        # - A release (the default, or an explicit pin) is used as soon as its
        #   version-scoped file exists; it is never refreshed on age.
        # - The nightly is re-downloaded once older than cache_time, or at once
        #   when the cached build is below the gem's floor (see cache_usable?).
        # - A `lightpanda` on PATH (Homebrew, a package) wins over downloading
        #   unless the version was chosen explicitly — a pin is a version
        #   contract PATH can't honor. It keeps a suite under VCR/WebMock from
        #   firing surprise HTTP at github.com.
        def update
          destination = install_path

          if cache_usable?
            log("Cached binary at #{destination} is usable")
            return destination
          end

          if !(pinned_version && explicit_version?) && (system_path = system_binary_path)
            log("Using lightpanda from PATH at #{system_path}")
            return system_path
          end

          # If the download fails (GitHub 5xx, DNS/connect timeouts, an HTTP
          # stub) but a binary is already cached, keep using it rather than
          # hard-failing; with nothing on disk the error surfaces. The floor is
          # enforced downstream in Process#start, so a sub-floor binary can't
          # slip in.
          #
          # Deliberately StandardError, not Exception: WebMock's
          # NetConnectNotAllowedError descends from Exception so it propagates
          # through app rescue blocks by design — a test suite that blocks net
          # connections SHOULD fail loudly here, not silently fall back.
          #
          # Kernel.warn, not log: log() is silent unless LIGHTPANDA_DEBUG or an
          # explicit logger is set, and this is exactly the moment the user
          # needs to hear about — a VCR-guarded suite (whose
          # UnhandledHTTPRequestError is a StandardError) lands here, and
          # without the hint all it sees is VCR's error or, later, a floor
          # error with no trace of the blocked download.
          begin
            download
          rescue StandardError => e
            cached = File.executable?(destination)
            warn("[capybara-lightpanda] Binary download failed (#{e.class}: #{e.message})" \
                 "#{"; falling back to the cached binary at #{destination}" if cached}. " \
                 "If your suite stubs HTTP (VCR/WebMock), pre-provision from an " \
                 "unstubbed process: #{PROVISION_HINT}")
            raise unless cached

            destination
          end
        end

        # Make sure the binary for the version in effect sits in the gem's own
        # cache, ignoring PATH: what `capybara-lightpanda install` runs from
        # bin/setup or a CI step, where the point is to fill the cache.
        def install(force: false)
          return install_path if !force && cache_usable?

          download
        end

        # Delete the cached binary. Returns the path that was deleted, or nil
        # if nothing was there.
        def remove
          path = install_path
          unless File.exist?(path)
            log("Nothing to remove at #{path}")
            return nil
          end

          File.delete(path)
          log("Removed #{path}")
          path
        end

        # Returns the `lightpanda version` output of the cached binary, or nil
        # if the binary isn't present / not runnable.
        def current_version
          path = install_path
          return nil unless File.executable?(path)

          stdout, _, status = Open3.capture3(path, "version")
          status.success? ? stdout.strip : nil
        rescue Errno::ENOENT
          nil
        end

        # Downloads into a sibling temp file and renames it into place only
        # once the transfer finished.
        #
        # Writing straight to `destination` corrupted a working binary on any
        # interrupted transfer: File.open(_, "wb") truncates the existing file
        # the moment the request starts, and truncation KEEPS the mode bits —
        # so a dropped connection left a partial file that still answered
        # File.executable? => true. #update's "fall back to the cached binary"
        # rescue then handed that corpse back as if it were the usable stale
        # binary, warning as though nothing was wrong. That is the common path,
        # not an edge case: past cache_time, #update calls #download precisely
        # when a good binary is already sitting at `destination`.
        #
        # rename(2) within one directory is atomic, so a concurrent reader sees
        # either the old binary or the new one, never a half-written one. The
        # temp file is a sibling (not Dir.tmpdir) so the rename never crosses a
        # filesystem, and chmod happens before it so the binary is never
        # visible non-executable. Two racing downloads get distinct temp names
        # and both rename a complete file — last writer wins, both are valid.
        def download
          binary_name = platform_binary
          tag = required_version
          url = "#{release_url}/#{tag}/#{binary_name}"
          destination = install_path

          log("Downloading #{binary_name} (#{tag}) → #{destination}")
          FileUtils.mkdir_p(File.dirname(destination))

          # ::Process, not Process — Capybara::Lightpanda::Process would win.
          temp = "#{destination}.download-#{::Process.pid}"
          begin
            download_file(url, temp)
            FileUtils.chmod(0o755, temp)
            File.rename(temp, destination)
          ensure
            # No-op on success (rename consumed it). ensure, not rescue, so an
            # Interrupt mid-download cleans up too; rm_f ignores a missing file.
            FileUtils.rm_f(temp)
          end

          destination
        end

        # Build a path-appropriate "how to update" command for Process's
        # too-old-binary error. Three branches:
        #
        # - Symlink into a `/Cellar/` directory → installed via Homebrew;
        #   suggest `brew update && brew upgrade lightpanda` (brew pins
        #   each user's binary at install time and doesn't refresh on its
        #   own when the tap publishes a newer nightly).
        # - Path equals our own cache → suggest the require-the-gem one-liner.
        #   NOT the lightpanda:binary:* rake tasks: in a Rails app the gem
        #   usually sits in the :test Gemfile group, so the tasks only exist
        #   under RAILS_ENV=test (the Railtie can't help a plain `bundle exec
        #   rake` in development), and outside Rails they're never loaded at
        #   all. The one-liner requires the gem explicitly, so it works from
        #   any environment. The `remove` step is required because `update`
        #   honors `cache_time` and would otherwise no-op on a
        #   too-old-but-not-yet-expired file.
        # - Path equals our cache AND a pin is set → the version is a deliberate
        #   choice, so tell the user to raise the pin. The re-provision one-liner
        #   would be a dead end here: it re-downloads the same pinned release and
        #   lands on the identical "too old" error.
        # - Anything else (user-managed install at a custom path) → keep
        #   the curl-overwrite suggestion, since we don't know how the file
        #   got there.
        def update_hint(binary_path)
          if brew_managed?(binary_path)
            "brew update && brew upgrade lightpanda"
          elsif binary_path == install_path && pinned_version
            "Capybara::Lightpanda::Binary.required_version is pinned to " \
              "#{required_version} — raise the pin to a newer release, " \
              "or set it to \"nightly\" to track the rolling nightly."
          elsif binary_path == install_path
            PROVISION_HINT
          else
            "curl -sL #{GITHUB_RELEASE_URL}/nightly/#{platform_binary} " \
              "-o #{binary_path} && chmod +x #{binary_path}"
          end
        end

        def platform_binary
          arch = normalize_arch(RbConfig::CONFIG["host_cpu"])
          os = normalize_os(RbConfig::CONFIG["host_os"])

          PLATFORMS[[arch, os]] || raise(UnsupportedPlatformError, "Unsupported platform: #{arch}-#{os}")
        end

        def default_binary_path
          cache_dir = ENV.fetch("XDG_CACHE_HOME") { File.expand_path("~/.cache") }

          File.join(cache_dir, "lightpanda", "lightpanda")
        end

        # Path the gem writes the downloaded binary to. Honors a
        # user-configured install_dir; otherwise falls back to default_binary_path.
        #
        # A pin gets its own filename (`lightpanda-0.3.5`) rather than sharing
        # the rolling-nightly one. `update` only checks that a file EXISTS at
        # this path, not which version it holds, so on a shared path a nightly
        # left over from an earlier run would be accepted as "the pin" — setting
        # required_version on any machine with a warm cache (every CI runner
        # restoring a cache, every existing dev checkout) would silently keep
        # running the nightly it was meant to replace. Version-scoping makes the
        # pin self-verifying and lets several pins coexist in one cache dir.
        def install_path
          dir = @install_dir || File.dirname(default_binary_path)
          basename = pinned_version ? "lightpanda-#{pinned_version}" : "lightpanda"

          File.join(dir, basename)
        end

        private

        # Release host, as its own method so tests can point #download at a
        # local socket and exercise the real streaming writer (which is where
        # the truncation bug lived) instead of stubbing it out.
        def release_url
          GITHUB_RELEASE_URL
        end

        # Detects a Homebrew-managed binary by checking whether `path` is a
        # symlink that resolves into a `/Cellar/` directory — the convention
        # both `/opt/homebrew` (Apple Silicon) and `/usr/local` (Intel /
        # linuxbrew) use. Plain files (manual installs) and gem-cache files
        # both return false.
        def brew_managed?(path)
          return false unless File.symlink?(path)

          File.realpath(path).include?("/Cellar/")
        rescue Errno::ENOENT, Errno::EACCES
          false
        end

        # Scan ENV["PATH"] for an executable `lightpanda`. Returns the first
        # match (PATH order), or nil. Lets `brew install lightpanda-io/
        # lightpanda/lightpanda` (and Linux package installs at /usr/local/bin)
        # short-circuit the auto-download path in `update`.
        def system_binary_path
          ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
            next if dir.empty?

            candidate = File.join(dir, "lightpanda")
            return candidate if File.file?(candidate) && File.executable?(candidate)
          end
          nil
        end

        # A cached release only has to exist: its filename carries the version.
        # A cached nightly must be young enough AND clear the gem's floor — age
        # alone let a build cached yesterday survive a floor bump for up to
        # cache_time, and the driver then refused to start on a binary the gem
        # itself had just called fresh.
        def cache_usable?
          path = install_path
          return File.executable?(path) if pinned_version

          cached_fresh?(path) && !below_floor?(path)
        end

        def cached_fresh?(path)
          return false unless File.executable?(path)
          return true if cache_time.zero?

          (Time.now - File.mtime(path)) < cache_time
        end

        # Only a version the floor check positively rejects counts. A file that
        # can't be run or doesn't answer is left to Process#start, which reports
        # it properly. Process is looked up lazily: binary.rb loads before
        # process.rb, and on its own in the provisioning scripts, where the
        # floor is unknown and nothing is rejected.
        def below_floor?(path)
          return false unless Lightpanda.const_defined?(:Process, false)

          stdout, _, status = Open3.capture3(path, "version")
          return false unless status.success? && !stdout.strip.empty?

          Lightpanda::Process.check_version!(stdout) { "" }
          false
        rescue BinaryError
          true
        rescue SystemCallError
          false
        end

        def normalize_arch(arch)
          case arch
          when /x86_64|amd64/i then "x86_64"
          when /aarch64|arm64/i then "aarch64"
          else arch
          end
        end

        def normalize_os(os)
          case os
          when /darwin|mac/i then "darwin"
          when /linux/i then "linux"
          else os
          end
        end

        def download_file(url, destination)
          uri = URI.parse(url)

          follow_redirects(uri, destination)
        end

        def follow_redirects(uri, destination, limit = 10)
          raise BinaryError, "Too many redirects" if limit.zero?

          http_start(uri) do |http|
            request = Net::HTTP::Get.new(uri)

            http.request(request) do |response|
              case response
              when Net::HTTPSuccess
                File.open(destination, "wb") do |file|
                  response.read_body { |chunk| file.write(chunk) }
                end
              when Net::HTTPRedirection
                log("Redirected → #{response['location']}")
                follow_redirects(URI.parse(response["location"]), destination, limit - 1)
              else
                raise BinaryError, "Failed to download binary: #{response.code} #{response.message}"
              end
            end
          end
        end

        def http_start(uri, &)
          if proxy_addr
            Net::HTTP.start(
              uri.host, uri.port,
              proxy_addr, proxy_port, proxy_user, proxy_pass,
              use_ssl: uri.scheme == "https", &
            )
          else
            Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", &)
          end
        end

        def log(message)
          logger&.puts("[lightpanda binary] #{message}")
        end
      end
    end
  end
end
