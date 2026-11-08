// --- Turbo activity tracking ---
// Tracks pending Turbo operations so the driver can wait for Turbo to settle.
// Inspired by the CapybaraLockstep approach for stabilizing Turbo integration tests.
// Events are not perfectly symmetrical in Turbo, so we track multiple pairs
// and use a counter to handle overlapping operations.
//
// Transitions across 0 emit `__lightpanda_turbo_busy` / `__lightpanda_turbo_idle`
// sentinels via console.debug. Browser#wait_for_turbo subscribes to those
// sentinels (Runtime.consoleAPICalled) and toggles a Concurrent::Event so the
// Ruby side can wait event-driven instead of polling.
//
// Pages without Turbo never trigger _turboStart, so no sentinels fire and the
// Ruby Event stays set (idle by default) — wait_for_turbo returns immediately.
var _pendingTurboOps = 0;
function _signalTurbo(state) {
  try { console.debug('__lightpanda_turbo_' + state); } catch (e) {}
}
function _turboStart() {
  _pendingTurboOps++;
  if (_pendingTurboOps === 1) _signalTurbo('busy');
}
function _turboEnd() {
  if (_pendingTurboOps > 0) {
    _pendingTurboOps--;
    if (_pendingTurboOps === 0) _signalTurbo('idle');
  }
}

// Fetch requests (covers Drive, Frames, and Form submission fetches).
//
// A fetch ends in one of three ways, and must be counted out exactly once:
// a response (turbo:before-fetch-response), a network error
// (turbo:fetch-request-error) or an abort. Turbo aborts fetches routinely — a
// frame whose src is removed or replaced, a visit superseded by another, a
// stopped form submission — and swallows the AbortError without dispatching
// either event (FetchRequest#perform), so the abort signal is the only trace.
// Counting on the two events alone left the counter stuck above zero and every
// later driver action waiting out its full timeout.
//
// Each fetch gets a token. The response and error events carry the request's
// target, not the request, so they close the oldest open token for that target;
// the abort listener closes its own token, and a token closes once — an abort
// after the response has been counted is a no-op.
var _turboFetches = [];
function _turboFetchEnd(token) {
  if (!token.open) return;
  token.open = false;
  var index = _turboFetches.indexOf(token);
  if (index !== -1) _turboFetches.splice(index, 1);
  _turboEnd();
}
function _turboFetchSettled(event) {
  for (var i = 0; i < _turboFetches.length; i++) {
    if (_turboFetches[i].target === event.target) return _turboFetchEnd(_turboFetches[i]);
  }
}
document.addEventListener('turbo:before-fetch-request', function(event) {
  var token = { target: event.target, open: true };
  _turboFetches.push(token);
  _turboStart();
  var options = event.detail && event.detail.fetchOptions;
  var signal = options && options.signal;
  if (signal && typeof signal.addEventListener === 'function') {
    if (signal.aborted) {
      _turboFetchEnd(token);
    } else {
      signal.addEventListener('abort', function() { _turboFetchEnd(token); });
    }
  }
});
document.addEventListener('turbo:before-fetch-response', _turboFetchSettled);
document.addEventListener('turbo:fetch-request-error', _turboFetchSettled);

// Form submissions (can outlast their underlying fetch)
document.addEventListener('turbo:submit-start', _turboStart);
document.addEventListener('turbo:submit-end', _turboEnd);

// Frame rendering (can outlast the fetch that triggered it)
document.addEventListener('turbo:before-frame-render', _turboStart);
document.addEventListener('turbo:frame-render', _turboEnd);

// Stream rendering (no symmetric end event — wrap the render function)
document.addEventListener('turbo:before-stream-render', function(event) {
  _turboStart();
  if (event.detail && event.detail.render) {
    var originalRender = event.detail.render;
    event.detail.render = function(streamElement) {
      var result = originalRender(streamElement);
      if (result && typeof result.then === 'function') {
        return result.finally(_turboEnd);
      }
      _turboEnd();
      return result;
    };
  } else {
    _turboEnd();
  }
});

// Drive page visits: turbo:load fires after the page is fully rendered.
// Also serves as a safety reset — clears any counter leaks from aborted fetches.
// Always re-signal idle so the Ruby Event re-arms even if some `_turboEnd`
// call dropped on the floor mid-navigation.
document.addEventListener('turbo:load', function() {
  _pendingTurboOps = 0;
  // Forget open fetches too: their late abort/response must not count down
  // operations that started after this reset.
  for (var i = 0; i < _turboFetches.length; i++) _turboFetches[i].open = false;
  _turboFetches = [];
  _signalTurbo('idle');
});
