# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

describe Capybara::Lightpanda::Downloads do
  it "records a slow export in the directory where it began after a destination change" do
    transport = Class.new(Capybara::Lightpanda::Client::Subscriber) do
      alias_method :on, :subscribe
      alias_method :off, :unsubscribe
    end.new
    transport.stubs(:command).returns({})
    downloads = Capybara::Lightpanda::Downloads.new(transport)
    Dir.mktmpdir do |root|
      first = File.join(root, "first")
      second = File.join(root, "second")
      downloads.set_behavior(save_path: first)
      transport.dispatch("Browser.downloadWillBegin", { "guid" => "old", "suggestedFilename" => "report.zip" })
      downloads.set_behavior(save_path: second)
      transport.dispatch("Browser.downloadWillBegin", { "guid" => "new", "suggestedFilename" => "report.zip" })
      %w[new old].each do |guid|
        transport.dispatch("Browser.downloadProgress", { "guid" => guid, "state" => "completed" })
      end
      assert_equal [File.join(second, "report.zip"), File.join(first, "report.zip")], downloads.files
    end
  end
end
