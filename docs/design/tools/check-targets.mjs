// 走遍所有状态，报告命中区太小、按钮没有读屏名称、文字被切。已知的见 docs/design/README.md
import { spawn } from 'node:child_process';
import { mkdtempSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
const FILE = new URL('../whisper-ui-language.html', import.meta.url).href;
const CHROME = process.env.CHROME || ['C:/Program Files/Google/Chrome/Application/chrome.exe', 'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/usr/bin/google-chrome', '/usr/bin/chromium'].find(p => existsSync(p));
if (!CHROME) { console.error('找不到 Chrome，请设置环境变量 CHROME'); process.exit(2); }
const PORT = 9700 + Math.floor(Math.random() * 200);
const proc = spawn(CHROME, ['--headless=new', `--remote-debugging-port=${PORT}`, `--user-data-dir=${mkdtempSync(join(tmpdir(), 'cdp-'))}`, '--no-first-run', '--window-size=1400,1000', 'about:blank'], { stdio: 'ignore' });
const sleep = ms => new Promise(r => setTimeout(r, ms));
let t; for (let i = 0; i < 50; i++) { try { t = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json(); if (t.length) break; } catch {} await sleep(200); }
const ws = new WebSocket(t.find(x => x.type === 'page').webSocketDebuggerUrl); await new Promise(r => (ws.onopen = r));
let id = 0; const p = new Map(), errs = []; ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && p.has(m.id)) { p.get(m.id)(m); p.delete(m.id); } if (m.method === 'Runtime.exceptionThrown') errs.push(m.params.exceptionDetails.exception?.description); };
const send = (method, params = {}) => new Promise(r => { const i = ++id; p.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async expr => (await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })).result.result?.value;
const click = s => ev(`document.querySelector(${JSON.stringify(s)})?.click()`);
await send('Page.enable'); await send('Runtime.enable');
await send('Emulation.setDeviceMetricsOverride', { width: 1400, height: 1000, deviceScaleFactor: 1, mobile: false });
await send('Page.navigate', { url: FILE }); await sleep(900);
const seen = new Map();
const scan = async label => {
  const r = await ev(`(()=>{const out=[];const win=document.getElementById('win'),c=win.dataset.size==='compact',min=c?44:28;
    const roots=[win,document.getElementById('trayPanel'),document.getElementById('trayMenu')].filter(Boolean);
    const vis=e=>{const q=e.getBoundingClientRect();if(q.width<1||q.height<1)return false;const s=getComputedStyle(e);if(s.visibility==='hidden'||s.opacity==='0')return false;for(let n=e;n;n=n.parentElement){if(n.classList&&n.classList.contains('ghost'))return false}return true};
    roots.forEach(root=>root.querySelectorAll('button,input,[role=button]').forEach(e=>{if(!vis(e))return;const q=e.getBoundingClientRect();
      const inMini=e.closest('.miniseg,.seg');
      if(e.type!=='range'&&!inMini&&!e.classList.contains('sw')&&!e.classList.contains('check')&&!e.classList.contains('scr')&&(q.height<min-.5||q.width<Math.min(min,28)-.5))out.push('small '+(e.className||e.tagName)+' '+Math.round(q.width)+'x'+Math.round(q.height)+' '+(e.getAttribute('aria-label')||e.textContent).slice(0,14));
      if(e.tagName==='BUTTON'&&!e.textContent.trim()&&!e.getAttribute('aria-label'))out.push('noname '+e.className);
      if(e.tagName==='INPUT'&&!e.getAttribute('aria-label')&&!e.closest('label')&&!e.placeholder)out.push('noname-input '+e.name);
    }));
    roots.forEach(root=>root.querySelectorAll('b,small,span,h3,h4,h5,p').forEach(e=>{if(!vis(e)||e.children.length)return;const s=getComputedStyle(e);
      if(e.scrollWidth>e.clientWidth+1&&s.overflow==='visible'&&s.display!=='inline'){let n=e.parentElement,clipped=false;for(;n&&n!==root;n=n.parentElement){if(n.scrollWidth>n.clientWidth+1&&getComputedStyle(n).overflowX==='hidden'&&getComputedStyle(n).textOverflow!=='ellipsis'){clipped=true;break}}if(clipped)out.push('clip '+e.textContent.slice(0,18))}
    }));
    if(document.documentElement.scrollWidth>document.documentElement.clientWidth)out.push('page overflow');
    return out})()`);
  for (const x of r) { if (!seen.has(x)) seen.set(x, label); }
};
const desk = [['chat', null], ['files', '[data-a=place][data-v=files]'], ['apps', '[data-a=place][data-v=apps]'], ['card', '[data-a=insp]'], ['audio', '[data-demo=audio]'], ['input', '[data-demo=input]'], ['links', '.self [data-a=global][data-v=links]'], ['tray', '#trayBtn'], ['tray-audio', '[data-a=trayMod][data-v=audio]'], ['tray-input', '[data-a=trayMod][data-v=input]']];
const walkDesk = async os => {
  for (const [l, s] of desk) { if (l === 'tray-audio' && (os === 'gnome' || os === 'kde')) { await ev(`[...document.querySelectorAll('.nm-i')].find(e=>e.textContent.includes('声音放到'))?.click()`); await sleep(300); await scan(os + ' tray-sub'); continue; } if (s) await click(s); await sleep(l === 'audio' ? 2000 : 700); await scan(os + ' ' + l); }
  await ev('document.body.click()'); await sleep(200);
  await click('.self [data-a=settings]'); await sleep(500);
  for (let i = 0; i < 6; i++) { await ev(`document.querySelectorAll('.st-nav button')[${i}]?.click()`); await sleep(200); await scan(os + ' settings ' + i); }
  await click('.st-close'); await sleep(400);
  await click('.self-b'); await sleep(500); await scan(os + ' self'); await click('.sheet [data-a=closeSheet]'); await sleep(400);
};
for (const os of ['win', 'gnome', 'kde']) { await send('Page.navigate', { url: `${FILE}?os=${os}` }); await sleep(900); await walkDesk(os); }
await send('Page.navigate', { url: FILE }); await sleep(900); await walkDesk('mac');
await click('[data-demo=phone]'); await sleep(700); await scan('phone list');
const steps = [['chat', '.side-list [data-a=dev][data-v=imac]'], ['card', '.tb-end [data-a=pgo][data-v=card]'], ['files', '.circ.act[data-v=files]'], ['back', '[data-a=back]'], ['apps', '.circ.act[data-v=apps]'], ['back', '[data-a=back]'], ['control', '.circ.act[data-v=control]'], ['back', '[data-a=back]'], ['back', '[data-a=back]'], ['back', '[data-a=back]'], ['connect', '.side-top [data-a=connectNew]'], ['scan', '[data-a=connTab][data-v=scan]'], ['addr', '[data-a=connTab][data-v=addr]'], ['back', '[data-a=back]'], ['settings', '.side-top [data-a=settings]'], ['links', '#main [data-a=pgo][data-v=links]']];
for (const [l, s] of steps) { await click(s); await sleep(750); if (l !== 'back') await scan('phone ' + l); }
console.log(seen.size ? [...seen].map(([k, v]) => `${v}: ${k}`).join('\n') : 'clean');
console.log('errors', JSON.stringify(errs));
ws.close(); proc.kill(); process.exit(0);
