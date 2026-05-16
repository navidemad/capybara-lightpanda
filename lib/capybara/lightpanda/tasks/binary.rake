# frozen_string_literal: true

require "capybara-lightpanda"

namespace :lightpanda do
  namespace :binary do
    desc "Print the version of the cached Lightpanda binary"
    task :version do
      version = Capybara::Lightpanda::Binary.current_version
      if version
        puts version
      else
        warn "No cached Lightpanda binary at #{Capybara::Lightpanda::Binary.install_path}"
        exit 1
      end
    end

    desc "Download the Lightpanda binary (optionally pinned: rake lightpanda:binary:update[0.3.0])"
    task :update, [:version] do |_, args|
      Capybara::Lightpanda::Binary.required_version = args[:version] if args[:version]
      path = Capybara::Lightpanda::Binary.update
      puts "Lightpanda binary ready at #{path}"
    end

    desc "Remove the cached Lightpanda binary"
    task :remove do
      removed = Capybara::Lightpanda::Binary.remove
      if removed
        puts "Removed #{removed}"
      else
        puts "Nothing to remove at #{Capybara::Lightpanda::Binary.install_path}"
      end
    end
  end
end
