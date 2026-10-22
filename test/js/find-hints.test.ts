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

test("findHints: reads NBSP and zero-width marks the way filter_text does", () => {
  const { predicates, nodes } = items("<li>a b c​d</li>");
  const kept = predicates.findHints(nodes, { texts: ["a b", "cd"] }) as any[];
  expect(kept.length).toBe(1);
});

test("findHints: one cache per kept node, aligned with the nodes", () => {
  const { predicates, nodes, setVisible } = items("<li>x</li><li>y</li>");
  setVisible(nodes[1], false);
  const kept = predicates.findHints(nodes, { visible: true });
  expect(hintsOf(kept)).toEqual([
    { tag_name: "li", visible: true },
    { tag_name: "li", visible: false },
  ]);
});

test("findHints: a failing hint returns the nodes unhinted, never a verdict", () => {
  const { predicates, nodes } = items("<li>x</li>");
  (nodes[0] as any).getBoundingClientRect = () => {
    throw new Error("boom");
  };
  const kept = predicates.findHints(nodes, { position: true }) as any;
  expect(kept.length).toBe(1);
  expect(kept.__lightpandaHints).toBeUndefined();
});
