# frozen_string_literal: true

require_relative "../test_helper"

describe "finder hint payload validation" do
  let(:browser) { Capybara::Lightpanda::Browser.allocate }

  def decode(raw, count = 1)
    browser.send(:parse_hints, [{ "name" => "__lightpandaHints", "value" => { "value" => raw } }], count)
  end

  it "falls back to live reads for malformed payloads and mutable answers" do
    [nil, "broken", "{}", "[]", '[{"unknown":true}]', '[{"tag_name":17}]',
     '[{"visible":"false"}]', '[{"position":{}}]', '[{"style":42}]',].each do |raw|
      assert_equal [{}], decode(raw), "trusted malformed or mutable payload: #{raw.inspect}"
    end
  end

  it "preserves aligned immutable answers with symbol outer keys" do
    assert_equal [{ tag_name: "div" }, { tag_name: "ShadowRoot" }],
                 decode('[{"tag_name":"div"},{"tag_name":"ShadowRoot"}]', 2)
  end
end
