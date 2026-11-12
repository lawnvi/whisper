// 把网页传输的页面（assets/web_transfer/index.html）换上一个假的「这台」，
// 不用启动 Whisper 就能看每个状态。页面本身一个字不改，只在它的脚本前面插一段。
//
//   node docs/design/tools/web-transfer-demo.mjs <输出目录>
//
// 输出 demo.html，用浏览器直接打开。地址后面加 #code、#closed、#declined、#chat、
// #empty、#ended、#reconnecting 直接到那个状态；不加是完整的流程：等确认 → 允许 → 对话。
// 只在本地看，不发布到任何线上地址。
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const out = resolve(process.argv[2] || '.');
const page = readFileSync(join(root, 'assets/web_transfer/index.html'), 'utf8');

const demo = String.raw`
(function () {
  var zh = /^zh\b/i.test(String((navigator.languages || [navigator.language])[0] || ''));
  var HOST = { name: 'MacBook Air', os: 'mac', kind: 'laptop' };
  var scenario = (location.hash || '').slice(1) || 'flow';
  var minute = 60 * 1000, now = Date.now();

  // 示例图片：画出来的，不是真实照片
  function picture(w, h, a, b, c) {
    var cv = document.createElement('canvas'); cv.width = w; cv.height = h;
    var g = cv.getContext('2d');
    var sky = g.createLinearGradient(0, 0, 0, h); sky.addColorStop(0, a); sky.addColorStop(1, b);
    g.fillStyle = sky; g.fillRect(0, 0, w, h);
    g.fillStyle = 'rgba(255,255,255,.85)'; g.beginPath(); g.arc(w * .72, h * .3, h * .09, 0, Math.PI * 2); g.fill();
    g.fillStyle = c; g.beginPath(); g.moveTo(0, h * .72);
    for (var x = 0; x <= w; x += w / 12) g.lineTo(x, h * (.62 + .08 * Math.sin(x / w * 7)));
    g.lineTo(w, h); g.lineTo(0, h); g.closePath(); g.fill();
    g.fillStyle = 'rgba(0,0,0,.18)'; g.beginPath(); g.moveTo(0, h * .84);
    for (var y = 0; y <= w; y += w / 10) g.lineTo(y, h * (.8 + .05 * Math.cos(y / w * 9)));
    g.lineTo(w, h); g.lineTo(0, h); g.closePath(); g.fill();
    return cv.toDataURL('image/jpeg', .86);
  }
  var photo = picture(1200, 900, '#8EC8F6', '#F5D0A9', '#3E7C5A');
  var photo2 = picture(900, 1200, '#5B5BD6', '#F2A7A7', '#2F3A56');

  var history = zh ? [
    { id: 'h1', kind: 'text', from: 'host', body: '这是周会的纪要，还有白板的照片', time: now - 26 * minute },
    { id: 'h2', kind: 'file', from: 'host', name: '周会纪要 11-12.pdf', size: 2516582, type: 'application/pdf', time: now - 26 * minute },
    { id: 'h3', kind: 'file', from: 'host', name: 'IMG_2043.jpg', size: 3355443, type: 'image/jpeg', time: now - 25 * minute },
    { id: 'h4', kind: 'text', from: 'me', body: '收到。改好的方案在这儿，另外参考链接 https://whisper-lan.github.io/zh', time: now - 3 * minute },
    { id: 'h5', kind: 'file', from: 'me', name: 'IMG_0371.HEIC', size: 2831155, type: 'image/jpeg', time: now - 2 * minute, state: 'sent' }
  ] : [
    { id: 'h1', kind: 'text', from: 'host', body: 'Here are the notes from the weekly meeting, and a photo of the whiteboard', time: now - 26 * minute },
    { id: 'h2', kind: 'file', from: 'host', name: 'Weekly notes 11-12.pdf', size: 2516582, type: 'application/pdf', time: now - 26 * minute },
    { id: 'h3', kind: 'file', from: 'host', name: 'IMG_2043.jpg', size: 3355443, type: 'image/jpeg', time: now - 25 * minute },
    { id: 'h4', kind: 'text', from: 'me', body: 'Got it. Here is the revised plan, and the link we talked about https://whisper-lan.github.io/en', time: now - 3 * minute },
    { id: 'h5', kind: 'file', from: 'me', name: 'IMG_0371.HEIC', size: 2831155, type: 'image/jpeg', time: now - 2 * minute, state: 'sent' }
  ];
  var media = { h3: photo, h5: photo2 };

  window.WhisperWebTransport = function () {
    var h = null, live = false, timers = [];
    function later(ms, fn) { timers.push(setTimeout(fn, ms)); }
    function frame(f) { if (live) h.frame(f); }
    function welcome(withHistory) {
      frame({ t: 'welcome', session: 'demo', host: HOST, history: withHistory ? history : [] });
    }
    function sampleUpload() {
      // 一个正在发的大文件，好看清进度条
      return new File([new ArrayBuffer(18874368)], zh ? '方案-v3.key' : 'Plan-v3.key', { type: 'application/octet-stream' });
    }
    return {
      start: function (handlers) {
        h = handlers; live = true;
        later(scenario === 'flow' ? 500 : 0, function () { h.status('open'); });
      },
      stop: function () { live = false; timers.forEach(clearTimeout); timers = []; },
      send: function (f) {
        if (!live) return false;
        if (f.t === 'hello') {
          if (scenario === 'closed') return frame({ t: 'closed', host: HOST }), true;
          if (scenario === 'declined') return frame({ t: 'declined' }), true;
          if (scenario === 'code' || scenario === 'flow') {
            frame({ t: 'wait', code: '4827', host: HOST });
            if (scenario === 'flow') later(3200, function () { welcome(true); });
            return true;
          }
          welcome(scenario !== 'empty');
          if (scenario === 'ended') later(0, function () { frame({ t: 'ended', by: 'host' }); });
          if (scenario === 'reconnecting') later(0, function () { live = false; h.status('down'); });
          if (scenario === 'chat') later(60, function () {
            var input = document.getElementById('picker');
            var dt = new DataTransfer(); dt.items.add(sampleUpload());
            input.files = dt.files; input.dispatchEvent(new Event('change'));
          });
          return true;
        }
        if (f.t === 'text') {
          later(250, function () { frame({ t: 'ack', id: f.id, time: Date.now() }); });
          later(1600, function () { frame({ t: 'text', id: 'r' + f.id, from: 'host', body: zh ? '好的' : 'OK', time: Date.now() }); });
        }
        if (f.t === 'offer') later(120, function () { frame({ t: 'state', id: f.id, state: 'ready', committed: 0 }); });
        return true;
      },
      session: function () { return Promise.resolve(true); },
      upload: function (file, id, from, onProgress) {
        var sent = from || 0, stopped = false, rate = scenario === 'chat' ? 0 : 6 * 1024 * 1024;
        var start = scenario === 'chat' ? file.size * .42 : sent;
        onProgress(start); sent = start;
        var p = new Promise(function (resolve, reject) {
          (function tick() {
            if (stopped) return reject(Object.assign(new Error('abort'), { name: 'AbortError' }));
            if (rate === 0) return; // 停在 42%，截图用
            sent = Math.min(file.size, sent + rate / 10);
            onProgress(sent);
            if (sent >= file.size) { resolve(sent); later(100, function () { frame({ t: 'state', id: id, state: 'done' }); }); }
            else setTimeout(tick, 100);
          })();
        });
        return { promise: p, abort: function () { stopped = true; } };
      },
      committed: function () { return Promise.resolve(0); },
      fileUrl: function (id) { return media[id] || '#'; }
    };
  };

  // 原型上方的状态切换，不属于产品
  addEventListener('DOMContentLoaded', function () {
    if (/[?&]shot\b/.test(location.search)) return;
    var pick = document.createElement('select');
    pick.setAttribute('aria-label', zh ? '状态' : 'State');
    pick.style.cssText = 'position:fixed;z-index:99;left:max(10px,env(safe-area-inset-left,0px));top:calc(72px + env(safe-area-inset-top,0px));font:500 12px/1 -apple-system,system-ui,sans-serif;padding:6px 8px;border-radius:999px;border:0;background:rgba(0,0,0,.72);color:#fff;';
    var names = zh
      ? { flow: '原型：完整流程', code: '等待确认', closed: '这台没打开', declined: '被拒绝', empty: '刚连上', chat: '对话中', reconnecting: '重新连接', ended: '已断开' }
      : { flow: 'Prototype: full flow', code: 'Waiting', closed: 'Not open', declined: 'Declined', empty: 'Just connected', chat: 'Chatting', reconnecting: 'Reconnecting', ended: 'Ended' };
    Object.keys(names).forEach(function (k) { var o = document.createElement('option'); o.value = k; o.textContent = names[k]; pick.appendChild(o); });
    pick.value = scenario;
    pick.onchange = function () { location.hash = pick.value === 'flow' ? '' : pick.value; location.reload(); };
    document.body.appendChild(pick);
  });
})();
`;

const marker = '<script>\n(function () {';
if (!page.includes(marker)) throw new Error('page script marker not found');
const full = page.replace(marker, '<script>' + demo + '</script>\n' + marker);
mkdirSync(out, { recursive: true });
writeFileSync(join(out, 'demo.html'), full);

console.log('wrote', join(out, 'demo.html'));
