# frozen_string_literal: true

module Capybara
  module Lightpanda
    module XPathPolyfill
      JS_PATH = File.expand_path("javascripts/index.js", __dir__).freeze
      JS = File.read(JS_PATH).freeze
    end
  end
end
