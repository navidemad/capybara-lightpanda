# frozen_string_literal: true

require "fileutils"
require "net/http"
require "open3"
require "rbconfig"
require "uri"

module Capybara
  module Lightpanda
    class Binary
      Result = Struct.new(:stdout, :stderr, :status) do
        def success?
          status.success?
        end

        def exit_code
          status.exitstatus
        end

        def output
          stdout.empty? ? stderr : stdout
        end
      end

      GITHUB_RELEASE_URL = "https://github.com/lightpanda-io/browser/releases/download"

      PLATFORMS = {
        %w[x86_64 linux] => "lightpanda-x86_64-linux",
        %w[aarch64 darwin] => "lightpanda-aarch64-macos",
        %w[arm64 darwin] => "lightpanda-aarch64-macos",
      }.freeze

      DEFAULT_CACHE_TIME = 86_400

      class << self
        # Set a specific release tag (e.g. "0.3.0") to pin downloads to that
        # release. When nil, the rolling "nightly" tag is used. The pin only
        # affects download URL construction — the gem's MINIMUM_NIGHTLY_BUILD
        # floor is still enforced at process start.
        attr_accessor :required_version

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

        def path
          @path ||= update
        end

        # Canonical entrypoint: ensure the binary at install_path is current,
        # download if needed, return its path. Pinned (required_version set)
        # never re-downloads when present. Unpinned re-downloads when older
        # than cache_time. When unpinned and the gem cache is empty/stale,
        # an already-installed `lightpanda` on PATH (e.g. via Homebrew) wins
        # over re-downloading — keeps test suites running under VCR/WebMock
        # from triggering surprise HTTP to github.com.
        def update
          destination = install_path

          if required_version
            if File.executable?(destination)
              log("Pinned #{required_version} present at #{destination}")
              return destination
            end
            return download
          end

          if cached_fresh?(destination)
            log("Cached binary at #{destination} is fresh (< #{cache_time}s)")
            return destination
          end

          if (system_path = system_binary_path)
            log("Using lightpanda from PATH at #{system_path}")
            return system_path
          end

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
          @path = nil
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

        def run(*)
          stdout, stderr, status = Open3.capture3(path, *)

          Result.new(stdout: stdout, stderr: stderr, status: status)
        rescue Errno::ENOENT
          raise BinaryNotFoundError, "Lightpanda binary not found"
        end

        def exec(*)
          Kernel.exec(path, *)
        end

        def fetch(url)
          result = run("fetch", "--dump", url)
          raise BinaryError, result.stderr unless result.success?

          result.stdout
        end

        def version
          result = run("version")
          result.output.strip
        end

        def download
          binary_name = platform_binary
          tag = required_version || "nightly"
          url = "#{GITHUB_RELEASE_URL}/#{tag}/#{binary_name}"
          destination = install_path

          log("Downloading #{binary_name} (#{tag}) → #{destination}")
          FileUtils.mkdir_p(File.dirname(destination))

          download_file(url, destination)
          FileUtils.chmod(0o755, destination)
          @path = destination

          destination
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
        def install_path
          if @install_dir
            File.join(@install_dir, "lightpanda")
          else
            default_binary_path
          end
        end

        private

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

        def cached_fresh?(path)
          return false unless File.executable?(path)
          return true if cache_time.zero?

          (Time.now - File.mtime(path)) < cache_time
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
          raise BinaryNotFoundError, "Too many redirects" if limit.zero?

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
                raise BinaryNotFoundError, "Failed to download binary: #{response.code} #{response.message}"
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
