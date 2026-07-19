# Whisper Web 下载体验整改 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `whisper-web/` 改成由 Server Components/ISR 驱动、Release 信息可验证、真实产品截图主导且移动端/SEO/无障碍完整的下载页。

**Architecture:** GitHub Release 解析和 fetch 收敛到 `lib/release/` 纯领域层；locale route 在服务端取目录并组合小型 Server Components。客户端只保留 `next-themes` 的切换按钮和复制 SHA-256 的反馈。

**Tech Stack:** Next.js 15.5.20、React 19、TypeScript、Tailwind CSS 3、next-themes、lucide-react、Vitest 3、Playwright 1、axe-core。

## Global Constraints

- 所有命令默认工作目录为独立仓库 `whisper-web/`；每个任务在该仓库独立 commit，最后才 push。
- `whisper-web/main` 当前已有用户 commit `c9a0f37 feat(web): 优化大屏自适应宽度`（相对 `origin/main` ahead 1）；必须原样保留，不 rebase/drop/amend，最终随本轮 commits 一起 push。
- 渠道只看 tag：`release-v*` 为 stable，`dev-v*` 为 preview；stable 优先，无 stable 才展示 preview。
- 所有可见版本只从选中的 Release tag 得出；失败时不得显示 `0.0.0` 或硬编码旧版本。
- 所有下载必须是直接 GitHub `browser_download_url` 的 `<a href>`；不得用 iframe、脚本下载或跨域 `download` 属性。
- 当前无端到端加密；文案必须限定可信 LAN，不能使用安全背书或绝对速度/大小承诺。
- 匿名 FTP 正在从 app 删除；Web 必须删除 FTP feature、alpha 标记、FAQ 和结构化数据痕迹。
- 不添加评分、评价、安装量、客户 logo 或虚构证明。
- 卡片圆角 <= 8px、触控目标 >= 44px、letter-spacing 为 0、正文对比 >= 4.5:1。
- 原子中文 Conventional Commits；每次 commit 前运行该任务的 focused tests 与 lint。

---

### Task 1: 升级生产依赖并建立测试基线

**Files:**
- Modify: `package.json`, `package-lock.json`, `eslint.config.mjs`
- Create: `vitest.config.ts`, `tests/package-baseline.test.ts`
- Delete: `scripts/check-release-asset-matching.mjs`

**Interfaces:**
- Produces scripts: `npm test`, `npm run test:e2e`, `npm run lint`, `npm run audit:prod`, `npm run check`。

- [ ] **Step 1: 写失败的 package baseline test**

断言 `private === true`、Web 包版本为 `0.0.0`、`dependencies.next === '15.5.20'`、`eslint-config-next === '15.5.20'`、lint script 为 `eslint .`，并断言 `overrides.next.postcss === '8.5.10'` 且 lockfile 中 Next 的嵌套 postcss 解析版本至少为 8.5.10。先运行：

```bash
npx vitest run tests/package-baseline.test.ts
```

Expected: FAIL，当前仍为 Next 15.1.0、Web version 0.0.29、`next lint`。

- [ ] **Step 2: 升级并锁定兼容版本**

```bash
npm install --save-exact next@15.5.20
npm install --save-exact server-only@0.0.1
npm install --save-exact next-themes@0.4.6 lucide-react@1.24.0
npm install --save-dev --save-exact eslint-config-next@15.5.20 eslint@9.39.4 @eslint/eslintrc@3.3.5 vitest@3.2.7 @playwright/test@1.61.1 @axe-core/playwright@4.12.1
```

在 `package.json` 设置 `engines.node: ">=20"`、`version: "0.0.0"`，以及 scoped override `"overrides": { "next": { "postcss": "8.5.10" } }`；scripts 设置：

```json
{
  "lint": "eslint .",
  "test": "vitest run",
  "test:e2e": "playwright test",
  "audit:prod": "npm audit --omit=dev --audit-level=moderate",
  "check": "npm run audit:prod && npm run lint && npm test && npm run build"
}
```

保留 React 19 与现有运行依赖到 Task 3 再删除未使用项。删除只检查源码字符串的旧 mjs test。

- [ ] **Step 3: 更新 ESLint flat config 并验证**

确保 `.next/`、`coverage/`、`playwright-report/`、`test-results/` 被 ignores；运行：

```bash
npm run audit:prod
npm run lint
npm test -- tests/package-baseline.test.ts
npm run build
```

Expected: production audit 0 vulnerabilities（包括 Next 的嵌套 postcss）；lint/test/build PASS。

- [ ] **Step 4: Commit**

```bash
git add package.json package-lock.json eslint.config.mjs vitest.config.ts tests/package-baseline.test.ts scripts/check-release-asset-matching.mjs
git commit -m "chore(web): 升级 Next 并建立测试基线"
```

---

### Task 2: 建立 Release 渠道、资产解析与 ISR adapter

**Files:**
- Create: `lib/release/types.ts`
- Create: `lib/release/asset-parser.ts`
- Create: `lib/release/github-core.ts`
- Create: `lib/release/github.ts`
- Create: `lib/release/system-requirements.ts`
- Create: `tests/fixtures/github-release-dev-v0.0.42.json`
- Create: `tests/fixtures/github-commit-dev-v0.0.42.json`
- Create: `tests/release/asset-parser.test.ts`, `tests/release/github.test.ts`

**Interfaces:**
- Produces: `selectRelease(releases: unknown): SelectedRelease | null`
- Produces: `parseReleaseAssets(assets: unknown): DownloadAsset[]`
- Produces: pure `fetchReleaseCatalog(fetcher)` in `github-core.ts`；`getReleaseCatalog(): Promise<ReleaseCatalog>` in `github.ts` (`server-only`, `unstable_cache`, revalidate 3600)
- Produces: `getSystemRequirementKeys(platform: Platform): RequirementKey[]`；Task 5 通过 locale 字典映射为可见文案，Task 2 不反向依赖尚未创建的 i18n 层。

- [ ] **Step 1: 固化真实 fixture 并写失败测试**

fixture 保存 2026-07-08 GitHub API 返回的 `dev-v0.0.42` release/commit，不手改资产名、size、digest。测试精确断言：10 个资产；Linux 3 个；Android 4 个；iOS unsigned IPA 1 个；所有 10 个 digest 合法；`.ipa.bak`/source archive 被拒绝；数组倒序后输出不变；commit endpoint 使用 encoded `tag_name`，fixture 的实际 SHA 以 `5432c2e` 开头而不是请求 `target_commitish`。

另构造最小 release 数组，断言 `release-v0.0.40` 优先于更新的 `dev-v0.0.42`，并断言 `dev-v* + prerelease:false` 仍是 preview。

```bash
npm test -- tests/release
```

Expected: FAIL，模块尚不存在。

- [ ] **Step 2: 实现纯解析领域层**

严格实现 spec 的 `ReleaseCatalog`/`DownloadAsset` 类型、tag regex、按 `published_at` + semver + tag 的稳定选择、资产稳定排序、legacy naming 和 SHA-256 校验。不得使用 `any`，不得按 platform 覆盖；推荐项仅为 Windows EXE、macOS universal/x86_64 fallback、Linux AppImage、Android universal，iOS 无推荐项。

- [ ] **Step 3: 写失败的 fetch/fallback 测试并实现 adapter**

向 `github-core.ts` 的 `fetchReleaseCatalog(fetcher)` 注入 fake fetch，覆盖：200 ready、release 403、无合法 tag、commit 404、畸形 JSON、`Link rel=next` 分页、stable 位于后页和页数上限。commit 404 仍返回 ready 且 `commit:null`；core 失败抛 typed error。

生产 wrapper 导入 `server-only`，用 `unstable_cache` 缓存严格验证后的 ready catalog；内部 GitHub fetch 使用 `cache: 'no-store'`、5 秒 timeout、API headers、可选 server-only `GITHUB_TOKEN`。重验证遇到失败/畸形值必须在 cache callback 内抛错以保留旧成功值；外层只在冷启动无缓存时返回 `{status:'unavailable'}`。

- [ ] **Step 4: 验证并 commit**

```bash
npm test -- tests/release
npm run lint
git add lib/release/types.ts lib/release/asset-parser.ts lib/release/github-core.ts lib/release/github.ts lib/release/system-requirements.ts tests/fixtures/github-release-dev-v0.0.42.json tests/fixtures/github-commit-dev-v0.0.42.json tests/release/asset-parser.test.ts tests/release/github.test.ts
git commit -m "feat(web): 建立可验证的 Release 目录"
```

---

### Task 3: 重建 locale root 与 Server Component 页面骨架

**Files:**
- Create: `lib/i18n.ts`
- Create: `app/[lang]/layout.tsx`
- Rewrite: `app/[lang]/page.tsx`
- Create: `app/components/site-header.tsx`, `app/components/site-footer.tsx`
- Create: `app/components/theme-toggle.tsx`
- Modify: `app/components/ThemeProvider.tsx`
- Modify: `middleware.ts`
- Delete: `app/layout.tsx`, `app/page.tsx`, `hooks/useLanguage.ts`, `hooks/useTheme.ts`, `app/components/ThemeToggle.tsx`
- Modify: `package.json`, `package-lock.json`
- Create: `tests/i18n.test.ts`, `tests/server-boundaries.test.ts`

**Interfaces:**
- Produces: `type Locale = 'zh' | 'en'`, `isLocale`, `localeToHtmlLang`, `getMessages`
- Consumes: `getReleaseCatalog()` from Task 2
- Produces: locale root with `<html lang="zh-CN|en">`; root `/` remains middleware redirect only。

- [ ] **Step 1: 写 locale/content 失败测试**

断言只有 zh/en、html lang 映射正确、两种字典 key 完全相同，并扫描序列化文案不得出现 FTP/alpha、`0.0.29`、`0.0.0`、“没有大小限制/跑满带宽/Never miss”。

```bash
npm test -- tests/i18n.test.ts tests/server-boundaries.test.ts
```

Expected: FAIL，文案仍在 1013 行 client 文件中且含 FTP/绝对宣传。

- [ ] **Step 2: 将 locale segment 提升为 root layout**

删除顶层 root layout/page，把字体、ThemeProvider 和 `<html>` 移入 `app/[lang]/layout.tsx`；Next 15 的 `params` 声明为 `Promise<{lang:string}>` 并 await，`generateStaticParams` 只产出 zh/en，invalid locale `notFound()`。middleware 只匹配 `/`，Accept-Language 中 zh -> `/zh`，其他 -> `/en`。

- [ ] **Step 3: 服务端组合页面并统一状态**

`app/[lang]/page.tsx` 调用 `getReleaseCatalog()` 并把 locale/catalog 传给子组件；不加 `'use client'`。header 用 locale `<Link>`，不维护 language store。ThemeToggle 是独立 client island，只用 `next-themes` 的 `resolvedTheme`/`setTheme`，mounted 前渲染稳定占位并带 locale aria-label；图标取自 `lucide-react`。

运行 `npm uninstall framer-motion zustand`；确认生产源码只有 ThemeProvider、ThemeToggle 和后续 CopyDigest 带 client boundary。

- [ ] **Step 4: 验证并 commit**

```bash
npm test -- tests/i18n.test.ts tests/server-boundaries.test.ts
npm run lint
npm run build
git add app lib/i18n.ts middleware.ts package.json package-lock.json hooks
git commit -m "refactor(web): 服务端渲染本地化下载页"
```

---

### Task 4: 以真实截图完成首屏与产品叙事

**Files:**
- Create binary assets: `public/product/file-share.png`, `public/product/audio-share.png`, `public/product/keyboard-share.png`, `public/product/app-icon.png`
- Create: `app/components/hero.tsx`, `app/components/product-gallery.tsx`, `app/components/capabilities.tsx`, `app/components/platform-support.tsx`, `app/components/faq.tsx`
- Rewrite: `app/globals.css`, `tailwind.config.ts`
- Create: `tests/landing-content.test.tsx`

**Interfaces:**
- Each component consumes `{ locale: Locale; messages: Messages }` only; `Hero` additionally consumes `catalog: ReleaseCatalog` for optional ready state label。

- [ ] **Step 1: 导入真实视觉证据**

从主仓库复制，不做模糊、暗化或伪设备框：

```bash
mkdir -p public/product
cp ../.github/image/file-share.png public/product/file-share.png
cp ../.github/image/audio-share.png public/product/audio-share.png
cp ../.github/image/keyboard-share.png public/product/keyboard-share.png
cp public/android-chrome-512x512.png public/product/app-icon.png
```

- [ ] **Step 2: 写失败的 HTML 内容测试**

用 `react-dom/server` 渲染主要 Server Components，断言唯一 H1 文本为 Whisper、首屏有 app icon/file-share、gallery 有三张 locale alt、FAQ 用 `<details>`；断言输出无大型 inline SVG、评分/review、FTP 和安全徽章。

```bash
npm test -- tests/landing-content.test.tsx
```

Expected: FAIL，新组件尚不存在。

- [ ] **Step 3: 实现首屏与 section**

按 spec 做全宽截图媒体层和直接叠放文案，不做 split hero/card hero/渐变。首屏 CTA 锚定 `#downloads`，H1 为 Whisper，支持文案包含可信 LAN 与无 E2E 加密提示；底部在 320x568 及以上 viewport 露出下一 section。移动端截图焦点使用约 54% center，并由 320/390 viewport 截图验证主体未被裁掉。

gallery 的三张截图使用 `next/image`，提供查看完整图的 anchor。capabilities 删除 FTP，只保留有实现证据的传输、Android 通知、音频和键鼠；iOS/Linux 限制在平台 section 与 FAQ 清晰呈现。

- [ ] **Step 4: 建立克制设计 tokens**

CSS 采用 spec 的中性表面 + 蓝色 action + 绿色/琥珀 semantic 色；card radius 最大 8px；无负字距、无 `vw` 字号、无 scroll reveal、无装饰 gradient。定义统一 `content-shell`、44px control、focus ring、light/dark contrast 和 reduced-motion 规则。

- [ ] **Step 5: 验证并 commit**

```bash
npm test -- tests/landing-content.test.tsx
npm run lint
npm run build
git add public/product app/components app/globals.css tailwind.config.ts tests/landing-content.test.tsx
git commit -m "feat(web): 用真实产品画面重塑下载首屏"
```

---

### Task 5: 实现多资产下载卡与诚实验证信息

**Files:**
- Create: `app/components/downloads/download-section.tsx`
- Create: `app/components/downloads/platform-download-card.tsx`
- Create: `app/components/downloads/release-facts.tsx`
- Create: `app/components/downloads/copy-digest.tsx`
- Modify: `app/[lang]/page.tsx`, `lib/i18n.ts`, `app/globals.css`
- Create: `tests/download-section.test.tsx`

**Interfaces:**
- `DownloadSection({ catalog, locale, messages }: DownloadSectionProps)`
- `CopyDigest({ digest, copiedLabel, copyLabel }: CopyDigestProps)` is the only new client island。

- [ ] **Step 1: 写失败的下载 HTML 测试**

用真实 fixture 转出的 catalog 渲染下载区，断言：10 个 direct GitHub anchors；Linux 3、Android 4、iOS 1；无 iframe/disabled fake download/`download=`；preview 可见；date 为 `<time>`；commit SHA 为链接；每个 digest 完整出现。

另渲染 `unavailable`，断言只提供 GitHub Releases anchor，无版本和资产。覆盖 commit null、digest null、verified/unsigned/unverified/unknown 文案。

- [ ] **Step 2: 实现下载信息架构**

Release facts 顺序为 channel/version、date、commit verification、installer-signature unavailable 说明。每个平台一张重复 card；推荐项突出但不隐藏其他架构/格式。系统要求来自 Task 2，未知下限明确“未发布”。iOS 明示 unsigned/sideload/未正式测试。

- [ ] **Step 3: 实现可访问交互**

所有资产直接 `<a>`；移动主链接全宽 48px、其他链接 >=44px 并可换行。catalog 状态与 copy 结果使用 `role="status" aria-live="polite"`。CopyDigest 使用 Clipboard API，失败时保留可选择的完整 digest，不显示成功假象。

- [ ] **Step 4: 验证并 commit**

```bash
npm test -- tests/download-section.test.tsx tests/release
npm run lint
npm run build
git add app/components/downloads app/[lang]/page.tsx app/globals.css lib/i18n.ts tests/download-section.test.tsx
git commit -m "feat(web): 提供多架构直链和构建校验信息"
```

---

### Task 6: 补齐 metadata、图标、结构化数据与端到端验收

**Files:**
- Modify: `lib/constants.ts`, `app/[lang]/layout.tsx`, `app/[lang]/page.tsx`, `next.config.ts`, `README.md`
- Rewrite: `app/components/StructuredData.tsx`, `app/sitemap.ts`
- Create: `app/robots.ts`, `app/manifest.ts`, `app/[lang]/opengraph-image.tsx`, `app/[lang]/twitter-image.tsx`
- Create binary assets: `app/icon.png`, `app/apple-icon.png`, `public/icon-192.png`, `public/icon-512.png`
- Delete: `app/favicon.tsx`, `app/favicon.ico`, `public/robots.txt`, `public/manifest.json`, `vercel.json`, obsolete default SVG assets
- Create: `playwright.config.ts`, `tests/e2e/landing.spec.ts`
- Create: `tests/seo.test.ts`

**Interfaces:**
- `buildLocalizedMetadata(locale: Locale): Metadata`
- `StructuredData({ locale, catalog }: { locale: Locale; catalog: ReleaseCatalog })`

- [ ] **Step 1: 写 metadata/JSON-LD 失败测试**

断言 zh/en canonical、规范的 language alternates 和 x-default；OG/Twitter metadata 分别链接存在的生成路由且不引用缺失 jpg；JSON-LD ready 时含真实 version/date/release URL，fallback 时省略 version/date；两者都不含 rating/review、FTP 或安全声明。sitemap 只含 `/zh`、`/en`，无动态 `new Date()`；manifest icons 精确指向稳定公开的 `/icon-192.png`、`/icon-512.png`。

- [ ] **Step 2: 实现 SEO 与真实 icon**

从 `public/product/app-icon.png` 复制真实 icon：

```bash
cp public/product/app-icon.png app/icon.png
cp public/product/app-icon.png app/apple-icon.png
```

删除 synthetic `W` icon 与不存在路径。OG/Twitter image 同时呈现真实 icon、Whisper 名和 file-share screenshot；生成 192/512 public manifest icons。robots/sitemap/manifest 使用 MetadataRoute API；`next.config.ts` 保留安全 headers 单一来源，删除重复 Vercel robots config。

README 改为不带固定 app version 的产品/开发说明，并列出 `npm run check` 与 `npm run test:e2e`。

- [ ] **Step 3: 写 Playwright + axe 验收**

`playwright.config.ts` 用 production `npm run build && npm run start -- --hostname 127.0.0.1 --port 4173` webServer 与固定 `baseURL`；CI `reuseExistingServer:false`，本地只在明确非 CI 时复用。`landing.spec.ts` 覆盖 `/zh`、`/en`：正确 html lang、唯一 H1、真实三张图、直接 download anchors 或诚实 fallback、主题切换后无 hydration error、键盘 Tab 可见焦点、无横向滚动、axe 无 critical/serious violations。请求并断言 `/robots.txt`、`/sitemap.xml`、`/manifest.webmanifest`、`/{lang}/opengraph-image`、`/{lang}/twitter-image` 状态与 content-type。

Playwright projects：Chromium 320x568、390x844、768x1024、1440x900、1920x1080；用 bounding boxes 断言 hero 文案/CTA/截图与下一 section 不重叠且首屏露出下一 section，至少 390x844 与 1440x900 的 light/dark 使用 `toHaveScreenshot` 基线断言，不只是把图片写入 output。`.gitignore` 忽略 `playwright-report/`、`test-results/`，只提交审核后的 snapshot baselines。

- [ ] **Step 4: 全量验证**

```bash
npx playwright install chromium
npm run audit:prod
npm run lint
npm test
npm run build
npm run test:e2e
```

Expected: 全部 PASS；production audit 为 0；Playwright/axe 无 critical/serious；五个 viewport 无横向 overflow。

- [ ] **Step 5: Commit、检查范围并 push**

```bash
git add README.md app/[lang]/layout.tsx app/[lang]/page.tsx app/[lang]/opengraph-image.tsx app/[lang]/twitter-image.tsx app/components/StructuredData.tsx app/robots.ts app/sitemap.ts app/manifest.ts app/icon.png app/apple-icon.png lib/constants.ts next.config.ts public/icon-192.png public/icon-512.png public/robots.txt public/manifest.json vercel.json playwright.config.ts tests/seo.test.ts tests/e2e/landing.spec.ts .gitignore
git commit -m "fix(web): 补齐多语言 SEO 和无障碍验收"
git status --short
git log --oneline --decorate -8
git diff --cached --check
git fetch origin main
# 必须保持 origin/main 为既有祖先；若远端前进则只做明确可审核的 fast-forward/普通合并，不改写 c9a0f37
git push origin main
```

Push 前用 `git merge-base --is-ancestor c9a0f37 HEAD`、`git rev-list --count origin/main..HEAD` 和逐文件 staged diff 确认保留既有用户 commit，其上追加本轮 6 个原子 commit；未提交 `.next/`、Playwright output、token 或本地环境文件。用户已明确授权本轮 push；发布/部署仍不执行。

## Plan Self-Review

- 覆盖：Next 漏洞、渠道/版本漂移、多平台多资产、真实 fixture、Server ISR/fallback、直接链接、locale/SEO/OG/icon/JSON-LD/sitemap/robots、移动 CTA/44px/focus/aria-live/contrast、theme 单一状态、真实截图、安全文案、FTP 删除、Client Component 拆分、SHA/date/signature/system requirements。
- 6 个任务分别形成可拒绝/可回滚的原子 commit；Task 2/3/4/5 均先写 focused failure，再实现。
- 所有跨任务接口名与 spec 一致；无 TBD/TODO 或依赖未定义的类型。
