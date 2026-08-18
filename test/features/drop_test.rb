# frozen_string_literal: true

require_relative "../test_helper"

# Drag-and-drop file/data upload via Capybara's standard `Element#drop`.
#
# Mirrors Capybara's own `Element#drop` shared examples, which the shared suite
# skips because their `html5_drag` tag is bundled with the geometry-dependent
# HTML5 drag_to tests Lightpanda can't do. File/data drops need no geometry, so
# we exercise them here against the `/lightpanda/drop_test` dropzone.
#
# DataTransfer/DataTransferItem/DragEvent landed upstream in PR #2671
# (build ≥6699), guaranteed by the MINIMUM_NIGHTLY_BUILD floor — a binary
# without them is rejected at startup before these tests run.
describe "Capybara::Lightpanda::Node#drop" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/drop_test") }
  after { session.reset_session! }

  def fixture(name)
    File.expand_path("../fixtures/#{name}", __dir__)
  end

  def dropzone
    session.find(:css, "#dropzone")
  end

  it "drops a single file, exposed to the page via dataTransfer.files/items" do
    dropzone.drop(fixture("capybara.jpg"))

    assert_includes session.html, "file: capybara.jpg"
    assert_includes session.html, "files=1"
  end

  it "drops multiple files in one call" do
    dropzone.drop(fixture("capybara.jpg"), fixture("test_file.txt"))

    assert_includes session.html, "file: capybara.jpg"
    assert_includes session.html, "file: test_file.txt"
    assert_includes session.html, "files=2"
  end

  it "accepts a Pathname (Capybara normalizes #to_path to a string path)" do
    dropzone.drop(Pathname.new(fixture("capybara.jpg")))

    assert_includes session.html, "file: capybara.jpg"
  end

  # Files travel via a hidden <input type=file> + DOM.setFileInputFiles, so the
  # browser reads them off disk itself instead of the gem base64-ing them into
  # one CDP message. Two things must hold: the page gets the real bytes, and
  # the helper input does not linger in the DOM afterwards.
  it "hands the page the file's actual bytes" do
    session.execute_script(<<~JS)
      document.getElementById('dropzone').addEventListener('drop', function(e) {
        e.dataTransfer.files[0].text().then(function(t) {
          document.getElementById('summary').setAttribute('data-bytes', t);
        });
      });
    JS
    dropzone.drop(fixture("test_file.txt"))

    expected = File.read(fixture("test_file.txt"))
    assert session.has_css?("#summary[data-bytes]"), "drop handler never read the file"
    assert_equal expected, session.find(:css, "#summary")["data-bytes"]
  end

  it "leaves no helper input behind" do
    dropzone.drop(fixture("capybara.jpg"))

    assert_includes session.html, "file: capybara.jpg"
    assert session.has_no_css?("input[type=file]", visible: :all)
  end

  it "drops string data as a typed item, readable via getAsString" do
    dropzone.drop("text/plain" => "Some dropped text")

    assert_includes session.html, "string: text/plain Some dropped text"
    assert_includes session.html, "types=text/plain"
  end

  it "drops multiple string types in one call" do
    dropzone.drop("text/plain" => "Some dropped text", "text/url" => "http://www.google.com")

    assert_includes session.html, "string: text/plain Some dropped text"
    assert_includes session.html, "string: text/url http://www.google.com"
  end
end
