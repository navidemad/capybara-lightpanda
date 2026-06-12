# frozen_string_literal: true

require_relative "../test_helper"
require "capybara/lightpanda/errors"

describe "Capybara::Lightpanda errors" do
  describe "hierarchy" do
    it "all errors descend from Capybara::Lightpanda::Error" do
      [
        Capybara::Lightpanda::ProcessTimeoutError,
        Capybara::Lightpanda::PortInUseError,
        Capybara::Lightpanda::BinaryNotFoundError,
        Capybara::Lightpanda::BinaryError,
        Capybara::Lightpanda::UnsupportedPlatformError,
        Capybara::Lightpanda::DeadBrowserError,
        Capybara::Lightpanda::TimeoutError,
        Capybara::Lightpanda::BrowserError,
        Capybara::Lightpanda::JavaScriptError,
        Capybara::Lightpanda::NodeNotFoundError,
        Capybara::Lightpanda::NoExecutionContextError,
        Capybara::Lightpanda::ObsoleteNode,
        Capybara::Lightpanda::InvalidSelector,
        Capybara::Lightpanda::MouseEventFailed,
        Capybara::Lightpanda::NoSuchPageError,
        Capybara::Lightpanda::StatusError,
      ].each do |klass|
        assert_includes klass.ancestors, Capybara::Lightpanda::Error
      end
    end

    it "CDP-class errors are catchable as BrowserError" do
      [
        Capybara::Lightpanda::DeadBrowserError,
        Capybara::Lightpanda::JavaScriptError,
        Capybara::Lightpanda::NodeNotFoundError,
        Capybara::Lightpanda::NoExecutionContextError,
        Capybara::Lightpanda::ObsoleteNode,
      ].each do |klass|
        assert_includes klass.ancestors, Capybara::Lightpanda::BrowserError
      end
    end

    it "base error inherits from StandardError" do
      assert_equal StandardError, Capybara::Lightpanda::Error.superclass
    end
  end

  describe Capybara::Lightpanda::BrowserError do
    it "captures the response and exposes message/code/data" do
      response = { "message" => "Something went wrong", "code" => -32_601, "data" => "extra" }
      error = Capybara::Lightpanda::BrowserError.new(response)
      assert_equal "Something went wrong", error.message
      assert_equal response, error.response
      assert_equal(-32_601, error.code)
      assert_equal "extra", error.data
    end

    it "accepts a plain string for callsites that raise with a literal" do
      error = Capybara::Lightpanda::BrowserError.new("plain message")
      assert_equal "plain message", error.message
      assert_nil error.response
      assert_nil error.code
      assert_nil error.data
    end
  end

  describe Capybara::Lightpanda::JavaScriptError do
    it "extracts class_name and description, appending the className tag" do
      response = {
        "exceptionDetails" => {
          "exception" => {
            "className" => "TypeError",
            "description" => "Cannot read property 'foo' of null",
          },
        },
      }
      error = Capybara::Lightpanda::JavaScriptError.new(response)
      assert_equal "TypeError", error.class_name
      assert_includes error.message, "Cannot read property 'foo' of null"
      assert_includes error.message, "(TypeError)"
    end

    it "skips the className tag when the description already mentions it" do
      response = {
        "exceptionDetails" => {
          "exception" => {
            "className" => "TypeError",
            "description" => "TypeError: foo is not a function",
          },
        },
      }
      error = Capybara::Lightpanda::JavaScriptError.new(response)
      assert_equal "TypeError: foo is not a function", error.message
    end

    it "falls back to text when description is missing" do
      response = {
        "exceptionDetails" => {
          "text" => "Uncaught error",
          "exception" => { "className" => "Error" },
        },
      }
      error = Capybara::Lightpanda::JavaScriptError.new(response)
      assert_includes error.message, "Uncaught error"
      assert_includes error.message, "(Error)"
    end

    it "falls back to a generic 'JsException' label when nothing is provided" do
      error = Capybara::Lightpanda::JavaScriptError.new("exceptionDetails" => {})
      assert_equal "JsException", error.message
    end

    it "appends a non-string thrown value when present (e.g. `throw 42`)" do
      response = {
        "exceptionDetails" => {
          "exception" => { "className" => "Number", "value" => 42 },
        },
      }
      error = Capybara::Lightpanda::JavaScriptError.new(response)
      assert_includes error.message, "value=42"
    end

    it "captures stack_trace and formats up to 5 frames in the message" do
      frames = (1..7).map do |i|
        { "functionName" => "fn#{i}", "url" => "f#{i}.js", "lineNumber" => i, "columnNumber" => 0 }
      end
      response = {
        "exceptionDetails" => {
          "exception" => { "className" => "Error", "description" => "oops" },
          "stackTrace" => { "callFrames" => frames },
        },
      }
      error = Capybara::Lightpanda::JavaScriptError.new(response)
      assert_equal({ "callFrames" => frames }, error.stack_trace)
      assert_includes error.message, "stack:"
      assert_includes error.message, "fn1 @ f1.js:1:0"
      assert_includes error.message, "fn5 @ f5.js:5:0"
      refute_includes error.message, "fn6" # capped at 5 frames
    end

    it "labels anonymous frames as <anon> in the formatted stack" do
      response = {
        "exceptionDetails" => {
          "exception" => { "className" => "Error", "description" => "oops" },
          "stackTrace" => { "callFrames" => [{ "functionName" => "", "url" => "", "lineNumber" => 0,
                                               "columnNumber" => 19, }] },
        },
      }
      error = Capybara::Lightpanda::JavaScriptError.new(response)
      assert_includes error.message, "<anon> @ :0:19"
    end
  end

  describe Capybara::Lightpanda::ObsoleteNode do
    it "captures the node reference" do
      node = mock("node")
      error = Capybara::Lightpanda::ObsoleteNode.new(node)
      assert_equal node, error.node
      assert_equal "Element is no longer attached to the DOM", error.message
    end

    it "accepts a custom message" do
      node = mock("node")
      error = Capybara::Lightpanda::ObsoleteNode.new(node, "custom message")
      assert_equal "custom message", error.message
    end
  end

  # Cuprite/Ferrum drop-in compatibility surface: never raised by this gem,
  # but suites migrating from those drivers may reference these classes in
  # rescue lists — they must keep existing and keep their peer shape.
  describe "peer-compatibility error classes" do
    it "MouseEventFailed parses position and selector from a cuprite-style message" do
      node = mock("node")
      error = Capybara::Lightpanda::MouseEventFailed.new(node, "at position (100, 200) selector: #btn")
      assert_equal({ x: 100, y: 200 }, error.position)
      assert_equal "#btn", error.selector
    end

    it "NoSuchPageError and StatusError stay rescuable as Capybara::Lightpanda::Error" do
      [Capybara::Lightpanda::NoSuchPageError, Capybara::Lightpanda::StatusError].each do |klass|
        assert_includes klass.ancestors, Capybara::Lightpanda::Error
      end
    end
  end
end
