# Changelog

## [0.1.0] - 2026-03-15

- Initial release
- Capybara driver for Lightpanda headless browser
- Built-in CDP client with WebSocket transport
- XPath polyfill (auto-injected after navigation)
- Cookie management with fallback for older Lightpanda versions
- Reliable navigation with readyState polling fallback
- Frame support via contentDocument scoping
- Runs Capybara's shared spec suite
