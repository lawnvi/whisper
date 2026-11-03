# Whisper 界面重做：从这里开始

这份目录是一次完整的界面重新设计。**如果你是接手实现的人或 AI，只看这里的文档就应该能做出来**，不需要之前的聊天记录。发现哪里要靠猜，先补文档，不要猜着做。

## 现在是什么状态

| 项 | 状态 |
|---|---|
| 设计方向、整体布局、三个桌面平台 | 用户已定稿（2026-11-02）。没答复的细节按 `decisions.md`「待定」的默认值做 |
| 文档、原型 | 完成 |
| Flutter 代码 | **一行没改**，要从 [`migration.md`](migration.md) 第 0 步开始 |
| 真实设备上的效果 | 只有 Windows 的云母在真实窗口里跑过（`windows-real-mica-light.jpg`）。其他只在无头 Chrome 里看过原型 |

## 读的顺序

1. **打开原型** [`whisper-ui-language.html`](whisper-ui-language.html)，双击就行，不用联网。先点完上面那排试用按钮。**文字说不清的手感都在这里。** 不能开浏览器就看 [`reference/`](reference/) 的截图。
2. [`../../DESIGN.md`](../../DESIGN.md)：语言、token、全局规则。每次碰界面都要遵守。
3. [`surfaces.md`](surfaces.md)：每个界面的结构、尺寸、状态、文案、现有代码入口。
4. [`flutter.md`](flutter.md)：可以直接用的 Flutter 代码。已经编译并测试过。
5. [`migration.md`](migration.md)：按什么顺序改、每步怎么算做完、数据从哪来。
6. [`decisions.md`](decisions.md)：为什么这么定，**用户否决过什么**，还有什么待定。想改规则之前先看。

**发生冲突时**：用户最新的明确要求 > `DESIGN.md` > `surfaces.md` > 原型 > 其他文档。`docs/superpowers/` 里的 spec 和 plan 是历史记录，协议和架构仍然有效，界面部分以这里为准。

## 用户在意什么

这些来自多轮反馈，比任何单条规则都重要。

- **「像苹果设计一款用心的产品那样」**。不是加几个圆角。要有材质、层次和连续的动效。
- **质感比规范重要**。曾经有一版 token、对比度、测试全部通过，用户说「感觉不高级了」。**每改完一个界面都要截图，和 `reference/` 放在一起比，不能掉档次。**
- **具体反馈不要放大**。用户说文件列表线太多，就改文件列表。上一次全局去线，界面就散了。
- **手机不是缩小的桌面**。不要把桌面结构挤进窄屏。平板和折叠屏不看设备类型，只看窗口，见 `DESIGN.md`「平板和折叠屏」。
- **状态变化不能把别的东西顶起来**，行不跳动，长名字不挤乱布局。
- **不比现有功能少**。原型漏过设置入口和删除链接，用户立刻发现了。`surfaces.md` 的现有功能清单是底线。
- **真实**。设置项以 `lib/page/settings.dart` 为准，不编造。协议做不到的事不画入口。

## 用原型的方法

「平板和折叠屏」一排切换 iPad、iPhone 折叠屏、阔折叠、三折叠和它们的状态，可以在对话里写点字，然后折叠、展开、半开，看东西留没留住。外框和折痕只是示意。最上面一排切换平台：macOS、Windows、GNOME、KDE，切到 Linux 还能把窗口按钮放到左边。下面的按钮能直接到达各个状态：把声音放到两台、排列键鼠、把指针推过去、把文件拖到托盘（也能接真实文件）、打开窗口、送出窗口、请求、接收声音、被控制、下线、局域网断开、手机、深色。

也可以直接打开 `whisper-ui-language.html?os=win`（`gnome`、`kde`），Linux 还能加 `&layout=appmenu:close` 试不同的按钮布局。Windows 的字体用仓库里的 `assets/fonts/NotoSansSC-Compact.ttf`，所以 HTML 要留在原来的位置。

**这个 HTML 是原型的唯一来源**，要改就直接改它，并跑下面的检查。

## 检查工具

都在 [`tools/`](tools/)，需要 Node 18+，`check-prototype` 和 `check-targets` 还需要 Chrome（默认找常见安装路径，也可以设环境变量 `CHROME`）。

| 命令 | 查什么 |
|---|---|
| `node docs/design/tools/check-prototype.mjs [输出目录]` | 用无头 Chrome 走完所有流程和平台，约 370 项断言，输出截图 |
| `node docs/design/tools/check-targets.mjs` | 走遍所有状态，报告命中区太小、按钮没有读屏名称、文字被切 |
| `node docs/design/tools/check-docs.mjs` | `DESIGN.md` 的 token 和原型一致，文档里的路径和代码符号都存在，没有旧词 |
| `node docs/design/tools/update-reference.mjs <目录>` | 把 `check-prototype` 用 `SHOT_FORMAT=jpeg` 输出的截图按内容命名，更新 `reference/`。改了颜色或布局后要跑 |
| `node docs/design/tools/check-contrast.mjs` | 所有用到的颜色组合的对比度，包括玻璃透出最饱和的壁纸时 |

`check-targets` 目前会报这些已知的：灵动岛收起时、手机的语言和位置按钮靠透明命中区补足到 48；手机输入框和发送键在 48 高的输入胶囊里。`check-contrast` 会报 3 条已知的：`ink2` 在 `bubble` 上 4.2:1，所以文件卡的次要字用 `ink2-glass`；强调色上的白字浅色 4.0:1、深色 3.7:1，是用户选这个蓝的代价，见 `DESIGN.md`「色彩」。蓝色字按图形的标准查（约 3:1 起），原因相同。

## 截图

[`reference/`](reference/) 是原型的静态参照，文件名就是内容。`desktop-*` 是 macOS，窗口宽 1144，`windows-*`、`gnome-*`、`kde-*` 同样大小，`windows-real-*` 是**真实窗口的截图**，不是原型。`regular-*` 约 800，`phone-*` 宽 380，`dark-*` 深色。灵动岛和进度的数字是示例，其他都应该对得上。背景的彩色渐变是示意的桌面，不属于产品。

## 做完的标准

一个界面算做完，要同时满足：

- [ ] 和 `reference/` 的截图放在一起看，质感不掉档
- [ ] 尺寸、状态、文案符合 `surfaces.md`，现有功能清单一项不少
- [ ] 按压、切换、展开都有过渡，可以打断，开启减少动态效果时退化成淡入淡出
- [ ] 深色、紧凑和宽屏、长设备名、200% 文字都看过
- [ ] 文案走 ARB，中、英、西都有
- [ ] 能用键盘操作，读屏名称完整
- [ ] 有 golden 和行为测试，`flutter analyze` 和 `flutter test` 通过
- [ ] 真实设备上跑过；跑不了的，写明平台、没跑的命令和剩余风险（`CLAUDE.md` 的要求）
