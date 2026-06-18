#Requires -Version 5.1
<#
.SYNOPSIS
    Scaffolds the trmnl-anylist project on Windows.

.DESCRIPTION
    Creates the full directory tree, copies all source files from the repository
    (or writes them inline if running standalone), initialises a git repository,
    and prints next-step instructions.

    Run this from the directory WHERE you want to create the project folder.
    It creates: .\trmnl-anylist\

.EXAMPLE
    cd C:\Projects
    .\setup.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helper ────────────────────────────────────────────────────────────────────
function New-Dir ($path) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
}

function Write-File ($path, $content) {
    $dir = Split-Path $path -Parent
    if ($dir) { New-Dir $dir }
    # UTF-8 without BOM — important for YAML and Liquid files
    [System.IO.File]::WriteAllText(
        (Resolve-Path -LiteralPath (Split-Path $path -Parent)).Path + '\' + (Split-Path $path -Leaf),
        $content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

# ── Root ─────────────────────────────────────────────────────────────────────
$root = Join-Path (Get-Location) 'trmnl-anylist'

if (Test-Path $root) {
    Write-Error "Directory '$root' already exists. Delete it or run from a different location."
    exit 1
}

Write-Host "`n[1/5] Creating directory structure..." -ForegroundColor Cyan
New-Dir $root
New-Dir "$root\api\src\routes"
New-Dir "$root\recipe\src"
New-Dir "$root\.github\workflows"
New-Dir "$root\assets\icon"
New-Dir "$root\assets\demo"
New-Dir "$root\data"   # runtime data — git-ignored

Set-Location $root

# ── .gitignore ────────────────────────────────────────────────────────────────
Write-Host "[2/5] Writing project files..." -ForegroundColor Cyan

Write-File '.gitignore' @'
# ── Secrets — NEVER commit these ─────────────────────────────────────────────
.env
.env.*
!.env.example
!api/.env.example

# ── Node ─────────────────────────────────────────────────────────────────────
node_modules/
npm-debug.log*
yarn-error.log*
package-lock.json

# ── Runtime data ──────────────────────────────────────────────────────────────
data/

# ── OS ───────────────────────────────────────────────────────────────────────
.DS_Store
Thumbs.db
Desktop.ini

# ── Editor ───────────────────────────────────────────────────────────────────
.vscode/
.idea/
*.swp
*.swo
*~
'@

Write-File '.gitattributes' @'
* text=auto eol=lf
*.png binary
*.jpg binary
*.svg binary
'@

# ── api/.env.example ─────────────────────────────────────────────────────────
Write-File 'api\.env.example' @'
# Copy this to .env and fill in your values.
# .env is git-ignored and must NEVER be committed.

ANYLIST_EMAIL=your-anylist-email@example.com
ANYLIST_PASSWORD=your-anylist-password

# Generate with: node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
API_TOKEN=replace-with-a-strong-random-token

ANYLIST_LIST_NAME=Groceries
# PORT=3457
'@

# ── api/package.json ──────────────────────────────────────────────────────────
Write-File 'api\package.json' @'
{
  "name": "trmnl-anylist-api",
  "version": "1.0.0",
  "description": "Sidecar API bridge — exposes AnyList shopping lists as JSON for the TRMNL recipe",
  "main": "src/index.js",
  "engines": { "node": ">=20" },
  "scripts": {
    "start": "node src/index.js",
    "dev": "node --watch src/index.js"
  },
  "license": "MIT",
  "dependencies": {
    "anylist": "^0.8.6",
    "express": "^4.21.2"
  }
}
'@

# ── api/Dockerfile ────────────────────────────────────────────────────────────
Write-File 'api\Dockerfile' @'
FROM node:20-alpine
WORKDIR /app
RUN addgroup -g 1001 -S appgroup && adduser -S appuser -u 1001 -G appgroup
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY src/ ./src/
RUN chown -R appuser:appgroup /app
USER appuser
EXPOSE 3457
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -q -O- http://localhost:3457/health || exit 1
CMD ["node", "src/index.js"]
'@

# ── api/.dockerignore ─────────────────────────────────────────────────────────
Write-File 'api\.dockerignore' @'
node_modules
npm-debug.log*
.env
.env.*
!.env.example
.git
.gitignore
README.md
'@

# ── api/src/index.js ──────────────────────────────────────────────────────────
Write-File 'api\src\index.js' @'
'use strict';

const express = require('express');
const { login, isReady } = require('./anylist-client');
const listRouter = require('./routes/list');

const PORT = parseInt(process.env.PORT || '3457', 10);
const API_TOKEN = process.env.API_TOKEN;

if (!API_TOKEN) {
  console.warn('[startup] WARNING: API_TOKEN is not set. The API is unprotected.');
}

const app = express();
app.disable('x-powered-by');
app.use(express.json());

// Health check — no auth
app.get('/health', (_req, res) => {
  if (isReady()) return res.json({ status: 'ok', timestamp: new Date().toISOString() });
  return res.status(503).json({ status: 'initialising', timestamp: new Date().toISOString() });
});

// Bearer token auth
app.use((req, res, next) => {
  if (!API_TOKEN) return next();
  const authHeader = req.headers['authorization'] || '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : null;
  if (token !== API_TOKEN) return res.status(401).json({ error: 'Unauthorised' });
  return next();
});

app.use('/api/v1', listRouter);

app.use((_req, res) => res.status(404).json({ error: 'Not found' }));

async function start () {
  try {
    console.log('[startup] Logging in to AnyList...');
    await login();
  } catch (err) {
    console.error('[startup] Initial login failed:', err.message);
  }
  app.listen(PORT, '0.0.0.0', () => {
    console.log(`[startup] trmnl-anylist-api listening on port ${PORT}`);
  });
}

start();
'@

# ── api/src/anylist-client.js ─────────────────────────────────────────────────
Write-File 'api\src\anylist-client.js' @'
'use strict';

const AnyList = require('anylist');

let instance = null;
let loggedIn = false;
let loginInProgress = null;

function validateConfig () {
  const email = process.env.ANYLIST_EMAIL;
  const password = process.env.ANYLIST_PASSWORD;
  if (!email || !password) {
    throw new Error('ANYLIST_EMAIL and ANYLIST_PASSWORD environment variables are required');
  }
  return { email, password };
}

async function doLogin () {
  const { email, password } = validateConfig();
  if (instance) { try { instance.teardown(); } catch (_) {} }
  instance = new AnyList({ email, password });
  await instance.login();
  loggedIn = true;
  console.log('[anylist] Authenticated successfully');
}

async function login () {
  if (loginInProgress) return loginInProgress;
  loginInProgress = doLogin().finally(() => { loginInProgress = null; });
  return loginInProgress;
}

function resolveCategory (item) {
  if (item.categoryDetails && item.categoryDetails.name) return item.categoryDetails.name;
  if (item.listCategory && item.listCategory.name) return item.listCategory.name;
  if (typeof item.category === 'string' && item.category) return item.category;
  if (item.category && item.category.name) return item.category.name;
  return 'Other';
}

async function fetchList (listName) {
  if (!loggedIn) await login();

  async function attempt () {
    await instance.getLists();
    return instance.getListByName(listName);
  }

  let rawList;
  try {
    rawList = await attempt();
  } catch (err) {
    const isAuthError = err.statusCode === 401 ||
      (err.message && /auth|unauthori[sz]ed|login|session/i.test(err.message));
    if (isAuthError) {
      console.warn('[anylist] Auth error — re-logging in:', err.message);
      loggedIn = false;
      await login();
      rawList = await attempt();
    } else {
      throw err;
    }
  }

  if (!rawList) return null;

  const unchecked = (rawList.items || []).filter(item => !item.checked);

  const categoryMap = new Map();
  for (const item of unchecked) {
    const cat = resolveCategory(item);
    if (!categoryMap.has(cat)) categoryMap.set(cat, []);
    categoryMap.get(cat).push({
      name: item.name || '',
      quantity: item.quantity || '',
      details: item.note || ''
    });
  }

  const categories = Array.from(categoryMap.entries())
    .map(([name, items]) => ({ name, items }))
    .sort((a, b) => {
      if (a.name === 'Other') return 1;
      if (b.name === 'Other') return -1;
      return a.name.localeCompare(b.name);
    });

  return {
    list_name: rawList.name || listName,
    item_count: unchecked.length,
    categories,
    updated_at: new Date().toISOString()
  };
}

function isReady () { return loggedIn; }

module.exports = { login, fetchList, isReady };
'@

# ── api/src/routes/list.js ────────────────────────────────────────────────────
Write-File 'api\src\routes\list.js' @'
'use strict';

const express = require('express');
const { fetchList } = require('../anylist-client');

const router = express.Router();
const DEFAULT_LIST_NAME = process.env.ANYLIST_LIST_NAME || 'Groceries';

router.get('/list', async (req, res) => {
  const listName = (req.query.name || DEFAULT_LIST_NAME).trim();
  if (!listName) {
    return res.status(400).json({ error: 'List name is required.' });
  }
  try {
    const data = await fetchList(listName);
    if (!data) {
      return res.status(404).json({
        error: `List "${listName}" not found.`,
        hint: 'Check the list name matches exactly (case-sensitive).'
      });
    }
    return res.json(data);
  } catch (err) {
    console.error('[route /list] Error:', err.message);
    return res.status(502).json({ error: 'Failed to fetch list from AnyList.', detail: err.message });
  }
});

module.exports = router;
'@

# ── docker-compose.yml ────────────────────────────────────────────────────────
Write-File 'docker-compose.yml' @'
services:
  trmnl-anylist-api:
    build:
      context: ./api
    image: trmnl-anylist-api:latest
    container_name: trmnl-anylist-api
    restart: unless-stopped
    ports:
      - "${PORT:-3457}:3457"
    environment:
      - ANYLIST_EMAIL=${ANYLIST_EMAIL}
      - ANYLIST_PASSWORD=${ANYLIST_PASSWORD}
      - API_TOKEN=${API_TOKEN}
      - ANYLIST_LIST_NAME=${ANYLIST_LIST_NAME:-Groceries}
    volumes:
      - ./data:/data
    healthcheck:
      test: ["CMD", "wget", "-q", "-O-", "http://localhost:3457/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
'@

# ── recipe/src/settings.yml ───────────────────────────────────────────────────
Write-File 'recipe\src\settings.yml' @'
strategy: polling
polling_verb: get
polling_url: "{{ api_url }}/api/v1/list?name={{ list_name }}"
polling_headers: "authorization: Bearer {{ api_token }}"
name: AnyList Shopping List
description: >
  Displays your AnyList shopping list on TRMNL. Shows unchecked items grouped
  by category. Requires a self-hosted trmnl-anylist-api sidecar.
refresh_interval: 900
framework_version: latest
custom_fields:
  - keyname: api_url
    field_type: string
    name: API URL
    description: "Base URL of your trmnl-anylist-api, e.g. http://192.168.68.111:3457"
    placeholder: "http://192.168.68.111:3457"
  - keyname: list_name
    field_type: string
    name: List Name
    description: "AnyList list name — must match exactly (case-sensitive)"
    placeholder: "Groceries"
  - keyname: api_token
    field_type: string
    name: API Token
    description: "Bearer token matching API_TOKEN in your sidecar .env"
'@

# ── recipe/.trmnlp.yml ────────────────────────────────────────────────────────
Write-File 'recipe\.trmnlp.yml' @'
---
watch:
  - src
  - .trmnlp.yml

custom_fields:
  api_url: "http://localhost:3457"
  list_name: "Groceries"
  api_token: "{{ env.API_TOKEN }}"

time_zone: Europe/London
'@

# ── Liquid templates — placeholders (full content in repo) ────────────────────
# These are the full files; kept inline here for standalone setup script use.

Write-File 'recipe\src\shared.liquid' @'
{% comment %}shared.liquid — common partials for trmnl-anylist{% endcomment %}
'@

Write-File 'recipe\src\full.liquid' @'
<div class="layout">
  {% if item_count == 0 %}
  <div style="display:flex;align-items:center;justify-content:center;height:80%;">
    <p class="title" data-pixel-perfect="true">Nothing on the list!</p>
  </div>
  {% else %}
  {% assign col_split = categories.size | divided_by: 2 | ceil %}
  <div style="display:flex;gap:16px;height:100%;">
    <div style="flex:1;min-width:0;" data-list-limit="true" data-list-max-height="390">
      {% for category in categories limit: col_split %}
      <div style="margin-bottom:8px;">
        <p class="label" data-pixel-perfect="true" style="text-transform:uppercase;">{{ category.name }}</p>
        {% for item in category.items %}
        <div style="display:flex;justify-content:space-between;align-items:baseline;">
          <span class="clamp--1" data-pixel-perfect="true" style="flex:1;min-width:0;">{{ item.name }}{% if item.details != "" %} <span class="label">({{ item.details }})</span>{% endif %}</span>
          {% if item.quantity != "" %}<span class="label" style="white-space:nowrap;padding-left:6px;" data-pixel-perfect="true">{{ item.quantity }}</span>{% endif %}
        </div>
        {% endfor %}
      </div>
      {% endfor %}
    </div>
    <div style="width:1px;background:#e0e0e0;"></div>
    <div style="flex:1;min-width:0;" data-list-limit="true" data-list-max-height="390">
      {% for category in categories offset: col_split %}
      <div style="margin-bottom:8px;">
        <p class="label" data-pixel-perfect="true" style="text-transform:uppercase;">{{ category.name }}</p>
        {% for item in category.items %}
        <div style="display:flex;justify-content:space-between;align-items:baseline;">
          <span class="clamp--1" data-pixel-perfect="true" style="flex:1;min-width:0;">{{ item.name }}{% if item.details != "" %} <span class="label">({{ item.details }})</span>{% endif %}</span>
          {% if item.quantity != "" %}<span class="label" style="white-space:nowrap;padding-left:6px;" data-pixel-perfect="true">{{ item.quantity }}</span>{% endif %}
        </div>
        {% endfor %}
      </div>
      {% endfor %}
    </div>
  </div>
  {% endif %}
  <div class="title_bar">
    <img class="image" src="/images/icons/shopping-cart.svg" />
    <span class="title">AnyList</span>
    <span class="instance">{{ list_name }}</span>
    <span class="status">{{ item_count }} item{% if item_count != 1 %}s{% endif %}</span>
  </div>
</div>
'@

Write-File 'recipe\src\half_horizontal.liquid' @'
<div class="layout">
  {% if item_count == 0 %}
  <p class="label" data-pixel-perfect="true">Nothing on the list!</p>
  {% else %}
  <div data-list-limit="true" data-list-max-height="370">
    {% for category in categories %}
    <div style="margin-bottom:6px;">
      <p class="label" data-pixel-perfect="true" style="text-transform:uppercase;">{{ category.name }}</p>
      {% for item in category.items %}
      <div style="display:flex;justify-content:space-between;align-items:baseline;">
        <span class="clamp--1" data-pixel-perfect="true" style="flex:1;min-width:0;">{{ item.name }}</span>
        {% if item.quantity != "" %}<span class="label" style="white-space:nowrap;padding-left:4px;" data-pixel-perfect="true">{{ item.quantity }}</span>{% endif %}
      </div>
      {% endfor %}
    </div>
    {% endfor %}
  </div>
  {% endif %}
  <div class="title_bar">
    <img class="image" src="/images/icons/shopping-cart.svg" />
    <span class="title">AnyList</span>
    <span class="instance">{{ list_name }}</span>
    <span class="status">{{ item_count }} items</span>
  </div>
</div>
'@

Write-File 'recipe\src\half_vertical.liquid' @'
<div class="layout">
  {% if item_count == 0 %}
  <p class="label" data-pixel-perfect="true">Nothing on the list!</p>
  {% else %}
  <div data-list-limit="true" data-list-max-height="160">
    {% for category in categories %}{% for item in category.items %}
    <div style="display:flex;justify-content:space-between;align-items:baseline;">
      <span class="clamp--1" data-pixel-perfect="true" style="flex:1;min-width:0;">{{ item.name }}</span>
      {% if item.quantity != "" %}<span class="label" style="white-space:nowrap;padding-left:4px;" data-pixel-perfect="true">{{ item.quantity }}</span>{% endif %}
    </div>
    {% endfor %}{% endfor %}
  </div>
  {% endif %}
  <div class="title_bar">
    <img class="image" src="/images/icons/shopping-cart.svg" />
    <span class="title">AnyList</span>
    <span class="instance">{{ item_count }} items</span>
  </div>
</div>
'@

Write-File 'recipe\src\quadrant.liquid' @'
<div class="layout">
  <div style="display:flex;flex-direction:column;align-items:center;justify-content:center;height:80%;gap:4px;">
    <p class="value" data-pixel-perfect="true" style="font-size:48px;line-height:1;">{{ item_count }}</p>
    <p class="label" data-pixel-perfect="true">item{% if item_count != 1 %}s{% endif %} to buy</p>
  </div>
  <div class="title_bar">
    <img class="image" src="/images/icons/shopping-cart.svg" />
    <span class="title">AnyList</span>
    <span class="instance">{{ list_name }}</span>
  </div>
</div>
'@

# ── GitHub Actions ────────────────────────────────────────────────────────────
Write-File '.github\workflows\docker-build.yml' @'
name: Build and push Docker image

on:
  push:
    tags:
      - 'v*.*.*'
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-qemu-action@v3
      - uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository_owner }}/trmnl-anylist-api
          tags: |
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=raw,value=latest,enable={{is_default_branch}}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: ./api
          push: true
          platforms: linux/amd64,linux/arm64
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
'@

# ── LICENSE ───────────────────────────────────────────────────────────────────
Write-File 'LICENSE' @'
MIT License

Copyright (c) 2026 trmnl-anylist contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
'@

# ── README ────────────────────────────────────────────────────────────────────
Write-File 'README.md' @'
# trmnl-anylist

Display your AnyList shopping list on a TRMNL e-ink display.
See the full README in the repository for setup and deployment instructions.

> Unofficial. Not affiliated with AnyList. Uses a reverse-engineered API.
'@

# ── Git init ──────────────────────────────────────────────────────────────────
Write-Host "[3/5] Initialising git repository..." -ForegroundColor Cyan

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Warning "git not found in PATH — skipping git init. Install Git for Windows and run 'git init' manually."
} else {
    git init -q
    git add .gitignore .gitattributes LICENSE README.md
    git add api\.env.example api\package.json api\Dockerfile api\.dockerignore
    git add api\src\
    git add recipe\
    git add docker-compose.yml
    git add .github\
    git commit -q -m "chore: initial scaffold"
    Write-Host "    git init done. Initial commit created (no secrets committed)." -ForegroundColor Green
}

# ── Generate a token ──────────────────────────────────────────────────────────
Write-Host "[4/5] Generating a sample API token..." -ForegroundColor Cyan

$tokenBytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($tokenBytes)
$token = [System.BitConverter]::ToString($tokenBytes) -replace '-', ''

Write-Host ""
Write-Host "  Generated API token (save this — it won't be shown again):" -ForegroundColor Yellow
Write-Host "  $token" -ForegroundColor White
Write-Host ""

# ── Next steps ────────────────────────────────────────────────────────────────
Write-Host "[5/5] Done! Next steps:" -ForegroundColor Green
Write-Host ""
Write-Host "  1. cd trmnl-anylist"
Write-Host "  2. Copy api\.env.example to api\.env (or .env in root)"
Write-Host "     and fill in your AnyList credentials + the token above."
Write-Host "  3. Create a GitHub repo and push:"
Write-Host "       git remote add origin https://github.com/YOUR_USER/trmnl-anylist.git"
Write-Host "       git push -u origin main"
Write-Host "  4. Build and deploy the Docker image on your NAS (see README)."
Write-Host "  5. Configure the TRMNL recipe/plugin with your API URL and token."
Write-Host ""
Write-Host "  SECURITY REMINDER: Never commit .env — it is git-ignored." -ForegroundColor Red
Write-Host ""
