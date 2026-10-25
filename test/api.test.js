import { test, before, after, describe } from 'node:test';
import assert from 'node:assert/strict';
import { WebSocket } from 'ws';
import { createVoiceServer } from '../server/app.js';

const API_KEY = 'x'.repeat(40);

let voice;
let base;
let wsBase;

async function start(options = {}) {
  voice = createVoiceServer({ apiKey: API_KEY, secureCookies: false, activateLimit: 1000, ...options });
  await new Promise((resolve) => voice.server.listen(0, '127.0.0.1', resolve));
  const { port } = voice.server.address();
  base = `http://127.0.0.1:${port}`;
  wsBase = `ws://127.0.0.1:${port}`;
}

async function stop() {
  if (voice) await voice.close();
  voice = null;
}

const gameHeaders = { 'content-type': 'application/json', authorization: `Bearer ${API_KEY}` };

async function createLink(userId, username = 'Player' + userId) {
  const res = await fetch(`${base}/api/link`, {
    method: 'POST',
    headers: gameHeaders,
    body: JSON.stringify({ userId, username }),
  });
  assert.equal(res.status, 200);
  const data = await res.json();
  const token = data.url.split('/a/')[1];
  return { url: data.url, token, data };
}

async function activate(token) {
  return fetch(`${base}/api/link/${token}/activate`, { method: 'POST' });
}

function cookieFrom(res) {
  const raw = res.headers.get('set-cookie') || '';
  return raw.split(';')[0]; // nt_sid=...
}

// يرجّع الحالة فوراً؛ state.closed يُملأ برمز الإغلاق عند الإغلاق
function openWs(cookie) {
  const ws = new WebSocket(`${wsBase}/ws/web`, { headers: cookie ? { cookie } : {} });
  const state = { ws, messages: [], closed: null };
  ws.on('message', (m) => state.messages.push(JSON.parse(m.toString())));
  ws.on('close', (code) => { state.closed = code; });
  ws.on('error', () => {});
  return new Promise((resolve) => {
    ws.on('open', () => resolve(state));
    ws.on('close', () => resolve(state));
    ws.on('error', () => resolve(state));
  });
}

function waitFor(predicate, timeout = 2000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const tick = () => {
      if (predicate()) return resolve();
      if (Date.now() - start > timeout) return reject(new Error('timeout'));
      setTimeout(tick, 20);
    };
    tick();
  });
}

describe('Roblox API auth', () => {
  before(() => start());
  after(() => stop());

  test('rejects missing or wrong API key', async () => {
    const noKey = await fetch(`${base}/api/link`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ userId: 1, username: 'a' }),
    });
    assert.equal(noKey.status, 401);

    const wrong = await fetch(`${base}/api/link`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${'y'.repeat(40)}` },
      body: JSON.stringify({ userId: 1, username: 'a' }),
    });
    assert.equal(wrong.status, 401);
  });

  test('rejects invalid input', async () => {
    const res = await fetch(`${base}/api/link`, {
      method: 'POST', headers: gameHeaders,
      body: JSON.stringify({ userId: 'abc', username: '' }),
    });
    assert.equal(res.status, 400);
  });

  test('position update for unknown player returns 404', async () => {
    const res = await fetch(`${base}/api/position/update`, {
      method: 'POST', headers: gameHeaders,
      body: JSON.stringify({ userId: 999, x: 0, y: 0, z: 0 }),
    });
    assert.equal(res.status, 404);
  });
});

describe('link activation', () => {
  before(() => start());
  after(() => stop());

  test('link is returned, info does not consume it, activation sets cookie', async () => {
    const { token, url } = await createLink(101, 'Ahmed');
    assert.match(url, /\/a\/[A-Za-z0-9_-]{16,64}$/);

    const info = await (await fetch(`${base}/api/link/${token}`)).json();
    assert.equal(info.status, 'pending');
    assert.equal(info.username, 'Ahmed');

    const res = await activate(token);
    assert.equal(res.status, 200);
    const cookie = cookieFrom(res);
    assert.match(cookie, /^nt_sid=/);
    assert.match(res.headers.get('set-cookie'), /HttpOnly/);
    assert.match(res.headers.get('set-cookie'), /SameSite=Strict/);

    const session = await (await fetch(`${base}/api/session`, { headers: { cookie } })).json();
    assert.deepEqual(session, { linked: true, username: 'Ahmed' });
  });

  test('a link can be used only once', async () => {
    const { token } = await createLink(102);
    assert.equal((await activate(token)).status, 200);
    const again = await activate(token);
    assert.equal(again.status, 409);
    assert.equal((await again.json()).status, 'used');
  });

  test('parallel activations: exactly one succeeds', async () => {
    const { token } = await createLink(103);
    const results = await Promise.all(Array.from({ length: 20 }, () => activate(token)));
    const ok = results.filter((r) => r.status === 200).length;
    assert.equal(ok, 1);
  });

  test('invalid or malformed tokens are rejected', async () => {
    const bogus = 'A'.repeat(22);
    assert.equal((await activate(bogus)).status, 409);
    const malformed = await activate('short');
    assert.equal(malformed.status, 400);
    const info = await (await fetch(`${base}/api/link/${bogus}`)).json();
    assert.equal(info.status, 'invalid');
  });

  test('requesting a new link invalidates the previous unused link', async () => {
    const first = await createLink(104);
    const second = await createLink(104);
    assert.equal((await activate(first.token)).status, 409);
    assert.equal((await activate(second.token)).status, 200);
  });

  test('activation fails if Roblox already ended the session', async () => {
    const { token } = await createLink(105);
    await fetch(`${base}/api/session/end`, {
      method: 'POST', headers: gameHeaders, body: JSON.stringify({ userId: 105 }),
    });
    assert.equal((await activate(token)).status, 409);
  });

  test('activation rate limit is enforced', async () => {
    await stop();
    await start({ activateLimit: 3 });
    const { token } = await createLink(106);
    const statuses = [];
    for (let i = 0; i < 5; i++) statuses.push((await activate(token)).status);
    assert.ok(statuses.includes(429), `expected 429 in ${statuses}`);
  });
});

describe('link expiry', () => {
  before(() => start({ linkTtlMs: 150 }));
  after(() => stop());

  test('expired link cannot be activated', async () => {
    const { token } = await createLink(201);
    await new Promise((r) => setTimeout(r, 250));
    const info = await (await fetch(`${base}/api/link/${token}`)).json();
    assert.equal(info.status, 'expired');
    assert.equal((await activate(token)).status, 409);
  });
});

describe('website WebSocket', () => {
  before(() => start());
  after(() => stop());

  test('connection without cookie is refused with an error message', async () => {
    const state = await openWs(null);
    await waitFor(() => state.closed !== null);
    const { messages } = state;
    assert.equal(messages[0].type, 'error');
    assert.equal(messages[0].reason, 'no_session');
  });

  test('linked browser receives linked + nearby updates; far players excluded', async () => {
    const near = await createLink(301, 'Near');
    const far = await createLink(302, 'Far');
    const me = await createLink(300, 'Me');
    const cookie = cookieFrom(await activate(me.token));
    await activate(near.token);
    await activate(far.token);

    await fetch(`${base}/api/position/update`, { method: 'POST', headers: gameHeaders,
      body: JSON.stringify({ userId: 301, x: 10, y: 0, z: 0 }) });
    await fetch(`${base}/api/position/update`, { method: 'POST', headers: gameHeaders,
      body: JSON.stringify({ userId: 302, x: 500, y: 0, z: 0 }) });
    await fetch(`${base}/api/position/update`, { method: 'POST', headers: gameHeaders,
      body: JSON.stringify({ userId: 300, x: 0, y: 0, z: 0 }) });

    const { ws, messages } = await openWs(cookie);
    await waitFor(() => messages.some((m) => m.type === 'nearby_update' && m.players.length > 0));
    const nearby = messages.filter((m) => m.type === 'nearby_update').at(-1).players;
    assert.deepEqual(nearby.map((p) => p.userId), [301]);
    assert.ok(messages.some((m) => m.type === 'linked' && m.username === 'Me'));
    ws.close();
  });

  test('webrtc signal is relayed only between nearby linked players', async () => {
    const a = await createLink(401, 'A');
    const b = await createLink(402, 'B');
    const c = await createLink(403, 'C');
    const cookieA = cookieFrom(await activate(a.token));
    const cookieB = cookieFrom(await activate(b.token));
    const cookieC = cookieFrom(await activate(c.token));
    const pos = (id, x) => fetch(`${base}/api/position/update`, { method: 'POST', headers: gameHeaders,
      body: JSON.stringify({ userId: id, x, y: 0, z: 0 }) });
    await pos(401, 0); await pos(402, 5); await pos(403, 900);

    const A = await openWs(cookieA);
    const B = await openWs(cookieB);
    A.ws.send(JSON.stringify({ type: 'webrtc_signal', to: 402, signal: { sdp: 'hello' } }));
    await waitFor(() => B.messages.some((m) => m.type === 'webrtc_signal'));
    assert.equal(B.messages.find((m) => m.type === 'webrtc_signal').from, 401);

    A.ws.send(JSON.stringify({ type: 'webrtc_signal', to: 403, signal: { sdp: 'far' } }));
    const C = await openWs(cookieC);
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(C.messages.some((m) => m.type === 'webrtc_signal'), false);
    A.ws.close(); B.ws.close(); C.ws.close();
  });

  test('mic toggle from browser is picked up by Roblox position response', async () => {
    const p = await createLink(501, 'Mic');
    const cookie = cookieFrom(await activate(p.token));
    const { ws } = await openWs(cookie);
    ws.send(JSON.stringify({ type: 'mic_toggle', muted: true }));
    await new Promise((r) => setTimeout(r, 100));
    const res = await fetch(`${base}/api/position/update`, { method: 'POST', headers: gameHeaders,
      body: JSON.stringify({ userId: 501, x: 0, y: 0, z: 0 }) });
    assert.equal((await res.json()).muted, true);
    ws.close();
  });

  test('unlink ends the session; Roblox then gets 404 and must request a new link', async () => {
    const p = await createLink(601, 'Leaver');
    const cookie = cookieFrom(await activate(p.token));
    const res = await fetch(`${base}/api/session/unlink`, { method: 'POST', headers: { cookie } });
    assert.equal(res.status, 200);
    const pos = await fetch(`${base}/api/position/update`, { method: 'POST', headers: gameHeaders,
      body: JSON.stringify({ userId: 601, x: 0, y: 0, z: 0 }) });
    assert.equal(pos.status, 404);
  });
});

describe('radio state mirroring', () => {
  before(() => start());
  after(() => stop());

  test('server mirrors Roblox radio decisions to the linked browser only', async () => {
    const p = await createLink(801, 'Radio');
    const cookie = cookieFrom(await activate(p.token));
    const { ws, messages } = await openWs(cookie);
    await waitFor(() => messages.some((m) => m.type === 'radio_state'));

    const post = (body) => fetch(`${base}/api/radio/state`, { method: 'POST', headers: gameHeaders, body: JSON.stringify(body) });
    assert.equal((await post({ userId: 801, channel: 4, talking: false })).status, 200);
    await waitFor(() => messages.some((m) => m.type === 'radio_state' && m.channel === 4));
    assert.equal((await post({ userId: 801, channel: 4, talking: true })).status, 200);
    await waitFor(() => messages.some((m) => m.type === 'radio_state' && m.talking === true));

    // leaving clears talking even if Roblox sends talking=true
    assert.equal((await post({ userId: 801, talking: true })).status, 200);
    await waitFor(() => messages.filter((m) => m.type === 'radio_state').at(-1).channel === null);
    assert.equal(messages.filter((m) => m.type === 'radio_state').at(-1).talking, false);

    // invalid channel values are rejected
    assert.equal((await post({ userId: 801, channel: 0, talking: false })).status, 400);
    assert.equal((await post({ userId: 801, channel: 21, talking: false })).status, 400);
    assert.equal((await post({ userId: 801, channel: 'police', talking: false })).status, 400);
    assert.equal((await post({ userId: 801, channel: 3.5, talking: false })).status, 400);
    assert.equal((await post({ userId: 801, channel: 2, talking: 'yes' })).status, 400);
    ws.close();
  });

  test('radio state for unknown player returns 404', async () => {
    const res = await fetch(`${base}/api/radio/state`, { method: 'POST', headers: gameHeaders,
      body: JSON.stringify({ userId: 98765, talking: false }) });
    assert.equal(res.status, 404);
  });
});

describe('radio channels from the website', () => {
  before(() => start());
  after(() => stop());

  const post = (path, body) => fetch(`${base}${path}`, {
    method: 'POST', headers: gameHeaders, body: JSON.stringify(body),
  });
  const setTeam = (userId, team) => post('/api/radio/team', { userId, team });
  const radioMsgs = (state, from) => state.messages.slice(from)
    .filter((m) => m.type === 'radio_state' || m.type === 'radio_error');

  // يرسل رسالة ويرجّع أول رد جديد بعدها فقط (مو الرسائل القديمة)
  async function send(state, msg) {
    const from = state.messages.length;
    state.ws.send(JSON.stringify(msg));
    await waitFor(() => radioMsgs(state, from).length > 0);
    return radioMsgs(state, from).at(-1);
  }

  test('channel list exposes rules to the website', async () => {
    const data = await (await fetch(`${base}/api/radio/channels`)).json();
    assert.equal(data.max, 20);
    assert.equal(data.channels.length, 20);
    assert.deepEqual(data.channels[0], { channel: 1, teams: ['Police'] });
    assert.equal(data.channels[5].teams, null); // القناة 6 مفتوحة
  });

  test('a player can only join channels allowed for their team', async () => {
    const cop = await createLink(901, 'Cop');
    const civ = await createLink(902, 'Civ');
    const copWs = await openWs(cookieFrom(await activate(cop.token)));
    const civWs = await openWs(cookieFrom(await activate(civ.token)));
    await setTeam(901, 'Police');
    await setTeam(902, 'Civilian');

    const copState = await send(copWs, { type: 'radio_join', channel: 2 });
    assert.equal(copState.type, 'radio_state');
    assert.equal(copState.channel, 2);

    const denied = await send(civWs, { type: 'radio_join', channel: 2 });
    assert.equal(denied.type, 'radio_error');
    assert.equal(denied.message, 'ما عندك صلاحية للقناة 2');

    const open = await send(civWs, { type: 'radio_join', channel: 6 });
    assert.equal(open.type, 'radio_state');
    assert.equal(open.channel, 6);

    copWs.ws.close(); civWs.ws.close();
  });

  test('every invalid channel number is rejected', async () => {
    const p = await createLink(903, 'Invalid');
    const { ws, messages } = await openWs(cookieFrom(await activate(p.token)));
    const state = { ws, messages };
    for (const bad of [0, 21, -1, 2.5, 'police', null]) {
      const reply = await send(state, { type: 'radio_join', channel: bad });
      assert.equal(reply.type, 'radio_error', `value ${JSON.stringify(bad)} should be rejected`);
      assert.equal(reply.message, 'رقم القناة غير صحيح');
    }
    ws.close();
  });

  test('a player without a known team gets only open channels', async () => {
    const p = await createLink(908, 'NoTeam');
    const state = await openWs(cookieFrom(await activate(p.token)));
    const denied = await send(state, { type: 'radio_join', channel: 4 });
    assert.equal(denied.type, 'radio_error');
    const open = await send(state, { type: 'radio_join', channel: 6 });
    assert.equal(open.channel, 6);
    state.ws.close();
  });

  test('team change removes the player from a restricted channel', async () => {
    const p = await createLink(904, 'Mover');
    const state = await openWs(cookieFrom(await activate(p.token)));
    await setTeam(904, 'Police');
    await send(state, { type: 'radio_join', channel: 1 });

    const from = state.messages.length;
    assert.equal((await setTeam(904, 'Civilian')).status, 200);
    await waitFor(() => radioMsgs(state, from).some((m) => m.channel === null));
    const last = radioMsgs(state, from).at(-1);
    assert.equal(last.channel, null);
    assert.equal(last.message, 'تم إخراجك من القناة لأن تيمك تغيّر');
    state.ws.close();
  });

  test('team change keeps the player in an open channel', async () => {
    const p = await createLink(905, 'Open');
    const state = await openWs(cookieFrom(await activate(p.token)));
    await setTeam(905, 'Police');
    await send(state, { type: 'radio_join', channel: 7 });

    const from = state.messages.length;
    await setTeam(905, 'Justice');
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(radioMsgs(state, from).length, 0, 'no channel change message expected');
    state.ws.close();
  });

  test('talk requires a channel; leave clears it', async () => {
    const p = await createLink(906, 'Talker');
    const state = await openWs(cookieFrom(await activate(p.token)));
    await setTeam(906, 'Police');

    const refused = await send(state, { type: 'radio_talk', talking: true });
    assert.equal(refused.type, 'radio_error');
    assert.equal(refused.message, 'اختر قناة أولاً');

    await send(state, { type: 'radio_join', channel: 3 });
    const talking = await send(state, { type: 'radio_talk', talking: true });
    assert.equal(talking.channel, 3);
    assert.equal(talking.talking, true);

    const left = await send(state, { type: 'radio_leave' });
    assert.equal(left.channel, null);
    assert.equal(left.talking, false);
    state.ws.close();
  });

  test('bad team payloads are rejected', async () => {
    const p = await createLink(907, 'Bad');
    await activate(p.token);
    assert.equal((await setTeam(907, '')).status, 400);
    assert.equal((await setTeam(907, 'x'.repeat(41))).status, 400);
    assert.equal((await setTeam(907, 42)).status, 400);
    assert.equal((await setTeam(98765, 'Police')).status, 404);
  });
});

describe('secrets and logs', () => {
  before(() => start());
  after(() => stop());

  test('activation token never appears in server logs', async () => {
    const captured = [];
    const origLog = console.log;
    const origErr = console.error;
    console.log = (...a) => captured.push(a.join(' '));
    console.error = (...a) => captured.push(a.join(' '));
    let token;
    try {
      ({ token } = await createLink(701));
      await (await fetch(`${base}/api/link/${token}`)).json();
      await activate(token);
      await fetch(`${base}/a/${token}`);
      await fetch(`${base}/api/link/${token}/activate`, { method: 'POST' });
      await fetch(`${base}/api/link/bogus-token-that-is-long-enough/activate`, { method: 'POST' });
    } finally {
      console.log = origLog;
      console.error = origErr;
    }
    assert.ok(captured.length > 0, 'expected at least one log line from link creation');
    assert.equal(captured.some((line) => line.includes(token)), false);
  });

  test('security headers are present on the page', async () => {
    const res = await fetch(`${base}/a/abcdefghijklmnopqrstuv`);
    assert.equal(res.headers.get('referrer-policy'), 'no-referrer');
    assert.match(res.headers.get('content-security-policy'), /default-src 'self'/);
    assert.equal(res.headers.get('x-frame-options'), 'DENY');
  });

  test('refuses to start without a strong API key', () => {
    assert.throws(() => createVoiceServer({ apiKey: 'short' }), /API_KEY/);
    assert.throws(() => createVoiceServer({}), /API_KEY/);
  });
});
