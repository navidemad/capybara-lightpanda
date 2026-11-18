# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "capybara/lightpanda/cli"

# The executable is what setup scripts and CI steps call, so its contract is
# the exit status and where the binary lands — a wrong status would let a
# setup step "succeed" with no browser installed.
describe Capybara::Lightpanda::CLI do
  before do
    @version = Capybara::Lightpanda::Binary.instance_variable_get(:@required_version)
    @install_dir = Capybara::Lightpanda::Binary.instance_variable_get(:@install_dir)
    Capybara::Lightpanda::Binary.required_version = nil
    Capybara::Lightpanda::Binary.install_dir = Dir.mktmpdir
    @out = StringIO.new
    @err = StringIO.new
  end

  after do
    Capybara::Lightpanda::Binary.instance_variable_set(:@required_version, @version)
    Capybara::Lightpanda::Binary.instance_variable_set(:@install_dir, @install_dir)
  end

  def run_cli(*argv)
    Capybara::Lightpanda::CLI.run(argv, out: @out, err: @err)
  end

  it "installs the requested version and reports where it landed" do
    Capybara::Lightpanda::Binary.expects(:install).with(force: false).returns("/cache/lightpanda-9.9.9")

    assert_equal 0, run_cli("install", "9.9.9")
    assert_equal "9.9.9", Capybara::Lightpanda::Binary.required_version
    assert_includes @out.string, "/cache/lightpanda-9.9.9"
  end

  it "passes --force through so a cached binary is replaced" do
    Capybara::Lightpanda::Binary.expects(:install).with(force: true).returns("/cache/lightpanda")

    assert_equal 0, run_cli("install", "--force")
  end

  it "exits 1 with the reason when the download fails" do
    Capybara::Lightpanda::Binary.expects(:install).raises(
      Capybara::Lightpanda::BinaryError, "Failed to download binary: 404 Not Found"
    )

    assert_equal 1, run_cli("install")
    assert_includes @err.string, "404 Not Found"
  end

  it "exits 1 when asked for the version of a binary that isn't cached" do
    assert_equal 1, run_cli("version")
    assert_includes @err.string, Capybara::Lightpanda::Binary.install_path
  end

  it "prints the cache path for the version in effect" do
    assert_equal 0, run_cli("path", "nightly")
    assert_equal "#{File.join(Capybara::Lightpanda::Binary.install_dir, 'lightpanda')}\n", @out.string
  end

  it "exits 1 on an unknown command" do
    assert_equal 1, run_cli("bogus")
    assert_includes @err.string, "Usage:"
  end
end
