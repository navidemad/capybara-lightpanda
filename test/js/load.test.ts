// Harness-integrity tests. The loader's whole value is that it exercises the
// SHIPPED predicates.js with no second copy of the logic. These tests guard
// that promise: if a predicate is added to predicates.js but not wired into
// attach.js (or vice versa), the bundle and the tested surface would diverge.

import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { makeDom, predicateNames } from "./load.ts";

test("the harness exposes exactly the predicates attach.js wires onto _lightpanda", () => {
  // attach.js wires each predicate as `name: name,` inside window._lightpanda
  // (the `turbo:` sub-object uses a different shape and is excluded).
  const attach = readFileSync(
    new URL("../../lib/capybara/lightpanda/javascripts/attach.js", import.meta.url),
    "utf8",
  );
  const shipped = [...attach.matchAll(/^\s*(\w+):\s*\1,?\s*$/gm)]
    .map((m) => m[1])
    .sort();

  const exposed = Object.keys(makeDom("<div></div>").predicates).sort();

  // If these drift, a predicate is either injected-but-untested or
  // tested-but-not-injected — both are bugs the loader exists to prevent.
  expect(exposed).toEqual(shipped);
});

test("every function declared in predicates.js is exposed (no silent omission)", () => {
  const declared = predicateNames().sort();
  const exposed = Object.keys(makeDom("<div></div>").predicates).sort();
  expect(exposed).toEqual(declared);
});
