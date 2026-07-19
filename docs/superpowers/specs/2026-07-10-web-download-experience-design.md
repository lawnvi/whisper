# Whisper Web 下载体验整改设计

> 范围仅为独立仓库 `whisper-web/`。目标是把当前介绍页改成可信、可验证、以真实产品为主角的下载页；不虚构评分、评价、安装量或安全背书。

## 背景与问题

截至 2026-07-10，审计确认：

- `next@15.1.0` 的生产依赖审计为 1 个 critical 加 1 个 moderate；升级到 `15.5.20` 后还需用 scoped npm override 将 Next 内嵌 `postcss` 锁到 `8.5.10`，并以 lockfile + production audit 证明为 0。
- `app/page.tsx` 是 1013 行 Client Component，静态文案、SVG 示意、设备检测、主题、语言和 GitHub 请求全部进入客户端。
- 页面请求 `/releases/latest`，但仓库实际只有 `dev-v*`；当前 `dev-v0.0.42` 又被 GitHub 标成非 prerelease。渠道不能依赖 GitHub 的 `prerelease` 或 `latest` 标志。
- Web 包与 README 仍写 `0.0.29`，Flutter `pubspec.yaml` 和最新 Release 已是 `0.0.42`，形成版本漂移。
- 资产匹配会让同平台后出现的文件覆盖前一个：Linux 只认 `.deb`，Android 只保留 universal，iOS 还错误匹配 `.ipa.bak`。当前 Release 实际有 10 个资产：Windows EXE、macOS DMG、Linux DEB/RPM/AppImage、Android universal/3 个 ABI APK、unsigned iOS IPA。
- Release 在浏览器 `useEffect` 中请求；失败时静默显示 `0.0.0`。下载由隐藏 iframe 触发，不是可检查、可复制、可在新上下文打开的真实链接。
- 根布局不能可靠获得子路由 `[lang]`；现有 OG 路径、多个 favicon 路径并不存在，sitemap 每次构建伪造新的修改时间，robots/headers 有重复配置。
- 页面同时使用 `next-themes` 与自建 Zustand theme store，语言也通过客户端 store 和整页跳转维护。
- 首屏使用抽象拓扑 SVG，而仓库已经有三张真实产品截图；图标与 Whisper 名称也不够突出。
- “所有类型、没有大小限制”“通常跑满带宽”“Never miss”等绝对文案无法由实现或测试保证。当前也没有端到端加密，不能暗示在不可信 LAN 上安全。
- 匿名 FTP 将在网络加固中彻底删除，下载页不得继续展示 FTP feature、alpha 标签或 FAQ。

## 目标

1. 页面在 GitHub API 正常、限流或不可达时都能服务，并且不展示伪版本或伪下载。
2. 渠道、版本、资产、校验和、日期与提交验证状态都有单一事实来源和确定规则。
3. 用户能直接选择平台与架构，所有下载都是语义化 `<a href>`。
4. 首屏明确出现真实 app 图标、H1 `Whisper`、真实截图和诚实的 LAN/加密说明。
5. 静态内容默认由 Server Components 输出，只保留主题切换与复制校验和两个小 Client Island。
6. 中英文、SEO、键盘操作、移动触控和明暗主题达到可发布质量。

## 非目标

- 不为 Web 页增加账号、遥测、评论、评分、二维码或安装量。
- 不在页面承担自动更新、安装包签名验证或 Release 发布工作流。
- 不宣称端到端加密、互联网中继、Wayland 键鼠支持或 iOS 已正式支持。
- 不引入 CMS、完整 i18n 框架或客户端平台侦测。

## 1. Release 事实模型

### 渠道选择

标签是渠道真相，GitHub `prerelease` 仅保留为原始信息：

- `release-v<semver>` -> `stable`
- `dev-v<semver>` -> `preview`
- 其他标签忽略

请求 `GET /repos/lawnvi/whisper/releases?per_page=100&page=N`，遵循 GitHub `Link` header 分页，直到找到 stable 或达到明确页数上限；忽略 draft。每个渠道按 `published_at` 取最大值（再以 semver、tag 作确定性 tie-break），优先选最新 `stable`；尚无 stable 时选最新 `preview`，并在所有主要下载入口明确显示“开发预览 / Preview”。不能把 `dev-v*` 显示为稳定版，即使 GitHub 返回 `prerelease: false`。

可见版本只由选中标签解析。`whisper-web/package.json` 是私有 Web 包，统一为非产品语义的 `0.0.0`；README 不再钉 app 版本。页面、metadata 和 structured data 不再有第二份版本常量。

### 领域接口

```ts
type ReleaseChannel = 'stable' | 'preview';
type Platform = 'windows' | 'macos' | 'linux' | 'android' | 'ios';
type Verification = 'verified' | 'unsigned' | 'unverified' | 'unknown';

type DownloadAsset = {
  id: number;
  name: string;
  url: string;
  bytes: number;
  platform: Platform;
  format: 'exe' | 'dmg' | 'deb' | 'rpm' | 'appimage' | 'apk' | 'ipa';
  arch: 'universal' | 'x86_64' | 'amd64' | 'arm64-v8a' | 'armeabi-v7a';
  digest: string | null; // 仅接受 GitHub 的 sha256:<64 hex>
  recommended: boolean;
};

type ReleaseCatalog =
  | {
      status: 'ready';
      channel: ReleaseChannel;
      tag: string;
      version: string;
      releaseUrl: string;
      publishedAt: string;
      commit: { sha: string; url: string; verification: Verification } | null;
      assets: DownloadAsset[];
    }
  | { status: 'unavailable'; releasesUrl: string };
```

`unavailable` 不携带要渲染的原始异常，避免泄露 token、上游响应或部署信息。

### 多资产解析

解析器返回全部识别资产，绝不以 platform key 覆盖：

| 平台 | 识别与顺序 | 推荐项 |
|---|---|---|
| Windows | x86_64 `.exe` | x86_64 installer |
| macOS | universal、arm64、x86_64 `.dmg`，兼容旧 `whisper.dmg` | universal，其次与现有资产相符的 x86_64 |
| Linux | `.AppImage`、`.deb`、`.rpm` | AppImage；其余按格式并列 |
| Android | universal、arm64-v8a、armeabi-v7a、x86_64 `.apk`；兼容旧 `app-release.apk` 等命名 | universal |
| iOS | `*-ios-unsigned.ipa` 与旧 `.ipa` | 无“推荐”；始终标 unsigned/sideload/实验 |

`.ipa.bak`、checksum 文本、source archive 和未知文件必须忽略。排序由平台、推荐级、格式、架构和文件名共同决定，API 数组顺序不能影响结果。

fixture 使用 2026-07-08 的真实 `dev-v0.0.42` GitHub 响应及其 commit 响应，覆盖上述 10 个资产和 SHA-256 digest；另用小型 fixture 覆盖 stable 优先、旧命名、空资产和坏数据。

### Server Component 与降级

`lib/release/github-core.ts` 是不导入 Next/server-only 的纯解析与可注入 fetch adapter；`lib/release/github.ts` 导入 `server-only` 并只在服务端执行。请求分别获取分页 release 列表与选中 `tag_name` 对应 commit（不能用通常为 `main` 的 `target_commitish`），使用：

- `next: { revalidate: 3600, tags: ['whisper-release'] }`
- 5 秒超时、`Accept: application/vnd.github+json` 与 GitHub API version header
- 可选 server-only `GITHUB_TOKEN`，绝不使用 `NEXT_PUBLIC_*`
- 显式 `response.ok` 和结构校验

用 `unstable_cache` 包裹“已验证的 ready catalog”且内部 fetch `cache: 'no-store'`：畸形/失败在缓存函数内部抛错，让 Next 保留旧成功值；外层只在首次构建/冷请求没有成功缓存时映射为 `unavailable`。页面仍显示真实产品内容和“暂时无法读取最新构建，前往 GitHub Releases”，不显示 `0.0.0`、旧硬编码版本或失效按钮。

## 2. 下载与可验证信息

每个资产以真实 `<a href={browser_download_url}>` 输出；不使用 iframe、`window.location`、模拟 toast 或跨域 `download` 属性。链接文本必须包含平台、格式/架构与文件大小。

Release 摘要显示：

- 渠道与从 tag 得出的版本
- `<time datetime>` 发布日期
- commit 短 SHA 和 GitHub commit 链接；请求失败则“提交信息不可用”
- `verified`、`unsigned`、`unverified`、`unknown` 四种提交验证状态，不能把 unknown 当 unsigned
- 每个资产的完整 SHA-256，可复制；digest 不存在时显示“该构建未发布校验和”
- “提交签名”和“安装包签名”是不同概念；GitHub API 没有安装包签名证明时显示“安装包签名状态未随 Release 发布”

系统要求只陈述仓库能证明的内容：macOS 10.15+；iOS 13+、unsigned sideload 且尚未完成正式测试；Linux x86_64、发现依赖 Avahi、音频依赖 PulseAudio/PipeWire Pulse、键鼠限 X11；Windows x86_64 但最低系统版本未发布；Android 列出对应 ABI，最低系统版本未发布。无法证明的版本下限必须明确为“未发布”，不能猜测。

## 3. 信息架构与组件边界

`app/[lang]/layout.tsx` 成为 locale root layout 并输出正确 `<html lang="zh-CN|en">`；Next 15 的 `params` 按 `Promise` 接收并 await。根路径继续由 middleware 根据 `Accept-Language` 重定向到 `/zh` 或 `/en`。`app/[lang]/page.tsx` 只做参数校验、服务端取数和页面组合。

建议边界：

- `lib/i18n.ts`：typed locale 与全部可见文案
- `lib/release/*`：GitHub 类型守卫、渠道选择、资产解析、系统要求和 ISR adapter
- `app/components/site-header.tsx`：品牌、locale links、ThemeToggle island
- `app/components/hero.tsx`：真实截图首屏与下载锚点
- `app/components/product-gallery.tsx`：三张真实产品截图与能力证据
- `app/components/downloads/*`：release 摘要、平台卡、直接链接、CopyDigest island
- `app/components/capabilities.tsx`、`platform-support.tsx`、`faq.tsx`、`site-footer.tsx`：静态 Server Components
- `app/components/structured-data.tsx`：locale/release 驱动的 JSON-LD

移除 `framer-motion`、`zustand`、`hooks/useLanguage.ts` 和自建 `hooks/useTheme.ts`。主题唯一来源为 `next-themes` 的 `resolvedTheme`；语言唯一来源为 URL。FAQ 使用原生 `<details>`，不为展开状态增加 JS。

## 4. 视觉设计

定位为“真实产品 + 克制技术感”，而不是营销模板或蓝图示意图。

### 首屏

- H1 必须是 `Whisper`，旁边/上方显示真实 app 图标；价值描述放在 supporting copy。
- `.github/image/file-share.png` 作为完整、可辨认的首屏产品画面，采用全宽、无卡片的媒体层；文案直接叠在截图留白区，不做左右分栏 hero、不用渐变或模糊图。
- 桌面显示桌面与手机同时传输的证据；移动端以约 54% 的水平 `object-position` 聚焦产品主体，不能简单靠右裁掉关键界面，并保留截图链接供查看完整原图。
- 首屏 CTA 是“选择下载版本 / Choose a build”，锚定下载区；页面能确定推荐资产时可另给直接链接，但不得靠 UA 猜测。
- 320x568、390x844、768x1024、1440x900 和 1920x1080 均应在首屏底部露出下一段内容。

### 后续内容

下载区紧随首屏。三张真实截图分别证明聊天式文件传输、音频多设备配置、键鼠屏幕排列，不再用大型自绘 SVG 代替产品。

页面 section 使用全宽 band 或无框内容；只有重复下载项使用 card，圆角不超过 8px，禁止 card 内再套 card。配色以中性纸面/碳黑为主，蓝色只承担主操作，绿色与琥珀仅承担已验证/预览等语义状态，避免整页单一蓝灰。继续使用 Geist/Space Grotesk，但所有 letter-spacing 为 `0`，不使用 viewport 字号或负字距。

动效只保留 150-250ms 的颜色/阴影反馈；无 scroll reveal。所有 hover 不改变几何尺寸，并尊重 `prefers-reduced-motion`。

需要图标的主题、下载、外链和复制按钮统一使用 `lucide-react`，不继续维护手绘 inline SVG；纯文字链接不为装饰而强加图标。

## 5. 文案与安全边界

核心安全文案固定表达为：Whisper 面向同一可信局域网内的设备直连，不提供公共中继；当前没有端到端加密，不应在不可信网络上传输敏感内容。

删除或改写：

- 删除 FTP feature、alpha 标签与所有 FTP FAQ/structured data 痕迹。
- “所有文件类型、没有大小限制”改为“可发送常见文件与文本；实际大小受设备存储和网络稳定性影响”。
- “通常跑满带宽/very fast”改为“速度取决于 Wi-Fi/以太网、设备和网络拥塞”。
- “Never miss”改为“可将 Android 通知转发到已连接设备”。
- “五个平台”改成逐平台成熟度：iOS 是 unsigned、sideload、未完成正式测试。

禁止添加评分、用户评价、下载量、客户 logo、加密盾牌或“安全/secure”徽章。

## 6. SEO、图标与结构化数据

- locale metadata 为 `/zh` 与 `/en` 输出各自 title/description/canonical/hreflang；`x-default` 指向会语言重定向的 `/`。
- OG 与 Twitter 分别由 `app/[lang]/opengraph-image.tsx`、`twitter-image.tsx` 生成，必须包含真实 app 图标与真实产品截图；metadata/head 同时链接二者，不再引用缺失的 `/og-image.jpg`。
- 用真实 app icon 生成 `app/icon.png`、`app/apple-icon.png`；manifest 使用稳定的 `public/icon-192.png`、`public/icon-512.png` URL，删除 synthetic `W` favicon 与不存在的声明。
- `app/manifest.ts` 使用中性产品名；`app/robots.ts` 取代 `public/robots.txt`；sitemap 只列 `/zh`、`/en`，带语言 alternates，不给 redirect 根路径和每次构建伪造 `lastModified`。
- JSON-LD 使用 `SoftwareApplication`，包含可证实的平台、免费价格、release URL，以及 ready 时的 version/date；没有 release 时省略这些字段。绝不输出 `aggregateRating` 或 `review`。
- `next.config.ts` 作为安全 header 单一来源，删除与 `vercel.json` 的重复 robots header。

## 7. 可访问性与响应式验收

- 所有链接、button、select/segmented links 的触控尺寸至少 44x44 CSS px。
- 所有交互元素有 `:focus-visible` 2px 高对比 ring，不用 `outline-none` 掩盖焦点。
- 正文与控件文字达到 WCAG AA 4.5:1，大字 3:1；两套主题都测。
- 图片有描述实际状态的 locale alt；纯装饰元素空 alt。heading 顺序唯一且连续。
- release 可用性和复制 digest 的反馈使用 `role="status" aria-live="polite"`，不依赖颜色表达 verified/preview/unsigned。
- 移动下载卡单列，主资产链接全宽至少 48px，次级资产不横向溢出；桌面最多两列并保持稳定尺寸。
- `prefers-reduced-motion` 下没有非必要动画。

## 8. 验证标准

- fixture 单测精确得到 10 个 `dev-v0.0.42` 资产，Linux/Android 多资产不丢失，iOS `.ipa` 可用且 `.ipa.bak` 被拒绝。
- stable/preview 选择不受 GitHub `prerelease` 错标影响；上游错误返回诚实 fallback。
- 页面 HTML 中有直接 GitHub asset anchors，无 iframe、`0.0.0`、FTP 或绝对宣传文案。
- `npm audit --omit=dev --audit-level=moderate`、`npm run lint`、`npm test`、`npm run build` 全部通过。
- Playwright 以 production `next start` webServer 和固定 loopback baseURL 运行，CI 不复用旧 server。zh/en、light/dark、上述五个 viewport 无 critical/serious accessibility issue、无溢出/重叠；关键元素用 bounding box 断言不相交，390/1440 的 light/dark 用 `toHaveScreenshot` 做稳定视觉回归；OG、Twitter、robots、sitemap、manifest 均返回正确类型。

## 风险与降级

- GitHub 匿名 API 限流：ISR、可选 server token 和 Releases 链接 fallback 降低影响；token 不进入客户端。
- GitHub digest/commit verification 字段可能缺失：显示 unknown/未发布，不推断。
- 截图包含真实设备名、局域网 IP 与当时版本 UI；这是产品证据，但发布前仍需人工确认没有敏感信息。现有截图中的均为演示性局域网数据。
- 首屏截图在极窄设备会裁切：提供完整图链接和 gallery 中的 `object-fit: contain` 版本，保证产品仍可检查。
