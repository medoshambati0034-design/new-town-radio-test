/*
  قسم الراديو في الموقع (يظهر تحت المايك بعد الربط).
  - اكتب رقم القناة واضغط "دخول" (أو Enter)، أو اختر من الأرقام.
  - السيرفر هو المرجع للصلاحيات. الواجهة تقفل القنوات الممنوعة كتلميح فقط.
  - الصوت الفعلي للراديو لم يُبنَ بعد: هذا القسم يدخل القناة ويعرض حالتها.
*/
(function (global) {
  'use strict';

  var DEFAULT_TIMEOUT_MS = 4000;

  // الرقم المكتوب -> رقم قناة صحيح أو null
  function parseChannel(text) {
    var t = String(text == null ? '' : text).trim();
    if (!/^\d{1,2}$/.test(t)) return null;
    var n = Number(t);
    return n >= 1 ? n : null;
  }

  // مرآة تلميحية لقواعد السيرفر (السيرفر يتحقق دائماً)
  function canUse(channel, team, channels) {
    var rule = null;
    for (var i = 0; i < channels.length; i++) {
      if (channels[i].channel === channel) { rule = channels[i]; break; }
    }
    if (!rule) return false;
    if (rule.teams === null) return true;
    return typeof team === 'string' && rule.teams.indexOf(team) !== -1;
  }

  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  function create(opts) {
    var container = opts.container;
    var send = opts.send;
    var fetchChannels = opts.fetchChannels || function () {
      return fetch('/api/radio/channels', { cache: 'no-store' }).then(function (r) { return r.json(); });
    };
    var timeoutMs = opts.timeoutMs || DEFAULT_TIMEOUT_MS;

    var state = {
      channel: null,      // القناة الحالية حسب السيرفر
      team: null,         // تيم اللاعب (من السيرفر)
      channels: [],       // قواعد القنوات من السيرفر
      pending: false,
      token: 0,
    };

    // ---------- بناء الواجهة ----------
    container.innerHTML = '';
    var panel = el('div', 'panel radio-panel');
    panel.appendChild(el('h3', null, 'الراديو'));
    panel.appendChild(el('div', 'sub', 'اكتب رقم القناة واضغط دخول، أو اختر من الأرقام تحت'));

    var current = el('div', 'radio-current', 'غير متصل');
    panel.appendChild(current);

    // يوضح للاعب هل وصل تيمه من اللعبة (إذا لا، القنوات المقيدة تبقى مقفلة)
    var teamLine = el('div', 'radio-team', '');
    panel.appendChild(teamLine);

    var row = el('div', 'radio-input-row');
    var input = el('input', 'radio-input');
    input.type = 'text';
    input.inputMode = 'numeric';
    input.maxLength = 2;
    input.placeholder = 'رقم القناة';
    input.setAttribute('aria-label', 'رقم القناة');
    var joinBtn = el('button', 'radio-btn primary', 'دخول');
    joinBtn.type = 'button';
    var leaveBtn = el('button', 'radio-btn', 'خروج');
    leaveBtn.type = 'button';
    row.appendChild(input);
    row.appendChild(joinBtn);
    row.appendChild(leaveBtn);
    panel.appendChild(row);

    var status = el('div', 'radio-status', '');
    panel.appendChild(status);

    var grid = el('div', 'radio-grid');
    panel.appendChild(grid);
    container.appendChild(panel);

    var buttons = {}; // channel -> button

    function buildGrid(max) {
      grid.innerHTML = '';
      buttons = {};
      for (var c = 1; c <= max; c++) {
        (function (channel) {
          var b = el('button', 'radio-ch', String(channel));
          b.type = 'button';
          b.addEventListener('click', function () { input.value = String(channel); join(channel); });
          buttons[channel] = b;
          grid.appendChild(b);
        })(c);
      }
    }

    function setStatus(message, kind) {
      status.textContent = message || '';
      status.className = 'radio-status' + (kind ? ' ' + kind : '');
    }

    function render() {
      teamLine.textContent = state.team
        ? ('تيمك: ' + state.team)
        : 'ما وصل تيمك من اللعبة، القنوات المقيدة مقفلة (افتح الماب وتأكد من تحديث السكربتات)';
      teamLine.className = 'radio-team' + (state.team ? '' : ' warn');
      current.textContent = state.channel ? ('متصل بالقناة ' + state.channel) : 'غير متصل';
      current.className = 'radio-current' + (state.channel ? ' on' : '');
      leaveBtn.disabled = !state.channel || state.pending;
      joinBtn.disabled = state.pending;
      Object.keys(buttons).forEach(function (key) {
        var channel = Number(key);
        var b = buttons[key];
        var allowed = canUse(channel, state.team, state.channels);
        b.classList.toggle('active', channel === state.channel);
        b.classList.toggle('locked', !allowed);
        b.disabled = state.pending;
        b.title = allowed ? '' : 'هذه القناة لتيم آخر';
      });
    }

    function arm() {
      state.token += 1;
      var mine = state.token;
      setTimeout(function () {
        if (mine === state.token && state.pending) {
          state.pending = false;
          setStatus('ما وصل رد من السيرفر، حاول مرة ثانية', 'err');
          render();
        }
      }, timeoutMs);
    }

    function join(channel) {
      if (state.pending) return;
      if (channel == null) { setStatus('اكتب رقم القناة ثم اضغط دخول', 'err'); return; }
      if (state.channels.length && (channel < 1 || channel > state.channels.length)) {
        setStatus('رقم القناة غير صحيح (1 - ' + state.channels.length + ')', 'err');
        return;
      }
      if (channel === state.channel) { setStatus('أنت متصل بالقناة ' + channel, ''); return; }
      if (!canUse(channel, state.team, state.channels)) {
        setStatus('ما عندك صلاحية للقناة ' + channel, 'err');
        return;
      }
      state.pending = true;
      setStatus('جارٍ الاتصال بالقناة ' + channel + '...', '');
      send({ type: 'radio_join', channel: channel });
      arm();
      render();
    }

    function leave() {
      if (state.pending || !state.channel) return;
      state.pending = true;
      setStatus('جارٍ الخروج من القناة...', '');
      send({ type: 'radio_leave' });
      arm();
      render();
    }

    // ---------- الأحداث ----------
    input.addEventListener('input', function () {
      input.value = input.value.replace(/\D/g, '').slice(0, 2);
    });
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') join(parseChannel(input.value));
    });
    joinBtn.addEventListener('click', function () { join(parseChannel(input.value)); });
    leaveBtn.addEventListener('click', leave);

    // ---------- تحميل القنوات ----------
    fetchChannels().then(function (data) {
      state.channels = data.channels || [];
      buildGrid(data.max || state.channels.length || 20);
      render();
    }).catch(function () {
      setStatus('تعذّر تحميل القنوات', 'err');
    });

    // ---------- واجهة للاستخدام من الصفحة ----------
    return {
      setTeam: function (team) {
        state.team = typeof team === 'string' && team.length ? team : null;
        render();
      },
      onState: function (msg) {
        state.pending = false;
        state.token += 1;
        var previous = state.channel;
        state.channel = (msg.channel === null || msg.channel === undefined) ? null : msg.channel;
        if (state.channel !== previous) input.value = '';
        setStatus(msg.message || (state.channel ? ('متصل بالقناة ' + state.channel) : 'غير متصل'), '');
        render();
      },
      onError: function (msg) {
        state.pending = false;
        state.token += 1;
        setStatus(msg.message || 'حدث خطأ في الراديو', 'err');
        render();
      },
      reset: function () {
        state.channel = null;
        state.pending = false;
        state.token += 1;
        input.value = '';
        setStatus('', '');
        render();
      },
      // للاختبار فقط
      _state: function () { return state; },
      _input: input,
      _buttons: function () { return buttons; },
    };
  }

  global.RadioPanel = { create: create, parseChannel: parseChannel, canUse: canUse };
})(typeof window !== 'undefined' ? window : globalThis);
