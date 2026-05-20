# frozen_string_literal: true

# Child process for TeardownTest. Starts a Browser and then EXITS WITHOUT
# calling #quit — exactly what happens to Capybara's shared browser at the end
# of a suite. Cleanup is therefore left to the gem's at_exit handler.
#
# Prints the lightpanda pid, and (from an at_exit registered AFTER the browser,
# so it runs BEFORE the gem's quit_all in at_exit's reverse order) a wall-clock
# marker at the start of teardown, so the parent can measure pure teardown time.
require "capybara-lightpanda"

bin  = ENV.fetch("LP_ABANDON_BIN")
port = ENV.fetch("LP_ABANDON_PORT").to_i

browser = Capybara::Lightpanda::Browser.new(browser_path: bin, port: port)
pid = browser.process.pid

at_exit do
  $stdout.puts "TEARDOWN_START #{Time.now.to_f}"
  $stdout.flush
end

$stdout.puts "READY #{pid}"
$stdout.flush
# Fall off the end: the at_exit chain runs — our marker first, then the gem's
# quit_all, which closes the CDP WebSocket before SIGTERMing the binary.
