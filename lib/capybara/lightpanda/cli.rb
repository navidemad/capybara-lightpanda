# frozen_string_literal: true

require "optparse"
require_relative "errors"
require_relative "binary"
require_relative "process"

module Capybara
  module Lightpanda
    # `capybara-lightpanda` executable: provisions the browser binary from a
    # process of its own. The driver otherwise downloads it lazily, inside the
    # test process, where VCR/WebMock block the request — so a setup script or
    # a CI step calls this first and the suite finds the binary already there.
    #
    # Loads only the binary/process files, not the driver: no Capybara, no
    # Rails, and nothing that stubs HTTP.
    class CLI
      USAGE = <<~TEXT
        Usage: capybara-lightpanda COMMAND [options]

        Commands:
          install [VERSION]  Download the Lightpanda binary into the gem's cache
                             (VERSION: a release tag or "nightly"; default: the
                             release this gem version was validated against)
          version            Print the version of the cached binary
          path               Print where the binary is (or would be) cached
          remove             Delete the cached binary

        Options:
      TEXT

      def self.run(argv, out: $stdout, err: $stderr)
        new(out, err).run(argv.dup)
      end

      def initialize(out, err)
        @out = out
        @err = err
        @force = false
      end

      # Returns the process exit status.
      def run(argv)
        parser.parse!(argv)
        command, version = argv
        Binary.required_version = version if version

        case command
        when "install" then install
        when "version" then version_command
        when "path" then @out.puts(Binary.install_path)
        when "remove" then remove
        else
          @err.puts(parser.help)
          return command.nil? ? 0 : 1
        end
        0
      rescue OptionParser::ParseError, LoadError, Error => e
        @err.puts("capybara-lightpanda: #{e.message}")
        1
      end

      private

      def parser
        @parser ||= OptionParser.new(USAGE) do |opts|
          opts.on("-f", "--force", "install: download even if a binary is already cached") { @force = true }
          # A project that configures Binary (install_dir, required_version,
          # a proxy) in a support file points at it here, so the command and
          # the suite agree on what to download and where.
          opts.on("-r", "--require FILE", "Load FILE first (your Binary.configure block)") do |file|
            require File.expand_path(file)
          end
        end
      end

      def install
        path = Binary.install(force: @force)
        @out.puts("Lightpanda #{Binary.current_version || Binary.required_version} ready at #{path}")
      end

      def version_command
        version = Binary.current_version
        raise BinaryNotFoundError, "no cached Lightpanda binary at #{Binary.install_path}" unless version

        @out.puts(version)
      end

      def remove
        removed = Binary.remove
        @out.puts(removed ? "Removed #{removed}" : "Nothing to remove at #{Binary.install_path}")
      end
    end
  end
end
