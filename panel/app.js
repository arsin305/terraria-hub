const express = require('express');
const rateLimit = require('express-rate-limit');
const Database = require('better-sqlite3');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const nodemailer = require('nodemailer');
const { v4: uuidv4 } = require('uuid');
const fs = require('fs');
const path = require('path');
const { execSync, execFileSync } = require('child_process');

const app = express();
const PORT = process.env.PANEL_PORT || 3001;
const JWT_SECRET = process.env.JWT_SECRET || null;

// ── Fatal startup check ────────────────────────────────────────────────────
if (!JWT_SECRET) {
  console.error('[FATAL] JWT_SECRET environment variable is not set. Refusing to start.');
  process.exit(1);
}
const WORLDS_DIR = process.env.WORLDS_DIR || '/worlds';
const HOST_WORLDS_DIR = process.env.HOST_WORLDS_DIR || '/worlds';
const TMOD_IMAGE = process.env.TMOD_IMAGE || 'jacobsmile/tmodloader1.4:latest';
const ADMIN_EMAIL = process.env.ADMIN_EMAIL || '';
const PORT_BASE = parseInt(process.env.PORT_BASE || '7777');
const PORT_MAX  = parseInt(process.env.PORT_MAX  || '7900');

// ── Database ───────────────────────────────────────────────────────────────
const db = new Database('/data/hub.db');
db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    email TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    username TEXT NOT NULL,
    role TEXT DEFAULT 'user',
    verified INTEGER DEFAULT 0,
    verify_token TEXT,
    reset_token TEXT,
    reset_expires INTEGER,
    created_at INTEGER DEFAULT (strftime('%s','now'))
  );
  CREATE TABLE IF NOT EXISTS sessions (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    expires_at INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS world_ports (
    userId TEXT NOT NULL,
    worldName TEXT NOT NULL,
    port INTEGER NOT NULL UNIQUE,
    PRIMARY KEY (userId, worldName)
  );
`);

// ── Port allocation ────────────────────────────────────────────────────────
function allocatePort(userId, worldName) {
  const existing = db.prepare('SELECT port FROM world_ports WHERE userId=? AND worldName=?').get(userId, worldName);
  if (existing) return existing.port;
  const used = new Set(db.prepare('SELECT port FROM world_ports').all().map(r => r.port));
  for (let p = PORT_BASE; p <= PORT_MAX; p++) {
    if (!used.has(p)) {
      db.prepare('INSERT INTO world_ports (userId,worldName,port) VALUES (?,?,?)').run(userId, worldName, p);
      return p;
    }
  }
  throw new Error(`No available game ports in range ${PORT_BASE}–${PORT_MAX}`);
}

function releasePort(userId, worldName) {
  db.prepare('DELETE FROM world_ports WHERE userId=? AND worldName=?').run(userId, worldName);
}

function getWorldPort(userId, worldName) {
  const r = db.prepare('SELECT port FROM world_ports WHERE userId=? AND worldName=?').get(userId, worldName);
  return r ? r.port : null;
}

// ── Mailer ─────────────────────────────────────────────────────────────────
const transporter = nodemailer.createTransport({
  host: process.env.SMTP_HOST,
  port: parseInt(process.env.SMTP_PORT || '587'),
  secure: false,
  auth: { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS }
});

async function sendVerificationEmail(email, token) {
  const url = `http://${process.env.HOST_IP || 'localhost'}:${PORT}/verify?token=${token}`;
  await transporter.sendMail({
    from: `"Terraria Hub" <${process.env.SMTP_FROM}>`,
    to: email,
    subject: 'Verify your Terraria Hub account',
    html: `<h2>Welcome to Terraria Hub</h2><p>Click below to verify your account:</p><a href="${url}" style="background:#4ade80;color:#000;padding:10px 20px;text-decoration:none;border-radius:4px;">Verify Email</a><p>Link expires in 24 hours.</p>`
  });
}

async function sendPasswordResetEmail(email, token) {
  const url = `http://${process.env.HOST_IP || 'localhost'}:${PORT}/reset?token=${token}`;
  await transporter.sendMail({
    from: `"Terraria Hub" <${process.env.SMTP_FROM}>`,
    to: email,
    subject: 'Reset your Terraria Hub password',
    html: `<h2>Password Reset</h2><p>Click below to reset your password:</p><a href="${url}" style="background:#4ade80;color:#000;padding:10px 20px;text-decoration:none;border-radius:4px;">Reset Password</a><p>Link expires in 1 hour.</p>`
  });
}

// ── Middleware ─────────────────────────────────────────────────────────────
app.use(express.json());
app.use(express.static('public'));

function authMiddleware(req, res, next) {
  const header = req.headers['authorization'];
  if (!header) return res.status(401).json({ error: 'No token' });
  const token = header.replace('Bearer ', '');
  try {
    const payload = jwt.verify(token, JWT_SECRET);
    const session = db.prepare('SELECT * FROM sessions WHERE token=? AND expires_at>?').get(token, Math.floor(Date.now()/1000));
    if (!session) return res.status(401).json({ error: 'Session expired' });
    const user = db.prepare('SELECT * FROM users WHERE id=?').get(payload.userId);
    if (!user) return res.status(401).json({ error: 'User not found' });
    req.user = user;
    next();
  } catch(e) { res.status(401).json({ error: 'Invalid token' }); }
}

function adminMiddleware(req, res, next) {
  if (req.user.role !== 'admin') return res.status(403).json({ error: 'Admin only' });
  next();
}

// ── Bootstrap admin ────────────────────────────────────────────────────────
function bootstrapAdmin() {
  if (!ADMIN_EMAIL) return;
  const existing = db.prepare('SELECT id FROM users WHERE email=?').get(ADMIN_EMAIL);
  if (!existing) {
    const id = uuidv4();
    const tempPass = process.env.ADMIN_TEMP_PASS || 'ChangeMe123!';
    const hash = bcrypt.hashSync(tempPass, 10);
    db.prepare('INSERT INTO users (id,email,password,username,role,verified) VALUES (?,?,?,?,?,1)')
      .run(id, ADMIN_EMAIL, hash, 'Admin', 'admin');
    console.log(`Admin created: ${ADMIN_EMAIL} / ${tempPass}`);
  }
}
bootstrapAdmin();

// ── Rate limiters ──────────────────────────────────────────────────────────
const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many attempts, please try again later.' }
});

// ── Auth routes ────────────────────────────────────────────────────────────
app.post('/api/auth/register', async (req, res) => {
  const { email, password, username } = req.body;
  if (!email || !password || !username) return res.status(400).json({ error: 'All fields required' });
  if (password.length < 8) return res.status(400).json({ error: 'Password must be at least 8 characters' });
  const existing = db.prepare('SELECT id FROM users WHERE email=?').get(email);
  if (existing) return res.status(400).json({ error: 'Email already registered' });
  const id = uuidv4();
  const hash = bcrypt.hashSync(password, 10);
  const verifyToken = uuidv4();
  db.prepare('INSERT INTO users (id,email,password,username,verify_token) VALUES (?,?,?,?,?)')
    .run(id, email, hash, username, verifyToken);
  try {
    await sendVerificationEmail(email, verifyToken);
    res.json({ success: true, message: 'Check your email to verify your account' });
  } catch(e) {
    res.status(500).json({ error: 'Failed to send verification email: ' + e.message });
  }
});

app.post('/api/auth/login', authLimiter, (req, res) => {
  const { email, password } = req.body;
  const user = db.prepare('SELECT * FROM users WHERE email=?').get(email);
  if (!user || !bcrypt.compareSync(password, user.password))
    return res.status(401).json({ error: 'Invalid email or password' });
  if (!user.verified) return res.status(401).json({ error: 'Please verify your email first' });
  const token = jwt.sign({ userId: user.id }, JWT_SECRET, { expiresIn: '7d' });
  const expires = Math.floor(Date.now()/1000) + 7*24*60*60;
  db.prepare('INSERT INTO sessions (token,user_id,expires_at) VALUES (?,?,?)').run(token, user.id, expires);
  res.json({ token, user: { id: user.id, email: user.email, username: user.username, role: user.role } });
});

app.post('/api/auth/logout', authMiddleware, (req, res) => {
  const token = req.headers['authorization'].replace('Bearer ', '');
  db.prepare('DELETE FROM sessions WHERE token=?').run(token);
  res.json({ success: true });
});

app.get('/api/auth/me', authMiddleware, (req, res) => {
  const { id, email, username, role } = req.user;
  res.json({ id, email, username, role });
});

app.get('/verify', (req, res) => {
  const { token } = req.query;
  const user = db.prepare('SELECT * FROM users WHERE verify_token=?').get(token);
  if (!user) return res.send('<h2>Invalid or expired verification link.</h2>');
  db.prepare('UPDATE users SET verified=1, verify_token=NULL WHERE id=?').run(user.id);
  res.redirect('/?verified=1');
});

app.post('/api/auth/forgot', authLimiter, async (req, res) => {
  const { email } = req.body;
  const user = db.prepare('SELECT * FROM users WHERE email=?').get(email);
  if (!user) return res.json({ success: true });
  const token = uuidv4();
  const expires = Math.floor(Date.now()/1000) + 3600;
  db.prepare('UPDATE users SET reset_token=?, reset_expires=? WHERE id=?').run(token, expires, user.id);
  try { await sendPasswordResetEmail(email, token); } catch(e) {}
  res.json({ success: true, message: 'If that email exists, a reset link was sent' });
});

app.post('/api/auth/reset', (req, res) => {
  const { token, password } = req.body;
  if (!token || !password || password.length < 8) return res.status(400).json({ error: 'Invalid request' });
  const user = db.prepare('SELECT * FROM users WHERE reset_token=? AND reset_expires>?').get(token, Math.floor(Date.now()/1000));
  if (!user) return res.status(400).json({ error: 'Invalid or expired reset token' });
  const hash = bcrypt.hashSync(password, 10);
  db.prepare('UPDATE users SET password=?, reset_token=NULL, reset_expires=NULL WHERE id=?').run(hash, user.id);
  res.json({ success: true });
});

// ── Admin routes ───────────────────────────────────────────────────────────
app.get('/api/admin/users', authMiddleware, adminMiddleware, (req, res) => {
  const users = db.prepare('SELECT id,email,username,role,verified,created_at FROM users').all();
  res.json(users);
});

app.post('/api/admin/users/:id/role', authMiddleware, adminMiddleware, (req, res) => {
  const { role } = req.body;
  if (!['user','admin'].includes(role)) return res.status(400).json({ error: 'Invalid role' });
  db.prepare('UPDATE users SET role=? WHERE id=?').run(role, req.params.id);
  res.json({ success: true });
});

app.post('/api/admin/users/:id/verify', authMiddleware, adminMiddleware, (req, res) => {
  db.prepare('UPDATE users SET verified=1, verify_token=NULL WHERE id=?').run(req.params.id);
  res.json({ success: true });
});

app.delete('/api/admin/users/:id', authMiddleware, adminMiddleware, (req, res) => {
  if (req.params.id === req.user.id) return res.status(400).json({ error: 'Cannot delete yourself' });
  db.prepare('DELETE FROM users WHERE id=?').run(req.params.id);
  db.prepare('DELETE FROM sessions WHERE user_id=?').run(req.params.id);
  res.json({ success: true });
});

app.get('/api/admin/worlds', authMiddleware, adminMiddleware, (req, res) => {
  try {
    const running = getRunningWorlds();
    const all = [];
    const users = db.prepare('SELECT id,username,email FROM users').all();
    for (const user of users) {
      const userDir = path.join(WORLDS_DIR, user.id);
      if (!fs.existsSync(userDir)) continue;
      const worlds = fs.readdirSync(userDir, { withFileTypes: true })
        .filter(d => d.isDirectory())
        .map(d => ({
          name: d.name,
          owner: user.username,
          email: user.email,
          userId: user.id,
          port: getWorldPort(user.id, d.name),
          running: running.has(containerName(user.id, d.name))
        }));
      all.push(...worlds);
    }
    res.json(all);
  } catch(e) { res.status(500).json({ error: e.message }); }
});

// ── Helpers ────────────────────────────────────────────────────────────────
function containerName(userId, worldName) {
  const safe = worldName.toLowerCase().replace(/[^a-z0-9]/g, '-');
  const shortId = userId.split('-')[0];
  return `th-${shortId}-${safe}`;
}

function playitContainerName(userId, worldName) {
  const safe = worldName.toLowerCase().replace(/[^a-z0-9]/g, '-');
  const shortId = userId.split('-')[0];
  return `th-playit-${shortId}-${safe}`;
}

function userWorldsDir(userId) { return path.join(WORLDS_DIR, userId); }
function hostUserWorldsDir(userId) { return path.join(HOST_WORLDS_DIR, userId); }
function worldDir(userId, worldName) { return path.join(userWorldsDir(userId), worldName); }
function hostWorldDir(userId, worldName) { return path.join(hostUserWorldsDir(userId), worldName); }

const DEFAULT_SETTINGS = {
  maxPlayers: 8, password: '', autosave: 10, seed: '',
  worldSize: 3, difficulty: 0, shutdownMessage: 'Server shutting down!',
  playitSecret: ''
};

function readSettings(userId, worldName) {
  const f = path.join(worldDir(userId, worldName), 'settings.json');
  try { if (fs.existsSync(f)) return { ...DEFAULT_SETTINGS, ...JSON.parse(fs.readFileSync(f, 'utf8')) }; } catch(e) {}
  return { ...DEFAULT_SETTINGS };
}

function saveSettings(userId, worldName, settings) {
  fs.writeFileSync(path.join(worldDir(userId, worldName), 'settings.json'), JSON.stringify(settings, null, 2));
}

function readModsConfig(userId, worldName) {
  const f = path.join(worldDir(userId, worldName), 'mods-config.json');
  try { if (fs.existsSync(f)) return JSON.parse(fs.readFileSync(f, 'utf8')); } catch(e) {}
  return [];
}

function saveModsConfig(userId, worldName, mods) {
  fs.writeFileSync(path.join(worldDir(userId, worldName), 'mods-config.json'), JSON.stringify(mods, null, 2));
}

const PROTECTED = ['terraria-hub', 'terraria-panel'];

function getRunningWorlds() {
  try {
    const out = execSync("docker ps --format '{{.Names}}' 2>/dev/null").toString().trim();
    if (!out) return new Set();
    return new Set(out.split('\n').filter(n =>
      n.startsWith('th-') &&
      !n.startsWith('th-playit-') &&
      !PROTECTED.includes(n)
    ));
  } catch(e) { return new Set(); }
}

function startWorld(userId, worldName) {
  const s = readSettings(userId, worldName);
  const mods = readModsConfig(userId, worldName);
  const autoDownload = mods.map(m => m.workshopId).filter(Boolean).join(',');
  const enabledMods = mods.filter(m => m.side === 'server' || m.side === 'both').map(m => m.workshopId).filter(Boolean).join(',');
  const cname = containerName(userId, worldName);
  const dataPath = hostWorldDir(userId, worldName) + '/data';
  const gamePort = allocatePort(userId, worldName);

  const args = [
    'run', '-d', '--name', cname, '--restart', 'unless-stopped',
    '-p', `${gamePort}:7777`,
    '-v', `${dataPath}:/data`,
    '--security-opt', 'label=disable',
    '-e', `TMOD_SHUTDOWN_MESSAGE=${s.shutdownMessage}`,
    '-e', `TMOD_AUTOSAVE_INTERVAL=${s.autosave}`,
    '-e', `TMOD_MAXPLAYERS=${s.maxPlayers}`,
    '-e', `TMOD_WORLDNAME=${worldName}`,
    '-e', `TMOD_WORLDSIZE=${s.worldSize}`,
    '-e', `TMOD_WORLDSEED=${s.seed}`,
    '-e', `TMOD_DIFFICULTY=${s.difficulty}`,
    '-e', `TMOD_PASS=${s.password}`,
    '-e', `TMOD_AUTODOWNLOAD=${autoDownload}`,
    '-e', `TMOD_ENABLEDMODS=${enabledMods}`,
    TMOD_IMAGE
  ];
  execFileSync('docker', args);

  // Start per-world playit tunnel if a secret key is configured
  if (s.playitSecret) {
    const pcname = playitContainerName(userId, worldName);
    try { execSync(`docker stop ${pcname} 2>/dev/null; docker rm ${pcname} 2>/dev/null`); } catch(e) {}
    execFileSync('docker', [
      'run', '-d', '--name', pcname, '--restart', 'unless-stopped',
      '--network', 'host',
      '-e', `SECRET_KEY=${s.playitSecret}`,
      'ghcr.io/playit-cloud/playit-agent:0.17'
    ]);
  }

  return gamePort;
}

function stopWorldContainers(userId, worldName) {
  const cname = containerName(userId, worldName);
  const pcname = playitContainerName(userId, worldName);
  for (const name of [cname, pcname]) {
    try { execSync(`docker stop ${name} 2>/dev/null`); } catch(e) {}
    try { execSync(`docker rm ${name} 2>/dev/null`); } catch(e) {}
  }
}

// ── World routes ───────────────────────────────────────────────────────────
app.get('/api/worlds', authMiddleware, (req, res) => {
  try {
    const userId = req.user.id;
    const running = getRunningWorlds();
    const uDir = userWorldsDir(userId);
    if (!fs.existsSync(uDir)) return res.json({ worlds: [], running: [...running] });
    const entries = fs.readdirSync(uDir, { withFileTypes: true })
      .filter(d => d.isDirectory())
      .map(d => {
        const wldPath = path.join(uDir, d.name, 'data', 'tModLoader', 'Worlds', `${d.name}.wld`);
        const cname = containerName(userId, d.name);
        const port = getWorldPort(userId, d.name);
        return {
          name: d.name,
          hasWorld: fs.existsSync(wldPath),
          running: running.has(cname),
          port,
          settings: readSettings(userId, d.name),
          modCount: readModsConfig(userId, d.name).length
        };
      });
    res.json({ worlds: entries, running: [...running] });
  } catch(e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/worlds', authMiddleware, (req, res) => {
  const { name, settings, mods } = req.body;
  if (!name || !/^[a-zA-Z0-9_-]+$/.test(name)) return res.status(400).json({ error: 'Invalid world name' });
  const userId = req.user.id;
  const wDir = worldDir(userId, name);
  if (fs.existsSync(wDir)) return res.status(400).json({ error: 'World already exists' });
  fs.mkdirSync(path.join(wDir, 'data', 'tModLoader', 'Worlds'), { recursive: true });
  fs.mkdirSync(path.join(wDir, 'data', 'tModLoader', 'Mods'), { recursive: true });
  let port;
  try { port = allocatePort(userId, name); } catch(e) { return res.status(500).json({ error: e.message }); }
  saveSettings(userId, name, { ...DEFAULT_SETTINGS, ...(settings || {}), gamePort: port });
  saveModsConfig(userId, name, mods || []);
  res.json({ success: true, port });
});

app.post('/api/worlds/:name/start', authMiddleware, (req, res) => {
  const { name } = req.params;
  const userId = req.user.id;
  if (!fs.existsSync(worldDir(userId, name))) return res.status(404).json({ error: 'World not found' });
  try {
    stopWorldContainers(userId, name);
    const port = startWorld(userId, name);
    res.json({ success: true, port, startedAt: new Date().toISOString() });
  } catch(e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/worlds/:name/stop', authMiddleware, (req, res) => {
  try {
    stopWorldContainers(req.user.id, req.params.name);
    res.json({ success: true });
  } catch(e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/worlds/:name/restart', authMiddleware, (req, res) => {
  const { name } = req.params;
  const userId = req.user.id;
  if (!fs.existsSync(worldDir(userId, name))) return res.status(404).json({ error: 'World not found' });
  try {
    stopWorldContainers(userId, name);
    const port = startWorld(userId, name);
    res.json({ success: true, port, startedAt: new Date().toISOString() });
  } catch(e) { res.status(500).json({ error: e.message }); }
});

app.delete('/api/worlds/:name', authMiddleware, (req, res) => {
  const { name } = req.params;
  const userId = req.user.id;
  const wDir = worldDir(userId, name);
  if (!fs.existsSync(wDir)) return res.status(404).json({ error: 'World not found' });
  stopWorldContainers(userId, name);
  releasePort(userId, name);
  fs.rmSync(wDir, { recursive: true, force: true });
  res.json({ success: true });
});

app.get('/api/worlds/:name/settings', authMiddleware, (req, res) => {
  const settings = readSettings(req.user.id, req.params.name);
  const port = getWorldPort(req.user.id, req.params.name);
  res.json({ ...settings, gamePort: port });
});

app.post('/api/worlds/:name/settings', authMiddleware, (req, res) => {
  const { gamePort, ...rest } = req.body;
  const existing = readSettings(req.user.id, req.params.name);
  saveSettings(req.user.id, req.params.name, { ...existing, ...rest });
  res.json({ success: true });
});

app.get('/api/worlds/:name/mods', authMiddleware, (req, res) => {
  res.json(readModsConfig(req.user.id, req.params.name));
});

app.post('/api/worlds/:name/mods', authMiddleware, (req, res) => {
  if (!Array.isArray(req.body)) return res.status(400).json({ error: 'Expected array' });
  saveModsConfig(req.user.id, req.params.name, req.body);
  res.json({ success: true });
});

app.get('/api/worlds/:name/logs', authMiddleware, (req, res) => {
  const cname = containerName(req.user.id, req.params.name);
  const lines = Math.min(parseInt(req.query.lines) || 50, 500);
  const since = req.query.since;

  // Validate `since` against ISO-8601 before passing to docker — prevents shell injection
  const ISO8601_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$/;
  if (since && !ISO8601_RE.test(since)) {
    return res.status(400).json({ error: 'Invalid since parameter' });
  }

  try {
    const args = ['logs', '--tail', String(lines)];
    if (since) args.push('--since', since);
    args.push(cname);
    // execFileSync with an array — no shell, no injection
    const out = execFileSync('docker', args, { stdio: ['ignore', 'pipe', 'pipe'] }).toString();
    res.json({ logs: out.trim(), ready: out.includes('Server started'), generating: out.includes('Creating world') });
  } catch(e) {
    // docker logs exits non-zero when container doesn't exist; return empty gracefully
    const combined = (e.stdout || '') + (e.stderr || '');
    if (combined) res.json({ logs: combined.toString().trim(), ready: false, generating: false });
    else res.status(500).json({ error: e.message });
  }
});

app.get('/api/status', authMiddleware, (req, res) => {
  const running = [...getRunningWorlds()];
  res.json({ running, anyRunning: running.length > 0 });
});

app.get('/api/steam/mod/:id', async (req, res) => {
  const id = req.params.id.replace(/[^0-9]/g, '');
  try {
    const body = new URLSearchParams({ itemcount: '1' });
    body.append('publishedfileids[0]', id);
    const r = await fetch('https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/', { method: 'POST', body });
    const d = await r.json();
    const item = d?.response?.publishedfiledetails?.[0];
    if (item && item.title) return res.json({ name: item.title });
    res.json({ name: null });
  } catch(e) { res.json({ name: null }); }
});

// Catch-all — serve index.html for frontend routes
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.listen(PORT, () => console.log(`Terraria Hub running on port ${PORT}`));
