# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

describe Capybara::Lightpanda::Downloads do
  it "records a slow export in the directory where it began after a destination change" do
    transport = Class.new(Capybara::Lightpanda::Client::Subscriber) do
      alias_method :on, :subscribe
      alias_method :off, :unsubscribe
    end.new
    transport.stubs(:client).returns(transport)
    transport.define_singleton_method(:command) do |_, params, on_success:|
      # A response to the preceding page action can begin an export while the
      # setter is still traveling to the browser. A second export starts after
      # its acknowledgement, before the Ruby caller resumes.
      changing = File.basename(params.fetch(:downloadPath)) == "second"
      event = "Browser.downloadWillBegin"
      dispatch(event, { "guid" => "old", "suggestedFilename" => "report.zip" }) if changing
      on_success.call
      dispatch(event, { "guid" => "new", "suggestedFilename" => "report.zip" }) if changing
      {}
    end
    downloads = Capybara::Lightpanda::Downloads.new(transport)
    Dir.mktmpdir do |root|
      first = File.join(root, "first")
      second = File.join(root, "second")
      downloads.set_behavior(save_path: first)
      downloads.set_behavior(save_path: second)
      %w[new old].each do |guid|
        transport.dispatch("Browser.downloadProgress", { "guid" => guid, "state" => "completed" })
      end
      assert_equal [File.join(second, "report.zip"), File.join(first, "report.zip")], downloads.files
    end
  end
end
