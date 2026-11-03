// 把 check-prototype 的截图按内容命名，放进 reference/。
// 用法：SHOT_FORMAT=jpeg node docs/design/tools/check-prototype.mjs <目录>，再 node docs/design/tools/update-reference.mjs <目录>
// windows-real-* 是真实窗口的截图，不从这里来。
import { copyFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const from = process.argv[2];
if (!from) { console.error('用法：node update-reference.mjs <check-prototype 的输出目录>'); process.exit(2); }
const to = fileURLToPath(new URL('../reference/', import.meta.url));
const MAP = {
  'desktop-chat': '01-chat', 'desktop-composer-shot': '01b-composer-shot', 'desktop-device-card': '02-card', 'desktop-tab-switch': '02b-tab-mid',
  'desktop-files': '03-files', 'desktop-files-location': '03b-files-location', 'desktop-link-detail': '05-link-qr', 'desktop-apps': '06-apps',
  'desktop-settings': '07-settings', 'desktop-settings-sharing': '07b-settings-sound', 'desktop-settings-language': '07c-settings-lang', 'desktop-self': '08-self',
  'desktop-audio-idle': '09-audio-idle', 'desktop-offline': '09b-offline', 'desktop-audio': '10-audio', 'desktop-input': '12-input', 'desktop-input-on': '13-input-on', 'desktop-input-drag': '14-input-drag',
  'desktop-tray-hold': '17-tray-hold', 'desktop-tray-clips': '19b-tray-clips', 'desktop-tray-copied': '19c-tray-copied', 'desktop-links': '20-links',
  'desktop-audio-sink': '23-sink', 'desktop-input-controlled': '24-controlled', 'desktop-island-request': '25-request', 'desktop-viewer': '26-viewer', 'desktop-palette': '28-palette',
  'dark-chat': '29-dark-chat', 'dark-input': '30-dark-input', 'dark-audio': '31-dark-audio', 'dark-tray': '32-dark-tray', 'dark-device-card': '33-dark-card',
  'phone-list': '34-phone-list', 'phone-connect': '34b-phone-connect', 'phone-scanned': '34c-phone-scanned', 'phone-connect-address': '34d-phone-addr', 'phone-connect-scan': '34e-phone-scan',
  'phone-chat': '35-phone-chat', 'phone-long-name': '35b-phone-long-name', 'phone-device': '36-phone-card', 'phone-files': '37-phone-files', 'phone-apps': '37b-phone-apps', 'phone-control': '39-phone-control',
  'phone-links': '41-phone-links', 'phone-settings': '42-phone-settings', 'phone-settings-bottom': '42d-phone-settings-3',
  'tablet-portrait': 'tablet-portrait', 'tablet-landscape': 'tablet-landscape', 'tablet-split': 'tablet-split', 'tablet-device-card': 'tablet-device-card', 'tablet-files': 'tablet-files', 'tablet-settings': 'tablet-settings', 'tablet-portrait-dark': 'tablet-portrait-dark',
  'fold-closed': 'fold-closed', 'fold-open': 'fold-open', 'fold-open-dark': 'fold-open-dark', 'fold-book': 'fold-book', 'fold-tabletop-control': 'fold-tabletop-control',
  'wide-closed': 'wide-closed', 'wide-open': 'wide-open', 'wide-small-portrait': 'wide-small-portrait', 'wide-small-landscape': 'wide-small-landscape', 'wide-small-landscape-control': 'wide-small-landscape-control', 'wide-small-landscape-connect': 'wide-small-landscape-connect',
  'trifold-one': 'trifold-one', 'trifold-two': 'trifold-two', 'trifold-three': 'trifold-three',
  'regular-device-card': '43-regular-card', 'regular-input': '44-regular-input',
  'windows-tray': '73-win-tray', 'windows-tray-menu': '73b-win-tray-menu', 'gnome-tray-menu': '73-gnome-tray-menu', 'kde-tray-menu': '73-kde-tray-menu', 'gnome-buttons-left': '78-gnome-left',
};
for (const [name, os] of [['windows', 'win'], ['gnome', 'gnome'], ['kde', 'kde']]) {
  for (const [what, n] of [['chat', 70], ['device-card', '71-card'], ['settings', 72], ['maximized', '74-max'], ['small', 75], ['small-request', 76], ['dark', 77]]) {
    const [num, suffix] = String(n).includes('-') ? String(n).split(/-(.*)/) : [n, what];
    MAP[`${name}-${what}`] = `${num}-${os}-${suffix}`;
  }
}
let bad = 0;
for (const [name, src] of Object.entries(MAP)) {
  const p = `${from}/${src}.jpg`;
  if (!existsSync(p)) { console.error('缺少', p); bad++; continue; }
  copyFileSync(p, `${to}${name}.jpg`);
}
console.log(`${Object.keys(MAP).length - bad} 张已更新`);
process.exit(bad ? 1 : 0);
