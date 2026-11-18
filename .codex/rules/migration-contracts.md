---
paths: ["lib/capybara/lightpanda/browser/selenium_compat.rb", "lib/capybara/lightpanda/downloads.rb", "lib/capybara/lightpanda/node.rb", "test/compatibility/*.rb"]
---

Verified 2026-11 with Capybara 3.40, Selenium 4.41 and Chromium 156.0.8078.4.

- Capybara prepends its own `getAttribute` atom to Selenium's bridge. Test `element.native.attribute` through a Capybara session. An enabled input returns `"false"` for `disabled` under the default Capybara optimization.
- Full Chrome with `--headless` retained the CDP download directory after Capybara session reset. Chrome Headless Shell at the same version reverted to its profile preference. The portable test sets the directory before each example.
