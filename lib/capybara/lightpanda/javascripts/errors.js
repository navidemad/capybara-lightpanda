// --- Uncaught page errors ---
// Lightpanda implements no `Runtime.exceptionThrown` (upstream gap, wishlist
// B19), so an uncaught exception in page JS reaches no CDP client at all. It is
// invisible to console_logs, which only ever sees explicit console.* calls, so
// a handler that dies on a TypeError leaves no trace and the failure surfaces
// far away as ElementNotFound on whatever it was supposed to produce. That is
// the exact shape of the solidus taxon-tree failure in real-apps causes.yml.
//
// These listeners are passive — no preventDefault, so nothing the page would
// otherwise see is swallowed, and nothing that would have propagated stops
// propagating. They re-emit through the same console.debug sentinel channel
// turbo.js uses, and console.rb routes them into Browser#page_errors rather
// than #console_logs. Keeping the two apart is deliberate: console_logs stays
// "the console.* calls the page made", which is what Chrome models (an
// exception is exceptionThrown, not consoleAPICalled) and what Playwright and
// Puppeteer expose (pageerror, separate from console). Folding exceptions into
// console_logs would also break every suite already asserting that buffer is
// free of errors.
//
// Delete this file once upstream emits Runtime.exceptionThrown and the floor
// covers it: subscribe Browser::Console to that event and feed the same buffer.
function _reportPageError(fields) {
  try {
    console.debug('__lightpanda_page_error_' + JSON.stringify(fields));
  } catch (e) {
    // A field that won't serialize (a getter that throws, a cyclic `reason`)
    // must not turn one page error into two, so report the kind and move on.
    try {
      console.debug('__lightpanda_page_error_' + JSON.stringify({
        kind: fields && fields.kind ? fields.kind : 'error',
        message: '(page error could not be serialized)'
      }));
    } catch (e2) {}
  }
}

window.addEventListener('error', function (e) {
  // A failed <img>/<script>/<link> fetch fires `error` too, but on the element
  // and without bubbling, so it shouldn't reach this listener. Guard anyway
  // (Lightpanda's dispatch need not match Chrome's exactly) and identify those
  // by their missing string `message` — a resource failure is a network fact
  // and Network#traffic already carries it.
  if (!e || typeof e.message !== 'string') return;

  _reportPageError({
    kind: 'error',
    message: e.message,
    url: typeof e.filename === 'string' ? e.filename : '',
    line: typeof e.lineno === 'number' ? e.lineno : null,
    column: typeof e.colno === 'number' ? e.colno : null,
    // Cap the stack: it rides a console argument over the CDP WebSocket, and a
    // deep recursion stack can be megabytes.
    stack: e.error && typeof e.error.stack === 'string' ? e.error.stack.slice(0, 4000) : null
  });
});

window.addEventListener('unhandledrejection', function (e) {
  var reason = e ? e.reason : null;
  var message;
  try {
    message = reason && reason.message ? String(reason.message) : String(reason);
  } catch (err) {
    message = '(rejection reason could not be stringified)';
  }

  _reportPageError({
    kind: 'unhandledrejection',
    message: message,
    url: '',
    line: null,
    column: null,
    stack: reason && typeof reason.stack === 'string' ? reason.stack.slice(0, 4000) : null
  });
});
