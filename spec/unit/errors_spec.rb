# frozen_string_literal: true

require "bundler/setup"
require "capybara/lightpanda/errors"

RSpec.describe "Capybara::Lightpanda errors" do
  describe "hierarchy" do
    it "all errors inherit from Capybara::Lightpanda::Error" do
      base = Capybara::Lightpanda::Error
      expect(Capybara::Lightpanda::ProcessTimeoutError.superclass).to eq(base)
      expect(Capybara::Lightpanda::BinaryNotFoundError.superclass).to eq(base)
      expect(Capybara::Lightpanda::BinaryError.superclass).to eq(base)
      expect(Capybara::Lightpanda::UnsupportedPlatformError.superclass).to eq(base)
      expect(Capybara::Lightpanda::DeadBrowserError.superclass).to eq(base)
      expect(Capybara::Lightpanda::TimeoutError.superclass).to eq(base)
      expect(Capybara::Lightpanda::BrowserError.superclass).to eq(base)
      expect(Capybara::Lightpanda::JavaScriptError.superclass).to eq(base)
      expect(Capybara::Lightpanda::NodeNotFoundError.superclass).to eq(base)
      expect(Capybara::Lightpanda::NoExecutionContextError.superclass).to eq(base)
      expect(Capybara::Lightpanda::ObsoleteNode.superclass).to eq(base)
      expect(Capybara::Lightpanda::MouseEventFailed.superclass).to eq(base)
      expect(Capybara::Lightpanda::InvalidSelector.superclass).to eq(base)
      expect(Capybara::Lightpanda::NoSuchPageError.superclass).to eq(base)
      expect(Capybara::Lightpanda::StatusError.superclass).to eq(base)
    end

    it "base error inherits from StandardError" do
      expect(Capybara::Lightpanda::Error.superclass).to eq(StandardError)
    end
  end

  describe Capybara::Lightpanda::BrowserError do
    it "captures the response and message" do
      response = { "message" => "Something went wrong", "code" => -32_601 }
      error = described_class.new(response)
      expect(error.message).to eq("Something went wrong")
      expect(error.response).to eq(response)
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
