# frozen_string_literal: true

require_relative "../test_helper"

class TestApp
  get "/lightpanda/event_stream_page" do
    <<~HTML
      <!DOCTYPE html>
      <p id="message">waiting</p>
      <script>
        new EventSource("/lightpanda/event_stream").onmessage = function(event) {
          document.getElementById("message").textContent = event.data;
        };
      </script>
    HTML
  end

  # Holds the response open after its first event, as a live stream does.
  get "/lightpanda/event_stream" do
    body = Enumerator.new do |out|
      out << "data: hello\n\n"
      sleep 3
    end
    [200, { "content-type" => "text/event-stream", "cache-control" => "no-cache" }, body]
  end
end

# A request counts as in flight until its body has arrived (Network.loadingFinished),
# not merely its headers, as in Chrome and Ferrum. WHY THIS MATTERS: an idle wait
# that returns while a response is still streaming lets the next assertion read a
# half-loaded page. The flip side, a stream that never ends never goes idle, is
# a visible change for 0.19 users; this pins both halves so neither can regress
# silently.
describe "Capybara::Lightpanda network idle with a streaming response" do
  let(:session) { TestSessions::Lightpanda }

  after { session.reset_session! }

  it "treats an open EventSource as in flight and idles with an allowance for it" do
    session.driver.network.enable
    session.visit("/lightpanda/event_stream_page")
    assert session.has_css?("#message", text: "hello")

    refute session.driver.wait_for_network_idle(timeout: 0.5)
    assert_equal 1, session.driver.network.pending_connections
    assert session.driver.wait_for_network_idle(timeout: 2, connections: 1)
  end
end
