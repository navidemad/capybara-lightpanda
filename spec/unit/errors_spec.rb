# frozen_string_literal: true

require "bundler/setup"
require "capybara/lightpanda/errors"

RSpec.describe "Capybara::Lightpanda errors" do
  describe "hierarchy" do
    it "all errors descend from Capybara::Lightpanda::Error" do
      [
        Capybara::Lightpanda::ProcessTimeoutError,
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
        Capybara::Lightpanda::MouseEventFailed,
        Capybara::Lightpanda::InvalidSelector,
        Capybara::Lightpanda::NoSuchPageError,
        Capybara::Lightpanda::StatusError,
      ].each do |klass|
        expect(klass.ancestors).to include(Capybara::Lightpanda::Error)
      end
    end

    it "CDP-class errors are catchable as BrowserError" do
      [
        Capybara::Lightpanda::DeadBrowserError,
        Capybara::Lightpanda::JavaScriptError,
        Capybara::Lightpanda::NodeNotFoundError,
        Capybara::Lightpanda::NoExecutionContextError,
        Capybara::Lightpanda::ObsoleteNode,
        Capybara::Lightpanda::MouseEventFailed,
      ].each do |klass|
        expect(klass.ancestors).to include(Capybara::Lightpanda::BrowserError)
      end
    end

    it "base error inherits from StandardError" do
      expect(Capybara::Lightpanda::Error.superclass).to eq(StandardError)
    end
  end

  describe Capybara::Lightpanda::BrowserError do
    it "captures the response and exposes message/code/data" do
      response = { "message" => "Something went wrong", "code" => -32_601, "data" => "extra" }
      error = described_class.new(response)
      expect(error.message).to eq("Something went wrong")
      expect(error.response).to eq(response)
      expect(error.code).to eq(-32_601)
      expect(error.data).to eq("extra")
    end

    it "accepts a plain string for callsites that raise with a literal" do
      error = described_class.new("plain message")
      expect(error.message).to eq("plain message")
      expect(error.response).to be_nil
      expect(error.code).to be_nil
      expect(error.data).to be_nil
    end
  end

  describe Capybara::Lightpanda::JavaScriptError do
    it "extracts class_name and description" do
      response = {
        "exceptionDetails" => {
          "exception" => {
            "className" => "TypeError",
            "description" => "Cannot read property 'foo' of null",
          },
        },
      }
      error = described_class.new(response)
      expect(error.class_name).to eq("TypeError")
      expect(error.message).to eq("Cannot read property 'foo' of null")
    end

    it "falls back to text when description is missing" do
      response = {
        "exceptionDetails" => {
          "text" => "Uncaught error",
          "exception" => {
            "className" => "Error",
          },
        },
      }
      error = described_class.new(response)
      expect(error.message).to eq("Uncaught error")
    end

    it "captures stack_trace when CDP supplies one" do
      response = {
        "exceptionDetails" => {
          "exception" => { "className" => "Error", "description" => "oops" },
          "stackTrace" => { "callFrames" => [{ "functionName" => "f", "url" => "u" }] },
        },
      }
      error = described_class.new(response)
      expect(error.stack_trace).to eq("callFrames" => [{ "functionName" => "f", "url" => "u" }])
    end
  end

  describe Capybara::Lightpanda::ObsoleteNode do
    it "captures the node reference" do
      node = double("node")
      error = described_class.new(node)
      expect(error.node).to eq(node)
      expect(error.message).to eq("Element is no longer attached to the DOM")
    end

    it "accepts a custom message" do
      node = double("node")
      error = described_class.new(node, "custom message")
      expect(error.message).to eq("custom message")
    end
  end

  describe Capybara::Lightpanda::MouseEventFailed do
    it "parses position and selector from message" do
      node = double("node")
      error = described_class.new(node, "at position (100, 200) selector: #btn")
      expect(error.position).to eq({ x: 100, y: 200 })
      expect(error.selector).to eq("#btn")
    end
  end
end
