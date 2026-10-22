---
paths: ["lib/capybara/lightpanda/browser/finder.rb", "lib/capybara/lightpanda/node.rb", "lib/capybara/lightpanda/javascripts/predicates.js"]
---

Finder hints (verified 2026-10-22, Capybara 3.40 / Lightpanda 1.0.1 and nightly 10965):
- `all(..., minimum: 1)` returns a lazy Result; later candidates are filtered after it returns. Do not cache mutable visibility, geometry or styles in `initial_cache`.
- Literal visible text retains U+200B/U+200E/U+200F and U+2028/U+2029; all_text normalizes them differently. Unicode lowercasing is not substring-preserving (Greek final sigma).
- Bound eager text walks: 20,000 nested divs made `first(text:)` exceed a 15-second command timeout; live lazy filtering completed in under 0.1 seconds locally.
- Publish filtered nodes and aligned tag caches atomically; return the original array on failure. Page-overridden array methods and JSON serialization cannot be trusted for alignment.
