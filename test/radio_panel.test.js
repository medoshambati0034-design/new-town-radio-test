import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';

const here = path.dirname(fileURLToPath(import.meta.url));
const panelSource = fs.readFileSync(path.join(here, '..', 'public', 'radio-panel.js'), 'utf8');

// قائمة القنوات كما يرجعها السيرفر (نفس القواعد)
const CHANNELS = {
  max: 20,
  channels: Array.from({ length: 20 }, (_, i) => {
    const n = i + 1;
    const teams = { 1: ['Police'], 2: ['Police'], 3: ['Police'], 4: ['EMS'], 5: ['Justice'] }[n];
    return { channel: n, teams: teams || null };
  }),
};

function makePage() {
  const dom = new JSDOM('<!doctype html><div id="root"></div>', { runScripts: 'outside-only', pretendToBeVisual: true });
  dom.window.eval(panelSource);
  return dom;
}

async function mount(opts = {}) {
  const dom = makePage();
  const doc = dom.window.document;
  const sent = [];
  const panel = dom.window.RadioPanel.create({
    container: doc.getElementById('root'),
    send: (obj) => sent.push(JSON.parse(JSON.stringify(obj))), // نسخة من realm الاختبار
    fetchChannels: async () => CHANNELS,
    timeoutMs: opts.timeoutMs || 4000,
  });
  // ننتظر تحميل القنوات (fetchChannels غير متزامنة)
  await new Promise((r) => setTimeout(r, 0));
  const input = panel._input;
  const status = () => doc.querySelector('.radio-status').textContent;
  const current = () => doc.querySelector('.radio-current').textContent;
  const button = (n) => panel._buttons()[n];
  const enter = () => input.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Enter' }));
  const type = (text) => { input.value = text; input.dispatchEvent(new dom.window.Event('input')); };
  const joinBtn = doc.querySelector('.radio-btn.primary');
  const leaveBtn = doc.querySelectorAll('.radio-btn')[1];
  return { dom, doc, panel, sent, input, status, current, button, enter, type, joinBtn, leaveBtn };
}

describe('parseChannel and canUse', () => {
  const dom = makePage();
  const { parseChannel, canUse } = dom.window.RadioPanel;

  test('parseChannel accepts only positive digits', () => {
    assert.equal(parseChannel('4'), 4);
    assert.equal(parseChannel(' 12 '), 12);
    assert.equal(parseChannel('0'), null);
    assert.equal(parseChannel(''), null);
    assert.equal(parseChannel('abc'), null);
    assert.equal(parseChannel('123'), null);
    assert.equal(parseChannel(null), null);
  });

  test('canUse mirrors server rules', () => {
    assert.equal(canUse(2, 'Police', CHANNELS.channels), true);
    assert.equal(canUse(2, 'Civilian', CHANNELS.channels), false);
    assert.equal(canUse(2, null, CHANNELS.channels), false);
    assert.equal(canUse(6, 'Civilian', CHANNELS.channels), true);
    assert.equal(canUse(6, null, CHANNELS.channels), true);
    assert.equal(canUse(99, 'Police', CHANNELS.channels), false);
  });
});

describe('radio panel in the page', () => {
  test('renders 20 channel buttons and an input', async () => {
    const p = await mount();
    assert.equal(p.doc.querySelectorAll('.radio-ch').length, 20);
    assert.equal(p.input.maxLength, 2);
    assert.equal(p.current(), 'غير متصل');
  });

  test('typing a number and pressing Enter sends a join request', async () => {
    const p = await mount();
    p.panel.setTeam('Police');
    p.type('2');
    p.enter();
    assert.deepEqual(p.sent, [{ type: 'radio_join', channel: 2 }]);
    assert.match(p.status(), /جارٍ الاتصال بالقناة 2/);
  });

  test('input keeps only digits and at most two characters', async () => {
    const p = await mount();
    p.type('a1b2c3');
    assert.equal(p.input.value, '12');
  });

  test('clicking a channel number joins it', async () => {
    const p = await mount();
    p.panel.setTeam('EMS');
    p.button(4).click();
    assert.deepEqual(p.sent, [{ type: 'radio_join', channel: 4 }]);
  });

  test('a second join while pending is ignored', async () => {
    const p = await mount();
    p.panel.setTeam('Police');
    p.type('2'); p.enter();
    p.type('3'); p.enter();
    assert.equal(p.sent.length, 1);
  });

  test('locked channels are refused locally with a clear message', async () => {
    const p = await mount();
    p.panel.setTeam('Civilian');
    assert.equal(p.button(2).classList.contains('locked'), true);
    assert.equal(p.button(6).classList.contains('locked'), false);
    p.type('2'); p.enter();
    assert.equal(p.sent.length, 0);
    assert.equal(p.status(), 'ما عندك صلاحية للقناة 2');
  });

  test('out-of-range numbers are rejected before sending', async () => {
    const p = await mount();
    p.panel.setTeam('Police');
    p.type('21'); p.enter();
    assert.equal(p.sent.length, 0);
    assert.equal(p.status(), 'رقم القناة غير صحيح (1 - 20)');
  });

  test('empty input asks for a number', async () => {
    const p = await mount();
    p.enter();
    assert.equal(p.sent.length, 0);
    assert.match(p.status(), /اكتب رقم القناة/);
  });

  test('server state shows the channel, highlights it and enables leave', async () => {
    const p = await mount();
    p.panel.setTeam('Police');
    p.type('2'); p.enter();
    p.panel.onState({ type: 'radio_state', channel: 2, talking: false, message: 'متصل بالقناة 2' });
    assert.equal(p.current(), 'متصل بالقناة 2');
    assert.equal(p.button(2).classList.contains('active'), true);
    assert.equal(p.leaveBtn.disabled, false);
    assert.equal(p.status(), 'متصل بالقناة 2');
  });

  test('leave sends radio_leave when connected', async () => {
    const p = await mount();
    p.panel.setTeam('Police');
    p.panel.onState({ type: 'radio_state', channel: 2, talking: false, message: '' });
    p.leaveBtn.click();
    assert.deepEqual(p.sent.at(-1), { type: 'radio_leave' });
  });

  test('leave is disabled when not connected', async () => {
    const p = await mount();
    assert.equal(p.leaveBtn.disabled, true);
    p.leaveBtn.click();
    assert.equal(p.sent.length, 0);
  });

  test('server error shows the message and allows another try', async () => {
    const p = await mount();
    p.panel.setTeam('Police');
    p.type('2'); p.enter();
    p.panel.onError({ type: 'radio_error', message: 'ما عندك صلاحية للقناة 2' });
    assert.equal(p.status(), 'ما عندك صلاحية للقناة 2');
    assert.equal(p.doc.querySelector('.radio-status').classList.contains('err'), true);
    p.enter();
    assert.equal(p.sent.length, 2);
  });

  test('a silent server is detected by the timeout', async () => {
    const p = await mount({ timeoutMs: 30 });
    p.panel.setTeam('Police');
    p.type('2'); p.enter();
    await new Promise((r) => setTimeout(r, 80));
    assert.equal(p.status(), 'ما وصل رد من السيرفر، حاول مرة ثانية');
    p.enter();
    assert.equal(p.sent.length, 2);
  });

  test('team change updates locks; open channels stay available', async () => {
    const p = await mount();
    p.panel.setTeam('Police');
    assert.equal(p.button(4).classList.contains('locked'), true);
    p.panel.setTeam('EMS');
    assert.equal(p.button(4).classList.contains('locked'), false);
    assert.equal(p.button(2).classList.contains('locked'), true);
    p.panel.setTeam(null);
    assert.equal(p.button(6).classList.contains('locked'), false);
    assert.equal(p.button(1).classList.contains('locked'), true);
  });

  test('reset (disconnect) clears the channel and the input', async () => {
    const p = await mount();
    p.panel.setTeam('Police');
    p.type('2');
    p.panel.onState({ type: 'radio_state', channel: 2, talking: false, message: '' });
    p.panel.reset();
    assert.equal(p.current(), 'غير متصل');
    assert.equal(p.input.value, '');
    assert.equal(p.button(2).classList.contains('active'), false);
  });

  test('a failing channel fetch shows an error instead of breaking', async () => {
    const dom = makePage();
    const doc = dom.window.document;
    dom.window.RadioPanel.create({
      container: doc.getElementById('root'),
      send: () => {},
      fetchChannels: async () => { throw new Error('offline'); },
    });
    await new Promise((r) => setTimeout(r, 0));
    assert.equal(doc.querySelector('.radio-status').textContent, 'تعذّر تحميل القنوات');
  });
});
