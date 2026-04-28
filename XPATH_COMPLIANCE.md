# XPath 1.0 Compliance — capybara-lightpanda polyfill

This document describes what the in-page XPath 1.0 evaluator at
`lib/capybara/lightpanda/javascripts/index.js` (lines 72–785, the
`XPathEval` IIFE) implements. It exists so that whoever lifts XPath
support into Lightpanda's Zig codebase upstream has a concrete
checklist of behavior to match, with empirical regression tests
already on hand.

The polyfill is a recursive-descent parser + tree walker over XPath
1.0 ([W3C Recommendation, 16 November 1999](https://www.w3.org/TR/1999/REC-xpath-19991116/)).
It implements XPath as an evaluator over the live DOM tree (no XSLT
context, no namespaces beyond name-prefix tokenization, no variable
bindings).

The authoritative regression suite is in
`spec/features/driver_spec.rb` under
`describe "XPath polyfill — XPath 1.0 conformance"`. It exercises 91
expressions against a rich body fixture via
`window._lightpanda.xpathFind` directly. Every behavior described
below is pinned by at least one case in that battery.

## Public API

```js
window._lightpanda.xpathFind(expression, contextNode) -> Array<Node>
```

- Returns a JS Array of DOM nodes in document order (per spec
  §2.1 — the final node-set is delivered ordered).
- Returns `[]` on parse error, evaluation error, or if the result is
  not a node-set (numbers, strings, booleans). Top-level scalar
  expressions are not supported by this entry point — they only
  appear inside predicates.
- Falls through to native `Document.evaluate` when available and not
  polyfilled, so the same call site works on engines with native
  XPath.

The polyfill also installs a `Document.evaluate` shim and
`window.XPathResult` constants (`ORDERED_NODE_SNAPSHOT_TYPE = 7`,
`FIRST_ORDERED_NODE_TYPE = 9`, `_polyfilled = true`) so the standard
DOM API call surface works.

## Grammar coverage (XPath 1.0 §3)

### Path expressions (§3.1, §3.3)

| Form                      | Supported | Notes                                                        |
|---------------------------|-----------|--------------------------------------------------------------|
| `/`                       | yes       | Root only — `[document]`                                     |
| `/foo/bar`                | yes       | Absolute path                                                |
| `//foo`                   | yes       | Desugars to `/descendant-or-self::node()/foo`                |
| `foo`                     | yes       | Implicit `child::foo`                                        |
| `.`                       | yes       | Self                                                         |
| `..`                      | yes       | Parent                                                       |
| `*`                       | yes       | Wildcard name test (disambiguated from `*` multiply by parser context) |
| `@id`                     | yes       | Abbreviated `attribute::id`                                  |
| `@*`                      | yes       | Any attribute                                                |
| `(expr)[n]`               | yes       | Filter expression with predicate — distinct from `expr[n]` per spec |
| `(expr)//foo`             | yes       | Filter expression followed by relative path                  |

### Axes (§3.2.2 — full list)

| Axis                  | Supported | Implementation notes                                              |
|-----------------------|-----------|-------------------------------------------------------------------|
| `child`               | yes       | `firstChild` ... `nextSibling`                                    |
| `descendant`          | yes       | DFS, no self                                                      |
| `descendant-or-self`  | yes       | Self then DFS                                                     |
| `self`                | yes       |                                                                   |
| `parent`              | yes       | `parentNode`                                                      |
| `ancestor`            | yes       | Walks `parentNode` chain, **emitted in proximity order** (nearest first) so positional predicates are correct |
| `ancestor-or-self`    | yes       | Self prepended, then ancestor chain                               |
| `following-sibling`   | yes       |                                                                   |
| `preceding-sibling`   | yes       | **Emitted in proximity order** (closest first)                    |
| `following`           | yes       | All nodes following context in document order, excluding ancestors and self |
| `preceding`           | yes       | All nodes preceding context, excluding ancestors                  |
| `attribute`           | yes       | Iterates `node.attributes`                                        |
| `namespace`           | **stub**  | Always returns `[]`. Rarely meaningful in HTML.                   |

The proximity-order rule is critical: `ancestor::*[1]` must select
the *parent*, not the document root. This is pinned by two regression
tests in the integration block (`XPath finding`).

The polyfill keeps each step's results in axis order during
evaluation and only sorts into document order at the *public entry
point* (`XPathEval.find`). Internal step intermediates remain in axis
order so predicates evaluate correctly per spec §2.4.

### Node tests (§2.3)

| Test                             | Supported | Notes                                              |
|----------------------------------|-----------|----------------------------------------------------|
| `name`                           | yes       | Case-insensitive match against `nodeName` (HTML-friendly; XPath spec is case-sensitive) |
| `prefix:local-name`              | parsed    | Tokenized; treated like a regular name (no namespace resolution) |
| `prefix:*`                       | parsed    | Same — no namespace mapping                        |
| `*`                              | yes       | Element wildcard                                   |
| `node()`                         | yes       | All nodes                                          |
| `text()`                         | yes       | `nodeType === 3`                                   |
| `comment()`                      | yes       | `nodeType === 8`                                   |
| `processing-instruction()`       | yes       | `nodeType === 7`                                   |
| `processing-instruction('name')` | partial   | Target literal is **consumed but not used to filter** — matches any PI. Acceptable for HTML. |

### Predicates (§2.4, §3.3)

- Multi-predicate chains (`foo[a][b]`) — yes, applied left to right with size recomputed per step.
- Numeric predicates select positionally: `[3]` matches the third item in axis order.
- Boolean predicates filter via `boolean()` coercion.
- Sub-paths in predicates: `[a/b]`, `[count(li) = 5]`, `[a/@href = '/foo']` — yes.
- `position()` and `last()` reflect the **current axis context size after preceding predicates** in the same step (per spec).

### Primary expressions (§3.1)

| Form              | Supported | Notes                                                       |
|-------------------|-----------|-------------------------------------------------------------|
| String literal    | yes       | Both `'…'` and `"…"`. No escape sequences (use the other quote type to embed). |
| Numeric literal   | yes       | Integers and decimals, including leading-dot form `.5`.     |
| Variable `$name`  | **stub**  | Always evaluates to `''` (empty string). No public binding API. |
| Function call     | yes       | All XPath 1.0 core library functions (see below).           |
| Parenthesized     | yes       | Used to form filter expressions and group precedence.       |

## Function library (§4 — XPath 1.0 core)

All 27 standard core-library functions are implemented. Every row
below is exercised by at least one case in the regression battery.

### Node-set functions (§4.1)

| Function           | Supported | Notes                                                       |
|--------------------|-----------|-------------------------------------------------------------|
| `last()`           | yes       | Context size                                                |
| `position()`       | yes       | Context position                                            |
| `count(node-set)`  | yes       | Returns 0 for non-node-set arguments                        |
| `id(object)`       | yes       | Accepts string, node-set, or arbitrary object. For node-sets, takes string-value of each (matches spec §4.1 modulo the equivalent split-then-rejoin). |
| `local-name()`     | yes       | Lowercased for HTML ergonomics — XPath spec returns name as-is |
| `namespace-uri()`  | partial   | Always returns `''` (no namespace tracking)                 |
| `name()`           | yes       | Lowercased — same caveat as `local-name()`                  |

### String functions (§4.2)

| Function                         | Supported | Notes                                                      |
|----------------------------------|-----------|------------------------------------------------------------|
| `string(object?)`                | yes       | Default arg is context node                                |
| `concat(s1, s2, ...)`            | yes       | Variadic                                                   |
| `starts-with(s1, s2)`            | yes       |                                                            |
| `contains(s1, s2)`               | yes       |                                                            |
| `substring-before(s1, s2)`       | yes       |                                                            |
| `substring-after(s1, s2)`        | yes       |                                                            |
| `substring(s, start, len?)`      | yes       | XPath 1-based indexing, half-to-positive-infinity rounding. NaN args produce `''`. |
| `string-length(s?)`              | yes       | Default arg is context node string-value                   |
| `normalize-space(s?)`            | yes       | Trim + collapse internal runs to single space              |
| `translate(s, from, to)`         | yes       | Character-by-character map; chars in `from` past `to.length` are **deleted** per spec |

### Boolean functions (§4.3)

| Function          | Supported | Notes                                                       |
|-------------------|-----------|-------------------------------------------------------------|
| `boolean(object)` | yes       | Per-spec coercion (non-empty node-set/string/non-zero number → true) |
| `not(boolean)`    | yes       |                                                             |
| `true()`          | yes       |                                                             |
| `false()`         | yes       |                                                             |
| `lang(string)`    | **stub**  | Always returns `false`. Useful future addition for `xml:lang`/`lang` attribute matching. |

### Number functions (§4.4)

| Function          | Supported | Notes                                                                      |
|-------------------|-----------|----------------------------------------------------------------------------|
| `number(object?)` | yes       | Empty/whitespace strings → `NaN`. Default arg is context.                  |
| `sum(node-set)`   | yes       | Sum of `number(string-value)` over each node                               |
| `floor(n)`        | yes       | Native `Math.floor`                                                        |
| `ceiling(n)`      | yes       | Native `Math.ceil`                                                         |
| `round(n)`        | yes       | Round half toward positive infinity. JS `Math.round` happens to match the XPath spec for finite values; verified for negative-half cases (`round(-0.5) = 0`, `round(-1.5) = -1`). |

## Operators (§3.4, §3.5)

| Category    | Operators                              | Supported | Notes                                                |
|-------------|----------------------------------------|-----------|------------------------------------------------------|
| Union       | `\|`                                   | yes       | Result deduplicated and document-order-sorted        |
| Logical     | `or`, `and`                            | yes       | Short-circuiting                                     |
| Equality    | `=`, `!=`                              | yes       | Per-§3.4 type coercion (see below)                   |
| Relational  | `<`, `<=`, `>`, `>=`                   | yes       | Both sides coerced to numbers                        |
| Additive    | `+`, `-`                               | yes       |                                                      |
| Multiplicat.| `*` (multiply), `div`, `mod`           | yes       | `*` disambiguated from wildcard by parser context    |
| Unary       | `-` (negation)                         | yes       |                                                      |

### Type coercion in comparisons (§3.4)

Implemented in `xCmp` (lines 390–440 of `index.js`). Behaviors verified:

- **node-set vs node-set**: existential — true iff some pair of
  string-values satisfies the comparison.
- **node-set vs scalar**: existential against the scalar; node-set
  side coerces each node's string-value (to number, string, or
  boolean) per the scalar's type.
- **scalar vs scalar**:
  - boolean involved → both coerced to boolean
  - number involved → both coerced to number
  - else → string compare for `=`/`!=`; number compare for `<`/`<=`/`>`/`>=`
- **NaN semantics** match IEEE 754 — `NaN != X` is true for all `X`,
  `NaN = NaN` is false. Pinned by the case
  `//tr[number(td[2]) != 30]` returning the header row (whose
  `td[2]` is the literal "Age" → NaN).

## Tokenizer notes

- Whitespace `\t \n \r ` is skipped between tokens.
- Both single and double quote string literals.
- Numeric literals include leading-dot form (`.5`).
- Two-char operators recognized: `//`, `::`, `!=`, `<=`, `>=`, `..`.
- Names take an optional namespace prefix (`prefix:local` or
  `prefix:*`) but the prefix is preserved as part of the name and
  not resolved.
- **Unknown characters are silently skipped** rather than thrown.
  This is permissive by design — Capybara only ever generates valid
  XPath, and the public `xpathFind` catches all exceptions and
  returns `[]`. An upstream Zig implementation may want to error
  here for better diagnostics.

## Spec deviations and stubs (intentional)

| Area                            | Behavior                                                        | Reason                            |
|---------------------------------|-----------------------------------------------------------------|-----------------------------------|
| `lang()` function               | Always `false`                                                  | Rarely used; not worth complexity |
| `namespace::` axis              | Always returns `[]`                                             | Rarely meaningful in HTML          |
| `namespace-uri()`               | Always returns `''`                                             | No namespace tracking              |
| `processing-instruction('name')`| Target literal ignored — matches any PI                         | PIs are rare in HTML               |
| `name()` / `local-name()`       | Lowercased instead of returning source-case name                | HTML ergonomics; nodeName is uppercase |
| Variable references `$name`     | Always `''`                                                     | No public binding API in Capybara  |
| Tokenizer                       | Silently skips unknown chars                                    | Capybara never generates invalid XPath |
| Top-level scalar results        | `xpathFind` returns `[]` for non-node-set top-level expressions | The API is designed for finding nodes, not arbitrary computation |

The integration spec block `XPath polyfill — XPath 1.0 conformance`
verifies positive behavior; documented stubs are not currently
asserted but were probed empirically during the audit (see commit
history if needed).

## Implementation notes worth preserving in a Zig port

1. **Reverse-axis proximity order**: `ancestor::*[1]` and
   `preceding-sibling::*[1]` must select the *nearest* node, not the
   document-order-first node. The polyfill enforces this by emitting
   reverse axes in proximity order during step evaluation and
   sorting into document order only at the public entry.

2. **Predicate `sz` is recomputed per predicate**: when chaining
   `[a][b]`, the size for `last()` inside `[b]` must reflect the
   *post-`[a]`* set size. The polyfill assigns `sz = cur.length`
   *before* entering the inner loop for each predicate (lines
   546–552 of `index.js`).

3. **`*` disambiguation**: in `parseMultExpr`, `*` is treated as
   multiply only after a complete `parseUnaryExpr`. In
   `parseStep`, `*` is treated as wildcard. The recursive-descent
   structure makes this fall out naturally — no explicit lookahead
   needed.

4. **`div` and `mod` are NCNames, not symbols**: they're tokenized
   as names and only become operators when seen by `parseMultExpr`
   in operator position. Same for `or` and `and` in
   `parseOr`/`parseAndExpr`.

5. **Node-set vs scalar comparison**: the existential semantics in
   `xCmp` require iterating the node-set side once for each scalar,
   not converting the whole node-set to a single scalar. Easy to
   get wrong with a naive implementation.

6. **Document order only at the boundary**: the public `find`
   sorts the final result; intermediate step outputs stay in axis
   order (proximity for reverse axes). Sorting eagerly at every
   step would break positional predicates on reverse axes.

7. **Filter expressions vs. location paths**: `(//a)[1]` and
   `//a[1]` mean different things per spec — the first picks the
   document-first `a`, the second picks the first `a` per parent.
   The polyfill distinguishes them with a separate AST node
   (`fpath` for filter-then-path, `filt` for filter-with-predicate)
   and routes through `parsePathExpr`.

8. **`Runtime.evaluate` execution-context invalidation**: the JS
   polyfill is registered via `Page.addScriptToEvaluateOnNewDocument`
   so it auto-injects on every navigation. A native Zig
   implementation would not need this — but keep in mind that any
   port should survive `Document` replacement and frame swaps.

## Test references

- **Comprehensive battery**:
  `spec/features/driver_spec.rb` →
  `describe "XPath polyfill — XPath 1.0 conformance"` — 91
  expressions exercised in one `aggregate_failures` example.
- **Capybara integration smoke** (round-trip through
  `session.find(:xpath, …)`):
  `spec/features/driver_spec.rb` → `describe "XPath finding"`.
- **Polyfill lifecycle** (re-injection after navigation):
  `spec/features/driver_spec.rb` → `describe "XPath polyfill"`.

## Out of scope

These XPath 1.0 features are **not** implemented and not currently
needed by Capybara users:

- Variable binding API
- True namespace resolution (`prefix:local-name` works as a name
  match, but no namespace URI lookup)
- The `namespace::` axis
- The `lang()` function (stub)
- XPath 2.0+ features (sequences, `for`/`if`/`some`/`every`, regex,
  schema-aware types, dateTime functions)
- XSLT-only constructs (`current()`, `document()`, etc.)

If a future Capybara/Lightpanda use case needs any of the above, the
polyfill's recursive-descent structure is small enough (~700 lines
including comments) that adding them is a contained change.
