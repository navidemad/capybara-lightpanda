// Reusable CDP scaffolding for Lightpanda probes and reproducers.
//
// Why raw `ws` and not `chrome-remote-interface`:
//   - Lightpanda's `/json/list` endpoint returns []. The default
//     `await CDP({port: 9222})` fails with "No inspectable targets".
//     Workarounds (`target: 'ws://...'`, `local: true`) help but still
//     can't drive the `Target.createTarget` + `Target.attachToTarget`
//     session-id flow that Lightpanda requires for any real test.
//   - Lightpanda also doesn't serve `/json/protocol` (the protocol
//     descriptor), so c-r-i fails on lookup of unknown methods.
//   - Raw `ws` gives us full control over the session_id parameter
//     that every per-page command needs.
//
// Usage:
//   const { connect } = require('<path>/cdp.js');
//   const c = await connect();              // opens ws + creates target + attaches
//   await c.eval('document.title');          // -> string
//   await c.send('Page.navigate', { url });  // raw send (sessionId auto-applied)
//   c.close();
//
// Cap probes at <80 lines of orchestration on top of this lib.
// If a probe needs more, the bug isn't isolated enough — split it.

const WebSocket = require('ws');

function makeClient(url = 'ws://127.0.0.1:9222/') {
  const ws = new WebSocket(url);
  let nextId = 1;
  const pending = new Map();
  const handlers = new Map();
  ws.on('message', (raw) => {
    const m = JSON.parse(raw.toString());
    if (m.id != null && pending.has(m.id)) {
      const { resolve, reject } = pending.get(m.id);
      pending.delete(m.id);
      if (m.error) reject(new Error(`${m.error.code}: ${m.error.message}`));
      else resolve(m.result);
    } else if (m.method) {
      const fn = handlers.get(m.method);
      if (fn) fn(m.params, m.sessionId);
    }
  });
  return {
    send(method, params = {}, sessionId) {
      const id = nextId++;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        ws.send(JSON.stringify({ id, method, params, sessionId }));
      });
    },
    on(method, fn) { handlers.set(method, fn); },
    ready() { return new Promise(r => ws.on('open', r)); },
    close() { ws.close(); },
  };
}

// connect() opens the WebSocket, creates a fresh target, attaches a session,
// and enables Page + Runtime. Returns a thin wrapper that auto-applies the
// session_id to every send/eval call.
async function connect(opts = {}) {
  const url = opts.url || 'ws://127.0.0.1:9222/';
  const startUrl = opts.startUrl || 'about:blank';
  const client = makeClient(url);
  await client.ready();
  const { targetId } = await client.send('Target.createTarget', { url: startUrl });
  const { sessionId } = await client.send('Target.attachToTarget', { targetId, flatten: true });
  await client.send('Page.enable', {}, sessionId);
  await client.send('Runtime.enable', {}, sessionId);

  return {
    sessionId,
    targetId,
    raw: client,
    send: (method, params = {}) => client.send(method, params, sessionId),
    on: (method, fn) => client.on(method, fn),
    close: () => client.close(),

    // eval(expr) -> the JS value (returnByValue: true). Throws on JS exception.
    // Auto-retries the post-navigation execution-context race (Lightpanda
    // issue #2187: "-32000 Cannot find default execution context") because
    // every probe hits it the first time it runs `eval` after `navigate`.
    async eval(expression, { awaitPromise = false } = {}) {
      const send = () => client.send('Runtime.evaluate', {
        expression, returnByValue: true, awaitPromise,
      }, sessionId);
      let r;
      try {
        r = await send();
      } catch (e) {
        if (!/Cannot find default execution context/.test(e.message)) throw e;
        await sleep(150);
        r = await send();
      }
      if (r.exceptionDetails) {
        throw new Error(`JS exception: ${r.exceptionDetails.text}`);
      }
      return r.result && r.result.value;
    },

    // navigate(url) -> resolves once Page.loadEventFired OR readyState==='complete',
    // whichever comes first (within ~3s). Lightpanda's loadEventFired is unreliable
    // on complex pages; the readyState fallback covers that.
    //
    // Settling check: do one final eval after the polling loop exits to make sure
    // V8's default execution context has been (re)created. Without this, the
    // first caller-side eval can hit issue #2187 — eval()'s auto-retry covers
    // that, but settling here keeps the probe's exit-code timing predictable.
    async navigate(url) {
      let loaded = false;
      const onLoad = () => { loaded = true; };
      client.on('Page.loadEventFired', onLoad);
      await client.send('Page.navigate', { url }, sessionId);
      for (let i = 0; i < 30; i++) {
        if (loaded) break;
        await sleep(100);
        try {
          const r = await client.send('Runtime.evaluate', {
            expression: 'document.readyState',
            returnByValue: true,
          }, sessionId);
          if (r.result && r.result.value === 'complete') break;
        } catch (e) {
          // Tolerate the post-nav context race during the polling loop;
          // next iteration will retry.
          if (!/Cannot find default execution context/.test(e.message)) throw e;
        }
      }
      // Settle: one extra eval through the auto-retry path so the next caller
      // eval doesn't race a context-recreate.
      await this.eval('1');
    },

    // waitFor(expr, { timeoutMs, intervalMs }) — polls `expr` until truthy or timeout.
    // Returns the final value (truthy on success, falsy on timeout).
    async waitFor(expression, { timeoutMs = 3000, intervalMs = 100 } = {}) {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        const v = await this.eval(expression);
        if (v) return v;
        await sleep(intervalMs);
      }
      return await this.eval(expression);
    },
  };
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

module.exports = { connect, makeClient, sleep };
