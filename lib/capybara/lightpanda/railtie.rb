# frozen_string_literal: true

module Capybara
  module Lightpanda
    # Exposes the gem's rake tasks (lightpanda:binary:*) inside Rails apps.
    # Without this, the BinaryError remediation hint ("bundle exec rake
    # lightpanda:binary:remove lightpanda:binary:update") pointed at tasks
    # that didn't exist in the app's rake namespace.
    class Railtie < Rails::Railtie
      rake_tasks do
        load File.expand_path("tasks/binary.rake", __dir__)
      end
    end
  end
end
