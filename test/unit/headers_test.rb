# frozen_string_literal: true

require_relative "../test_helper"
require "capybara/lightpanda/headers"

describe Capybara::Lightpanda::Headers do
  let(:headers) do
    Capybara::Lightpanda::Headers.new.tap do |h|
      h["content-type"] = "text/html; charset=utf-8"
      h["x-frame-options"] = "SAMEORIGIN"
    end
  end

  it "looks up the canonical-casing key on a lowercase-keyed hash" do
    assert_equal "text/html; charset=utf-8", headers["Content-Type"]
    assert_equal "SAMEORIGIN", headers["X-Frame-Options"]
  end

  it "looks up the lowercased key directly" do
    assert_equal "text/html; charset=utf-8", headers["content-type"]
  end

  it "returns nil for a missing key regardless of case" do
    assert_nil headers["Cache-Control"]
    assert_nil headers["cache-control"]
  end

  it "accepts Symbol keys by coercing to a downcased String" do
    assert_equal "text/html; charset=utf-8", headers[:"Content-Type"]
  end
end
