// ============================================================
//  سيرفر New Town Voice
//  - Roblox -> السيرفر: مصادقة بمفتاح API (Bearer)
//  - المتصفح -> السيرفر: مصادقة بكوكي جلسة بعد تفعيل الرابط (بدون أي كود يدوي)
// ============================================================

import http from 'node:http';
import crypto from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import express from 'express';
import rateLimit from 'express-rate-limit';
import { WebSocketServer, WebSocket } from 'ws';
import { createStore, SESSION_COOKIE_TTL_MS } from './store.js';
import { MAX_RADIO_CHANNEL, channelAllowed, isValidChannel, publicChannelList } from './radio-rules.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.resolve(__dirname, '..', 'public');

export const NEARBY_RADIUS = 60;
const COOKIE_NAME = 'nt_sid';
const TOKEN_PATTERN = /^[A-Za-z0-9_-]{16,64}$/;

const CONTENT_SECURITY_POLICY = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline'",
  "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
  "font-src 'self' https://fonts.gstatic.com",
  "img-src 'self' data:",
  "connect-src 'self' ws: wss:",
  "media-src 'self' blob:",
  "object-src 'none'",
  "base-uri 'none'",
  "frame-ancestors 'none'",
].join('; ');

const isUserId = (v) => Number.isSafeInteger(v) && v > 0;
const distance3D = (a, b) => Math.hypot(a.x - b.x, a.y - b.y, a.z - b.z);

function readCookie(req, name) {
  const header = req.headers.cookie || '';
  for (const part of header.split(';')) {
    const [key, ...rest] = part.trim().split('=');
    if (key === name) return decodeURIComponent(rest.join('='));
  }
  return undefined;
}

function safeEqual(a, b) {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

export function createVoiceServer(options = {}) {
  const apiKey = options.apiKey;
  if (!apiKey || apiKey.length < 32) {
    throw new Error('API_KEY must be set and be at least 32 characters long');
  }

  const store = createStore({ linkTtlMs: options.linkTtlMs ?? 5 * 60_000 });
  const secureCookies = options.secureCookies ?? true;
  const publicBaseUrl = options.publicBaseUrl ? options.publicBaseUrl.replace(/\/+$/, '') : null;

  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', 1); // Render يضع الخدمة خلف proxy

  // ---------- ترويسات الأمان ----------
  app.use((_req, res, next) => {
    res.set({
      'Content-Security-Policy': CONTENT_SECURITY_POLICY,
      'Referrer-Policy': 'no-referrer',          // مهم: الرابط يحتوي التوكن، لا نرسله لأي موقع
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
      'Permissions-Policy': 'microphone=(self)',
    });
    next();
  });

  // ---------- حدود الطلبات ----------
  const activateLimiter = rateLimit({
    windowMs: 15 * 60_000,
    limit: options.activateLimit ?? 20,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    message: { error: 'too many attempts, try again later' },
  });
  const linkInfoLimiter = rateLimit({
    windowMs: 60_000,
    limit: 60,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    message: { error: 'too many requests' },
  });

  // ---------- مصادقة Roblox ----------
  function requireGameKey(req, res, next) {
    const match = /^Bearer\s+(.+)$/i.exec(req.get('authorization') || '');
    if (!match || !safeEqual(match[1], apiKey)) {
      res.status(401).json({ error: 'unauthorized' });
      return;
    }
    next();
  }

  // ---------- إرسال للمتصفح ----------
  function send(session, message) {
    if (session.ws && session.ws.readyState === WebSocket.OPEN) {
      session.ws.send(JSON.stringify(message));
    }
  }

  function sendNearby(session) {
    if (!session.position) return;
    const players = [];
    for (const other of store.allSessions()) {
      if (other.userId === session.userId || !other.linked || !other.position) continue;
      const distance = distance3D(session.position, other.position);
      if (distance <= NEARBY_RADIUS) {
        players.push({ userId: other.userId, username: other.username, distance });
      }
    }
    send(session, { type: 'nearby_update', players });
  }

  function broadcastNearby() {
    for (const s of store.allSessions()) if (s.linked) sendNearby(s);
  }

  // تغيير حالة الراديو للجلسة وإرسالها للموقع (مصدر واحد لكل التغييرات)
  function setRadio(s, channel, talking, message) {
    s.radioChannel = channel;
    s.radioTalking = channel === null ? false : talking;
    send(s, { type: 'radio_state', channel: s.radioChannel, talking: s.radioTalking, message: message || '' });
  }

  function linkUrl(req, token) {
    const base = publicBaseUrl || `${req.protocol}://${req.get('host')}`;
    return `${base}/a/${token}`;
  }

  // ---------- API ----------
  const api = express.Router();
  api.use((_req, res, next) => {
    res.set('Cache-Control', 'no-store');
    next();
  });

  api.get('/health', (_req, res) => {
    res.json({ ok: true });
  });

  // قائمة القنوات وتيماتها (للعرض فقط)
  api.get('/radio/channels', (_req, res) => {
    res.json({ max: MAX_RADIO_CHANNEL, channels: publicChannelList() });
  });

  // هل المتصفح مربوط الآن؟ (يستخدمها الموقع عند فتح الصفحة)
  api.get('/session', (req, res) => {
    const s = store.getSessionBySid(readCookie(req, COOKIE_NAME));
    if (s && s.linked) res.json({ linked: true, username: s.username });
    else res.json({ linked: false });
  });

  // معلومات الرابط: لا تستهلك الرابط
  api.get('/link/:token', linkInfoLimiter, (req, res) => {
    const token = req.params.token;
    if (!TOKEN_PATTERN.test(token)) {
      res.json({ status: 'invalid' });
      return;
    }
    const result = store.getLink(token);
    res.json({ status: result.status, username: result.username });
  });

  // التفعيل: يستهلك الرابط مرة واحدة ويضع كوكي الجلسة
  api.post('/link/:token/activate', activateLimiter, (req, res) => {
    const token = req.params.token;
    if (!TOKEN_PATTERN.test(token)) {
      res.status(400).json({ status: 'invalid' });
      return;
    }
    const result = store.activate(token);
    if (result.status !== 'ok') {
      res.status(409).json({ status: result.status });
      return;
    }
    res.cookie(COOKIE_NAME, result.sid, {
      httpOnly: true,
      secure: secureCookies,
      sameSite: 'strict',
      path: '/',
      maxAge: SESSION_COOKIE_TTL_MS,
    });
    broadcastNearby();
    res.json({ ok: true, username: result.session.username });
  });

  // فصل الربط من الموقع: يُنهي الجلسة، فيطلب Roblox رابطاً جديداً عند تحديثه القادم
  api.post('/session/unlink', (req, res) => {
    const s = store.getSessionBySid(readCookie(req, COOKIE_NAME));
    if (s) {
      store.endSession(s.userId);
      broadcastNearby();
    }
    res.clearCookie(COOKIE_NAME, { path: '/', httpOnly: true, secure: secureCookies, sameSite: 'strict' });
    res.json({ ok: true });
  });

  // ---------- Roblox -> السيرفر (محمي بمفتاح API) ----------
  api.post('/link', requireGameKey, (req, res) => {
    const { userId, username } = req.body ?? {};
    const team = req.body?.team ?? null; // اختياري: تيم اللاعب وقت الدخول
    const validTeam = team === null || (typeof team === 'string' && team.length > 0 && team.length <= 40);
    if (!isUserId(userId) || typeof username !== 'string' || !username.trim() || username.length > 50 || !validTeam) {
      res.status(400).json({ error: 'invalid input' });
      return;
    }
    const result = store.createLink(userId, username.trim(), team);
    broadcastNearby();
    console.log(`[link] رابط جديد للاعب ${userId}`); // لا نسجّل التوكن أبداً
    res.json({ url: linkUrl(req, result.token), expiresIn: Math.round(result.ttlMs / 1000) });
  });

  api.post('/position/update', requireGameKey, (req, res) => {
    const { userId, x, y, z } = req.body ?? {};
    if (!isUserId(userId) || ![x, y, z].every(Number.isFinite)) {
      res.status(400).json({ error: 'invalid input' });
      return;
    }
    const s = store.getSession(userId);
    if (!s) {
      res.status(404).json({ error: 'session not found' });
      return;
    }
    s.position = { x, y, z };
    s.lastSeen = Date.now();
    broadcastNearby();
    res.json({
      ok: true,
      muted: s.muted,
      linked: s.linked,
      radioChannel: s.radioChannel,   // القناة اللي دخلها اللاعب من الموقع
      radioTalking: s.radioTalking,
    });
  });

  api.post('/mic/toggle', requireGameKey, (req, res) => {
    const { userId, muted } = req.body ?? {};
    if (!isUserId(userId) || typeof muted !== 'boolean') {
      res.status(400).json({ error: 'invalid input' });
      return;
    }
    const s = store.getSession(userId);
    if (!s) {
      res.status(404).json({ error: 'session not found' });
      return;
    }
    s.muted = muted;
    s.lastSeen = Date.now();
    send(s, { type: 'mic_state', muted });
    res.json({ ok: true });
  });

  // Roblox يرسل تيم اللاعب. إذا تغيّر وما عاد مسموحاً له بالقناة الحالية، نخرجه منها.
  api.post('/radio/team', requireGameKey, (req, res) => {
    const { userId } = req.body ?? {};
    const team = req.body?.team ?? null;
    const validTeam = team === null || (typeof team === 'string' && team.length > 0 && team.length <= 40);
    if (!isUserId(userId) || !validTeam) {
      res.status(400).json({ error: 'invalid input' });
      return;
    }
    const s = store.getSession(userId);
    if (!s) {
      res.status(404).json({ error: 'session not found' });
      return;
    }
    s.team = team;
    s.lastSeen = Date.now();
    if (s.radioChannel !== null && !channelAllowed(s.radioChannel, team)) {
      setRadio(s, null, false, 'تم إخراجك من القناة لأن تيمك تغيّر');
    }
    res.json({ ok: true });
  });

  // حالة الراديو: يرسلها سكربت Roblox بعد كل قرار (انضمام/خروج/تحدث).
  // السيرفر لا يقرر الصلاحيات، فقط يعكس القرار للموقع.
  api.post('/radio/state', requireGameKey, (req, res) => {
    const { userId, talking } = req.body ?? {};
    const channel = req.body?.channel ?? null;
    const validChannel = channel === null
      || (Number.isSafeInteger(channel) && channel >= 1 && channel <= MAX_RADIO_CHANNEL);
    if (!isUserId(userId) || !validChannel || typeof talking !== 'boolean') {
      res.status(400).json({ error: 'invalid input' });
      return;
    }
    const s = store.getSession(userId);
    if (!s) {
      res.status(404).json({ error: 'session not found' });
      return;
    }
    s.radioChannel = channel;
    s.radioTalking = channel === null ? false : talking;
    s.lastSeen = Date.now();
    send(s, { type: 'radio_state', channel: s.radioChannel, talking: s.radioTalking });
    res.json({ ok: true });
  });

  api.post('/radio/talk', requireGameKey, (req, res) => {
    const { userId, talking } = req.body ?? {};
    if (!isUserId(userId) || typeof talking !== 'boolean') {
      res.status(400).json({ error: 'invalid input' });
      return;
    }
    const s = store.getSession(userId);
    if (!s) {
      res.status(404).json({ error: 'session not found' });
      return;
    }
    if (s.radioChannel === null) {
      res.json({ ok: true, channel: null, talking: false });
      return;
    }
    setRadio(s, s.radioChannel, talking, '');
    res.json({ ok: true, channel: s.radioChannel, talking: s.radioTalking });
  });

  api.post('/session/end', requireGameKey, (req, res) => {
    const { userId } = req.body ?? {};
    if (!isUserId(userId)) {
      res.status(400).json({ error: 'invalid input' });
      return;
    }
    store.endSession(userId);
    broadcastNearby();
    res.json({ ok: true });
  });

  app.use('/api', express.json({ limit: '16kb' }), api);
  app.use('/api', (_req, res) => res.status(404).json({ error: 'not found' }));

  // ---------- صفحة التفعيل والموقع ----------
  app.get('/a/:token', (_req, res) => {
    res.set('Cache-Control', 'no-store');
    res.sendFile(path.join(PUBLIC_DIR, 'index.html'));
  });
  app.use(express.static(PUBLIC_DIR, { index: 'index.html', dotfiles: 'ignore' }));

  // ---------- معالج الأخطاء (بدون تسجيل محتوى الطلب) ----------
  app.use((err, _req, res, _next) => {
    if (err.type === 'entity.parse.failed' || err.type === 'entity.too.large') {
      res.status(400).json({ error: 'bad request' });
      return;
    }
    console.error('[error] unexpected server error');
    res.status(500).json({ error: 'server error' });
  });

  // ---------- WebSocket للموقع ----------
  const server = http.createServer(app);
  const wss = new WebSocketServer({ server, path: '/ws/web', maxPayload: 64 * 1024 });

  wss.on('connection', (ws, req) => {
    const s = store.getSessionBySid(readCookie(req, COOKIE_NAME));
    if (!s || !s.linked) {
      ws.send(JSON.stringify({
        type: 'error',
        reason: 'no_session',
        message: 'الجلسة غير مفعّلة. ارجع للعبة وافتح الرابط الجديد.',
      }));
      ws.close(4003, 'no session');
      return;
    }

    if (s.ws && s.ws !== ws) {
      try { s.ws.close(4001, 'newer connection'); } catch { /* ignore */ }
    }
    s.ws = ws;
    s.lastSeen = Date.now();
    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });

    send(s, { type: 'linked', username: s.username, userId: s.userId, team: s.team });
    send(s, { type: 'radio_state', channel: s.radioChannel, talking: s.radioTalking });
    sendNearby(s);

    ws.on('message', (raw, isBinary) => {
      if (isBinary) return;
      let msg;
      try { msg = JSON.parse(raw.toString()); } catch { return; }
      if (!msg || typeof msg !== 'object') return;

      // ---------- الراديو من الموقع (السيرفر يتحقق من التيم دائماً) ----------
      if (msg.type === 'radio_join') {
        if (!isValidChannel(msg.channel)) {
          send(s, { type: 'radio_error', message: 'رقم القناة غير صحيح' });
          return;
        }
        if (!channelAllowed(msg.channel, s.team)) {
          send(s, { type: 'radio_error', message: `ما عندك صلاحية للقناة ${msg.channel}` });
          return;
        }
        setRadio(s, msg.channel, false, `متصل بالقناة ${msg.channel}`);
        return;
      }

      if (msg.type === 'radio_leave') {
        setRadio(s, null, false, 'خرجت من القناة');
        return;
      }

      if (msg.type === 'radio_talk' && typeof msg.talking === 'boolean') {
        if (s.radioChannel === null) {
          if (msg.talking) send(s, { type: 'radio_error', message: 'اختر قناة أولاً' });
          return;
        }
        setRadio(s, s.radioChannel, msg.talking, '');
        return;
      }

      if (msg.type === 'mic_toggle' && typeof msg.muted === 'boolean') {
        s.muted = msg.muted; // Roblox يسحبها مع أقرب تحديث موقع
        return;
      }

      if (msg.type === 'webrtc_signal' && isUserId(msg.to) && msg.signal && typeof msg.signal === 'object') {
        const target = store.getSession(msg.to);
        if (!target || !target.linked || !s.position || !target.position) return;
        if (distance3D(s.position, target.position) > NEARBY_RADIUS) return; // لازم يكونون قريبين
        send(target, { type: 'webrtc_signal', from: s.userId, signal: msg.signal });
      }
    });

    ws.on('close', () => {
      if (s.ws === ws) s.ws = null;
    });
    ws.on('error', () => { /* يُعالج بالإغلاق */ });
  });

  // نبض كل 25 ثانية يكشف الاتصالات الميتة
  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (ws.isAlive === false) { ws.terminate(); continue; }
      ws.isAlive = false;
      try { ws.ping(); } catch { /* ignore */ }
    }
  }, 25_000);

  // تنظيف الجلسات المتوقفة
  const cleanup = setInterval(() => {
    if (store.cleanup().length) broadcastNearby();
  }, 30_000);

  heartbeat.unref();
  cleanup.unref();

  function close() {
    clearInterval(heartbeat);
    clearInterval(cleanup);
    for (const ws of wss.clients) ws.terminate();
    wss.close();
    return new Promise((resolve) => server.close(() => resolve()));
  }

  return { server, store, close };
}
