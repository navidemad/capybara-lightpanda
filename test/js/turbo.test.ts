// The Turbo activity tracker (turbo.js) behind Browser#wait_for_idle. Every
// Turbo operation that starts must end exactly once: a fetch left open keeps
// the Ruby @turbo_event reset, and then every click, send_keys and back waits
// out the full driver timeout. These tests drive the shipped file with the
// event shapes Turbo 8 dispatches (test/fixtures/turbo-8.0.23.umd.js).

import { test, expect } from "bun:test";
import { Window, type EventTarget } from "happy-dom";
import { readFileSync } from "node:fs";

const TURBO_SRC = readFileSync(
  new URL("../../lib/capybara/lightpanda/javascripts/turbo.js", import.meta.url),
  "utf8",
);

// Evaluate turbo.js the way AutoScripts does (a classic-script body), with a
// console that records the busy/idle sentinels console.rb listens for.
function tracker() {
  const win = new Window();
  const document = win.document;
  const signals: string[] = [];
  const console = { debug: (marker: string) => signals.push(marker) };
  const pending = new Function(
    "document",
    "console",
    `${TURBO_SRC}\n;return function() { return _pendingTurboOps; };`,
  )(document, console) as () => number;

  const dispatch = (name: string, target: EventTarget, detail: object = {}) =>
    target.dispatchEvent(new win.CustomEvent(name, { bubbles: true, cancelable: true, detail }));

  // FetchRequest#perform: turbo:before-fetch-request carries fetchOptions,
  // whose signal belongs to the request's AbortController.
  const startFetch = (target: EventTarget = document) => {
    const controller = new win.AbortController();
    dispatch("turbo:before-fetch-request", target, { fetchOptions: { signal: controller.signal } });
    return controller;
  };

  return { win, document, signals, pending, dispatch, startFetch };
}

test("an aborted fetch counts down, so the tracker returns to idle", () => {
  // Turbo swallows AbortError: no before-fetch-response, no fetch-request-error.
  const t = tracker();
  const controller = t.startFetch();
  expect(t.pending()).toBe(1);

  controller.abort();

  expect(t.pending()).toBe(0);
  expect(t.signals).toEqual(["__lightpanda_turbo_busy", "__lightpanda_turbo_idle"]);
});

test("a fetch already aborted when announced is never counted as busy work", () => {
  const t = tracker();
  const controller = new t.win.AbortController();
  controller.abort();
  t.dispatch("turbo:before-fetch-request", t.document, { fetchOptions: { signal: controller.signal } });

  expect(t.pending()).toBe(0);
});

test("an abort after the response was counted does not end another fetch early", () => {
  // Visit#cancel can abort a request whose response already arrived. Counting
  // it twice would report idle while the second fetch is still in flight.
  const t = tracker();
  const first = t.startFetch();
  t.dispatch("turbo:before-fetch-response", t.document);
  t.startFetch();

  first.abort();

  expect(t.pending()).toBe(1);
});

test("a response or error ends the fetch for its own target", () => {
  const t = tracker();
  const frame = t.document.createElement("turbo-frame");
  t.document.body.appendChild(frame);
  t.startFetch(frame);
  t.startFetch(t.document);

  t.dispatch("turbo:fetch-request-error", frame);
  expect(t.pending()).toBe(1);

  t.dispatch("turbo:before-fetch-response", t.document);
  expect(t.pending()).toBe(0);
});

test("turbo:load forgets open fetches, so their late abort cannot end newer work", () => {
  const t = tracker();
  const stale = t.startFetch();
  t.dispatch("turbo:load", t.document);
  t.startFetch();

  stale.abort();

  expect(t.pending()).toBe(1);
});

function streamRender(t: ReturnType<typeof tracker>, render: () => unknown) {
  const detail = { render };
  t.dispatch("turbo:before-stream-render", t.document, detail);
  return detail.render;
}

test("a canceled stream render leaves the tracker idle", () => {
  const t = tracker();
  // StreamElement#render skips detail.render when dispatchEvent returns false.
  let rendered = false;
  t.document.addEventListener("turbo:before-stream-render", (event) => event.preventDefault());
  const detail = { render: () => { rendered = true; } };
  if (t.dispatch("turbo:before-stream-render", t.document, detail)) detail.render();
  expect(rendered).toBe(false);
  expect(t.pending()).toBe(0);
  expect(t.signals).toEqual([]);
});

test("a synchronous stream renderer failure releases busy and preserves the error", () => {
  const t = tracker();
  const error = new Error("custom stream renderer failed");
  const render = streamRender(t, () => { throw error; });
  expect(render).toThrow(error);
  expect(t.pending()).toBe(0);
  expect(t.signals).toEqual(["__lightpanda_turbo_busy", "__lightpanda_turbo_idle"]);
});

test("a stream settling after turbo:load cannot mark a newer fetch idle", async () => {
  const t = tracker();
  let finish!: () => void;
  const render = streamRender(t, () => new Promise<void>((resolve) => { finish = resolve; }));
  const result = render();
  expect(t.pending()).toBe(1);
  t.dispatch("turbo:load", t.document);
  const fetch = t.startFetch();

  finish();
  await result;
  expect(t.pending()).toBe(1);
  expect(t.signals.at(-1)).toBe("__lightpanda_turbo_busy");
  fetch.abort();
  expect(t.pending()).toBe(0);
});

test("a rejected stream releases only its own operation while another render runs", async () => {
  const t = tracker();
  let finish!: () => void;
  const second = streamRender(t, () => new Promise<void>((resolve) => { finish = resolve; }))();
  const error = new Error("async renderer failed");
  const first = streamRender(t, () => Promise.reject(error))();
  await expect(first).rejects.toBe(error);
  expect(t.pending()).toBe(1);
  finish();
  await second;
  expect(t.pending()).toBe(0);
});
