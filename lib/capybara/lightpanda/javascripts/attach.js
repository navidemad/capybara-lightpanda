// --- Public surface ---
// The one place that names window._lightpanda. References the function/var
// declarations from turbo.js and predicates.js (hoisted into the same IIFE
// scope by AutoScripts). Runs last in the concatenation order.
window._lightpanda = {
  turbo: {
    pending: function() { return _pendingTurboOps; },
    idle: function() { return _pendingTurboOps <= 0; }
  },

  isVisible: isVisible,
  isObscured: isObscured,
  isDisabled: isDisabled,
  isContentEditable: isContentEditable,
  isDraggable: isDraggable,
  visibleText: visibleText
};
