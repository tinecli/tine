// Runtime shims so the Fig engine runs in JavaScriptCore (bare JSC has ECMAScript
// only — no Web/Node globals). Baked into the bundle via esbuild --inject, so it
// runs before any engine code. Uses globalThis.* (not `var`) because --inject
// wraps this as a module.
//
// Provided separately by the host: __tineReadFile, __tineRun, __tineSpecsDir.
//
// KNOWN gaps, add when a spec needs them:
//   - fetch: network-based custom generators (npm search, some cloud APIs). Needs
//     a Swift URLSession bridge; fails gracefully until then.
//   - URL:   full parser; no engine code constructs one, so unshimmed.

if (typeof globalThis.self === "undefined") globalThis.self = globalThis;
if (typeof globalThis.global === "undefined") globalThis.global = globalThis;

if (typeof globalThis.window === "undefined") {
  globalThis.window = {
    location: { protocol: "file:" },
    addEventListener: () => {},
    removeEventListener: () => {},
  };
}
if (typeof globalThis.document === "undefined") {
  globalThis.document = {
    addEventListener: () => {},
    removeEventListener: () => {},
  };
}
if (typeof globalThis.process === "undefined") {
  globalThis.process = {
    env: {},
    platform: "darwin",
    argv: [],
    cwd: () => "/",
  };
}
if (typeof globalThis.performance === "undefined") {
  globalThis.performance = { now: () => Date.now() };
}
if (typeof globalThis.console === "undefined") {
  var _noop = () => {};
  globalThis.console = {
    log: _noop,
    info: _noop,
    debug: _noop,
    warn: _noop,
    error: _noop,
    trace: _noop,
  };
}

// In-memory storage (some code touches localStorage for caching/flags).
if (typeof globalThis.localStorage === "undefined") {
  var _ls = Object.create(null);
  globalThis.localStorage = {
    getItem: (k) => (k in _ls ? _ls[k] : null),
    setItem: (k, v) => {
      _ls[k] = String(v);
    },
    removeItem: (k) => {
      delete _ls[k];
    },
    clear: () => {
      _ls = Object.create(null);
    },
  };
  globalThis.sessionStorage = globalThis.localStorage;
}

// base64 (Web APIs, not in ECMAScript).
if (typeof globalThis.btoa === "undefined") {
  var _b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  globalThis.btoa = (s) => {
    var out = "",
      i = 0;
    while (i < s.length) {
      var c1 = s.charCodeAt(i++),
        c2 = s.charCodeAt(i++),
        c3 = s.charCodeAt(i++);
      out +=
        _b64[c1 >> 2] +
        _b64[((c1 & 3) << 4) | (c2 >> 4)] +
        (Number.isNaN(c2) ? "=" : _b64[((c2 & 15) << 2) | (c3 >> 6)]) +
        (Number.isNaN(c3) ? "=" : _b64[c3 & 63]);
    }
    return out;
  };
  globalThis.atob = (s) => {
    s = s.replace(/=+$/, "");
    var out = "",
      bits = 0,
      buf = 0;
    for (var i = 0; i < s.length; i++) {
      buf = (buf << 6) | _b64.indexOf(s[i]);
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out += String.fromCharCode((buf >> bits) & 0xff);
      }
    }
    return out;
  };
}

// JSC has no timers. No-op: raced timeouts never fire, so synchronous work wins.
if (typeof globalThis.setTimeout === "undefined") {
  globalThis.setTimeout = () => 0;
  globalThis.clearTimeout = () => {};
  globalThis.setInterval = () => 0;
  globalThis.clearInterval = () => {};
}

// UTF-8 TextEncoder/Decoder.
if (typeof globalThis.TextEncoder === "undefined") {
  globalThis.TextEncoder = function TextEncoder() {};
  globalThis.TextEncoder.prototype.encode = (str) => {
    var u = [];
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);
      if (c < 0x80) u.push(c);
      else if (c < 0x800) u.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
      else if (c >= 0xd800 && c < 0xdc00) {
        var c2 = str.charCodeAt(++i);
        var cp = 0x10000 + (((c & 0x3ff) << 10) | (c2 & 0x3ff));
        u.push(
          0xf0 | (cp >> 18),
          0x80 | ((cp >> 12) & 0x3f),
          0x80 | ((cp >> 6) & 0x3f),
          0x80 | (cp & 0x3f),
        );
      } else
        u.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    }
    return new Uint8Array(u);
  };
  globalThis.TextDecoder = function TextDecoder() {};
  globalThis.TextDecoder.prototype.decode = (buf) => {
    var a = new Uint8Array(buf.buffer || buf),
      s = "",
      i = 0;
    while (i < a.length) {
      var c = a[i++];
      if (c < 0x80) s += String.fromCharCode(c);
      else if (c < 0xe0)
        s += String.fromCharCode(((c & 0x1f) << 6) | (a[i++] & 0x3f));
      else if (c < 0xf0)
        s += String.fromCharCode(
          ((c & 0xf) << 12) | ((a[i++] & 0x3f) << 6) | (a[i++] & 0x3f),
        );
      else {
        var cp =
          ((c & 0x7) << 18) |
          ((a[i++] & 0x3f) << 12) |
          ((a[i++] & 0x3f) << 6) |
          (a[i++] & 0x3f);
        cp -= 0x10000;
        s += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
      }
    }
    return s;
  };
}
