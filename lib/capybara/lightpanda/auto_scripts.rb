# frozen_string_literal: true

module Capybara
  module Lightpanda
    module AutoScripts
      JS_PATH = File.expand_path("javascripts/index.js", __dir__).freeze
      JS = File.read(JS_PATH).freeze

      # Polyfills pour les APIs DOM manquantes du binaire Lightpanda.
      # Voir UPSTREAM_BUGS.md à la racine du gem.
      POLYFILLS_PATH = File.expand_path("javascripts/polyfills.js", __dir__).freeze
      POLYFILLS_JS = File.read(POLYFILLS_PATH).freeze
    end
  end
end
