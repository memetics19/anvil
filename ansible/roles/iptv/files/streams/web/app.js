/* Kannada TV web page. Works like a TV: it opens playing the last-watched channel full
 * screen; Left/Right (and Channel -/+) change channel, OK shows the channel banner,
 * Up/Down open the channel list, Back closes the list or shows the banner.
 * Only the managed lineup is shown (from /guide.json); streams come from this same origin
 * (/<channel id>), played with mpegts.js, or by the browser itself without MSE. */
(function () {
  'use strict';

  var BANNER_MS = 4000;
  var ZAP_DEBOUNCE_MS = 400;
  var GUIDE_EVERY_MS = 60000;
  var SLOT_RETRIES = 3; // a stream this page just stopped can hold its slot for a moment
  var SLOT_RETRY_MS = 1500;

  if (window.mpegts) {
    // Errors only on the console (a TV browser pays for every log line).
    var lc = mpegts.LoggingControl;
    lc.enableVerbose = lc.enableDebug = lc.enableInfo = lc.enableWarn = false;
  }

  // Stream loader: mpegts.js's own fetch loader, on Chrome, defers the abort of a running
  // stream until the next chunk arrives (seconds for a live source), which keeps the old
  // stream (and its helper slot) alive while the next channel starts. This one aborts the
  // request at once.
  var LiveLoader = null;
  if (window.mpegts && window.fetch && window.ReadableStream && window.AbortController) {
    LiveLoader = class extends mpegts.BaseLoader {
      static isSupported() { return true; }

      constructor() {
        super('live-fetch-loader');
        this._needStash = true;
        this._ac = null;
        this._received = 0;
      }

      destroy() {
        if (this.isWorking()) this.abort();
        super.destroy();
      }

      open(dataSource, range) {
        var S = mpegts.LoaderStatus, E = mpegts.LoaderErrors;
        var ac = new AbortController();
        this._ac = ac;
        this._range = range;
        this._status = S.kConnecting;
        fetch(dataSource.url, { cache: 'no-store', credentials: 'same-origin', signal: ac.signal })
          .then((res) => {
            if (ac.signal.aborted) return null;
            if (!res.ok) {
              this._status = S.kError;
              if (this._onError) this._onError(E.HTTP_STATUS_CODE_INVALID, { code: res.status, msg: res.statusText });
              return null;
            }
            return this._pump(res.body.getReader(), ac);
          })
          .catch((e) => {
            if (ac.signal.aborted) return;
            this._status = S.kError;
            if (this._onError) this._onError(E.EXCEPTION, { code: -1, msg: e && e.message });
          });
      }

      _pump(reader, ac) {
        var S = mpegts.LoaderStatus;
        return reader.read().then((r) => {
          if (ac.signal.aborted) return null;
          if (r.done) {
            this._status = S.kComplete;
            if (this._onComplete) this._onComplete(this._range.from, this._range.from + this._received - 1);
            return null;
          }
          this._status = S.kBuffering;
          var chunk = r.value.buffer;
          var byteStart = this._range.from + this._received;
          this._received += chunk.byteLength;
          if (this._onDataArrival) this._onDataArrival(chunk, byteStart, this._received);
          return this._pump(reader, ac);
        });
      }

      abort() {
        if (this._ac) this._ac.abort();
        this._status = mpegts.LoaderStatus.kComplete;
      }
    };
  }

  var $ = function (id) { return document.getElementById(id); };
  var video = $('video');
  var banner = $('banner');
  var list = $('list');
  var grid = $('grid');

  var channels = [];
  var cards = {};
  var current = null;   // channel tuned (or about to be)
  var engine = null;    // mpegts player
  var state = '';       // tuning | playing | buffering | notlive | busy | ended | error | muted | start
  var lastStop = 0;
  var slotRetries = 0;
  var timers = { banner: 0, zap: 0, retry: 0, wait: 0 };

  function store(key, value) {
    try {
      if (value === undefined) return window.localStorage.getItem(key);
      window.localStorage.setItem(key, value);
    } catch (e) { /* storage blocked: start on the first channel */ }
    return null;
  }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }

  function hhmm(sec) {
    return new Date(sec * 1000).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  }

  function monogram(name) {
    var words = name.replace(/[^A-Za-z0-9 ]/g, '').split(/\s+/).filter(Boolean);
    if (words.length === 1) return words[0].slice(0, 2).toUpperCase();
    return words.slice(0, 2).map(function (w) { return w[0]; }).join('').toUpperCase();
  }

  function hue(id) {
    var h = 0;
    for (var i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) % 360;
    return h;
  }

  function paintLogo(logo, ch) {
    logo.style.setProperty('--hue', hue(ch.id));
    logo.querySelector('.mono').textContent = monogram(ch.name);
    logo.querySelector('.num').textContent = String(ch.number);
  }

  function nowText(ch) { return ch.now ? ch.now.title : 'Live'; }

  // "Until 3:30 PM · Next: News at 3:30"
  function nextText(ch) {
    var parts = [];
    if (ch.now) parts.push('Until ' + hhmm(ch.now.stop));
    if (ch.next) parts.push('Next: ' + ch.next.title);
    return parts.join(' · ');
  }

  function indexOf(id) {
    for (var i = 0; i < channels.length; i++) if (channels[i].id === id) return i;
    return -1;
  }

  function channel(id) { return channels[indexOf(id)] || null; }

  /* ---- banner -------------------------------------------------------------------------- */

  // state -> [text, shown as a problem]
  var STATUS = {
    tuning: ['Tuning…', false],
    buffering: ['Buffering…', false],
    notlive: ['Not live right now', true],
    busy: ['Busy: two streams already play on other screens. OK to retry', true],
    ended: ['The stream ended. OK to retry', true],
    error: ['Cannot play this channel. OK to retry', true],
    muted: ['Press OK for sound', false],
    start: ['Press OK to start', false]
  };

  function paintBanner() {
    var ch = channel(current);
    if (!ch) return;
    paintLogo($('b-logo'), ch);
    $('b-num').textContent = ch.number;
    $('b-name').textContent = ch.name;
    $('b-now').textContent = nowText(ch);
    $('b-next').textContent = nextText(ch);
    var s = STATUS[state];
    var box = $('b-status');
    box.hidden = !s;
    if (s) {
      box.textContent = s[0];
      box.className = 'b-status' + (s[1] ? ' bad' : '');
    }
    banner.dataset.state = state;
  }

  // Shown for a few seconds; it stays while the channel cannot play or plays muted.
  function hideLater() {
    clearTimeout(timers.banner);
    timers.banner = setTimeout(function () {
      if (state === 'playing' || state === 'tuning' || state === 'buffering') banner.hidden = true;
    }, BANNER_MS);
  }

  function showBanner() {
    paintBanner();
    banner.hidden = false;
    hideLater();
  }

  function setState(s) {
    state = s;
    paintBanner();
    if (s === 'playing') hideLater();
    else if (STATUS[s] && STATUS[s][1]) banner.hidden = false;
  }

  /* ---- playback ------------------------------------------------------------------------ */

  // Stops the stream: destroying the player aborts its request, so the helper frees the slot.
  // True if a stream was running.
  function stopEngine() {
    var had = false;
    clearTimeout(timers.retry);
    clearTimeout(timers.wait);
    if (engine) {
      had = true;
      var e = engine;
      engine = null;
      try { e.pause(); } catch (x) { /* already stopped */ }
      try { e.unload(); } catch (x) { /* already unloaded */ }
      try { e.detachMediaElement(); } catch (x) { /* already detached */ }
      try { e.destroy(); } catch (x) { /* already destroyed */ }
      lastStop = Date.now();
    }
    if (video.getAttribute('src')) {
      had = true;
      video.removeAttribute('src');
      video.load();
      lastStop = Date.now();
    }
    return had;
  }

  function failed(code) {
    var justStopped = Date.now() - lastStop < 8000;
    stopEngine();
    if (code === 503 && slotRetries < SLOT_RETRIES && justStopped) {
      slotRetries++;
      setState('tuning');
      var id = current;
      timers.retry = setTimeout(function () { if (current === id) start(id); }, SLOT_RETRY_MS);
      return;
    }
    if (code === 504) setState('notlive');
    else if (code === 503) setState('busy');
    else if (code === 'ended') setState('ended');
    else setState('error');
  }

  function startPlaying() {
    var p = video.play();
    if (!p || !p.catch) return;
    p.catch(function (err) {
      if (!err || err.name !== 'NotAllowedError') return;
      // Autoplay with sound refused before any key press: play muted until OK.
      var id = current;
      video.muted = true;
      var q = video.play();
      if (q && q.catch) q.catch(function () { if (current === id && state === 'tuning') setState('start'); });
    });
  }

  function start(id) {
    stopEngine();
    var url = new URL('/' + encodeURIComponent(id), location.href).href;
    var mse = window.mpegts && mpegts.isSupported() && mpegts.getFeatureList().mseLivePlayback;
    if (mse) {
      var e = mpegts.createPlayer({ type: 'mpegts', isLive: true, url: url }, {
        enableWorker: false,
        lazyLoad: false,
        autoCleanupSourceBuffer: true,
        liveBufferLatencyChasing: true,
        liveBufferLatencyMaxLatency: 8,
        liveBufferLatencyMinRemain: 3,
        customLoader: LiveLoader || undefined
      });
      engine = e;
      e.on(mpegts.Events.ERROR, function (type, detail, info) {
        if (engine !== e) return;
        if (detail === mpegts.ErrorDetails.NETWORK_STATUS_CODE_INVALID && info && info.code) failed(info.code);
        else failed(detail || type);
      });
      e.on(mpegts.Events.LOADING_COMPLETE, function () { if (engine === e) failed('ended'); });
      e.attachMediaElement(video);
      e.load();
    } else {
      video.src = url; // no MSE: the browser's own player
    }
    startPlaying();
  }

  function mark(id) {
    if (current && cards[current]) cards[current].classList.remove('on');
    current = id;
    if (cards[id]) cards[id].classList.add('on');
  }

  // Tune (list, start-up, end of a zap). A running stream is stopped first and the next one
  // starts a moment later, so the two never overlap at the helper.
  function tune(id) {
    if (!channel(id)) return;
    clearTimeout(timers.zap);
    if (id === current && engine && (state === 'playing' || state === 'muted' || state === 'buffering')) {
      showBanner(); // already on it
      return;
    }
    mark(id);
    store('tv.last', id);
    slotRetries = 0;
    state = 'tuning';
    showBanner();
    var gap = stopEngine() ? 250 : 0;
    timers.zap = setTimeout(function () { if (current === id) start(id); }, gap);
  }

  // Left/Right: the stream stops and the banner follows every press at once; only the
  // channel the presses settle on is tuned.
  function zap(step) {
    if (!channels.length) return;
    var i = indexOf(current);
    var id = channels[((i < 0 ? 0 : i) + step + channels.length) % channels.length].id;
    stopEngine();
    mark(id);
    state = 'tuning';
    showBanner();
    clearTimeout(timers.zap);
    timers.zap = setTimeout(function () { tune(id); }, ZAP_DEBOUNCE_MS);
  }

  function retry() {
    slotRetries = 0;
    state = 'tuning';
    showBanner();
    start(current);
  }

  // OK in playback: sound on if muted, retry if the channel cannot play, else the banner.
  function ok() {
    if (video.muted) {
      video.muted = false;
      if (state === 'muted') state = 'playing';
    }
    if (STATUS[state] && STATUS[state][1] || state === 'start') retry();
    else showBanner();
  }

  video.addEventListener('playing', function () {
    clearTimeout(timers.wait);
    setState(video.muted ? 'muted' : 'playing');
  });
  video.addEventListener('waiting', function () {
    clearTimeout(timers.wait);
    timers.wait = setTimeout(function () {
      if (state === 'playing') { state = 'buffering'; showBanner(); }
    }, 1500);
  });
  video.addEventListener('error', function () {
    if (!engine && video.getAttribute('src')) failed('native');
  });

  /* ---- channel list -------------------------------------------------------------------- */

  function buildCard(ch) {
    var b = el('button', 'card');
    b.type = 'button';
    b.setAttribute('role', 'listitem');
    b.dataset.id = ch.id;
    var logo = el('span', 'logo');
    logo.appendChild(el('span', 'mono'));
    logo.appendChild(el('span', 'num'));
    paintLogo(logo, ch);
    b.appendChild(logo);
    b.appendChild(el('span', 'name', ch.name));
    b.appendChild(el('span', 'now'));
    var bar = el('span', 'bar');
    bar.appendChild(el('span'));
    b.appendChild(bar);
    b.appendChild(el('span', 'next'));
    b.addEventListener('click', function () { closeList(); tune(ch.id); });
    grid.appendChild(b);
    return b;
  }

  function fillCard(b, ch, t) {
    b.querySelector('.now').textContent = nowText(ch);
    var pct = ch.now ? Math.max(0, Math.min(100, 100 * (t - ch.now.start) / (ch.now.stop - ch.now.start))) : 0;
    b.querySelector('.bar > span').style.width = pct + '%';
    b.querySelector('.bar').hidden = !ch.now;
    b.querySelector('.next').textContent = nextText(ch);
    b.setAttribute('aria-label', ch.number + ' ' + ch.name + ', ' + nowText(ch) + '. ' + nextText(ch));
  }

  function blur() {
    if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
  }

  function openList() {
    if (!list.hidden) return;
    list.hidden = false;
    banner.hidden = true;
    tick();
    // Back closes the list through history, so the browser's own Back button works too.
    if (!(history.state && history.state.tv === 'list')) history.pushState({ tv: 'list' }, '');
    var b = cards[current] || grid.querySelector('.card');
    if (b) { b.focus(); if (b.scrollIntoView) b.scrollIntoView({ block: 'nearest' }); }
  }

  function closeList() {
    if (list.hidden) return;
    list.hidden = true;
    blur();
    if (history.state && history.state.tv === 'list') history.back();
  }

  window.addEventListener('popstate', function () {
    if (!list.hidden) { list.hidden = true; blur(); showBanner(); }
  });

  // Spatial navigation in the list: the nearest card in the pressed direction.
  function moveFocus(dir) {
    var items = Array.prototype.slice.call(grid.querySelectorAll('.card'));
    var cur = document.activeElement;
    if (items.indexOf(cur) < 0) { if (items[0]) items[0].focus(); return; }
    var a = cur.getBoundingClientRect();
    var ax = a.left + a.width / 2, ay = a.top + a.height / 2;
    var best = null, bestScore = Infinity;
    items.forEach(function (it) {
      if (it === cur) return;
      var r = it.getBoundingClientRect();
      var dx = r.left + r.width / 2 - ax, dy = r.top + r.height / 2 - ay;
      var primary, cross;
      if (dir === 'ArrowRight') { primary = dx; cross = dy; }
      else if (dir === 'ArrowLeft') { primary = -dx; cross = dy; }
      else if (dir === 'ArrowDown') { primary = dy; cross = dx; }
      else { primary = -dy; cross = dx; }
      if (primary <= 1) return;
      var score = primary + 2 * Math.abs(cross);
      if (score < bestScore) { bestScore = score; best = it; }
    });
    if (best) { best.focus(); if (best.scrollIntoView) best.scrollIntoView({ block: 'nearest' }); }
  }

  /* ---- keys and pointer ---------------------------------------------------------------- */

  var BACK_KEYS = { Escape: 1, Backspace: 1, GoBack: 1, BrowserBack: 1 };
  var BACK_CODES = { 4: 1, 8: 1, 27: 1, 461: 1, 10009: 1 };
  var NEXT_KEYS = { ArrowRight: 1, PageUp: 1, ChannelUp: 1, MediaTrackNext: 1, MediaNextTrack: 1, MediaFastForward: 1, FastForward: 1, AudioFastForward: 1, FastFwd: 1, '>': 1, '>>': 1 };
  var PREV_KEYS = { ArrowLeft: 1, PageDown: 1, ChannelDown: 1, MediaTrackPrevious: 1, MediaPreviousTrack: 1, MediaRewind: 1, Rewind: 1, AudioRewind: 1, '<<': 1, '<': 1 };
  var PLAY_KEYS = { MediaPlayPause: 1, MediaPlay: 1, MediaPause: 1 };
  var NEXT_CODES = { 90: 1, 190: 1, 228: 1, 417: 1, 176: 1 };
  var PREV_CODES = { 89: 1, 188: 1, 227: 1, 412: 1, 177: 1 };
  var PLAY_CODES = { 85: 1, 126: 1, 127: 1, 179: 1, 415: 1, 19: 1 };
  var ARROWS = { ArrowUp: 1, ArrowDown: 1, ArrowLeft: 1, ArrowRight: 1 };

  function remote(e) {
    var key = e.key;
    if (NEXT_KEYS[key]) return 'next';
    if (PREV_KEYS[key]) return 'prev';
    if (PLAY_KEYS[key]) return 'play';
    if (key && key.length === 1) return '';
    if (NEXT_CODES[e.keyCode]) return 'next';
    if (PREV_CODES[e.keyCode]) return 'prev';
    if (PLAY_CODES[e.keyCode]) return 'play';
    return '';
  }

  function playPause() {
    if (banner.hidden || !(state === 'playing' || state === 'buffering')) showBanner();
    else { clearTimeout(timers.banner); banner.hidden = true; }
  }

  document.addEventListener('keydown', function (e) {
    var key = e.key;
    var act = remote(e);
    var isBack = BACK_KEYS[key] || BACK_CODES[e.keyCode];
    if (!list.hidden) {
      if (isBack) { e.preventDefault(); closeList(); showBanner(); }
      else if (act === 'next' || act === 'prev') { e.preventDefault(); closeList(); zap(act === 'next' ? 1 : -1); }
      else if (ARROWS[key]) { e.preventDefault(); moveFocus(key); }
      else if (act) e.preventDefault();
      // Enter: the focused card's own click tunes it.
      return;
    }
    if (!channels.length) return;
    if (act === 'next') { e.preventDefault(); zap(1); }
    else if (act === 'prev') { e.preventDefault(); zap(-1); }
    else if (act === 'play') { e.preventDefault(); playPause(); }
    else if (key === 'ArrowUp' || key === 'ArrowDown') { e.preventDefault(); openList(); }
    else if (key === 'Enter' || key === ' ') { e.preventDefault(); ok(); }
    else if (isBack) { e.preventDefault(); showBanner(); }
  });

  function onButton(id, fn) {
    $(id).addEventListener('click', function (e) { e.stopPropagation(); this.blur(); fn(); });
  }
  onButton('b-prev', function () { zap(-1); });
  onButton('b-next-ch', function () { zap(1); });
  onButton('b-list', openList);
  video.addEventListener('click', function () { if (video.muted) ok(); else showBanner(); });
  video.addEventListener('dblclick', function () {
    if (document.fullscreenElement) document.exitFullscreen();
    else if (document.documentElement.requestFullscreen) document.documentElement.requestFullscreen().catch(function () {});
  });

  /* ---- guide and start-up -------------------------------------------------------------- */

  function render(data) {
    channels = data.channels;
    var present = {};
    var t = Date.now() / 1000;
    channels.forEach(function (ch) {
      present[ch.id] = true;
      if (!cards[ch.id]) cards[ch.id] = buildCard(ch);
      grid.appendChild(cards[ch.id]);
      fillCard(cards[ch.id], ch, t);
    });
    Object.keys(cards).forEach(function (id) {
      if (present[id]) return;
      cards[id].remove();
      delete cards[id];
    });
    var notice = $('notice');
    notice.hidden = data.guide;
    notice.textContent = data.guide ? '' : 'The programme guide is not available yet; channels still play.';
    paintBanner();
  }

  function loadGuide() {
    return fetch('/guide.json', { cache: 'no-store' })
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      })
      .then(render);
  }

  function tick() { $('clock').textContent = hhmm(Date.now() / 1000); }

  function boot() {
    loadGuide().then(function () {
      if (!channels.length) throw new Error('empty lineup');
      $('splash').hidden = true;
      var last = store('tv.last');
      tune(channel(last) ? last : channels[0].id);
      setInterval(function () { loadGuide().catch(function () { /* keep the last guide */ }); }, GUIDE_EVERY_MS);
    }).catch(function () {
      $('splash').textContent = 'Cannot reach the TV server. Retrying…';
      setTimeout(boot, 5000);
    });
  }

  // Leaving the page ends the stream at once (frees the helper's slot).
  window.addEventListener('pagehide', stopEngine);

  if (history.state && history.state.tv === 'list') history.replaceState(null, '');
  setInterval(tick, 15000);
  boot();
})();
