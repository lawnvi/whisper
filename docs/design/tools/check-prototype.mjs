import { spawn } from 'node:child_process';
import { writeFileSync, mkdirSync, mkdtempSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
// 走完原型的所有流程并截图。用法：node check-prototype.mjs [输出目录] ，环境变量 SHOT_FORMAT=jpeg 输出 jpg
const OUT = process.argv[2] || mkdtempSync(join(tmpdir(), 'whisper-shots-')); mkdirSync(OUT, { recursive: true });
const FORMAT = process.env.SHOT_FORMAT === 'jpeg' ? 'jpeg' : 'png';
const FILE = new URL('../whisper-ui-language.html', import.meta.url).href;
const CHROME = process.env.CHROME || ['C:/Program Files/Google/Chrome/Application/chrome.exe', 'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/usr/bin/google-chrome', '/usr/bin/chromium'].find(p => existsSync(p));
if (!CHROME) { console.error('找不到 Chrome，请设置环境变量 CHROME'); process.exit(2); }
const PORT = 9400 + Math.floor(Math.random()*500);
const proc = spawn(CHROME, ['--headless=new', `--remote-debugging-port=${PORT}`, `--user-data-dir=${mkdtempSync(join(tmpdir(), 'cdp-'))}`, '--no-first-run', '--window-size=1400,1000', ...(process.env.NOTHROTTLE?['--disable-background-timer-throttling','--disable-renderer-backgrounding','--disable-backgrounding-occluded-windows']:[]), 'about:blank'], { stdio: 'ignore' });
const sleep = ms => new Promise(r => setTimeout(r, ms));
let targets; for (let i = 0; i < 50; i++) { try { targets = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json(); if (targets.length) break; } catch {} await sleep(200); }
const ws = new WebSocket(targets.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => (ws.onopen = r));
let id = 0; const pending = new Map(); const errors = []; const fails = []; let passes = 0;
ws.onmessage = ev => { const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  if (m.method === 'Runtime.exceptionThrown') errors.push(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text);
  if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error') errors.push(m.params.args.map(a => a.value).join(' '));
  if (m.method === 'Log.entryAdded' && m.params.entry.level === 'error') errors.push(m.params.entry.text);
};
const send = (method, params = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async expr => { const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }); if (r.result.exceptionDetails) errors.push('eval: ' + expr.slice(0,80) + ' => ' + r.result.exceptionDetails.exception?.description); return r.result.result?.value; };
const shot = async name => { const c = await ev(`(()=>{const r=document.getElementById('stage').getBoundingClientRect();return {x:r.left+scrollX,y:r.top+scrollY,width:r.width,height:r.height}})()`); const r = await send('Page.captureScreenshot', { format: FORMAT, quality: FORMAT === 'jpeg' ? 84 : undefined, captureBeyondViewport: false, clip: { ...c, scale: 1 } }); writeFileSync(join(OUT, name + (FORMAT === 'jpeg' ? '.jpg' : '.png')), Buffer.from(r.result.data, 'base64')); };
const size = async (w, h, dark) => { await send('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 1, mobile: false }); await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: dark ? 'dark' : 'light' }] }); await sleep(250); };
const click = async s => { const r = await ev(`(()=>{const e=document.querySelector(${JSON.stringify(s)});if(!e)return false;e.click();return true})()`); if(!r){ console.log('MISSING '+s+' :: '+await ev(STATE)); errors.push('missing '+s);} return r; };
const STATE=`JSON.stringify({vis:document.visibilityState,focus:document.hasFocus(),title:document.querySelector('.tb-title')?.textContent,pk:document.querySelector('.place')?.dataset.pk,drag:!!document.querySelector('.scr.drag'),sheet:!!document.querySelector('.sheet')})`;
const ok = async (name, cond, detail='') => { if (cond) passes++; else { fails.push(name); console.log('FAIL ' + name + (detail?'  '+detail:'') + ' :: ' + await ev(STATE)); } };
const mouse = (type, x, y, buttons=1) => send('Input.dispatchMouseEvent', { type, x, y, button: type==='mouseMoved'?'none':'left', buttons: type==='mouseReleased'?0:buttons, clickCount: type==='mouseMoved'?0:1 });
const rect = async s => { const q = await ev(`(()=>{const e=document.querySelector(${JSON.stringify(s)});if(!e)return null;const r=e.getBoundingClientRect();return {x:r.left,y:r.top,w:r.width,h:r.height}})()`); if(!q){ console.log('NORECT '+s+' :: '+await ev(STATE)); return {x:0,y:0,w:0,h:0}; } return q; };
const overflow = async label => { const o = await ev(`document.documentElement.scrollWidth>document.documentElement.clientWidth`); await ok('no page overflow: '+label, !o); };

await send('Page.enable'); await send('Runtime.enable'); await send('Log.enable');
if (process.env.NOTHROTTLE) await send('Emulation.setFocusEmulationEnabled',{enabled:true});
await size(1400, 1000, false);
await send('Page.navigate', { url: FILE }); await sleep(900);
await overflow('desktop'); await shot('01-chat');
const b = await ev(`[...document.querySelectorAll('.bub')].map(e=>{const r=e.getBoundingClientRect();const g=document.createRange();g.selectNodeContents(e);const l=[...g.getClientRects()];return {t:e.textContent.slice(0,6),box:Math.round(r.width),text:Math.round(Math.max(...l.map(x=>x.right))-Math.min(...l.map(x=>x.left)))}})`);
await ok('bubbles hug content', b.every(x => x.box - x.text <= 28), JSON.stringify(b));
const edges = await ev(`(()=>{const m=document.getElementById('main').getBoundingClientRect();const bs=[...document.querySelectorAll('.bub')];const me=bs.find(x=>x.classList.contains('me')).getBoundingClientRect(),o=bs.find(x=>!x.classList.contains('me')).getBoundingClientRect();return [o.left-m.left,m.right-me.right]})()`);
await ok('messages close to the edges', edges[0]<=18&&edges[1]<=18, JSON.stringify(edges));
const comp = await ev(`(()=>{const m=document.getElementById('main').getBoundingClientRect(),c=document.querySelector('.composer').getBoundingClientRect();return [c.left-m.left,m.right-c.right,c.width]})()`);
await ok('composer inset and not too long', comp[0]>=48&&comp[1]>=48&&comp[2]<=620&&Math.abs(comp[0]-comp[1])<2, JSON.stringify(comp));
await ok('screenshot on the desktop composer', await ev(`!!document.querySelector('.composer [data-a=shot]')`));
await ok('send clipboard on the composer', await ev(`!!document.querySelector('.composer [data-a=sendClip]')`));
await click('[data-a=shot]'); await sleep(300); await shot('01b-composer-shot');
await ok('screenshot attaches', await ev(`document.querySelector('.att').textContent.includes('截图')&&document.querySelector('.send').classList.contains('ready')`));
await click('[data-a=attachOff]'); await sleep(100);
await click('[data-a=composeAct]'); await sleep(250); await shot('01c-composer-add');
await ok('plus offers file and folder', await ev(`document.querySelector('.menu').textContent.includes('文件夹')`));
await ev(`document.body.click()`); await sleep(100);

// continuity: a switch must keep its element so its transition can play
await ok('island clear of the toolbar', await ev(`(()=>{const hit=(a,b)=>a&&b&&a.left<b.right&&b.left<a.right&&a.top<b.bottom&&b.top<a.bottom;const i=document.getElementById('island');if(i.hidden)return true;const r=i.getBoundingClientRect();return ![...document.querySelectorAll('.tb-end > *')].some(e=>hit(r,e.getBoundingClientRect()))})()`));
await click('[data-a=insp]'); await sleep(700); await shot('02-card');
await ok('island clear of the toolbar with the card open', await ev(`(()=>{const hit=(a,b)=>a&&b&&a.left<b.right&&b.left<a.right&&a.top<b.bottom&&b.top<a.bottom;const i=document.getElementById('island');if(i.hidden)return true;const r=i.getBoundingClientRect();return ![...document.querySelectorAll('.tb-end > *')].some(e=>hit(r,e.getBoundingClientRect()))})()`));
await ok('switch element survives toggle', await ev(`(()=>{const a=document.querySelector('#inspIn .sw');a.__m=1;a.click();const b=document.querySelector('#inspIn .sw');return b.__m===1&&b.getAttribute('aria-checked')==='false'})()`));
await ev(`document.querySelector('#inspIn .sw').click()`); await sleep(100);
await ok('switch transition running', await ev(`(()=>{const a=document.querySelector('#inspIn .sw');a.click();const n=a.getAnimations({subtree:true}).length;a.click();return n>0})()`));
await ok('spring easing installed', await ev(`getComputedStyle(document.documentElement).getPropertyValue('--ease-smooth').includes('linear(')`));
await ok('circle toggles present', (await ev(`document.querySelectorAll('#inspIn .circ').length`))===4);
await click('[data-a=insp]'); await sleep(500);

// files
await ok('tab thumb stretches while moving', await ev(`new Promise(res=>{const t=document.querySelector('#mainSeg .thumb'),w0=parseFloat(t.style.width);document.querySelector('[data-a=place][data-v=files]').click();const g=document.querySelector('.place.ghost'),n=document.querySelector('.place:not(.ghost)');const ok1=!!g&&g.classList.contains('t-out-r')&&n.classList.contains('t-in-r');let mx=0;const s=performance.now();(function f(){mx=Math.max(mx,parseFloat(document.querySelector('#mainSeg .thumb').style.width));if(performance.now()-s<300)requestAnimationFrame(f);else res(ok1&&mx>w0+6)})()})`));
await sleep(350); await click('[data-a=place][data-v=apps]'); await sleep(90); await shot('02b-tab-mid'); await sleep(600);
await ok('going back slides the other way', await ev(`(()=>{document.querySelector('[data-a=place][data-v=files]').click();return document.querySelector('.place.ghost').classList.contains('t-out-l')&&document.querySelector('.place:not(.ghost)').classList.contains('t-in-l')})()`));
await sleep(700);
await ok('no rule lines in file rows', (await ev(`[...document.querySelectorAll('.frow')].filter(e=>parseFloat(getComputedStyle(e).borderBottomWidth)>0||getComputedStyle(e).boxShadow!=='none').length`))===0);
await ev(`document.querySelector('[data-a=selFile]').click()`); await sleep(420); await shot('03-files');
await ok('remote files have no share link', !(await ev(`!!document.querySelector('.float-bar [data-a=share]')`)));
await ok('remote files can be copied here', await ev(`!!document.querySelector('.float-bar [data-a=copyHere]')`));
await click('[data-a=fileLoc]'); await sleep(250); await shot('03b-files-location');
await ok('location menu lists this device first', await ev(`document.querySelector('.menu .mi').textContent.includes('MacBook')`));
await ev(`document.querySelector('.menu .mi').click()`); await sleep(300);
await ev(`document.querySelector('[data-a=selFile]').click()`); await sleep(350);
await ok('own files can be shared', await ev(`!!document.querySelector('.float-bar [data-a=share]')`));
await click('[data-a=fileMore]'); await sleep(200);
await ok('more menu holds the rest', await ev(`['新建文件夹','显示隐藏文件','传输'].every(x=>document.querySelector('.menu').textContent.includes(x))`));
await ev(`document.body.click()`); await sleep(120);
await ok('float bar on selection', await ev(`!!document.querySelector('.float-bar')`));
await click('[data-a=share]'); await sleep(500); await shot('05-link-qr');
await ok('a link is made without asking', await ev(`!document.querySelector('form[data-form=link]')&&!!document.querySelector('.sheet [data-a=linkRoute]')&&!!document.querySelector('.sheet [data-a=linkPw]')`));
await ev(`document.querySelector('.sheet [data-a=linkRoute]').click()`); await sleep(300); await ev(`(()=>{const f=document.querySelector('form[data-form=linkRoute]');f.route.value='trip-2026';f.requestSubmit()})()`); await sleep(350);
await ok('the route changes from its row', await ev(`document.querySelector('.sheet .url').textContent.includes('trip-2026')`));
await click('.sheet [data-a=closeSheet]'); await sleep(450);

// apps
await click('[data-a=place][data-v=apps]'); await sleep(420); await shot('06-apps');

// settings / self
await click('.self [data-a=settings]'); await sleep(550); await shot('07-settings');
await ev(`[...document.querySelectorAll('.st-nav button')].find(b=>b.textContent.includes('系统')).click()`); await sleep(150);
await ok('settings has no invented rows', !(await ev(`(()=>{let t='';return document.querySelector('.st-body').textContent.includes('发送剪贴板快捷键')})()`)));
await ok('settings nav', (await ev(`document.querySelector('.st-body h4').textContent`))==='系统');
await ok('shortcut can be turned off', await ev(`document.querySelector('.st-body').textContent.includes('启用截图快捷键')`));
await ok('shortcut is changeable', await ev(`!!document.querySelector('.st-body .hk')`));
await click('.st-body .hk'); await sleep(100);
await ok('shortcut records', await ev(`document.querySelector('.st-body .hk').textContent.includes('按下')`));
await ev(`document.dispatchEvent(new KeyboardEvent('keydown',{key:'j',ctrlKey:true,shiftKey:true,bubbles:true}))`); await sleep(100);
await ok('shortcut saved', await ev(`document.querySelector('.st-body .hk').textContent.includes('J')`));
await ev(`[...document.querySelectorAll('.st-nav button')].find(b=>b.textContent.includes('共享与权限')).click()`); await sleep(350); await shot('07b-settings-sound');
await ok('sharing keeps what is decided there', await ev(`(()=>{const t=document.querySelector('.st-body').textContent;return t.includes('同步剪贴板')&&!t.includes('增益')&&!t.includes('滚轮')})()`));
await ok('only a missing permission has a row', await ev(`(()=>{const t=document.querySelector('.st-body').textContent;return !t.includes('已允许')})()`));
await ev(`[...document.querySelectorAll('.st-nav button')].find(b=>b.textContent.includes('通用')).click()`); await sleep(350);
await click('.st-body .popb'); await sleep(280); await shot('07c-settings-lang');
await ok('language menu lists the languages', await ev(`(()=>{const t=document.querySelector('.menu').textContent;return t.includes('English')&&t.includes('Español')&&t.includes('简体中文')&&t.includes('跟随系统')})()`));
await ev(`[...document.querySelectorAll('.mi')].find(m=>m.textContent.includes('English')).click()`); await sleep(150);
await ok('language applied', await ev(`document.querySelector('.st-body .popb').textContent.includes('English')`));
await ok('save folder is changeable', await ev(`!!document.querySelector('.st-body [data-a=pickDir]')`));
await ev(`[...document.querySelectorAll('.st-nav button')].find(b=>b.textContent.includes('通用')).click()`); await sleep(350);
await ev(`[...document.querySelectorAll('.st-nav button')].find(b=>b.textContent.includes('连接')).click()`); await sleep(300);
await ev(`(()=>{const i=document.querySelector('.st-body .sfield');i.focus();i.value='99999';i.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}))})()`); await sleep(120);
await ok('bad port reverts', await ev(`document.querySelector('.st-body .sfield').value==='10002'`));
await ok('bad port says why', await ev(`document.getElementById('island').textContent.includes('1–65535')`));
await ev(`[...document.querySelectorAll('.st-nav button')].find(b=>b.textContent.includes('通用')).click()`); await sleep(300);
await ok('device name is editable', await ev(`document.querySelector('.st-body .sfield').tagName==='INPUT'`));
await ok('theme thumb slides', await ev(`(()=>{const t=document.querySelector('.st-body .mthumb');return t&&parseFloat(t.style.width)>0})()`));
await click('.st-close'); await sleep(450);
await click('.self-b'); await sleep(500); await shot('08-self'); await click('.sheet [data-a=closeSheet]'); await sleep(450);
await ok('corner shows the name', (await ev(`document.querySelector('.self-b b').textContent`)).length>0);
await ok('long name truncates, icons stay tight', await ev(`(()=>{const b=document.querySelector('.self-b b'),ic=[...document.querySelectorAll('.self .iconbtn')].map(e=>e.getBoundingClientRect());const gaps=ic.slice(1).map((r,i)=>r.left-ic[i].right);return b.scrollWidth>b.clientWidth&&ic.length===2&&gaps.every(g=>g<=2)&&b.getBoundingClientRect().right<=ic[0].left+1})()`));
const footH0 = await ev(`document.querySelector('.self').getBoundingClientRect().height`);
const listY0 = await ev(`document.querySelector('.side-list').getBoundingClientRect().height`);
await click('[data-demo=lost]'); await sleep(150);
await ok('corner height stable when lost', Math.abs(footH0-(await ev(`document.querySelector('.self').getBoundingClientRect().height`)))<.5 && Math.abs(listY0-(await ev(`document.querySelector('.side-list').getBoundingClientRect().height`)))<.5);
await ok('lost speaks from the island', await ev(`document.getElementById('island').textContent.includes('发现不了')`));
await click('[data-demo=lost]'); await sleep(100);

// audio
await click('[data-a=global][data-v=audio]'); await sleep(450); await shot('09-audio-idle');
await ok('sidebar has one flat list', (await ev(`document.querySelectorAll('.side-list .sec').length`))===0);
const order = await ev(`[...document.querySelectorAll('.side-list .dev b')].map(e=>e.textContent)`);
await ok('nearby sits above offline', order.indexOf('2698b')<order.indexOf('Ubuntu') && order.indexOf('Redmi Pad')<order.indexOf('Pixel 6'), JSON.stringify(order));
await click('[data-demo=drop]'); await sleep(200);
const order2 = await ev(`[...document.querySelectorAll('.side-list .dev b')].map(e=>e.textContent)`);
await ok('going offline moves a row below the online ones', order2.indexOf('iMac')>order2.indexOf('2698b') && order2.indexOf('iMac')<order2.indexOf('Ubuntu'), JSON.stringify(order2));
await ok('offline row says so', await ev(`document.querySelector('[data-dev=imac]').textContent.includes('离线')`));
await shot('09b-offline');
await click('[data-demo=drop]'); await sleep(200);
await ok('sound and input at the top of the sidebar', (await ev(`[...document.querySelectorAll('.side-top .iconbtn')].map(b=>b.dataset.a+':'+(b.dataset.v||'')).join()`))==='palette:,global:audio,global:input');
await ok('links and settings in the corner; the name opens the rest', (await ev(`[...document.querySelectorAll('.self .iconbtn')].map(b=>b.dataset.a+':'+(b.dataset.v||'')).join()`))==='global:links,settings:');
await ok('corner shows settings', await ev(`!!document.querySelector('.self [data-a=settings]')`));
await click('[data-demo=audio]'); await sleep(2100); await shot('10-audio');
await ok('auto left/right', await ev(`document.querySelector('.row-a[data-k=imac] .popb').textContent.includes('左声道')&&document.querySelector('.row-a[data-k=mi] .popb').textContent.includes('右声道')`));
await ok('per-device sync', await ev(`document.querySelector('.row-a[data-k=mi]').textContent.includes('同步一般')`));
await ok('channels in a popup, two or more only', await ev(`!document.querySelector('.pane .row-a .miniseg')&&!!document.querySelector('.row-a[data-k=imac] .popb')`));
await ok('selected row stays one line tall', await ev(`document.querySelector('.row-a[data-k=imac]').getBoundingClientRect().height<=64`));
await size(760, 1000, false); await sleep(500);
await ok('the switch is in the page', await ev(`!document.querySelector('.tb [data-a=audSwitch]')&&!!document.querySelector('.pane [data-a=audSwitch]')`));
await size(1400, 1000, false); await sleep(500);
await ev(`document.querySelector('.row-a[data-k=mi] .popb').click()`); await sleep(150);
await ok('row height stable', await ev(`Math.abs(document.querySelector('.row-a[data-k=imac]').getBoundingClientRect().height-document.querySelector('.row-a[data-k=tp]').getBoundingClientRect().height)<1`));
await ev(`[...document.querySelectorAll('.menu button')].find(b=>b.textContent.includes('单声道')).click()`); await sleep(150);
await ok('role change', await ev(`document.querySelector('.row-a[data-k=mi] .popb').textContent.includes('单声道')`));
await sleep(1100); await shot('11-audio-detail');
await ok('sync numbers and how it is going, in the row', await ev(`document.querySelector('.pane').textContent.includes('抖动')`));
await ok('a worse sync is marked in its row', await ev(`document.querySelector('.row-a[data-k=mi] .q').classList.contains('warn')`));
await ok('no separate sync section', await ev(`!document.querySelector('[data-a=audDetail]')&&!document.querySelector('.pane').textContent.includes('同步详情')`));
await ok('page says it when a device has trouble', await ev(`document.querySelector('.pane-hero small').textContent.includes('同步')`));
await ok('rows stay the same height', await ev(`Math.abs(document.querySelector('.row-a[data-k=imac]').getBoundingClientRect().height-document.querySelector('.row-a[data-k=tp]').getBoundingClientRect().height)<1`));
await click('[data-a=audToggle][data-v=tp]'); await sleep(200);
await ok('third joins', await ev(`document.querySelector('.row-a[data-k=tp] .check').getAttribute('aria-checked')==='true'`));
await click('[data-a=audToggle][data-v=tp]'); await sleep(200);

// input
await click('[data-demo=input]'); await sleep(900); await shot('12-input');
await ok('tp placed', await ev(`!!document.querySelector('.scr[data-node=tp]')`));
await ok('offline ghost', await ev(`document.querySelector('.scr[data-node=ubuntu]').classList.contains('ghostly')`));
await ok('real wallpaper on screens', await ev(`getComputedStyle(document.querySelector('.scr[data-node=imac] .disp')).backgroundImage.includes('gradient')`));
await ok('two displays', (await ev(`document.querySelectorAll('.scr[data-node=tp] .disp').length`))===2);
await click('[data-a=kbSwitch]'); await sleep(1100); await shot('13-input-on');
await ok('tp fails alone', await ev(`document.querySelector('.scr[data-node=tp]').textContent.includes('没有连上')`));
await ok('retry visible', await ev(`!!document.querySelector('[data-a=kbRetry]')`));
await click('[data-a=kbRetry]'); await sleep(900);
await ok('retry works', !(await ev(`document.querySelector('.scr[data-node=tp]').textContent.includes('没有连上')`)));
let s0 = await rect('.scr[data-node=imac]'); const cv = await rect('.kb-canvas');
const px=s0.x+s0.w/2, py=s0.y+s0.h/2, tx=cv.x+cv.w*.5, ty=cv.y+24;
await mouse('mouseMoved', px, py, 0); await mouse('mousePressed', px, py);
for (let i=1;i<=8;i++){ await mouse('mouseMoved', px+(tx-px)*i/8, py+(ty-py)*i/8); await sleep(16);}
await sleep(60); await shot('14-input-drag');
await ok('snap ghost', await ev(`!!document.querySelector('.kb-ghost')`));
await ok('drag lift', await ev(`document.querySelector('.scr[data-node=imac]').classList.contains('drag')`));
await mouse('mouseReleased', tx, ty); await sleep(900); await shot('15-input-drop');
const geo = await ev(`(()=>{const ids=[...document.querySelectorAll('.scr[data-node]')].map(e=>e.dataset.node);const R=ids.map(n=>{const e=document.querySelector('.scr[data-node='+n+']').getBoundingClientRect();return [e.left,e.top,e.right,e.bottom]});let bad=false,lost=[];for(let i=0;i<R.length;i++)for(let j=i+1;j<R.length;j++){const a=R[i],b=R[j];if(a[0]<b[2]-1&&b[0]<a[2]-1&&a[1]<b[3]-1&&b[1]<a[3]-1)bad=true}return {ids,bad}})()`);
await ok('no overlap after drop', !geo.bad, JSON.stringify(geo));
// a lost release must not freeze the page
s0 = await rect('.scr[data-node=imac]');
await mouse('mouseMoved', s0.x+s0.w/2, s0.y+s0.h/2, 0); await mouse('mousePressed', s0.x+s0.w/2, s0.y+s0.h/2);
await mouse('mouseMoved', s0.x+s0.w/2+30, s0.y+s0.h/2+10); await sleep(40);
await ev(`window.dispatchEvent(new Event('blur'))`); await sleep(500);
await ok('drag ends when the window loses focus', !(await ev(`!!document.querySelector('.scr.drag')||!!document.querySelector('.kb-ghost')`)));
await mouse('mouseReleased', s0.x+s0.w/2+30, s0.y+s0.h/2+10); await sleep(100);
await click('.self [data-a=global][data-v=links]'); await sleep(300);
await ok('page still updates after a lost release', await ev(`document.querySelector('.tb-title').textContent.includes('共享链接')`));
await click('.side-top [data-a=global][data-v=input]'); await sleep(400);
await click('[data-demo=push]'); await sleep(900); await shot('16-input-active');
await ok('pointer crossed', await ev(`document.querySelector('.scr[data-node=imac]').textContent.includes('正在控制')`));
await ok('cursor rendered', await ev(`!!document.querySelector('.kb-ptr svg')`));
await click('[data-demo=push]'); await sleep(600);

// tray
await click('[data-demo=tray]'); await sleep(560); await shot('17-tray-hold');
await ok('tray holds file', await ev(`document.querySelector('.tr-what').textContent.includes('周报')`));
await ok('tray lists connected', (await ev(`document.querySelectorAll('.tr-t').length`))===3);
await click('.tr-t[data-v=imac]'); await sleep(350);
await ok('tray transfer', await ev(`document.getElementById('trayPanel').textContent.includes('周报')`));
await click('[data-a=trayMod][data-v=audio]'); await sleep(600); await shot('18-tray-audio');
await ok('tray audio open', await ev(`document.querySelectorAll('#trayPanel .exp')[0].classList.contains('open')`));
await click('[data-a=trayMod][data-v=input]'); await sleep(600); await shot('19-tray-input');
await ok('minimap', await ev(`!!document.querySelector('.minimap')`));
await ok('minimap labels fit their screens', await ev(`[...document.querySelectorAll('.minimap g')].filter(g=>g.querySelector('text')).every(g=>{const r=g.querySelector('rect').getBoundingClientRect(),rs=[...g.querySelectorAll('rect')].map(x=>x.getBoundingClientRect()),w=Math.max(...rs.map(x=>x.right))-Math.min(...rs.map(x=>x.left));return g.querySelector('text').getBoundingClientRect().width<=w+1})`));
await ok('tray: no recent files', !(await ev(`document.getElementById('trayPanel').textContent.includes('最近收到')`)));
await ok('tray: clipboard list', (await ev(`document.querySelectorAll('#trayPanel .tr-cl').length`))===5);
const clipOrder = await ev(`[...document.querySelectorAll('#trayPanel .tr-cl b')].map(e=>e.textContent).join()`);
await click('[data-a=trayMod][data-v=input]'); await sleep(450); await shot('19b-tray-clips'); await click('[data-a=trayMod][data-v=input]'); await sleep(300);
await click('#trayPanel .tr-cl:nth-of-type(2)'); await sleep(120); await shot('19c-tray-copied');
await ok('tray: copying ticks that row, and the list stays still', await ev(`document.querySelectorAll('#trayPanel .tr-cl .cp.done').length===1&&[...document.querySelectorAll('#trayPanel .tr-cl b')].map(e=>e.textContent).join()===${JSON.stringify(clipOrder)}`));
await sleep(1000);
await ok('tray: the tick goes back', await ev(`document.querySelectorAll('#trayPanel .tr-cl .cp.done').length===0`));
await sleep(1000);
await ok('tray: copied item is now the clipboard', await ev(`document.querySelector('.tr-what').textContent.includes('10003')`));
await ok('tray panel same element across renders', await ev(`(()=>{const a=document.querySelector('#trayPanel .tr-mod');a.__m=1;document.querySelector('[data-a=trayMod][data-v=input]').click();return document.querySelector('#trayPanel .tr-mod').__m===1})()`));
await ev(`document.body.click()`); await sleep(200);
await ev(`(()=>{const dt=new DataTransfer();dt.items.add(new File(['x'.repeat(2048)],'真实文件.txt'));document.getElementById('trayBtn').dispatchEvent(new DragEvent('dragenter',{bubbles:true,dataTransfer:dt}));})()`); await sleep(300);
await ok('drag opens tray', await ev(`!!document.getElementById('trayPanel')`));
await ev(`(()=>{const dt=new DataTransfer();dt.items.add(new File(['x'.repeat(2048)],'真实文件.txt'));const t=document.querySelector('.tr-t[data-v=mi]');t.dispatchEvent(new DragEvent('dragover',{bubbles:true,cancelable:true,dataTransfer:dt}));t.dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:dt}));})()`); await sleep(300);
await ok('real file drop', await ev(`document.getElementById('trayPanel').textContent.includes('真实文件')`));
await ev(`document.body.click()`); await sleep(200);

// links
await click('[data-a=global][data-v=links]'); await sleep(450); await shot('20-links');
const n0 = await ev(`document.querySelectorAll('[data-a=linkMore]').length`);
await ok('links: no rules between rows', await ev(`getComputedStyle(document.querySelector('.lks .row+.row'),'::before').display==='none'`));
await click('[data-a=linkMore]'); await sleep(300); await shot('21-link-menu');
await ev(`[...document.querySelectorAll('.mi')].find(m=>m.textContent.includes('删除')).click()`); await sleep(450); await shot('22-link-del');
await click('[data-a=linkDeleteYes]'); await sleep(450);
await ev(`document.querySelector('.dev[data-dev=tp]').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true}))`); await sleep(250);
await ok('device row has a context menu', await ev(`document.querySelector('.menu').textContent.includes('断开连接')`));
await ev(`document.body.click()`); await sleep(120);
await ok('link deleted', (await ev(`document.querySelectorAll('[data-a=linkMore]').length`))===n0-1);

// inbound
await click('[data-demo=inAudio]'); await sleep(550); await shot('23-sink');
await ok('sink actions', await ev(`document.querySelector('#main').textContent.includes('断开')`));
await click('[data-a=sinkStop]'); await sleep(200);
await click('[data-demo=inInput]'); await sleep(550); await shot('24-controlled');
await click('[data-a=ctrlStop]'); await sleep(200);
await click('[data-demo=req]'); await sleep(700); await shot('25-request');
await ok('a request: its answers side by side, equally wide', await ev(`(()=>{const b=[...document.querySelectorAll('.ask-acts button')].map(e=>e.getBoundingClientRect());return b.length===2&&b.every(r=>Math.abs(r.width-b[0].width)<.5&&r.top===b[0].top)})()`));
await ev(`document.querySelector('.ask-acts [data-v$=once]').click()`); await sleep(300);

// flows
await click('[data-demo=open]'); await sleep(900); await shot('26-viewer');
await click('[data-a=vSend]'); await sleep(250);
await ev(`document.querySelector('.mi').click()`); await sleep(1300);
await click('[data-demo=send]'); await sleep(1300); await shot('27-flows');

// palette
await click('[data-a=palette]'); await sleep(300); await ev(`(()=>{const i=document.getElementById('palInput');i.value='设置';i.dispatchEvent(new Event('input'));})()`); await sleep(120); await shot('28-palette');
await ev(`document.querySelector('.pal-it').click()`); await sleep(500);
await ok('palette settings', await ev(`!!document.querySelector('.sheet.settings')`));
await click('.st-close'); await sleep(450);

// send
await click('[data-a=dev][data-v=imac]'); await sleep(100); await click('[data-a=place][data-v=chat]'); await sleep(250);
await ok('send neutral when empty', !(await ev(`document.querySelector('.send').classList.contains('ready')`)));
await ev(`(()=>{const i=document.getElementById('composerInput');i.value='测试';i.dispatchEvent(new Event('input',{bubbles:true}));})()`); await sleep(40);
await ok('send lights up', await ev(`document.querySelector('.send').classList.contains('ready')`));
await ev(`document.querySelector('.composer').requestSubmit()`); await sleep(300);
await ok('message sent', await ev(`[...document.querySelectorAll('.bub.me')].pop().textContent==='测试'`));

// dark
await click('[data-demo=dark]'); await sleep(300); await shot('29-dark-chat');
await click('[data-a=global][data-v=input]'); await sleep(800); await shot('30-dark-input');
await click('[data-a=global][data-v=audio]'); await sleep(600); await shot('31-dark-audio');
await click('#trayBtn'); await sleep(500); await shot('32-dark-tray'); await ev(`document.body.click()`); await sleep(150);
await click('[data-a=dev][data-v=imac]'); await sleep(200); await click('[data-a=insp]'); await sleep(600); await shot('33-dark-card'); await click('[data-a=insp]'); await sleep(400);
await click('[data-demo=dark]'); await sleep(200);

// phone
await click('[data-demo=phone]'); await sleep(700); await overflow('phone'); await shot('34-phone-list');
await ok('phone: no corner row', await ev(`getComputedStyle(document.querySelector('.self')).display==='none'`));
await ok('phone: settings in the top bar', await ev(`!!document.querySelector('.side-top [data-a=settings]')`));
await ok('phone: no sections', (await ev(`document.querySelectorAll('.side-list .sec').length`))===0);
await ok('phone: desktop-only demos hidden', await ev(`document.querySelector('[data-demo=audio]').hidden`));
await ok('phone: touch target 48', await ev(`document.querySelector('.side-top [data-a=settings]').getBoundingClientRect().height>=48`));
await click('.side-list [data-a=dev][data-v=imac]'); await sleep(750); await shot('35-phone-chat');
await ok('phone: no bottom tabs', await ev(`!document.querySelector('#mainSeg')`));
await ok('phone: no screenshot', await ev(`!document.querySelector('.composer [data-a=shot]')`));
await ok('phone: composer at the bottom', await ev(`document.getElementById('win').getBoundingClientRect().bottom-document.querySelector('.composer').getBoundingClientRect().bottom<30`));
await ok('phone: no keyboard on top, control is on the device page', await ev(`!document.querySelector('.tb-end [data-v=control]')`));
await ok('plus icon centred', await ev(`(()=>{const b=document.querySelector('.send').getBoundingClientRect(),i=document.querySelector('.send svg.add').getBoundingClientRect();return Math.abs((b.left+b.width/2)-(i.left+i.width/2))<1&&Math.abs((b.top+b.height/2)-(i.top+i.height/2))<1})()`));
await click('.tb-end [data-a=pgo][data-v=card]'); await sleep(750); await shot('36-phone-card');
await ok('phone: no audio or mount in card', !(await ev(`document.querySelector('#main').textContent`)).match(/挂载|放进访达|把这台的声音/));
await ok('phone: clipboard row', await ev(`document.querySelector('#main').textContent.includes('同步给')`));
await ok('no invented keyboard permission', !(await ev(`document.querySelector('#main').textContent.includes('控制我的键鼠')`)));
await ok('phone device page leaves disconnect to the toolbar', await ev(`!document.querySelector('#main .insp-in, #main').textContent.includes('断开连接')`));
await ok('phone: history search in card', await ev(`document.querySelector('#main').textContent.includes('搜索聊天记录')`));
await ok('phone: control, files, apps on the device page', (await ev(`document.querySelectorAll('#main .circ.act').length`))===3);
await click('.circ.act[data-v=files]'); await sleep(700); await shot('37-phone-files');
await click('[data-a=back]'); await sleep(700);
await click('.circ.act[data-v=apps]'); await sleep(700); await shot('37b-phone-apps');
await click('[data-a=back]'); await sleep(700);
await click('.circ.act[data-v=control]'); await sleep(700); await shot('39-phone-control');
await click('[data-a=back]'); await sleep(700);
await click('[data-a=back]'); await sleep(700);
await ok('phone: back to chat', await ev(`!!document.querySelector('#composerInput')`));
await click('[data-a=back]'); await sleep(700);
// long device name
await click('.side-list [data-a=dev][data-v=tp]'); await sleep(750); await shot('35b-phone-long-name');
const lg = await ev(`(()=>{const t=document.querySelector('.tb-title').getBoundingClientRect(),e=document.querySelector('.tb-end').getBoundingClientRect();return {w:t.width,gap:e.left-t.right}})()`);
await ok('phone: long name has room', lg.w>=170&&lg.gap>=-1, JSON.stringify(lg));
await click('[data-a=back]'); await sleep(700);
// connect by camera
await click('.side-top [data-a=connectNew]'); await sleep(750); await shot('34b-phone-connect');
await ok('phone: connect opens on the QR, camera off', await ev(`!!document.querySelector('.conn-qr .qr')&&!document.querySelector('.vf')`));
await ok('phone: connect has three tabs', (await ev(`document.querySelectorAll('#connSeg button').length`))===3);
await click('[data-a=connTab][data-v=addr]'); await sleep(500); await shot('34d-phone-addr');
await ok('phone: address tab', await ev(`document.querySelectorAll('.conn input').length`)===2 || (await ev(`document.querySelectorAll('.conn input').length`))===2);
await click('[data-a=connTab][data-v=scan]'); await sleep(600); await shot('34e-phone-scan');
await ok('phone: camera only after switching', await ev(`!!document.querySelector('.vf')`));
await ok('phone: camera tools clear of the viewfinder', await ev(`document.querySelector('.vf-b').getBoundingClientRect().top>=document.querySelector('.vf').getBoundingClientRect().bottom`));
await ok('phone: torch and flip like the real page', await ev(`!!document.querySelector('[data-a=torch]')&&!!document.querySelector('[data-a=flipCam]')`));
await click('.vf'); await sleep(750); await shot('34c-phone-scanned');
await ok('phone: scan leads to comparing numbers', await ev(`document.querySelector('.code')?.textContent.includes('481')`));
await click('[data-a=back]'); await sleep(700);
await ok('phone: no root tabs', await ev(`!document.querySelector('#rootBar')`));
await click('.side-top [data-a=settings]'); await sleep(650); await shot('42-phone-settings');
await ok('phone: settings is a page', await ev(`!document.querySelector('.sheet.settings')&&document.querySelector('.tb-title').textContent.includes('设置')`));
await ok('phone: links in settings', await ev(`!!document.querySelector('#main [data-a=pgo][data-v=links]')`));
await click('#main [data-a=pgo][data-v=links]'); await sleep(750); await shot('41-phone-links');
await ok('phone: links page has a plus', await ev(`!!document.querySelector('.tb-end [data-a=linkNew]')`));
await ok('phone: no explaining under the list', await ev(`!document.querySelector('#main').textContent.includes('不用装 Whisper')`));
await click('.tb-end [data-a=linkNew]'); await sleep(350);
await ev(`document.querySelector('.menu button').click()`); await sleep(550); await shot('41b-phone-link-new');
await ok('phone: new link without a device', await ev(`!!document.querySelector('.sheet [data-a=linkRoute]')`));
await click('.sheet [data-a=closeSheet]'); await sleep(550);
await click('[data-a=back]'); await sleep(750);
await ok('phone: gain slider has the full width', await ev(`(()=>{const i=document.querySelector('#main input[data-input=gain]'),g=i.closest('.group').getBoundingClientRect();return i.getBoundingClientRect().width>=g.width-40})()`));
await ok('phone: settings rows keep one height', await ev(`[...document.querySelectorAll('#main .group .row:not(.stack)')].filter(r=>!r.querySelector('svg[width="44"],svg[height="44"]')).every(r=>r.getBoundingClientRect().height<=50)`));
await ok('phone: version and about are separate', await ev(`(()=>{const t=[...document.querySelectorAll('#main .row')].map(r=>r.textContent);return t.some(x=>x.includes('版本')&&x.includes('0.0.58'))&&t.some(x=>x.includes('关于 Whisper')&&!x.includes('0.0.58'))})()`));
await ok('slider fill follows its value', await ev(`(()=>{const i=document.querySelector('#main input[data-input=gain]');i.value=2;i.dispatchEvent(new Event('input',{bubbles:true}));const f=getComputedStyle(i).getPropertyValue('--f').trim();i.value=1;i.dispatchEvent(new Event('input',{bubbles:true}));return Math.abs(parseFloat(f)-.5)<.01})()`));
await click('#main [data-a=aboutOpen]'); await sleep(550); await shot('42e-phone-about');
await ok('about sheet', await ev(`document.querySelector('.about').textContent.includes('Whisper')`));
await click('.sheet [data-a=closeSheet]'); await sleep(500);
await ok('phone: no manual connect in settings', !(await ev(`document.querySelector('#main').textContent.includes('手动连接')`)));
await ok('phone: no separate update row', !(await ev(`document.querySelector('#main').textContent.includes('检查更新')`)));
await ok('phone: settings merged into few groups', (await ev(`document.querySelectorAll('#main .glabel').length`))<=3);
await ok('phone: no desktop-only rows', !(await ev(`document.querySelector('#main').textContent`)).match(/电视投屏|开机自启动|截图快捷键|滚轮/));
await ok('phone: island overlay is a status, not a switch', await ev(`[...document.querySelectorAll('#main .row')].find(r=>r.textContent.includes('后台灵动岛')).textContent.includes('已开启')&&!document.querySelector('[aria-label=后台灵动岛]')`));
await ok('phone: real android rows', await ev(`(()=>{const t=document.querySelector('#main').textContent;return t.includes('自动连接互信设备')&&t.includes('电池优化白名单')&&t.includes('后台灵动岛')&&t.includes('推送安卓通知')&&t.includes('验证码写入剪贴板')})()`));
await ev(`document.querySelector('#main .scroll').scrollTop=400`); await sleep(120); await shot('42c-phone-settings-2');
await ev(`document.querySelector('#main .scroll').scrollTop=9999`); await sleep(120); await shot('42d-phone-settings-3');
await ev(`document.querySelector('#main .scroll').scrollTop=0`);
await ok('phone: language picker in settings', await ev(`!!document.querySelector('#main .popb')`));
await ok('phone: settings has one level', await ev(`!document.querySelector('[data-a=pset]')&&document.querySelector('#main').textContent.includes('关于 Whisper')`));
await ok('phone: no desktop sections', !(await ev(`document.querySelector('#main').textContent.includes('系统行为')`)));
await click('[data-a=back]'); await sleep(650);
await ok('phone: back to list', await ev(`document.getElementById('main').style.visibility==='hidden'||!!document.querySelector('.side-list')`));
await click('[data-demo=inAudio]'); await sleep(400);
await click('.side-list [data-a=dev][data-v=imac]'); await sleep(700); await click('.tb-end [data-a=pgo][data-v=card]'); await sleep(700); await shot('43b-phone-sink');
await ok('phone: sink controls in card', await ev(`document.querySelector('#main').textContent.includes('断开')`));
await click('[data-a=sinkStop]'); await sleep(200);
await click('[data-a=back]'); await sleep(650); await click('[data-a=back]'); await sleep(650);
await click('[data-demo=phone]'); await sleep(550);

// connecting from the offline chat moves the row up
await click('.self [data-a=global][data-v=links]'); await sleep(200);
await click('[data-a=dev][data-v=pixel]'); await sleep(300);
await ok('offline chat offers connect in the toolbar, and has no composer', await ev(`!!document.querySelector('.tb-end [data-a=connect]')&&!document.querySelector('.composer')`));
await click('.tb-end [data-a=connect]'); await sleep(1200);
await ok('connected chat offers disconnect in the toolbar', await ev(`!!document.querySelector('.tb-end [data-a=disconnect]')`));
const order3 = await ev(`[...document.querySelectorAll('.side-list .dev b')].map(e=>e.textContent)`);
await ok('connecting moves a device up', order3.indexOf('Pixel 6')<order3.indexOf('2698b'), JSON.stringify(order3));
// resizing keeps the page
await click('.self [data-a=global][data-v=links]'); await sleep(300);
await size(500, 1000, false); await sleep(500); await size(1400, 1000, false); await sleep(500);
await ok('resize keeps the page', await ev(`document.querySelector('.place').dataset.pk==='/links'`));
// widths
await size(860, 1000, false); await sleep(450); await overflow('regular');
await click('[data-a=dev][data-v=imac]'); await sleep(700);
await ok('island clear of the toolbar at regular width', await ev(`(()=>{const hit=(a,b)=>a&&b&&a.left<b.right&&b.left<a.right&&a.top<b.bottom&&b.top<a.bottom;const i=document.getElementById('island');if(i.hidden)return true;const r=i.getBoundingClientRect();return ![...document.querySelectorAll('.tb-end > *')].some(e=>hit(r,e.getBoundingClientRect()))})()`));
await click('[data-a=insp]'); await sleep(600); await shot('43-regular-card'); await click('[data-a=insp]'); await sleep(450);
await click('.side-top [data-a=global][data-v=input]'); await sleep(1500); await shot('44-regular-input');
await size(390, 900, false); await sleep(600); await overflow('narrow');
await ok('no gradient defs inside the app', (await ev(`document.querySelectorAll('#stage defs').length`))===0);
await ok('every device gradient resolves', await ev(`[...document.querySelectorAll('#stage [fill^="url(#"]')].every(e=>document.getElementById(e.getAttribute('fill').slice(5,-1)))`));

// ---------- 侧栏和增益 ----------
await size(1400, 1000, false); await send('Page.navigate', { url: FILE }); await sleep(800);
const pillOn = async () => ev(`(()=>{const p=document.querySelector('.side-sel').getBoundingClientRect(),c=document.querySelector('.side-list .dev[aria-current=true]').getBoundingClientRect();return Math.abs(p.top-c.top)<1&&Math.abs(p.height-c.height)<1&&getComputedStyle(document.querySelector('.side-sel')).opacity==='1'})()`);
await sleep(300);
await ok('selection sits on the current row', await pillOn());
await ok('sidebar rows are letters in a circle', await ev(`getComputedStyle(document.querySelector('.side-list .dev .g')).borderRadius==='50%'&&document.querySelector('.side-list .dev .g').textContent.length===1`));
await ok('accent comes from Radix', await ev(`getComputedStyle(document.documentElement).getPropertyValue('--accent').trim()==='#0090ff'`));
await ok('wallpapers stay in one colour family', await ev(`[...document.querySelectorAll('svg defs linearGradient[id^="w-"] stop')].every(s=>{const c=s.getAttribute('stop-color'),r=parseInt(c.slice(1,3),16),g=parseInt(c.slice(3,5),16),b=parseInt(c.slice(5,7),16);const mx=Math.max(r,g,b),d=mx-Math.min(r,g,b);if(!d)return true;let h=mx===r?((g-b)/d)%6:mx===g?(b-r)/d+2:(r-g)/d+4;h=(h*60+360)%360;return h>=170&&h<=290})`));
await ok('live status uses the accent', await ev(`(()=>{const s=document.querySelector('.side-list small.live');return !!s&&getComputedStyle(s).color==='rgb(13, 116, 206)'})()`));
await ok('offline circle is grey, connected is blue', await ev(`getComputedStyle(document.querySelector('.side-list [data-dev=ubuntu] .g')).backgroundColor!==getComputedStyle(document.querySelector('.side-list [data-dev=imac] .g')).backgroundColor`));
await ok('selection glides and keeps its element', await ev(`new Promise(res=>{const el=document.querySelector('.side-sel');el.__m=1;const y0=new DOMMatrix(getComputedStyle(el).transform).m42;document.querySelector('.side-list [data-dev=mi]').click();const target=document.querySelector('.side-list [data-dev=mi]').offsetTop;let mid=false;const s=performance.now();(function f(){const y=new DOMMatrix(getComputedStyle(document.querySelector('.side-sel')).transform).m42;if(y>y0+1&&y<target-1)mid=true;if(performance.now()-s<700)requestAnimationFrame(f);else res(document.querySelector('.side-sel').__m===1&&mid)})()})`));
await ok('selection lands on the new row', await pillOn());
await click('.self [data-a=global][data-v=links]'); await sleep(300);
await ok('no selection on shared pages', await ev(`getComputedStyle(document.querySelector('.side-sel')).opacity==='0'`));
await click('[data-a=dev][data-v=imac]'); await sleep(400);
await ok('selection comes back on the row', await pillOn());
await click('[data-demo=inAudio]'); await sleep(700);
await ok('gain row is short and together', await ev(`(()=>{const g=document.querySelector('.group.gain').getBoundingClientRect(),l=document.querySelector('.gain .row span').getBoundingClientRect(),s=document.querySelector('.gain input').getBoundingClientRect(),p=document.querySelector('.pane').getBoundingClientRect();return g.width<=320&&s.left-l.right<=14&&s.width>=140&&Math.abs((g.left+g.right)/2-(p.left+p.right)/2)<1})()`));
await shot('60-sink-gain');
await click('[data-demo=inAudio]'); await sleep(300);

// ---------- 手机的蓝 ----------
await size(1400, 1000, false); await send('Page.navigate', { url: FILE }); await sleep(800);
await click('[data-demo=phone]'); await sleep(700);
const phoneBlue = `[getComputedStyle(document.querySelector('.side-list small.live')).color]`;
await ok('phone blue is the accent', (await ev(phoneBlue)).every(c => c === 'rgb(13, 116, 206)'), JSON.stringify(await ev(phoneBlue)));
await ok('phone list shows the circles', await ev(`getComputedStyle(document.querySelector('.side-list .dev .g')).borderRadius==='50%'`));
await click('#darkChip'); await sleep(300);
await ok('phone blue in dark', (await ev(phoneBlue)).every(c => c === 'rgb(112, 184, 255)'), JSON.stringify(await ev(phoneBlue)));
await click('#darkChip'); await sleep(200);
await click('[data-demo=phone]'); await sleep(500);

// ---------- 平台：Windows、GNOME、KDE ----------
const hitJs = (a, b) => `(()=>{const A=document.querySelector(${JSON.stringify(a)}),B=[...document.querySelectorAll(${JSON.stringify(b)})];if(!A)return false;const r=A.getBoundingClientRect();return B.some(e=>{const q=e.getBoundingClientRect();return q.width>0&&r.left<q.right&&q.left<r.right&&r.top<q.bottom&&q.top<r.bottom})})()`;
for (const os of ['win', 'gnome', 'kde']) {
  await size(1400, 1000, false);
  await send('Page.navigate', { url: `${FILE}?os=${os}` }); await sleep(800);
  await overflow(os);
  await shot(`70-${os}-chat`);
  const isWin = os === 'win';
  await ok(`${os}: no traffic lights`, await ev(`getComputedStyle(document.querySelector('.lights')).display==='none'`));
  await ok(`${os}: three window buttons with names`, await ev(`[...document.querySelectorAll('#capR button')].map(b=>b.getAttribute('aria-label')).join()==='最小化,最大化,关闭'`));
  if (isWin) await ok('win: caption is 138×32 in the corner', await ev(`(()=>{const c=document.getElementById('capR').getBoundingClientRect(),w=document.getElementById('win').getBoundingClientRect();return Math.round(c.width)===138&&Math.round(c.height)===32&&Math.abs(c.right-w.right)<1&&Math.abs(c.top-w.top)<1})()`));
  else await ok(`${os}: buttons sit on the toolbar midline`, await ev(`(()=>{const c=document.querySelector('#capR button').getBoundingClientRect(),w=document.getElementById('win').getBoundingClientRect();return Math.abs((c.top+c.height/2)-w.top-26)<1.5})()`));
  await ok(`${os}: toolbar clear of the buttons`, !(await ev(hitJs('#capR', '.tb-end > *'))));
  await ok(`${os}: shortcuts are spelled out`, await ev(`document.querySelector('[data-a=palette]').title.includes('Ctrl+K')&&document.querySelector('.self [data-a=settings]').title.includes('Ctrl+,')`));
  await click('[data-a=insp]'); await sleep(700);
  await ok(`${os}: the card gives way to the buttons`, await ev(`document.querySelector('#inspIn').firstElementChild.getBoundingClientRect().top>=document.getElementById('capR').getBoundingClientRect().bottom-1`));
  await ok(`${os}: the toolbar keeps its room under a floating card`, await ev(`parseFloat(getComputedStyle(document.getElementById('win')).getPropertyValue('--cap-r'))>0`));
  await ok(`${os}: mount wording follows the platform`, await ev(`[...document.querySelectorAll('#inspIn [aria-label]')].some(e=>e.getAttribute('aria-label').includes(${JSON.stringify(isWin ? '文件资源管理器' : '文件管理器')}))`));
  await shot(`71-${os}-card`);
  await click('[data-a=insp]'); await sleep(500);
  await click('.self [data-a=settings]'); await sleep(500);
  await ok(`${os}: screenshot key is the real default`, await ev(`(()=>{document.querySelectorAll('.st-nav button')[2].click();return true})()`) && await ev(`new Promise(r=>setTimeout(()=>r(document.querySelector('.hk')?.textContent==='Ctrl+Alt+S'),200))`));
  await ok(`${os}: no macOS permission rows`, await ev(`(()=>{document.querySelectorAll('.st-nav button')[3].click();return true})()`) && await ev(`new Promise(r=>setTimeout(()=>r(!document.querySelector('.st-body').textContent.includes('辅助功能')),200))`));
  await ev(`document.querySelectorAll('.st-nav button')[2].click()`); await sleep(250);
  const sys = await ev(`document.querySelector('.st-body').textContent`);
  await ok(`${os}: platform rows in 系统`, isWin ? sys.includes('锁屏与 UAC') && !sys.includes('窗口流转组件') : os === 'gnome' ? sys.includes('窗口流转组件') && !sys.includes('锁屏') : !sys.includes('窗口流转组件') && !sys.includes('锁屏'), sys);
  await shot(`72-${os}-settings`);
  await click('.st-close'); await sleep(450);
  // 托盘
  await click('#trayBtn'); await sleep(650);
  if (isWin) {
    await ok('win: tray is a panel above the taskbar', await ev(`(()=>{const p=document.getElementById('trayPanel'),m=document.querySelector('.menubar');return !!p&&p.getBoundingClientRect().bottom<=m.getBoundingClientRect().top` + `})()`));
    await shot('73-win-tray');
    await ev('document.body.click()'); await sleep(200);
    await ev(`document.getElementById('trayBtn').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true}))`); await sleep(200);
    await ok('win: right click keeps the native menu', await ev(`!document.getElementById('trayPanel')&&document.getElementById('trayMenu').textContent.includes('退出 Whisper')`));
    await shot('73b-win-tray-menu');
    await ev('document.body.click()'); await sleep(200);
    await ok('win: files cannot be dropped on the icon', await ev(`(()=>{const d=new DataTransfer();d.items.add(new File(['x'],'a.txt'));document.getElementById('trayBtn').dispatchEvent(new DragEvent('dragenter',{bubbles:true,dataTransfer:d}));return !document.getElementById('trayPanel')})()`));
  } else {
    await ok(`${os}: tray is only a menu`, await ev(`!document.getElementById('trayPanel')&&!!document.getElementById('trayMenu')`));
    await ok(`${os}: menu has the panel's content`, await ev(`['打开 Whisper','发送剪贴板到','发送文件到','声音放到','键鼠共享','最近的剪贴板','设置…','退出 Whisper'].every(t=>document.getElementById('trayMenu').textContent.includes(t))`));
    await ev(`[...document.querySelectorAll('.nm-i')].find(e=>e.textContent.includes('声音放到')).click()`); await sleep(200);
    await shot(`73-${os}-tray-menu`);
    await ev(`[...document.querySelectorAll('.nm-w[data-open=true] .nm-i')].find(e=>e.textContent.trim()==='iMac').click()`); await sleep(500);
    await ok(`${os}: picking in the menu starts the session`, await ev(`document.querySelector('.side-list [data-dev=imac] small').textContent.length>0`));
    await click('#trayBtn'); await sleep(200);
    await ev(`[...document.querySelectorAll('.nm-i')].find(e=>e.textContent.includes('声音放到')).click()`); await sleep(150);
    await ok(`${os}: menu shows the check`, await ev(`[...document.querySelectorAll('.nm-w[data-open=true] .nm-i')].some(e=>e.getAttribute('aria-checked')==='true')`));
    await ev(`[...document.querySelectorAll('.nm-w[data-open=true] .nm-i')].find(e=>e.getAttribute('aria-checked')==='true').click()`); await sleep(300);
    await ev('document.body.click()'); await sleep(200);
  }
  // 窗口按钮真的能用
  await click('#capR [data-a=capMax]'); await sleep(400);
  await ok(`${os}: maximize fills and squares the window`, await ev(`getComputedStyle(document.getElementById('win')).borderTopLeftRadius==='0px'&&document.querySelector('#capR .maximize').getAttribute('aria-label')==='还原'`));
  await shot(`74-${os}-max`);
  await ev(`document.querySelector('.tb-title').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}))`); await sleep(400);
  await ok(`${os}: double click on the toolbar restores`, await ev(`getComputedStyle(document.getElementById('win')).borderTopLeftRadius!=='0px'`));
  await click('#capR [data-a=capClose]'); await sleep(400);
  await ok(`${os}: close hides the window`, await ev(`document.getElementById('win').classList.contains('gone')&&!document.getElementById('winRestore').hidden`));
  await click('#winRestore'); await sleep(400);
  await ok(`${os}: window comes back`, await ev(`!document.getElementById('win').classList.contains('gone')`));
  // 最小窗口：宽 720 也放得下
  await size(772, 760, false); await sleep(500);
  await ok(`${os}: window is 720 wide in this check`, Math.abs(await ev(`document.getElementById('win').offsetWidth`) - 668) < 80, String(await ev(`document.getElementById('win').offsetWidth`)));
  await ok(`${os}: toolbar fits at the smallest window`, !(await ev(hitJs('#capR', '.tb-end > *'))) && await ev(`document.querySelector('.tb-title').getBoundingClientRect().width>=24`), String(await ev(`JSON.stringify({title:document.querySelector('.tb-title').getBoundingClientRect().width,end:document.querySelector('.tb-end').getBoundingClientRect().right,cap:document.getElementById('capR')?.getBoundingClientRect().left,main:document.getElementById('main').clientWidth})`)));
  await ok(`${os}: island does not cover the title`, await ev(`new Promise(r=>setTimeout(()=>{const i=document.getElementById('island');if(i.hidden)return r(true);const a=i.getBoundingClientRect(),g=document.createRange();g.selectNodeContents(document.querySelector('.tb-title b'));const b=g.getBoundingClientRect();r(!(a.left<b.right&&b.left<a.right&&a.top<b.bottom&&b.top<a.bottom))},500))`));
  await shot(`75-${os}-small`);
  await click('[data-demo=req]'); await sleep(800);
  await ok(`${os}: open island stays clear of the buttons`, !(await ev(hitJs('#island', '#capR button'))));
  await shot(`76-${os}-small-request`);
  await size(1400, 1000, false);
  await send('Page.navigate', { url: `${FILE}?os=${os}` }); await sleep(800);
  await ev(`document.querySelector('#darkChip').click()`); await sleep(350); await shot(`77-${os}-dark`);
  await ok(`${os}: phone has no window buttons`, await ev(`(()=>{document.querySelector('[data-demo=phone]').click();return true})()`) && await ev(`new Promise(r=>setTimeout(()=>r(document.getElementById('capR').offsetWidth===0&&document.getElementById('win').dataset.os==='phone'),500))`));
}
// GTK 的按钮布局
await send('Page.navigate', { url: `${FILE}?os=gnome&layout=close,minimize,maximize:` }); await sleep(800);
await ok('gnome: buttons on the left', await ev(`document.querySelectorAll('#capL button').length===3&&document.querySelectorAll('#capR button').length===0`));
await ok('gnome: left buttons clear of the sidebar icons', !(await ev(hitJs('#capL', '.side-top .iconbtn'))));
await shot('78-gnome-left');
await send('Page.navigate', { url: `${FILE}?os=gnome&layout=appmenu:close` }); await sleep(800);
await ok('gnome: stock layout shows only close', await ev(`[...document.querySelectorAll('#capL button,#capR button')].map(b=>b.getAttribute('aria-label')).join()==='关闭'`));
await send('Page.navigate', { url: `${FILE}?os=mac` }); await sleep(800);
await ok('mac: unchanged', await ev(`getComputedStyle(document.querySelector('.lights')).display!=='none'&&document.getElementById('capR').offsetWidth===0&&document.querySelector('[data-a=palette]').title.includes('⌘K')`));
// ---------- 平板和折叠屏 ----------
await size(1520, 1420, false); await send('Page.navigate', { url: FILE }); await sleep(800);
const form = async (f, st) => { await click(`#try [data-form=${f}]`); await sleep(250); if (st != null) await click(`[data-fstate="${st}"]`); await sleep(800); };
const wa = k => ev(`document.getElementById('win').dataset.${k}`);
const LADDER = [
  ['ipad', 0, 'regular', 'tablet-portrait'], ['ipad', 1, 'expanded', 'tablet-landscape'], ['ipad', 2, 'compact', 'tablet-split'],
  ['fold', 0, 'compact', 'fold-closed'], ['fold', 1, 'regular', 'fold-open'],
  ['wide', 0, 'compact', 'wide-closed'], ['wide', 1, 'expanded', 'wide-open'], ['wide', 2, 'compact', 'wide-small-portrait'], ['wide', 3, 'regular', 'wide-small-landscape'],
  ['tri', 0, 'compact', 'trifold-one'], ['tri', 1, 'regular', 'trifold-two'], ['tri', 2, 'expanded', 'trifold-three'],
];
for (const [f, st, cls, name] of LADDER) {
  await form(f, st);
  await ok(`${name}: size class follows the window`, (await wa('size')) === cls, await wa('size'));
  await ok(`${name}: touch density`, (await wa('input')) === 'touch');
  await ok(`${name}: no desktop chrome`, await ev(`getComputedStyle(document.querySelector('.self')).display==='none'&&getComputedStyle(document.querySelector('.lights')).display==='none'&&document.getElementById('capR').offsetWidth===0&&!document.querySelector('[data-a=palette]')`));
  await ok(`${name}: nothing sticks out`, await ev(`(()=>{const w=document.getElementById('win');return w.scrollWidth<=w.clientWidth+1})()`));
  if (cls !== 'compact') {
    await ok(`${name}: title clear of the toolbar controls`, await ev(`(()=>{const t=document.querySelector('.tb-title').getBoundingClientRect(),e=document.querySelector('.tb-end').getBoundingClientRect();return t.right<=e.left+1})()`));
    await ok(`${name}: sidebar stays in the rule`, await ev(`(()=>{const w=document.getElementById('side').offsetWidth;return w>=240&&w<=300})()`));
    await ok(`${name}: content keeps a phone's width`, await ev(`document.getElementById('main').offsetWidth>=360`));
  }
  await overflow(name);
  await shot(name);
  await click(`#try [data-form=${f}]`); await sleep(300);
}
await ok('leaving a device brings the desktop back', await ev(`document.getElementById('win').dataset.input==='pointer'&&getComputedStyle(document.querySelector('.self')).display!=='none'&&document.getElementById('stage').dataset.frame==='desktop'`));

// 设备卡片的高度跟着内容走
await size(1400, 1000, false); await send('Page.navigate', { url: FILE }); await sleep(800);
const cardFits = `(()=>{const c=document.getElementById('inspIn'),r=c.getBoundingClientRect(),w=document.getElementById('win').getBoundingClientRect();return {h:r.height,free:w.bottom-r.bottom,scrolls:c.scrollHeight>c.clientHeight+1}})()`;
await click('[data-a=insp]'); await sleep(700);
let cf = await ev(cardFits);
await ok('expanded: the card is as tall as its content', cf.free>40&&!cf.scrolls, JSON.stringify(cf));
await ok('expanded: the card floats over the content', await ev(`(()=>{const a=document.getElementById('insp').getBoundingClientRect(),m=document.getElementById('main').getBoundingClientRect();return a.right<=m.right&&a.left>m.left&&getComputedStyle(document.getElementById('insp')).borderRadius==='20px'})()`));
await ev(`(()=>{const t=document.createElement('style');t.id='shortWin';t.textContent='.win{height:420px!important}';document.head.append(t)})()`); await sleep(500);
cf = await ev(cardFits);
await ok('expanded: a short window scrolls inside the card', cf.free>=9&&cf.scrolls, JSON.stringify(cf));
await ev(`document.getElementById('shortWin').remove()`); await sleep(200);
await size(900, 1000, false); await sleep(600);
cf = await ev(cardFits);
await ok('regular: the card is as tall as its content', cf.free>40&&!cf.scrolls, JSON.stringify(cf));
await ev(`(()=>{const t=document.createElement('style');t.id='shortWin';t.textContent='.win{height:420px!important}';document.head.append(t)})()`); await sleep(500);
cf = await ev(cardFits);
await ok('regular: a short window scrolls inside the card', cf.free>=9&&cf.scrolls, JSON.stringify(cf));
await ev(`document.getElementById('shortWin').remove()`); await sleep(200);
await size(1520, 1420, false); await send('Page.navigate', { url: FILE }); await sleep(800);

// 卡片：盖在内容上，有 ×，点外面、换设备都收起，内容不动
await click('.side-list [data-dev=imac]'); await sleep(400);
const mainW = () => ev(`document.getElementById('main').offsetWidth`);
const cardShown = `getComputedStyle(document.getElementById('insp')).display!=='none'&&document.getElementById('insp').getBoundingClientRect().left<document.getElementById('win').getBoundingClientRect().right`;
const before = await mainW();
await click('.tb-end [data-a=insp]'); await sleep(700);
await ok('card: nothing under it moves', (await mainW())===before);
await ok('card: it has a close button', await ev(`!!document.querySelector('#inspIn .insp-x')`));
await click('.insp-x'); await sleep(700);
await ok('card: the close button closes it', !(await ev(cardShown)));
await click('.tb-end [data-a=insp]'); await sleep(700);
await ok('card: reopens', await ev(cardShown));
await click('.tb-title'); await sleep(700);
await ok('card: a click anywhere else closes it', !(await ev(cardShown)));
await click('.tb-end [data-a=insp]'); await sleep(700);
await click('.side-list [data-dev=tp]'); await sleep(700);
await ok('card: another device closes it', !(await ev(cardShown)));
await click('.side-list [data-dev=imac]'); await sleep(700);
await ok('card: and it stays closed coming back', !(await ev(cardShown)));
await click('.tb-end [data-a=insp]'); await sleep(700);
await ev(`document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))`); await sleep(700);
await ok('card: Esc closes it', !(await ev(cardShown)));

// 灵动岛：永远在窗口正中；这件事自己的进度在屏幕上时不显示
const islandShown = `!document.getElementById('island').hidden`;
const islandCentred = `(()=>{const i=document.getElementById('island').getBoundingClientRect(),w=document.getElementById('win').getBoundingClientRect();return Math.abs((i.left+i.width/2)-(w.left+w.width/2))<2})()`;
await click('[data-a=place][data-v=chat]'); await sleep(500);
await ev(`(()=>{const s=document.querySelector('.chat-scroll');s.scrollTop=s.scrollHeight})()`); await sleep(400);
await ok('island: quiet while the file card shows its own progress', !(await ev(islandShown)));
await ev(`document.querySelector('.chat-scroll').scrollTop=0`); await click('[data-a=place][data-v=files]'); await sleep(700);
await ok('island: comes back on another tab', await ev(islandShown));
await ok('island: in the middle of the window', await ev(islandCentred));
await click('.side-top [data-a=global][data-v=input]'); await sleep(700);
await ok('island: and on another page', await ev(islandShown));
await ok('island: still in the middle', await ev(islandCentred));
await click('.side-list [data-dev=imac]'); await sleep(500);
await click('[data-a=place][data-v=chat]'); await sleep(600);

// 扫码框
await click('[data-demo=phone]'); await sleep(600);
await click('.side-top [data-a=connectNew]'); await sleep(700);
await click('[data-a=connTab][data-v=scan]'); await sleep(500);
await ok('phone: the viewfinder is not oversized', await ev(`(()=>{const v=document.querySelector('.vf').getBoundingClientRect(),p=document.querySelector('.vf').parentElement.getBoundingClientRect();return v.width===280&&Math.abs(v.left-p.left-(p.right-v.right))<1})()`));
await send('Page.navigate', { url: FILE }); await sleep(800);
await form('ipad', 1);
await click('[data-a=connectNew]'); await sleep(600);
await click('[data-a=connTab][data-v=scan]'); await sleep(500);
await ok('tablet: the viewfinder keeps its size', await ev(`document.querySelector('.vf').getBoundingClientRect().width===280`));
await click('.side-list [data-dev=imac]'); await sleep(400);
await click('#try [data-form=ipad]'); await sleep(300);

// 平板的布局
await form('ipad', 1);
await ok('tablet: tabs are back, control is on the card', await ev(`!!document.getElementById('mainSeg')&&!document.querySelector('.tb-end [data-v=control]')`));
await ok('tablet: tabs have a full touch target', await ev(`(()=>{const b=document.querySelector('.seg button'),c=getComputedStyle(b,'::before');return b.offsetHeight+parseFloat(c.top)*-1+parseFloat(c.bottom)*-1>=48})()`));
await click('[data-a=insp]'); await sleep(650);
await ok('tablet: device card has no entries the toolbar already has', await ev(`!document.querySelector('.circ.act[data-v=files]')&&!document.querySelector('.circ.act[data-v=apps]')&&!!document.querySelector('.circ.act[data-v=control]')`));
await ok('tablet: device card has only what a phone can do', await ev(`!document.querySelector('#inspIn [data-a=tileAudio]')&&!document.querySelector('#inspIn [data-a=tileMount]')&&!!document.querySelector('#inspIn [data-a=tileClip]')`));
await ok('tablet: card floats over the content', await ev(`document.getElementById('insp').offsetWidth===320&&getComputedStyle(document.getElementById('insp')).position==='absolute'`));
await shot('tablet-device-card');
await click('[data-a=insp]'); await sleep(450);
await click('[data-a=place][data-v=files]'); await sleep(800); await shot('tablet-files');
await click('[data-a=place][data-v=chat]'); await sleep(600);
await click('[data-a=insp]'); await sleep(650);
await click('[data-a=settings]'); await sleep(700);
await ok('tablet: an open card steps aside for settings', await ev(`getComputedStyle(document.getElementById('insp')).display==='none'||document.getElementById('insp').offsetWidth<2`));
await ok('tablet: settings open in the content, the sidebar stays', await ev(`!document.querySelector('.sheet')&&document.querySelector('.tb-title').textContent.includes('设置')&&document.getElementById('side').offsetWidth>0`));
await ok('tablet: no device is selected in settings', await ev(`!document.querySelector('.side-list .dev[aria-current=true]')`));
await ok('tablet: only settings a phone has', await ev(`!document.querySelector('.st-nav')&&document.querySelector('.place').textContent.includes('共享链接')`));
await shot('tablet-settings');
await click('[data-a=pgo][data-v=links]'); await sleep(600);
await ok('tablet: pushed page has a way back', await ev(`getComputedStyle(document.querySelector('.tb .back')).display!=='none'`));
await click('.tb .back'); await sleep(500);
await click('.side-list [data-dev=tp]'); await sleep(700);
await click('[data-a=insp]'); await sleep(450);
await ok('tablet: tapping a device leaves settings', await ev(`document.querySelector('.place').dataset.pk==='tp/chat'&&!document.querySelector('.tb .back.show')`));
await click('[data-a=connectNew]'); await sleep(600);
await ok('tablet: connect opens in the content', await ev(`!document.querySelector('.sheet')&&document.querySelector('.tb-title').textContent.includes('连接设备')`));
await click('.side-list [data-dev=imac]'); await sleep(500);
await click('#try [data-form=ipad]'); await sleep(300);

// 折叠和展开不丢东西
await form('fold', 1);
await click('.side-list [data-dev=tp]'); await sleep(500);
await ev(`(()=>{const i=document.getElementById('composerInput');i.value='还没写完';i.dispatchEvent(new Event('input',{bubbles:true}))})()`);
await click('[data-fstate="0"]'); await sleep(900);
await ok('fold: closing keeps the device on top', await ev(`document.getElementById('win').dataset.size==='compact'&&document.querySelector('.tb-title').textContent.includes('ThinkPad')&&getComputedStyle(document.getElementById('main')).visibility!=='hidden'`));
await ok('fold: closing keeps the draft', await ev(`document.getElementById('composerInput').value==='还没写完'`));
await click('[data-fstate="1"]'); await sleep(900);
await ok('fold: opening keeps the draft', await ev(`document.getElementById('composerInput').value==='还没写完'`));
await ok('fold: opening selects that device in the sidebar', await ev(`document.querySelector('.side-list .dev[aria-current=true]').dataset.dev==='tp'`));
await ok('fold: bubbles fit the wider window', await ev(`[...document.querySelectorAll('.bub')].every(b=>b.scrollWidth<=b.clientWidth+1)`));
await ok('fold: chat stays at the bottom', await ev(`(()=>{const s=document.querySelector('.chat-scroll');return s.scrollHeight-s.scrollTop-s.clientHeight<4})()`));
await click('[data-a=place][data-v=files]'); await sleep(700);
await click('[data-fstate="0"]'); await sleep(900);
await ok('fold: closing keeps the tab', await ev(`document.querySelector('.place').dataset.pk==='tp/files'`));
await click('[data-fstate="1"]'); await sleep(900);
await ok('fold: opening keeps the tab', await ev(`document.querySelector('.place').dataset.pk==='tp/files'&&document.querySelector('.seg [aria-selected=true]').dataset.v==='files'`));
await click('[data-a=place][data-v=chat]'); await sleep(500);
await click('[data-a=insp]'); await sleep(650);
await click('[data-fstate="0"]'); await sleep(900);
await ok('fold: the open device card becomes the device page', await ev(`document.querySelector('.place').dataset.pk==='tp/card'&&!!document.querySelector('.place .circs.act3')`));
await click('[data-fstate="1"]'); await sleep(900);
await ok('fold: the device page becomes the open card', await ev(`document.querySelector('.place').dataset.pk==='tp/chat'&&getComputedStyle(document.getElementById('insp')).display!=='none'&&document.querySelector('[data-a=insp]').getAttribute('aria-pressed')==='true'`));
await click('[data-a=insp]'); await sleep(450);
await click('[data-fstate="0"]'); await sleep(900);
await click('.tb .back'); await sleep(600);
await ok('fold: back from the top of the stack is the list', await ev(`new DOMMatrix(getComputedStyle(document.getElementById('main')).transform).m41>100`));

// 姿态
await click('[data-fstate="1"]'); await sleep(900);
await click('.side-list [data-dev=imac]'); await sleep(400);
await click('[data-fstate="2"]'); await sleep(900);
await ok('book: the sidebar edge is on the fold', await ev(`Math.abs(document.getElementById('side').offsetWidth-452)<1`));
await ok('book: fold drawn at the same place', await ev(`(()=>{const c=document.querySelector('#creases i.v').getBoundingClientRect(),m=document.getElementById('main').getBoundingClientRect();return Math.abs((c.left+c.width/2)-m.left)<1})()`));
await ok('book: island is in the middle of the window', await ev(`(()=>{const i=document.getElementById('island');if(i.hidden)return true;const a=i.getBoundingClientRect(),w=document.getElementById('win').getBoundingClientRect();return Math.abs((a.left+a.width/2)-(w.left+w.width/2))<2})()`));
await shot('fold-book');
await click('[data-fstate="3"]'); await sleep(900);
await click('[data-a=insp]'); await sleep(600);
await click('.circ[data-v=control]'); await sleep(800);
await ok('tabletop: the pad is below the fold', await ev(`(()=>{const c=document.querySelector('#creases i.h').getBoundingClientRect(),y=c.top+c.height/2,p=document.querySelector('.gs-table .pad').getBoundingClientRect(),t=document.querySelector('.ctl-top').getBoundingClientRect();return p.top>=y&&t.bottom<=y})()`));
await ok('tabletop: control is full width', await ev(`getComputedStyle(document.getElementById('side')).display==='none'&&document.getElementById('main').offsetWidth===640`));
await shot('fold-tabletop-control');
await click('.tb .back'); await sleep(500);
await ok('tabletop: other pages keep their layout', await ev(`document.getElementById('side').offsetWidth===240`));
await click('#try [data-form=fold]'); await sleep(300);

// 高度不够
await form('wide', 3);
await ok('short: flagged under 600 tall', (await wa('short')) === 'true');
await click('[data-a=insp]'); await sleep(600);
await click('.circ[data-v=control]'); await sleep(800);
await ok('short: pad and buttons sit side by side', await ev(`(()=>{const a=document.querySelector('.pad').getBoundingClientRect(),b=document.querySelector('.pad-b').getBoundingClientRect();return b.left>=a.right-1&&a.height>=240})()`));
await shot('wide-small-landscape-control');
await click('.tb .back'); await sleep(500);
await click('[data-a=connectNew]'); await sleep(700);
await ok('short: connect fits or scrolls', await ev(`(()=>{const r=document.querySelector('.conn-qr svg').getBoundingClientRect(),m=document.getElementById('main').getBoundingClientRect();return r.top>=m.top&&r.bottom<=m.bottom})()`));
await shot('wide-small-landscape-connect');
await click('.side-list [data-dev=imac]'); await sleep(400);
await click('#try [data-form=wide]'); await sleep(300);

// 浏览器变窄再变回来，外框不丢
await form('tri', 2);
await size(500, 900, false); await sleep(500);
await ok('narrow browser falls back to the phone', (await wa('size')) === 'compact');
await size(1520, 1420, false); await sleep(900);
await ok('back from narrow keeps the device frame', await ev(`getComputedStyle(document.getElementById('devFrame')).borderRadius==='24px'&&document.getElementById('win').offsetWidth===1337`));

// 小屏幕的浏览器：外框缩放后，灵动岛和菜单还在该在的地方
await size(1180, 760, false); await sleep(900);
await ok('scaled frame fits the browser', await ev(`document.getElementById('devFrame').getBoundingClientRect().width<=1180`));
await click('[data-demo=req]'); await sleep(900);
await ok('scaled frame: island is in the middle of the window', await ev(`(()=>{const a=document.getElementById('island').getBoundingClientRect(),w=document.getElementById('win').getBoundingClientRect();return Math.abs((a.left+a.width/2)-(w.left+w.width/2))<2})()`));
await size(1520, 1420, true); await send('Page.navigate', { url: FILE }); await sleep(800);
await click('#darkChip'); await sleep(300);
await form('fold', 1); await shot('fold-open-dark');
await click('#try [data-form=fold]'); await sleep(300);
await form('ipad', 0); await shot('tablet-portrait-dark');
await click('#try [data-form=ipad]'); await sleep(300);
await click('#darkChip'); await sleep(200);

console.log(`pass ${passes} fail ${fails.length}`);
console.log('ERRORS', JSON.stringify(errors));
console.log('FAILED', JSON.stringify(fails));
console.log('截图在', OUT);
ws.close(); proc.kill(); process.exit(fails.length || errors.length ? 1 : 0);
