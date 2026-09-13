# 宣传图生图提示词（2026-09）

依据 `web/assets/shots/`（2026-09-12 重拍）的截图，给专门的生图工具（GPT Image、Gemini、Midjourney 等）用。产出两类：App Store 推广截图、官网横幅。

## 一、推荐做法：两步走

生图工具会**重采样**截图里的界面文字，小字、图标、按钮经常被改坏；中文标题也容易出错。App Store 要求截图反映真实界面，所以推荐：

1. **生图工具只负责「壳 + 场景」**：让它生成带设备外壳的海报底图，屏幕区域填纯绿色 `#00FF00`，不写任何文字（或只留出文字位置）。
2. **在 Figma / Photoshop 里合成**：把原始截图贴进屏幕区域（按屏幕圆角裁切），再用真字体排标题。这样界面像素级真实，文案可随时改。

如果只想一步出图，用第四节的「一步出图」提示词，把截图作为参考图上传；出图后必须逐字核对界面与标题。

## 二、统一规格

| 用途 | 画布尺寸 | 设备 | 备注 |
| --- | --- | --- | --- |
| App Store iPhone 6.5" | 1242 × 2688（竖） | iPhone 17 Pro | 与往期提交一致；RGB，无透明通道 |
| App Store iPhone 6.9"（可选） | 1320 × 2868（竖） | iPhone 17 Pro | 新机型主尺寸 |
| App Store iPad 13" | 2064 × 2752（竖） | iPad Pro 13" | 截图本身是竖屏 3:4 |
| 官网总览横幅 | 2400 × 1400 | iPad + iPhone | 替换 `web/assets/promo-overview-*.png` |
| 官网分享图 OG | 1200 × 630 | iPhone | 替换 `web/assets/og.png` |

大多数工具不支持任意像素，按比例出图（iPhone ≈ 9:19.5，iPad 3:4，横幅 12:7）后再放大/裁切到上表尺寸。

**品牌色**（从截图取样）：主色深梅紫 `#4A134A`；浅底 `#FAFAF8`；深底 `#1F1F1F`；点缀绿 `#3E8E5E`（会话列表里的完成圆点）。

## 三、风格基底（每条提示词前都贴上）

```text
Premium Apple-style App Store marketing poster, clean editorial layout.
Background: soft warm off-white (#FAFAF8) with a very subtle large radial
glow in deep plum (#4A134A) at 8–12% opacity, plus one or two soft blurred
translucent plum circles far behind the device. No busy patterns, no
gradients mesh, no stock-photo scenery, no people, no hands.
Device: photorealistic Apple device with a thin, uniform black bezel,
Dynamic Island on iPhone, accurate rounded screen corners, soft studio
lighting, gentle realistic contact shadow below. Slight tilt only
(1–3 degrees), no dramatic perspective, screen fully visible and facing
the viewer.
Screen: fill the entire display area with flat pure chroma green #00FF00,
edge to edge inside the bezel, no reflections or glare on the screen.
Leave the top 28% of the canvas empty for a headline. Do not render any
text, letters, logos, Apple logo, watermarks, badges, UI, icons or app
store buttons anywhere.
```

一步出图时，把最后两段（Screen 与 Do not render）换成第四节的写法。

## 四、一步出图的替换段

上传对应截图作为参考图，把风格基底里 Screen 段和最后一段换成：

```text
Screen: place the supplied app screenshot on the display exactly as-is,
scaled to fit edge to edge, clipped to the rounded screen corners. Treat
the screenshot as a fixed bitmap: do not redraw, re-typeset, translate,
simplify or invent any UI, labels, icons or numbers.
Headline text (render exactly once, correct Chinese characters, bold
modern sans-serif like PingFang SC Semibold, dark ink #1C1C1E, centered
in the top area):
Line 1: 「{主标题第一行}」
Line 2: 「{主标题第二行}」
Subtitle below in smaller regular weight, #6B6B70: 「{副标题}」
No other text, logos, Apple logo, watermarks or badges anywhere.
```

## 五、App Store iPhone 组（6 张，按上架顺序）

App Store 标题里不要出现 Codex、Claude、OpenAI、Tailscale 等第三方名称（1.2.1 提交时就是因此改稿）；截图界面里原有的名称可以保留。前三张最重要，用户在搜索结果里只看得到它们。

### 1. 会话接力（首图）

- 截图：`iphone-conversation-zh-light.webp`（英文版换 `-en-`）
- 标题：离开电脑， / 会话不断 ｜ Leave your desk. / Not your session.
- 副标题：电脑继续工作，你在手机上跟进与回复 ｜ Your computer keeps working. You follow along.
- 追加提示词：

```text
Single iPhone 17 Pro in Silver, centered, rotated 1.5 degrees clockwise,
occupying about 62% of canvas height, bottom of the phone slightly cropped
by the canvas edge. Behind it, a very soft out-of-focus silhouette of a
laptop far in the background at 10% opacity to suggest "away from the desk".
```

### 2. 就地审批

- 截图：`iphone-approval-zh-light.webp`
- 标题：审批就在手边， / 一步放行 ｜ Approve in place. / Keep it moving.
- 副标题：仅一次、本会话或始终允许 ｜ Once, for the session, or always.
- 追加提示词：

```text
Single iPhone 17 Pro in Silver, rotated 2 degrees counter-clockwise,
shifted slightly right. The lower half of the screen (the approval card)
is the focal point: add a soft plum (#4A134A) glow behind the lower half
of the phone and a subtle floating magnified callout that enlarges the
lower-middle part of the screen by 1.3x, offset to the left, with a thin
white border and soft shadow. The callout shows the same screen region,
not new content.
```

一步出图时放大框容易画出假按钮，建议这张走两步走，在 Figma 里用截图本身裁一块做放大框。

### 3. 通知

- 截图：`iphone-sessions-zh-light.webp`
- 标题：需要你的时候， / 第一时间知道 ｜ When it needs you, / you'll know.
- 副标题：审批、回复与失败，直达锁屏 ｜ Approvals, replies and failures on your lock screen.
- 追加提示词：

```text
Single iPhone 17 Pro in Silver, centered, rotated 1 degree clockwise, the
screen dimmed slightly. Three frosted-glass iOS notification banners float
in front of the phone, stacked with slight offsets and depth, overlapping
the phone edges by about 10%, each with rounded corners 24px, white 70%
translucent material, soft shadow. Leave the banners blank (no text, no
icons) so real copy can be added later.
```

横幅文字在 Figma 里照官网锁屏区的文案补（来源 `web/site.js` 的 `lock.*`）：
「整理开源发布说明 · 现在 — Codex 在 Demo Mac Studio 上等待审批 · 运行命令」
「检查连接恢复测试 · 2 分钟前 — 已回复，点按查看。」
「完善示例项目文档 · 18 分钟前 — 任务未能完成，点按查看原因。」
第一条横幅文案含「Codex」，在 App Store 版里改成「Agent 在 Demo Mac Studio 上等待审批」。

### 4. 多台电脑

- 截图：`iphone-mac-connection-zh-light.webp`（⚠ 设备页 09-13 已改版，这张先重拍再做）
- 标题：一部手机， / 管好每台电脑 ｜ One phone. / All your computers.
- 副标题：Mac、Windows、Linux，扫码配对，任何网络都能连 ｜ Mac, Windows & Linux. Scan once, connect from anywhere.
- 追加提示词：

```text
Single iPhone 17 Pro in Silver, centered, rotated 2.5 degrees
counter-clockwise. Behind the phone, three softly blurred, stylized
computer silhouettes arranged in a gentle arc: a desktop display, a
laptop, and a tower PC, each at 15% opacity in cool gray, connected to the
phone by thin dotted plum (#4A134A) lines. No brand logos on any computer.
```

### 5. 工作区

- 截图：`iphone-workspaces-zh-light.webp`
- 标题：每个项目， / 进度一眼看清 ｜ Every project, / at a glance.
- 副标题：正在运行与最近会话，按项目分好 ｜ Running and recent sessions, grouped by project.
- 追加提示词：

```text
Single iPhone 17 Pro in Silver, rotated 3 degrees clockwise, slightly
closer to the viewer (phone occupies about 68% of canvas height), shifted
slightly left. A few small soft rounded-square tiles in muted plum and
warm gray float at the right edge, blurred, as abstract "project" shapes.
```

### 6. 深浅色

- 截图：`iphone-sessions-zh-light.webp` + `iphone-sessions-zh-dark.webp`
- 标题：浅色深色， / 同样用心 ｜ Light and dark, / equally crafted.
- 副标题：为 iPhone 与 iPad 分别打磨 ｜ Designed separately for iPhone and iPad.
- 追加提示词（替换基底里的「single device」描述）：

```text
Two iPhone 17 Pro devices side by side, overlapping by about 18%: the left
one in Silver slightly in front, the right one in Deep Blue slightly
behind and 4% smaller. Left screen green #00FF00, right screen magenta
#FF00FF (two different chroma colors so each screenshot can be placed
separately). Background split subtly: left half warm off-white #FAFAF8,
right half graphite #1F1F1F, with a soft diagonal blend in the middle.
```

一步出图时，上传两张截图并写明「left device shows the light screenshot, right device shows the dark screenshot」。

## 六、App Store iPad 组（3 张）

基底里把设备描述换成：

```text
Device: photorealistic iPad Pro 13-inch in Space Black, portrait
orientation, thin uniform black bezel, accurate rounded screen corners,
occupying about 70% of canvas height, soft studio shadow.
```

| 序号 | 截图 | 标题 | 副标题 | 追加 |
| --- | --- | --- | --- | --- |
| 1 | `ipad-approval-zh-light.webp` | 同样的会话， / 在 iPad 上展开成工作台 ｜ The same sessions, / opened into a workbench. | 侧栏、正文与审批同屏 ｜ Sidebar, thread and approvals side by side. | `Rotated 1 degree clockwise, centered.` |
| 2 | `ipad-workspaces-zh-light.webp` | 每个项目， / 进度一眼看清 ｜ Every project, / at a glance. | 正在运行、刚完成、最近会话一目了然 ｜ Running, just finished and recent, all in one view. | `Rotated 1.5 degrees counter-clockwise, shifted slightly right.` |
| 3 | `ipad-approval-zh-dark.webp` | 深色模式， / 一样精致 ｜ Dark mode, / just as refined. | 为 iPad 单独打磨的多栏布局 ｜ A multi-column layout built for iPad. | 背景换深色：`Background graphite #1F1F1F with a subtle plum (#4A134A) glow at 15% opacity; headline text color #F2F2F2.` |

## 七、官网组（2 张）

官网可以直接写 Codex 与 Claude Code，页脚已有「与 OpenAI、Anthropic、Tailscale 均无关联」的声明。

### W1. 总览横幅（2400 × 1400）

- 截图：`ipad-approval-zh-light.webp`（iPad）+ `iphone-conversation-zh-light.webp`（iPhone）
- 标题：离开电脑，会话不断 ｜ Leave your desk. Not your session.
- 副标题：Codex 与 Claude Code 的原生 iPhone、iPad 客户端 ｜ The native iPhone & iPad app for Codex and Claude Code.

```text
Wide landscape hero banner, 12:7 aspect ratio, premium Apple-style product
composition. Right 60% of the canvas: an iPad Pro 13-inch in Space Black,
portrait orientation, rotated 2 degrees counter-clockwise; an iPhone 17
Pro in Silver stands in front of the iPad's lower-left corner, overlapping
it by about 20%, rotated 3 degrees clockwise, casting a soft shadow onto
the iPad. iPad screen chroma green #00FF00, iPhone screen chroma magenta
#FF00FF. Left 40%: empty space for headline. Background warm off-white
#FAFAF8 with a large soft plum (#4A134A) radial glow at 10% opacity behind
the devices. Soft studio lighting, realistic contact shadows. No text,
logos, Apple logo, watermarks or UI anywhere.
```

另出一版深色：背景换 `#1F1F1F`，截图换 `-dark`，官网切到深色时用。

### W2. 分享图 OG（1200 × 630）

- 截图：`iphone-conversation-zh-light.webp`
- 左侧文字：Mimi Remote（加 App 图标 `web/assets/app-icon.png`）/ 离开电脑，会话不断

```text
Landscape social share card, 1200x630 proportions. An iPhone 17 Pro in
Silver on the right third, rotated 6 degrees clockwise, its bottom 25%
cropped by the canvas edge, screen chroma green #00FF00. Left two thirds
empty for an app icon and headline. Background deep plum #4A134A with a
soft lighter plum radial highlight behind the phone and a faint grain
texture. No text, logos, Apple logo or watermarks.
```

## 八、通用负面提示词

不支持负面提示词的工具，把这段并进正文的「Do not」里：

```text
no extra devices, no duplicated phones, no cracked or curved screens,
no reflections on the screen, no Apple logo, no brand logos, no fake app
UI, no garbled text, no English placeholder text, no watermarks,
no App Store badge, no price tags, no hands, no people, no desk clutter,
no neon, no heavy gradients, no 3D isometric tilt, no fisheye
```

## 九、发布前检查

- [ ] 屏幕里的界面与原始截图逐字一致（一步出图的必查项）。
- [ ] 标题每个字都对，没有重复或漏字。
- [ ] App Store 版标题与横幅文字不含第三方产品名称。
- [ ] 没有 Apple logo、没有生成出来的假图标或假按钮。
- [ ] 尺寸符合第二节；PNG/JPEG 为 RGB，无透明通道。
- [ ] 截图素材里不含真实 Token、地址或个人目录（`shots/` 用的是 Debug 种子数据，已满足）。
- [ ] 设备页那张（第 4 张）用的是改版后重拍的截图。
- [ ] 中英两套分别出图，英文版全部换成 `-en-` 截图。
