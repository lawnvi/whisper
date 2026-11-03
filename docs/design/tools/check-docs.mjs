// Checks that DESIGN.md, the prototype and the docs agree.
import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const R = fileURLToPath(new URL('../../../', import.meta.url)).replace(/[\\/]$/, '');
const d = readFileSync(`${R}/DESIGN.md`, 'utf8'), p = readFileSync(`${R}/docs/design/whisper-ui-language.html`, 'utf8');
const fm = d.split('---')[1], bad = [], symbols = new Set();
// Only `colors:`: the blocks after it (settings icons, the viewfinder) are not CSS variables in the prototype.
const colorsBlock = fm.slice(fm.indexOf('colors:'), fm.indexOf('\noverlays:'));
const col = {}; for (const m of colorsBlock.matchAll(/^  ([a-z0-9-]+): "(#[0-9A-Fa-f]{6})"/gm)) col[m[1]] = m[2].toLowerCase();
const block = s => { const i = p.indexOf(s), j = p.indexOf('}', i); return p.slice(i, j); };
const light = block(':root{'), dark = block(':root[data-theme=dark]{');
const v = (b, n) => (b.match(new RegExp(`--${n}:(#[0-9a-f]{6})`)) || [])[1];
for (const [k, val] of Object.entries(col)) {
  const isDark = k.endsWith('-dark'), name = isDark ? k.slice(0, -5) : k, cssVal = v(isDark ? dark : light, name);
  if (cssVal !== val) bad.push(`${k}: DESIGN ${val} vs prototype ${cssVal}`);
}
for (const m of fm.matchAll(/^  (large|title|head|body|note|tiny): \[(\d+), (\d+)\]/gm)) { if (!light.includes(`--t-${m[1]}:${m[2]}px`)) bad.push('type ptr ' + m[1]); if (!p.includes(`--t-${m[1]}:${m[3]}px`)) bad.push('type touch ' + m[1]); }
// 壁纸
for (const m of fm.matchAll(/^  (self|device-\d|unpaired): \["(#[0-9A-F]{6})", "(#[0-9A-F]{6})"\]/gm)) { if (!p.includes(m[2].toLowerCase()) || !p.includes(m[3].toLowerCase())) bad.push('wallpaper ' + m[1]); }
for (const k of ['xs', 's', 'm', 'l']) { const val = fm.match(new RegExp(`^  ${k}: (\\d+)$`, 'm'))[1]; if (!light.includes(`--r-${k}:${val}px`)) bad.push('radius ' + k); }
for (const k of ['follow', 'snappy', 'smooth', 'expressive']) {
  const m = fm.match(new RegExp(`${k}: \\{ response: ([\\d.]+), damping-ratio: ([\\d.]+), stiffness: (\\d+), damping: ([\\d.]+)`));
  const K = (2 * Math.PI / +m[1]) ** 2, C = 2 * +m[2] * Math.sqrt(K);
  if (Math.abs(K - +m[3]) > 1 || Math.abs(C - +m[4]) > .1) bad.push(`spring math ${k}`);
  const q = p.match(new RegExp(`${k}: SP\\(([\\d.]+), ?([\\d.]+)\\)`));
  if (!q || +q[1] !== +m[1] || +q[2] !== +m[2]) bad.push(`spring proto ${k}`);
}
for (const m of p.matchAll(/(?:src|href)="(https?:[^"]+)"|url\((https?:[^)]+)\)|@import/g)) bad.push('external: ' + m[0]);
const DOCS = ['DESIGN.md', 'docs/design/README.md', 'docs/design/surfaces.md', 'docs/design/flutter.md', 'docs/design/decisions.md', 'docs/design/migration.md'];
for (const f of DOCS) {
  const s = readFileSync(`${R}/${f}`, 'utf8'), base = f.includes('/') ? f.slice(0, f.lastIndexOf('/') + 1) : '';
  for (const m of s.matchAll(/\]\(([^)#]+)\)/g)) if (!/^http/.test(m[1])) { const out = []; (base + m[1]).split('/').forEach(x => x === '..' ? out.pop() : out.push(x)); if (!existsSync(`${R}/${out.join('/')}`)) bad.push(`dead link in ${f}: ${m[1]}`); }
  // 引用的代码符号要真实存在；截图要真实存在
  for (const m of s.matchAll(/`([a-z-]+\.jpg)`/g)) if (!existsSync(`${R}/docs/design/reference/${m[1]}`)) bad.push(`missing shot in ${f}: ${m[1]}`);
  if (f !== 'docs/design/flutter.md' && f !== 'docs/design/decisions.md') for (const m of s.matchAll(/`((?:_?[A-Z][a-z]+[A-Za-z]+)|(?:_?[a-z]+[A-Z][A-Za-z]+))(?:\.[a-zA-Z]+)?(?:\(\))?`/g)) symbols.add(m[1]);
  for (const m of s.matchAll(/`((?:lib|docs|assets|script)\/[^`*:\s]+?)(?::\d+)?`/g)) if (!existsSync(`${R}/${m[1]}`) && m[1] !== 'lib/theme/whisper_ui.dart') bad.push(`missing path in ${f}: ${m[1]}`);
}
// 新设计引入的符号在 flutter.md 里定义
const defined = readFileSync(`${R}/docs/design/flutter.md`, 'utf8');
const walk = d => readdirSync(d).flatMap(n => { const p = `${d}/${n}`; return statSync(p).isDirectory() ? walk(p) : p.endsWith('.dart') ? [p] : []; });
const lib = walk(`${R}/lib`).map(p => readFileSync(p, 'utf8')).join('\n') + readFileSync(`${R}/lib/l10n/app_zh.arb`, 'utf8');
for (const y of symbols) if (!lib.includes(y) && !defined.includes(y) && !['SnackBar', 'DwmSetWindowAttribute', 'ExcludeClipboardContentFromMonitorProcessing'].includes(y)) bad.push(`unknown symbol: ${y}`);
// stale vocabulary from the rejected version
for (const f of ['DESIGN.md', 'docs/design/README.md', 'docs/design/surfaces.md', 'docs/design/flutter.md', 'docs/design/migration.md']) { const s = readFileSync(`${R}/${f}`, 'utf8'); for (const w of ['舞台', '环青', 'accent-soft', '成组']) if (s.includes(w)) bad.push(`stale "${w}" in ${f}`); }
for (const w of ['环青', '舞台', '--ring', '--h1:']) if (p.includes(w)) bad.push(`stale "${w}" in prototype`);
console.log(bad.length ? 'PROBLEMS\n' + bad.join('\n') : 'token、链接、路径、符号、截图都对得上');
process.exit(bad.length ? 1 : 0);
