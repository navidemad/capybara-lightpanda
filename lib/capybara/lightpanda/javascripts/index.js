(function() {
  if (window._lightpanda) return;

  // --- Turbo activity tracking ---
  // Tracks pending Turbo operations so the driver can wait for Turbo to settle.
  // Inspired by the CapybaraLockstep approach for stabilizing Turbo integration tests.
  // Events are not perfectly symmetrical in Turbo, so we track multiple pairs
  // and use a counter to handle overlapping operations.
  var _pendingTurboOps = 0;
  function _turboStart() { _pendingTurboOps++; }
  function _turboEnd() { if (_pendingTurboOps > 0) _pendingTurboOps--; }

  // Fetch requests (covers Drive, Frames, and Form submission fetches)
  document.addEventListener('turbo:before-fetch-request', _turboStart);
  document.addEventListener('turbo:before-fetch-response', _turboEnd);
  document.addEventListener('turbo:fetch-request-error', _turboEnd);

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
  document.addEventListener('turbo:load', function() { _pendingTurboOps = 0; });

  // ====== XPath 1.0 Evaluator ======

  var XPathEval = (function() {

    // --- Tokenizer ---

    var NODE_TYPES = {text:1, node:1, comment:1, 'processing-instruction':1};

    function tokenize(expr) {
      var toks = [], i = 0, len = expr.length;
      while (i < len) {
        // Skip whitespace
        while (i < len && ' \t\n\r'.indexOf(expr[i]) >= 0) i++;
        if (i >= len) break;
        var c = expr[i];

        // String literals
        if (c === '"' || c === "'") {
          var q = c, s = ++i;
          while (i < len && expr[i] !== q) i++;
          toks.push({t: 'S', v: expr.substring(s, i)});
          i++;
          continue;
        }

        // Numbers: digits or . followed by digit
        if (c >= '0' && c <= '9' || (c === '.' && i + 1 < len && expr[i + 1] >= '0' && expr[i + 1] <= '9')) {
          var s = i;
          while (i < len && expr[i] >= '0' && expr[i] <= '9') i++;
          if (i < len && expr[i] === '.') { i++; while (i < len && expr[i] >= '0' && expr[i] <= '9') i++; }
          toks.push({t: 'D', v: parseFloat(expr.substring(s, i))});
          continue;
        }

        // Double-char operators
        if (i + 1 < len) {
          var c2 = expr[i + 1];
          if (c === '/' && c2 === '/') { toks.push({t: '//'}); i += 2; continue; }
          if (c === ':' && c2 === ':') { toks.push({t: '::'}); i += 2; continue; }
          if (c === '!' && c2 === '=') { toks.push({t: '!='}); i += 2; continue; }
          if (c === '<' && c2 === '=') { toks.push({t: '<='}); i += 2; continue; }
          if (c === '>' && c2 === '=') { toks.push({t: '>='}); i += 2; continue; }
          if (c === '.' && c2 === '.') { toks.push({t: '..'}); i += 2; continue; }
        }

        // Single-char operators
        if ('()[],|=<>+-*$/@.'.indexOf(c) >= 0) { toks.push({t: c}); i++; continue; }

        // Names (NCName, possibly with namespace prefix)
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c === '_') {
          var s = i;
          while (i < len && /[a-zA-Z0-9_\-.]/.test(expr[i])) i++;
          var name = expr.substring(s, i);
          // Check for namespace prefix (name:localname but not name::)
          if (i < len && expr[i] === ':' && (i + 1 >= len || expr[i + 1] !== ':')) {
            i++; // skip :
            if (i < len && expr[i] === '*') { name += ':*'; i++; }
            else { var ls = i; while (i < len && /[a-zA-Z0-9_\-.]/.test(expr[i])) i++; name += ':' + expr.substring(ls, i); }
          }
          toks.push({t: 'N', v: name});
          continue;
        }

        i++; // skip unknown characters
      }
      toks.push({t: 'E'}); // EOF
      return toks;
    }

    // --- Parser ---
    // Recursive descent parser producing an AST from XPath 1.0 tokens.

    function Parser(tokens) { this.tk = tokens; this.p = 0; }

    Parser.prototype.peek = function() { return this.tk[this.p]; };
    Parser.prototype.next = function() { return this.tk[this.p++]; };
    Parser.prototype.expect = function(t) {
      var tok = this.next();
      if (tok.t !== t) throw new Error('XPath parse error: expected ' + t + ', got ' + tok.t);
      return tok;
    };
    Parser.prototype.at = function(t) { return this.peek().t === t; };
    Parser.prototype.match = function(t) { if (this.at(t)) { this.p++; return true; } return false; };
    Parser.prototype.lookahead = function(offset) { return this.tk[this.p + offset] || {t: 'E'}; };

    Parser.prototype.parseExpr = function() { return this.parseOrExpr(); };

    Parser.prototype.parseOrExpr = function() {
      var left = this.parseAndExpr();
      while (this.peek().t === 'N' && this.peek().v === 'or') { this.next(); left = {op: 'or', l: left, r: this.parseAndExpr()}; }
      return left;
    };

    Parser.prototype.parseAndExpr = function() {
      var left = this.parseEqualityExpr();
      while (this.peek().t === 'N' && this.peek().v === 'and') { this.next(); left = {op: 'and', l: left, r: this.parseEqualityExpr()}; }
      return left;
    };

    Parser.prototype.parseEqualityExpr = function() {
      var left = this.parseRelationalExpr();
      while (this.at('=') || this.at('!=')) {
        var op = this.next().t === '=' ? 'eq' : 'neq';
        left = {op: op, l: left, r: this.parseRelationalExpr()};
      }
      return left;
    };

    Parser.prototype.parseRelationalExpr = function() {
      var left = this.parseAdditiveExpr();
      while (true) {
        var t = this.peek().t, op;
        if (t === '<') op = 'lt'; else if (t === '>') op = 'gt'; else if (t === '<=') op = 'lte'; else if (t === '>=') op = 'gte'; else break;
        this.next();
        left = {op: op, l: left, r: this.parseAdditiveExpr()};
      }
      return left;
    };

    Parser.prototype.parseAdditiveExpr = function() {
      var left = this.parseMultExpr();
      while (this.at('+') || this.at('-')) {
        var op = this.next().t === '+' ? 'add' : 'sub';
        left = {op: op, l: left, r: this.parseMultExpr()};
      }
      return left;
    };

    // After a complete unary expression, * is multiply; div/mod are operators
    Parser.prototype.parseMultExpr = function() {
      var left = this.parseUnaryExpr();
      while (true) {
        var t = this.peek(), op;
        if (t.t === '*') op = 'mul';
        else if (t.t === 'N' && t.v === 'div') op = 'div';
        else if (t.t === 'N' && t.v === 'mod') op = 'mod';
        else break;
        this.next();
        left = {op: op, l: left, r: this.parseUnaryExpr()};
      }
      return left;
    };

    Parser.prototype.parseUnaryExpr = function() {
      if (this.at('-')) { this.next(); return {op: 'neg', a: this.parseUnaryExpr()}; }
      return this.parseUnionExpr();
    };

    Parser.prototype.parseUnionExpr = function() {
      var left = this.parsePathExpr();
      while (this.match('|')) { left = {op: 'union', l: left, r: this.parsePathExpr()}; }
      return left;
    };

    // Distinguishes filter expressions (starting with primary) from location paths
    Parser.prototype.parsePathExpr = function() {
      var t = this.peek();

      // Absolute path: / or //
      if (t.t === '/' || t.t === '//') return this.parseAbsPath();

      // Check if this starts a filter expression (primary expr)
      var isFilter = false;
      if (t.t === '(' || t.t === 'S' || t.t === 'D' || t.t === '$') isFilter = true;
      else if (t.t === 'N' && this.lookahead(1).t === '(' && !NODE_TYPES[t.v]) isFilter = true;

      if (isFilter) {
        var primary = this.parsePrimaryExpr();
        // Parse predicates on the filter expression
        while (this.at('[')) { this.next(); var pred = this.parseExpr(); this.expect(']'); primary = {op: 'filt', e: primary, pred: pred}; }
        // Optional / or // after filter
        if (this.at('/') || this.at('//')) {
          var dsl = this.next().t === '//';
          var steps = this.parseRelSteps();
          if (dsl) steps.unshift({ax: 'descendant-or-self', test: {ty: 'type', nt: 'node'}, preds: []});
          return {op: 'fpath', f: primary, steps: steps};
        }
        return primary;
      }

      // Relative location path
      return this.parseRelPath();
    };

    Parser.prototype.parseAbsPath = function() {
      var steps = [];
      if (this.match('//')) {
        steps.push({ax: 'descendant-or-self', test: {ty: 'type', nt: 'node'}, preds: []});
        steps = steps.concat(this.parseRelSteps());
      } else {
        this.expect('/');
        if (this.canStartStep()) steps = this.parseRelSteps();
      }
      return {op: 'path', abs: true, steps: steps};
    };

    Parser.prototype.parseRelPath = function() {
      return {op: 'path', abs: false, steps: this.parseRelSteps()};
    };

    Parser.prototype.parseRelSteps = function() {
      var steps = [this.parseStep()];
      while (this.at('/') || this.at('//')) {
        if (this.next().t === '//') steps.push({ax: 'descendant-or-self', test: {ty: 'type', nt: 'node'}, preds: []});
        steps.push(this.parseStep());
      }
      return steps;
    };

    Parser.prototype.canStartStep = function() {
      var t = this.peek().t;
      return t === 'N' || t === '*' || t === '.' || t === '..' || t === '@';
    };

    Parser.prototype.parseStep = function() {
      // Abbreviated steps
      if (this.match('.')) return {ax: 'self', test: {ty: 'type', nt: 'node'}, preds: []};
      if (this.match('..')) return {ax: 'parent', test: {ty: 'type', nt: 'node'}, preds: []};

      // Determine axis
      var axis = 'child';
      if (this.match('@')) {
        axis = 'attribute';
      } else if (this.peek().t === 'N' && this.lookahead(1).t === '::') {
        axis = this.next().v; this.next(); // consume name and ::
      }

      // Node test
      var test;
      if (this.match('*')) {
        test = {ty: 'name', n: '*'};
      } else if (this.peek().t === 'N') {
        var name = this.peek().v;
        if (NODE_TYPES[name] && this.lookahead(1).t === '(') {
          this.next(); this.next(); // consume name and (
          if (name === 'processing-instruction' && this.at('S')) this.next(); // optional literal
          this.expect(')');
          test = {ty: 'type', nt: name};
        } else {
          this.next();
          test = {ty: 'name', n: name};
        }
      } else {
        throw new Error('XPath parse error: expected node test, got ' + this.peek().t);
      }

      // Predicates
      var preds = [];
      while (this.at('[')) { this.next(); preds.push(this.parseExpr()); this.expect(']'); }

      return {ax: axis, test: test, preds: preds};
    };

    Parser.prototype.parsePrimaryExpr = function() {
      if (this.at('S')) { var v = this.next().v; return {op: 'lit', v: v}; }
      if (this.at('D')) { var v = this.next().v; return {op: 'num', v: v}; }
      if (this.match('$')) { return {op: 'var', v: this.expect('N').v}; }
      if (this.match('(')) { var e = this.parseExpr(); this.expect(')'); return e; }
      if (this.at('N')) {
        var name = this.next().v;
        this.expect('(');
        var args = [];
        if (!this.at(')')) {
          args.push(this.parseExpr());
          while (this.match(',')) args.push(this.parseExpr());
        }
        this.expect(')');
        return {op: 'fn', name: name, args: args};
      }
      throw new Error('XPath parse error: expected primary expression, got ' + this.peek().t);
    };

    // --- Evaluator Utilities ---

    function stringVal(node) {
      if (!node) return '';
      if (node.nodeType === 1 || node.nodeType === 9) return node.textContent || '';
      if (node.nodeType === 2) return node.value || '';
      return node.nodeValue || node.textContent || '';
    }

    function toStr(val) {
      if (Array.isArray(val)) return val.length > 0 ? stringVal(val[0]) : '';
      if (typeof val === 'boolean') return val ? 'true' : 'false';
      if (typeof val === 'number') return isNaN(val) ? 'NaN' : String(val);
      return String(val);
    }

    function toNum(val) {
      if (typeof val === 'number') return val;
      if (typeof val === 'boolean') return val ? 1 : 0;
      if (Array.isArray(val)) val = toStr(val);
      var s = String(val).trim();
      return s === '' ? NaN : Number(s);
    }

    function toBool(val) {
      if (Array.isArray(val)) return val.length > 0;
      if (typeof val === 'string') return val.length > 0;
      if (typeof val === 'number') return val !== 0 && !isNaN(val);
      return Boolean(val);
    }

    // --- Comparison ---

    function cmpOp(a, b, op) {
      switch (op) {
        case 'eq': return a === b;
        case 'neq': return a !== b;
        case 'lt': return a < b;
        case 'gt': return a > b;
        case 'lte': return a <= b;
        case 'gte': return a >= b;
      }
      return false;
    }

    // XPath comparison with type coercion rules per spec section 3.4
    function xCmp(left, right, op) {
      var isEq = (op === 'eq' || op === 'neq');
      var lArr = Array.isArray(left), rArr = Array.isArray(right);

      // Both node-sets
      if (lArr && rArr) {
        for (var i = 0; i < left.length; i++) {
          var lv = stringVal(left[i]);
          for (var j = 0; j < right.length; j++) {
            if (isEq ? cmpOp(lv, stringVal(right[j]), op) : cmpOp(toNum(lv), toNum(stringVal(right[j])), op)) return true;
          }
        }
        return false;
      }

      // One node-set, one scalar
      if (lArr || rArr) {
        var ns = lArr ? left : right, other = lArr ? right : left, nsLeft = lArr;

        // Boolean comparison: convert node-set to boolean
        if (typeof other === 'boolean') {
          var b = ns.length > 0;
          return cmpOp(nsLeft ? b : other, nsLeft ? other : b, op);
        }

        for (var i = 0; i < ns.length; i++) {
          var sv = stringVal(ns[i]);
          var a, b;
          if (typeof other === 'number') {
            a = nsLeft ? toNum(sv) : other;
            b = nsLeft ? other : toNum(sv);
          } else if (isEq) {
            a = nsLeft ? sv : String(other);
            b = nsLeft ? String(other) : sv;
          } else {
            a = nsLeft ? toNum(sv) : toNum(String(other));
            b = nsLeft ? toNum(String(other)) : toNum(sv);
          }
          if (cmpOp(a, b, op)) return true;
        }
        return false;
      }

      // Neither is a node-set
      if (isEq) {
        if (typeof left === 'boolean' || typeof right === 'boolean') return cmpOp(toBool(left), toBool(right), op);
        if (typeof left === 'number' || typeof right === 'number') return cmpOp(toNum(left), toNum(right), op);
        return cmpOp(toStr(left), toStr(right), op);
      }
      return cmpOp(toNum(left), toNum(right), op);
    }

    // --- Axis Traversal ---

    function addDesc(node, out) {
      var c = node.firstChild;
      while (c) { out.push(c); addDesc(c, out); c = c.nextSibling; }
    }

    function addFollowing(node, out) {
      var n = node;
      while (n) {
        var s = n.nextSibling;
        while (s) { out.push(s); addDesc(s, out); s = s.nextSibling; }
        n = n.parentNode;
      }
    }

    function addPrecedingSubtree(node, out) {
      var c = node.lastChild;
      while (c) { addPrecedingSubtree(c, out); c = c.previousSibling; }
      out.push(node);
    }

    function addPreceding(node, out) {
      var n = node;
      while (n.parentNode) {
        var s = n.previousSibling;
        while (s) { addPrecedingSubtree(s, out); s = s.previousSibling; }
        n = n.parentNode;
      }
    }

    function getAxisNodes(node, axis) {
      var out = [], c, p;
      switch (axis) {
        case 'child':
          c = node.firstChild; while (c) { out.push(c); c = c.nextSibling; } break;
        case 'descendant':
          addDesc(node, out); break;
        case 'descendant-or-self':
          out.push(node); addDesc(node, out); break;
        case 'self':
          out.push(node); break;
        case 'parent':
          if (node.parentNode) out.push(node.parentNode); break;
        case 'ancestor':
          p = node.parentNode; while (p) { out.push(p); p = p.parentNode; } break;
        case 'ancestor-or-self':
          out.push(node); p = node.parentNode; while (p) { out.push(p); p = p.parentNode; } break;
        case 'following-sibling':
          c = node.nextSibling; while (c) { out.push(c); c = c.nextSibling; } break;
        case 'preceding-sibling':
          c = node.previousSibling; while (c) { out.push(c); c = c.previousSibling; } break;
        case 'following':
          addFollowing(node, out); break;
        case 'preceding':
          addPreceding(node, out); break;
        case 'attribute':
          if (node.attributes) { for (var i = 0; i < node.attributes.length; i++) out.push(node.attributes[i]); } break;
        case 'namespace':
          break; // stub
      }
      return out;
    }

    // --- Node Test Matching ---

    function matchTest(node, test, axis) {
      if (test.ty === 'type') {
        switch (test.nt) {
          case 'node': return true;
          case 'text': return node.nodeType === 3;
          case 'comment': return node.nodeType === 8;
          case 'processing-instruction': return node.nodeType === 7;
        }
        return false;
      }
      // Name test
      if (axis === 'attribute') {
        return test.n === '*' || (node.name || node.nodeName || '').toLowerCase() === test.n.toLowerCase();
      }
      if (node.nodeType !== 1) return false;
      if (test.n === '*') return true;
      return node.nodeName.toLowerCase() === test.n.toLowerCase();
    }

    // --- Step Evaluation ---

    function evalStep(ctxNodes, step) {
      var result = [];
      for (var i = 0; i < ctxNodes.length; i++) {
        var axNodes = getAxisNodes(ctxNodes[i], step.ax);
        // Filter by node test
        var filtered = [];
        for (var j = 0; j < axNodes.length; j++) {
          if (matchTest(axNodes[j], step.test, step.ax)) filtered.push(axNodes[j]);
        }
        // Apply predicates
        var cur = filtered;
        for (var p = 0; p < step.preds.length; p++) {
          var newCur = [], sz = cur.length;
          for (var k = 0; k < cur.length; k++) {
            var val = evaluate(step.preds[p], cur[k], k + 1, sz);
            if (typeof val === 'number') { if (val === k + 1) newCur.push(cur[k]); }
            else { if (toBool(val)) newCur.push(cur[k]); }
          }
          cur = newCur;
        }
        // Add to result, dedup
        for (var k = 0; k < cur.length; k++) {
          if (result.indexOf(cur[k]) < 0) result.push(cur[k]);
        }
      }
      return result;
    }

    // --- Document Order Sort ---

    function sortDocOrder(nodes) {
      if (nodes.length <= 1) return nodes;
      if (nodes[0] && typeof nodes[0].compareDocumentPosition === 'function') {
        return nodes.sort(function(a, b) {
          if (a === b) return 0;
          var pos = a.compareDocumentPosition(b);
          return (pos & 4) ? -1 : (pos & 2) ? 1 : 0;
        });
      }
      return nodes;
    }

    // --- AST Evaluation ---

    function evaluate(ast, ctx, pos, size) {
      if (!ast || !ast.op) {
        // Step node (from path parsing)
        if (ast && ast.ax) return evalStep([ctx], ast);
        throw new Error('XPath eval error: invalid AST node');
      }

      switch (ast.op) {
        case 'path': {
          var nodes;
          if (ast.abs) {
            nodes = [ctx.nodeType === 9 ? ctx : (ctx.ownerDocument || ctx)];
          } else {
            nodes = [ctx];
          }
          for (var i = 0; i < ast.steps.length; i++) nodes = evalStep(nodes, ast.steps[i]);
          return nodes;
        }

        case 'fpath': {
          var base = evaluate(ast.f, ctx, pos, size);
          if (!Array.isArray(base)) return base;
          for (var i = 0; i < ast.steps.length; i++) base = evalStep(base, ast.steps[i]);
          return base;
        }

        case 'filt': {
          var base = evaluate(ast.e, ctx, pos, size);
          if (!Array.isArray(base)) return base;
          var out = [], sz = base.length;
          for (var i = 0; i < base.length; i++) {
            var val = evaluate(ast.pred, base[i], i + 1, sz);
            if (typeof val === 'number') { if (val === i + 1) out.push(base[i]); }
            else { if (toBool(val)) out.push(base[i]); }
          }
          return out;
        }

        case 'or': return toBool(evaluate(ast.l, ctx, pos, size)) || toBool(evaluate(ast.r, ctx, pos, size));
        case 'and': return toBool(evaluate(ast.l, ctx, pos, size)) && toBool(evaluate(ast.r, ctx, pos, size));

        case 'eq': case 'neq': case 'lt': case 'gt': case 'lte': case 'gte':
          return xCmp(evaluate(ast.l, ctx, pos, size), evaluate(ast.r, ctx, pos, size), ast.op);

        case 'add': return toNum(evaluate(ast.l, ctx, pos, size)) + toNum(evaluate(ast.r, ctx, pos, size));
        case 'sub': return toNum(evaluate(ast.l, ctx, pos, size)) - toNum(evaluate(ast.r, ctx, pos, size));
        case 'mul': return toNum(evaluate(ast.l, ctx, pos, size)) * toNum(evaluate(ast.r, ctx, pos, size));
        case 'div': return toNum(evaluate(ast.l, ctx, pos, size)) / toNum(evaluate(ast.r, ctx, pos, size));
        case 'mod': return toNum(evaluate(ast.l, ctx, pos, size)) % toNum(evaluate(ast.r, ctx, pos, size));
        case 'neg': return -toNum(evaluate(ast.a, ctx, pos, size));

        case 'union': {
          var l = evaluate(ast.l, ctx, pos, size), r = evaluate(ast.r, ctx, pos, size);
          if (!Array.isArray(l) || !Array.isArray(r)) throw new Error('Union requires node-sets');
          var merged = l.slice();
          for (var i = 0; i < r.length; i++) { if (merged.indexOf(r[i]) < 0) merged.push(r[i]); }
          return sortDocOrder(merged);
        }

        case 'lit': return ast.v;
        case 'num': return ast.v;
        case 'var': return '';
        case 'fn': return evalFunc(ast.name, ast.args, ctx, pos, size);
      }

      throw new Error('XPath eval error: unknown op ' + ast.op);
    }

    // --- XPath Functions ---

    function evalFunc(name, args, ctx, pos, size) {
      switch (name) {
        // -- Node-set functions --
        case 'position': return pos;
        case 'last': return size;
        case 'count': {
          var ns = evaluate(args[0], ctx, pos, size);
          return Array.isArray(ns) ? ns.length : 0;
        }
        case 'id': {
          var val = evaluate(args[0], ctx, pos, size);
          var idStr;
          if (Array.isArray(val)) { idStr = []; for (var i = 0; i < val.length; i++) idStr.push(stringVal(val[i])); idStr = idStr.join(' '); }
          else idStr = toStr(val);
          var ids = idStr.split(/\s+/), doc = ctx.ownerDocument || ctx, nodes = [];
          for (var i = 0; i < ids.length; i++) {
            if (ids[i]) { var el = doc.getElementById(ids[i]); if (el && nodes.indexOf(el) < 0) nodes.push(el); }
          }
          return nodes;
        }
        case 'local-name': {
          var ns = args.length === 0 ? [ctx] : evaluate(args[0], ctx, pos, size);
          if (!Array.isArray(ns) || ns.length === 0) return '';
          return (ns[0].localName || ns[0].nodeName || '').toLowerCase();
        }
        case 'name': case 'namespace-uri': {
          if (name === 'namespace-uri') return '';
          var ns = args.length === 0 ? [ctx] : evaluate(args[0], ctx, pos, size);
          if (!Array.isArray(ns) || ns.length === 0) return '';
          return (ns[0].nodeName || '').toLowerCase();
        }

        // -- String functions --
        case 'string':
          return args.length === 0 ? stringVal(ctx) : toStr(evaluate(args[0], ctx, pos, size));
        case 'concat': {
          var r = '';
          for (var i = 0; i < args.length; i++) r += toStr(evaluate(args[i], ctx, pos, size));
          return r;
        }
        case 'contains': {
          var s1 = toStr(evaluate(args[0], ctx, pos, size));
          var s2 = toStr(evaluate(args[1], ctx, pos, size));
          return s1.indexOf(s2) >= 0;
        }
        case 'starts-with': {
          var s1 = toStr(evaluate(args[0], ctx, pos, size));
          var s2 = toStr(evaluate(args[1], ctx, pos, size));
          return s1.indexOf(s2) === 0;
        }
        case 'substring': {
          var s = toStr(evaluate(args[0], ctx, pos, size));
          var start = Math.round(toNum(evaluate(args[1], ctx, pos, size)));
          if (isNaN(start)) return '';
          if (args.length >= 3) {
            var len = Math.round(toNum(evaluate(args[2], ctx, pos, size)));
            if (isNaN(len)) return '';
            var si = Math.max(start - 1, 0), ei = Math.min(start - 1 + len, s.length);
            return si >= ei ? '' : s.substring(si, ei);
          }
          return s.substring(Math.max(start - 1, 0));
        }
        case 'substring-before': {
          var s1 = toStr(evaluate(args[0], ctx, pos, size));
          var s2 = toStr(evaluate(args[1], ctx, pos, size));
          var idx = s1.indexOf(s2);
          return idx >= 0 ? s1.substring(0, idx) : '';
        }
        case 'substring-after': {
          var s1 = toStr(evaluate(args[0], ctx, pos, size));
          var s2 = toStr(evaluate(args[1], ctx, pos, size));
          var idx = s1.indexOf(s2);
          return idx >= 0 ? s1.substring(idx + s2.length) : '';
        }
        case 'string-length': {
          var s = args.length === 0 ? stringVal(ctx) : toStr(evaluate(args[0], ctx, pos, size));
          return s.length;
        }
        case 'normalize-space': {
          var s = args.length === 0 ? stringVal(ctx) : toStr(evaluate(args[0], ctx, pos, size));
          return s.replace(/^\s+|\s+$/g, '').replace(/\s+/g, ' ');
        }
        case 'translate': {
          var s = toStr(evaluate(args[0], ctx, pos, size));
          var from = toStr(evaluate(args[1], ctx, pos, size));
          var to = toStr(evaluate(args[2], ctx, pos, size));
          var r = '';
          for (var i = 0; i < s.length; i++) {
            var idx = from.indexOf(s[i]);
            if (idx < 0) r += s[i];
            else if (idx < to.length) r += to[idx];
            // else: character removed
          }
          return r;
        }

        // -- Boolean functions --
        case 'boolean': return toBool(evaluate(args[0], ctx, pos, size));
        case 'not': return !toBool(evaluate(args[0], ctx, pos, size));
        case 'true': return true;
        case 'false': return false;
        case 'lang': return false; // stub

        // -- Number functions --
        case 'number':
          return args.length === 0 ? toNum(stringVal(ctx)) : toNum(evaluate(args[0], ctx, pos, size));
        case 'sum': {
          var ns = evaluate(args[0], ctx, pos, size);
          if (!Array.isArray(ns)) return NaN;
          var total = 0;
          for (var i = 0; i < ns.length; i++) total += toNum(stringVal(ns[i]));
          return total;
        }
        case 'floor': return Math.floor(toNum(evaluate(args[0], ctx, pos, size)));
        case 'ceiling': return Math.ceil(toNum(evaluate(args[0], ctx, pos, size)));
        case 'round': {
          var n = toNum(evaluate(args[0], ctx, pos, size));
          if (isNaN(n) || !isFinite(n)) return n;
          return Math.round(n);
        }
      }
      throw new Error('XPath error: unknown function ' + name + '()');
    }

    // --- Public API ---
    return {
      find: function(expression, contextNode) {
        var tokens = tokenize(expression);
        var parser = new Parser(tokens);
        var ast = parser.parseExpr();
        var result = evaluate(ast, contextNode, 1, 1);
        return Array.isArray(result) ? result : [];
      }
    };
  })();

  // --- Main API ---

  window._lightpanda = {
    xpathFind: function(expression, contextNode) {
      // Use native XPath if available (non-polyfilled)
      if (typeof contextNode.evaluate === 'function' && typeof XPathResult !== 'undefined' &&
          !XPathResult._polyfilled) {
        try {
          var result = contextNode.evaluate(expression, contextNode, null,
            XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
          var nodes = [];
          for (var i = 0; i < result.snapshotLength; i++) {
            nodes.push(result.snapshotItem(i));
          }
          return nodes;
        } catch(e) {
          // Fall through to polyfill
        }
      }

      try {
        return XPathEval.find(expression, contextNode);
      } catch(e) {
        return [];
      }
    },

    turbo: {
      pending: function() { return _pendingTurboOps; },
      idle: function() { return _pendingTurboOps <= 0; }
    }
  };

  // --- XPathResult polyfill ---

  if (typeof XPathResult === 'undefined') {
    window.XPathResult = {
      ORDERED_NODE_SNAPSHOT_TYPE: 7,
      FIRST_ORDERED_NODE_TYPE: 9,
      _polyfilled: true
    };
  }
  if (!document.evaluate) {
    document.evaluate = function(expression, contextNode) {
      var nodes = window._lightpanda.xpathFind(expression, contextNode);
      return {
        snapshotLength: nodes.length,
        snapshotItem: function(i) { return nodes[i] || null; },
        singleNodeValue: nodes[0] || null
      };
    };
  }

  // --- requestSubmit polyfill ---
  // Required for Turbo form interception. Turbo listens for the `submit` event,
  // but form.submit() doesn't fire it. requestSubmit() does.

  if (typeof HTMLFormElement !== 'undefined' && !HTMLFormElement.prototype.requestSubmit) {
    HTMLFormElement.prototype.requestSubmit = function(submitter) {
      if (submitter) {
        var validTypes = {submit: 1, image: 1};
        if (!validTypes[(submitter.type || '').toLowerCase()]) {
          throw new TypeError('The specified element is not a submit button.');
        }
        if (submitter.form !== this) {
          throw new DOMException('The specified element is not owned by this form element.', 'NotFoundError');
        }
      }
      var event;
      if (typeof SubmitEvent === 'function') {
        event = new SubmitEvent('submit', {bubbles: true, cancelable: true, submitter: submitter || null});
      } else {
        event = new Event('submit', {bubbles: true, cancelable: true});
        event.submitter = submitter || null;
      }
      if (this.dispatchEvent(event)) {
        this.submit();
      }
    };
  }
})();
