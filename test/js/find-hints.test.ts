// findHints answers Capybara's finder hints inside the find call. Its text
// pre-filter may only drop a node Capybara would reject anyway: dropping one
// it would have matched turns a passing `find(..., text:)` into
// ElementNotFound. These tests pin that the filter stays on the safe side.

import { test, expect } from "bun:test";
import { makeDom } from "./load.ts";

function hintsOf(nodes: any): any[] {
  return JSON.parse(nodes.__lightpandaHints);
}

function items(html: string) {
  const dom = makeDom(html);
  return { ...dom, nodes: Array.from(dom.document.querySelectorAll("li")) };
}

test("findHints: drops only nodes missing a text fragment", () => {
  const { predicates, nodes } = items("<li>Item 1</li><li>Item 2</li><li>Other</li>");
  const kept = predicates.findHints(nodes, { texts: ["Item", "2"] }) as any[];
  expect(kept.map((el) => el.textContent)).toEqual(["Item 2"]);
});

test("findHints: matches case-insensitively (text-transform, Capybara's own casing)", () => {
  const { predicates, nodes } = items("<li>ITEM</li>");
  expect((predicates.findHints(nodes, { texts: ["item"] }) as any[]).length).toBe(1);
});

test("findHints: keeps a node whose text is only in textContent (visible: :all queries)", () => {
  const { predicates, nodes, setVisible } = items("<li>hidden words</li>");
  setVisible(nodes[0], false);
  expect((predicates.findHints(nodes, { texts: ["hidden"] }) as any[]).length).toBe(1);
});

test("findHints: retains Unicode candidates for authoritative text filtering", () => {
  const { predicates, nodes } = items("<li>a b c​d</li>");
  const kept = predicates.findHints(nodes, { texts: ["a b", "cd"] }) as any[];
  expect(kept.length).toBe(1);
});


test("findHints: caches only immutable tag names", () => {
  const { predicates, nodes } = items("<li>x</li><li>y</li>");
  const kept = predicates.findHints(nodes, { visible: true, position: true, styles: ["display"] });
  expect(hintsOf(kept)).toEqual([{ tag_name: "li" }, { tag_name: "li" }]);
});

test("findHints: a failure after filtering returns the original unhinted nodes", () => {
  const { predicates, nodes } = items("<li>needle</li><li>other</li>");
  Object.defineProperty(nodes[0], "tagName", { get() { throw new Error("boom"); } });
  const kept = predicates.findHints(nodes, { texts: ["needle"] }) as any;
  expect(kept === nodes).toBe(true);
  expect(kept.length).toBe(2);
  expect(kept.__lightpandaHints).toBeUndefined();
});

test("findHints: large lazy searches never read every candidate's text", () => {
  const { predicates, nodes } = items("<li>needle</li>".repeat(513));
  let reads = 0;
  for (const node of nodes) {
    Object.defineProperty(node, "innerText", { get() { reads++; return "needle"; } });
    Object.defineProperty(node, "textContent", { get() { reads++; return "needle"; } });
  }
  const kept = predicates.findHints(nodes, { texts: ["needle"] }) as any[];
  expect(kept.length).toBe(nodes.length);
  expect(reads).toBe(0);
});
