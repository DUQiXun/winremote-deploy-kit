#!/usr/bin/env node
/**
 * winremote-relay — a session-stable HTTP relay for winremote-mcp.
 *
 * Why this exists
 * ---------------
 * winremote-mcp speaks MCP "streamable HTTP". Every time the server process
 * restarts, all in-memory MCP sessions are dropped. A normal MCP client keeps
 * sending its old `mcp-session-id`, gets `400 {"error":"Session not found"}`,
 * and — because the HTTP transport never closes — never re-initialises.
 * The result is a client that looks connected but can't call a single tool
 * until the whole host application is restarted.
 *
 * This relay sits between the client and one or more winremote-mcp endpoints:
 *
 *   client ──► relay (stable local URL) ──► best available target
 *
 *   * re-resolves hostnames on every request, so DHCP / bridged-network IP
 *     changes are invisible to the client
 *   * transparently re-runs `initialize` when the upstream session died, then
 *     replays the original request once
 *   * fails over through an ordered target list (e.g. interactive instance
 *     first, headless always-on instance second)
 *
 * Usage
 * -----
 *   node winremote-relay.js \
 *     --listen 127.0.0.1:8091 \
 *     --target DESKTOP-ABC:8090,DESKTOP-ABC:8095,10.0.0.5:8090 \
 *     --auth-key "$WINREMOTE_AUTH_KEY" \
 *     --timeout 60000
 *
 * Environment fallbacks: WINREMOTE_AUTH_KEY, WINREMOTE_LISTEN, WINREMOTE_TARGETS
 *
 * Zero dependencies. Node >= 18.
 */

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------- arguments

function parseArgs(argv) {
  const out = {};
  for (let i = 2; i < argv.length; i += 2) {
    const k = argv[i];
    if (!k || !k.startsWith('--')) continue;
    out[k.slice(2)] = argv[i + 1];
  }
  return out;
}

const args = parseArgs(process.argv);

const listenSpec = args.listen || process.env.WINREMOTE_LISTEN || '127.0.0.1:8091';
const [LISTEN_HOST, LISTEN_PORT_RAW] = listenSpec.includes(':')
  ? [listenSpec.slice(0, listenSpec.lastIndexOf(':')), listenSpec.slice(listenSpec.lastIndexOf(':') + 1)]
  : ['127.0.0.1', listenSpec];
const LISTEN_PORT = Number(LISTEN_PORT_RAW);

const AUTH_KEY = args['auth-key'] || process.env.WINREMOTE_AUTH_KEY || '';
if (!AUTH_KEY) {
  console.error('fatal: --auth-key (or WINREMOTE_AUTH_KEY) is required');
  process.exit(2);
}

const targetSpec = args.target || process.env.WINREMOTE_TARGETS || '';
const TARGETS = targetSpec
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)
  .map((s) => {
    const i = s.lastIndexOf(':');
    return { host: s.slice(0, i), port: Number(s.slice(i + 1)), label: s };
  });
if (TARGETS.length === 0) {
  console.error('fatal: --target host:port[,host:port...] is required');
  process.exit(2);
}

const TIMEOUT_MS = Number(args.timeout || 60000);
const TARGET_PATH = args.path || '/mcp';
const PROTOCOL_VERSION = args.protocol || '2025-06-18';
const LOG_PATH = args.log || path.join(__dirname, 'relay.log');
const VERBOSE = process.argv.includes('--verbose');

// -------------------------------------------------------------------- state

let upstreamSession = null; // current upstream mcp-session-id
let activeTarget = 0;       // index into TARGETS
let bootstrapPromise = null;

// -------------------------------------------------------------------- utils

function log(...parts) {
  const line = new Date().toISOString() + '  ' + parts.join(' ');
  try { fs.appendFileSync(LOG_PATH, line + '\n'); } catch { /* log is best-effort */ }
  if (VERBOSE) console.log(line);
}

function upstreamHeaders(overrides = {}) {
  const h = {
    'Content-Type': 'application/json',
    Accept: 'application/json, text/event-stream',
    Authorization: 'Bearer ' + AUTH_KEY,
    ...overrides,
  };
  if (upstreamSession) h['mcp-session-id'] = upstreamSession;
  return h;
}

/** POST to one target, buffering the response. Resolves {status, headers, body}. */
function post(target, bodyBuf, overrides) {
  return new Promise((resolve, reject) => {
    const headers = { ...upstreamHeaders(overrides), 'Content-Length': Buffer.byteLength(bodyBuf) };
    // Empty value == "do not send this header" (an empty mcp-session-id is
    // treated as an invalid session by the server).
    for (const k of Object.keys(headers)) {
      if (headers[k] === '' || headers[k] == null) delete headers[k];
    }
    const req = http.request(
      { host: target.host, port: target.port, path: TARGET_PATH, method: 'POST', headers, timeout: TIMEOUT_MS },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
      },
    );
    req.on('error', reject);
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.end(bodyBuf);
  });
}

/** Establish a fresh upstream session. Returns the new session id or null. */
function bootstrap() {
  if (bootstrapPromise) return bootstrapPromise;
  bootstrapPromise = (async () => {
    for (let attempt = 0; attempt < TARGETS.length * 2; attempt++) {
      const target = TARGETS[activeTarget];
      try {
        const init = Buffer.from(JSON.stringify({
          jsonrpc: '2.0',
          id: 'relay-init',
          method: 'initialize',
          params: {
            protocolVersion: PROTOCOL_VERSION,
            capabilities: {},
            clientInfo: { name: 'winremote-relay', version: '1.0' },
          },
        }));
        const res = await post(target, init, { 'mcp-session-id': '' });
        const sid = res.headers['mcp-session-id'];
        if (sid) {
          upstreamSession = sid;
          try {
            await post(target, Buffer.from(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' })));
          } catch { /* notification is advisory */ }
          log('bootstrap ok target=' + target.label + ' session=' + sid);
          return sid;
        }
        log('bootstrap: no session header target=' + target.label + ' status=' + res.status);
      } catch (e) {
        log('bootstrap failed target=' + target.label + ': ' + e.message);
      }
      activeTarget = (activeTarget + 1) % TARGETS.length;
      await new Promise((r) => setTimeout(r, 500));
    }
    log('bootstrap exhausted all targets');
    return null;
  })().finally(() => { bootstrapPromise = null; });
  return bootstrapPromise;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function sendJson(res, status, obj) {
  const buf = Buffer.from(JSON.stringify(obj));
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': buf.length });
  res.end(buf);
}

// ------------------------------------------------------------------- server

const server = http.createServer(async (req, res) => {
  const pathname = req.url.split('?')[0];

  if (pathname === '/health') {
    return sendJson(res, 200, {
      status: 'ok',
      relay: true,
      target: TARGETS[activeTarget].label,
      session: Boolean(upstreamSession),
    });
  }
  if (pathname !== TARGET_PATH && pathname !== TARGET_PATH + '/') {
    return sendJson(res, 404, { error: 'not found' });
  }

  // GET (server->client SSE) and DELETE (session teardown): best-effort proxy.
  if (req.method === 'GET' || req.method === 'DELETE') {
    const target = TARGETS[activeTarget];
    if (!upstreamSession) await bootstrap();
    const upstream = http.request(
      { host: target.host, port: target.port, path: TARGET_PATH, method: req.method, headers: upstreamHeaders() },
      (up) => {
        res.writeHead(up.statusCode, up.headers);
        up.pipe(res);
      },
    );
    upstream.on('error', () => {
      // Never leave the client hanging: close the stream cleanly.
      try { res.writeHead(200, { 'Content-Type': 'text/event-stream' }); res.end(); } catch { /* already closed */ }
    });
    upstream.end();
    return;
  }

  // POST: the main path.
  let bodyBuf;
  try {
    bodyBuf = await readBody(req);
  } catch {
    return sendJson(res, 400, { error: 'body read failed' });
  }

  let isInitialize = false;
  try {
    const parsed = JSON.parse(bodyBuf.toString('utf8'));
    const batch = Array.isArray(parsed) ? parsed : [parsed];
    isInitialize = batch.some((m) => m && m.method === 'initialize');
  } catch { /* not JSON: let the upstream decide */ }

  const forward = async (retried) => {
    const target = TARGETS[activeTarget];
    if (!isInitialize && !upstreamSession) await bootstrap();
    if (isInitialize) upstreamSession = null; // let upstream mint a new session

    let res1;
    try {
      res1 = await post(target, bodyBuf, isInitialize ? { 'mcp-session-id': '' } : {});
    } catch (e) {
      log('POST error target=' + target.label + ': ' + e.message);
      if (!retried) {
        activeTarget = (activeTarget + 1) % TARGETS.length;
        upstreamSession = null;
        return forward(true);
      }
      return sendJson(res, 503, {
        jsonrpc: '2.0', id: null,
        error: { code: -32000, message: 'relay: all targets unreachable (' + e.message + ')' },
      });
    }

    if (isInitialize && res1.headers['mcp-session-id']) {
      upstreamSession = res1.headers['mcp-session-id'];
      log('client initialize -> session=' + upstreamSession);
    }

    if (res1.status >= 400) {
      const text = res1.body.toString('utf8');
      const sessionDead = /session not found|no valid session|session .*(expired|invalid)/i.test(text);
      if (!retried && sessionDead) {
        log('upstream session invalid -> re-bootstrap and retry once');
        upstreamSession = null;
        const sid = await bootstrap();
        if (sid) return forward(true);
      }
      res.writeHead(res1.status, { 'Content-Type': res1.headers['content-type'] || 'application/json' });
      return res.end(res1.body);
    }

    const headers = { 'Content-Type': res1.headers['content-type'] || 'application/json' };
    if (res1.headers['mcp-session-id']) headers['mcp-session-id'] = res1.headers['mcp-session-id'];
    res.writeHead(res1.status, headers);
    res.end(res1.body);
  };

  try {
    await forward(false);
  } catch (e) {
    log('handler crash: ' + (e && e.stack ? e.stack : e));
    try { sendJson(res, 500, { error: 'relay crash: ' + e.message }); } catch { /* client gone */ }
  }
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  log('listening http://' + LISTEN_HOST + ':' + LISTEN_PORT + TARGET_PATH + ' -> ' + TARGETS.map((t) => t.label).join(' | '));
});

process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
