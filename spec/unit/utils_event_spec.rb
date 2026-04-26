# frozen_string_literal: true

require "bundler/setup"
require "capybara/lightpanda/utils/event"

RSpec.describe Capybara::Lightpanda::Utils::Event do
  subject(:event) { described_class.new }

  it "starts unset with iteration 0" do
    expect(event.set?).to be false
    expect(event.iteration).to eq(0)
  end

  it "behaves like Concurrent::Event for set/wait" do
    event.set
    expect(event.set?).to be true
    expect(event.wait(0)).to be true
  end

  describe "#reset" do
    it "increments iteration counter on every reset" do
      expect { event.reset }.to change(event, :iteration).by(1)
      expect { event.reset }.to change(event, :iteration).by(1)
    end

    it "increments iteration even when already unset" do
      event.set
      expect(event.iteration).to eq(0)
      event.reset
      expect(event.iteration).to eq(1)
      expect(event.set?).to be false
    end

    it "returns the new iteration value" do
      expect(event.reset).to eq(1)
      expect(event.reset).to eq(2)
    end
  end

  it "lets callers detect a set→reset→set race via iteration" do
    before = event.iteration
    event.set
    event.reset
    event.set
    after = event.iteration
    expect(after).to be > before
  end
end
