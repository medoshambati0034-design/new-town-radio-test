// اختبار تكامل: يحمّل صفحة الموقع الحقيقية في DOM ويتتبع الربط كاملاً:
// تشغيل المايك -> رسالة linked من السيرفر -> لوحة الراديو -> دخول قناة -> ردّ السيرفر.
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM, VirtualConsole } from 'jsdom';

const here = path.dirname(fileURLToPath(import.meta.url));
const publicDir = path.join(here, '..', 'public');
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

function buildChannels() {
  const teamsFor = (n) => ({ 1: ['Police'], 2: ['Police'], 3: ['Police'], 4: ['EMS'], 5: ['Justice'] }[n] || null);
  return { max: 20, channels: Array.from({ length: 20 }, (_, i) => ({ channel: i + 1, teams: teamsFor(i + 1) })) };
}

async function loadPage({ team }) {
  let html = fs.readFileSync(path.join(publicDir, 'index.html'), 'utf8');
  const panelJs = fs.readFileSync(path.join(publicDir, 'radio-panel.js'), 'utf8');
  html = html.replace('<script src="/radio-panel.js"></script>', `<script>${panelJs}</script>`);

  const sockets = [];
  class FakeWS {
    constructor(url) { this.url = url; this.readyState = 0; this.sent = []; sockets.push(this); }
    send(d) { this.sent.push(JSON.parse(d)); }
    close() { this.readyState = 3; if (this.onclose) this.onclose({}); }
    open() { this.readyState = 1; if (this.onopen) this.onopen({}); }
    recv(obj) { if (this.onmessage) this.onmessage({ data: JSON.stringify(obj) }); }
  }
  FakeWS.OPEN = 1;

  const payloads = {
    '/api/session': { linked: true, username: 'Tester', team },
    '/api/radio/channels': buildChannels(),
  };
  const fakeFetch = async (url) => {
    const key = Object.keys(payloads).find((k) => url.includes(k));
    const body = key ? payloads[key] : {};
    return { ok: true, status: 200, json: async () => body, text: async () => JSON.stringify(body) };
  };

  const stub = new Proxy(function () {}, {
    get: (t, k) => (k === 'then' ? undefined : k === Symbol.toPrimitive ? () => 0 : stub),
    apply: () => stub,
    construct: () => stub,
  });

  const vc = new VirtualConsole();
  const errors = [];
  vc.on('jsdomError', (e) => errors.push(String(e && e.message || e)));

  const dom = new JSDOM(html, {
    runScripts: 'dangerously', pretendToBeVisual: true, url: 'https://localhost/', virtualConsole: vc,
    beforeParse(window) {
      window.WebSocket = FakeWS;
      window.fetch = fakeFetch;
      window.AudioContext = function () { return stub; };
      window.webkitAudioContext = window.AudioContext;
      window.RTCPeerConnection = function () { return stub; };
      window.RTCSessionDescription = function () { return stub; };
      window.RTCIceCandidate = function () { return stub; };
      window.matchMedia = () => ({ matches: false, addListener() {}, addEventListener() {} });
      window.requestAnimationFrame = (cb) => setTimeout(cb, 16);
      window.HTMLMediaElement.prototype.play = () => Promise.resolve();
      Object.defineProperty(window, 'isSecureContext', { value: true, configurable: true });
      const fakeStream = { getTracks: () => [], getAudioTracks: () => [], getVideoTracks: () => [] };
      Object.defineProperty(window.navigator, 'mediaDevices', { value: {
        getUserMedia: async () => fakeStream, enumerateDevices: async () => [],
        addEventListener() {}, removeEventListener() {},
      }, configurable: true });
    },
  });
  return { dom, doc: dom.window.document, sockets, errors };
}

describe('website radio is linked to the voice session', () => {
  const pages = [];
  after(() => { pages.forEach((p) => { try { p.dom.window.close(); } catch { /* ignore */ } }); });

  test('linking shows the radio panel with team-based locks and joins a channel', async () => {
    const page = await loadPage({ team: 'Police' });
    pages.push(page);
    const { doc, sockets, errors } = page;
    await wait(200);

    assert.equal(typeof page.dom.window.RadioPanel, 'object', 'radio panel script must load');
    assert.equal(doc.querySelectorAll('.radio-ch').length, 20, 'channel buttons are built on page load (dashboard still hidden)');

    // المستخدم يضغط تشغيل المايك (وضع الربط المحفوظ)
    doc.getElementById('connect-btn').click();
    await wait(200);
    const ws = sockets[0];
    assert.ok(ws, 'connection opened after mic tap');
    ws.open();
    ws.recv({ type: 'linked', username: 'Tester', userId: 1, team: 'Police' });
    await wait(200);

    assert.equal(doc.getElementById('dashboard').style.display, 'block');
    assert.equal(doc.querySelectorAll('.radio-ch').length, 20);
    assert.equal(doc.querySelectorAll('.radio-ch.locked').length, 2, 'EMS and Justice locked for Police');
    assert.match(doc.querySelector('.radio-team').textContent, /تيمك: Police/);

    doc.querySelectorAll('.radio-ch')[1].click();
    await wait(20);
    assert.deepEqual(ws.sent.at(-1), { type: 'radio_join', channel: 2 });

    ws.recv({ type: 'radio_state', channel: 2, talking: false, message: 'متصل بالقناة 2' });
    await wait(20);
    assert.equal(doc.querySelector('.radio-current').textContent, 'متصل بالقناة 2');
    assert.equal(doc.querySelectorAll('.radio-ch')[1].classList.contains('active'), true);

    assert.deepEqual(errors, [], 'no page errors');
  });

  test('a player whose team never arrived sees a clear warning', async () => {
    const page = await loadPage({ team: null });
    pages.push(page);
    const { doc, sockets } = page;
    await wait(200);
    doc.getElementById('connect-btn').click();
    await wait(200);
    const ws = sockets[0];
    ws.open();
    ws.recv({ type: 'linked', username: 'NoTeam', userId: 2, team: null });
    await wait(200);
    assert.match(doc.querySelector('.radio-team').textContent, /ما وصل تيمك/);
    assert.equal(doc.querySelector('.radio-team').classList.contains('warn'), true);
  });
});
