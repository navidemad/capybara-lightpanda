# frozen_string_literal: true

require_relative "../test_helper"
require "capybara/lightpanda/errors"
require "capybara/lightpanda/options"
require "capybara/lightpanda/client/web_socket"

# Lightpanda escapes a lone UTF-16 surrogate in a JS string as `\ud83d`, which
# Ruby's json rejects. A frame that fails to parse is dropped, so the command
# it answers waits out its whole timeout. The fallback must turn only *lone*
# surrogates into U+FFFD: rewriting a valid pair would corrupt emoji, and
# rewriting the text after an escaped backslash would corrupt literal strings.
describe "Capybara::Lightpanda::Client::WebSocket#parse_message" do
  let(:ws) { Capybara::Lightpanda::Client::WebSocket.allocate }

  def parse(json)
    ws.send(:parse_message, json)
  end

  it "replaces a lone lead surrogate with U+FFFD instead of dropping the frame" do
    assert_equal({ "v" => "a\uFFFDb" }, parse('{"v":"a\ud83db"}'))
  end

  it "replaces a lone trail surrogate" do
    assert_equal({ "v" => "\uFFFD" }, parse('{"v":"\ude00"}'))
  end

  it "keeps a valid pair next to a lone surrogate" do
    assert_equal({ "v" => "\uFFFD\u{1F600}A" }, parse('{"v":"\udc00\ud83d\ude00\u0041"}'))
  end

  it "leaves an escaped backslash followed by surrogate-looking text as literal text" do
    # The frame also carries a real lone surrogate, so the fallback runs.
    assert_equal({ "v" => "\\ud800\uFFFD\"" }, parse('{"v":"\\\\ud800\ud800\\""}'))
  end

  it "still drops a frame that is invalid for another reason, with one warning" do
    _, err = capture_io { assert_nil parse('{"v":undefined}') }

    assert_match(/Failed to parse WebSocket message/, err)
  end
end
