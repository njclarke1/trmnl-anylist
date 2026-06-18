'use strict';

const express = require('express');
const { login, isReady } = require('./anylist-client');
const listRouter = require('./routes/list');

const PORT = parseInt(process.env.PORT || '3457', 10);
const API_TOKEN = process.env.API_TOKEN;

if (!API_TOKEN) {
  console.warn('[startup] WARNING: API_TOKEN is not set. The API is unprotected — do not expose this port outside your LAN.');
}

const app = express();
app.disable('x-powered-by');
app.use(express.json());

// ── Health check — intentionally before auth middleware ──────────────────────
app.get('/health', (_req, res) => {
  if (isReady()) {
    return res.json({ status: 'ok', timestamp: new Date().toISOString() });
  }
  return res.status(503).json({ status: 'initialising', timestamp: new Date().toISOString() });
});

// ── Bearer token auth ─────────────────────────────────────────────────────────
app.use((req, res, next) => {
  if (!API_TOKEN) return next(); // No token configured → allow all (dev mode)

  const authHeader = req.headers['authorization'] || '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : null;

  if (token !== API_TOKEN) {
    return res.status(401).json({ error: 'Unauthorised' });
  }
  return next();
});

// ── Routes ────────────────────────────────────────────────────────────────────
app.use('/api/v1', listRouter);

// ── 404 catch-all ─────────────────────────────────────────────────────────────
app.use((_req, res) => {
  res.status(404).json({ error: 'Not found' });
});

// ── Start ─────────────────────────────────────────────────────────────────────
async function start () {
  try {
    console.log('[startup] Logging in to AnyList...');
    await login();
  } catch (err) {
    // Log clearly but don't crash — requests will retry login on first call
    console.error('[startup] Initial login failed:', err.message);
    console.error('[startup] Check ANYLIST_EMAIL and ANYLIST_PASSWORD are correct.');
  }

  app.listen(PORT, '0.0.0.0', () => {
    console.log(`[startup] trmnl-anylist-api listening on port ${PORT}`);
  });
}

start();
