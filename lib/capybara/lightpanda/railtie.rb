# frozen_string_literal: true

module Capybara
  module Lightpanda
    # Exposes the gem's rake tasks (lightpanda:binary:version, :update,
    # :remove) inside Rails apps, so `bin/rails lightpanda:binary:update`
    # works without a Rakefile edit. Rails only loads the gem (and so this
    # Railtie) in the Gemfile groups the current environment requires — for
    # the usual :test group that means RAILS_ENV=test — which is why
    # Binary's too-old-binary hint suggests a require-the-gem one-liner
    # instead of these tasks.
    class Railtie < Rails::Railtie
      rake_tasks do
        load File.expand_path("tasks/binary.rake", __dir__)
      end
    end
  end
end
