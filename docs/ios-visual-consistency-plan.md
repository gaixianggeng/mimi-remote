# iOS 视觉一致性整改方案

生成日期：2026-09-19
适用仓库：`gaixianggeng/mimi-remote`
适用范围：`ios/MimiRemote/Sources`（187 个 Swift 文件，113,993 行）
文档状态：**施工图**。所有事实已在 2026-09-19 当天对 `main` 复核，每条都附了复核命令。

---

## 第 0 章　执行须知（执行模型必读，不可跳过）

### 0.1 这份文档的性质

这是一份**施工图**，不是调研报告。所有该查的已经查完了。

- **不要重新调研。** 第 1 章的数字全部实测过。要复核就跑给出的命令，不要用别的方法重新统计后得出不同数字再去改方案。
- **不要自行扩大范围。** 每个任务都有「改动清单」和「禁止改动清单」。禁止清单里的东西即使看起来也有同样的问题，也不要在本任务里改。
- **遇到规则没覆盖的情况就停下来问用户**，不要猜。本文档在每个任务里都标了「规则未覆盖时怎么办」。

### 0.2 任务与分支约定（来自 `AGENTS.md`）

- 一项独立用户结果 = 一张 GitHub Issue = 一个主要 Worktree。
- 分支名：`codex/gh-<编号>-<英文描述>`。
- PR 描述用 `Refs #<编号>` 关联，**不要**用 `Closes`/`Fixes`（不默认自动关闭 Issue）。
- Issue 状态：开始实现 → In Progress；PR/测试/合并待完成 → Verify；只有改动进 main 且 worktree 清理后才 Close。
- 同时最多 2 张 Issue 处于 In Progress。本方案有 5 个阶段，**必须串行推进，不要并行开 5 个分支**。

### 0.3 本仓库已知的坑（踩进去会浪费很多时间）

| 坑 | 后果 | 规避方法 |
|---|---|---|
| Worktree 建在 `/tmp` 或 `/private/tmp` | 重启后目录被清空，未提交改动无法恢复 | worktree 一律建在 `~/code/` 下 |
| 新增 Swift 文件后没跑 xcodegen | 文件不进 target，编译看似通过但代码没生效 | 新增任何 `.swift` 文件后必须执行 `cd ios/MimiRemote && xcodegen generate` |
| `-only-testing` 写了文件名而不是类名 | **静默跑 0 个测试并报 passed**，得到假绿灯 | 用类名，不是文件名。跑完用 `xcresulttool` 确认执行数 > 0 |
| 快照测试基线本来就是红的 | 误以为自己改坏了 | `main` 上 Conversation / SkillModelPicker 快照**基线已有 18 个 precision 失败**；`ConversationDataFlowTests` **基线已红 5 个**。这些不是你造成的 |
| worktree 和主 checkout 共用 DerivedData | 两边同时跑测试会互相破坏 | 不要并行跑；或给 worktree 指定私有 DerivedData |
| `Localizable.xcstrings` 整文件重排 | diff 爆炸、review 无法进行 | 只能定点插入条目，不能让工具重排整个文件 |
| PR 被 Codex bot 行内评论卡住 | PR 一直 BLOCKED | `main` 开了 `required_conversation_resolution`，bot 的行内评论必须逐条 resolve。不要尝试 `--admin` |
| 设置页字号没过 `@ScaledMetric` | 丢失系统 Dynamic Type | 设置链路的字号必须先过 `@ScaledMetric` 再交给 `ThemeStore` |

### 0.4 每次提交前必须跑的验证

```bash
cd ios/MimiRemote && xcodegen generate     # 只在新增/删除文件后需要
bash ./scripts/check-ios-localization.sh   # 本方案会新增文案时必跑
bash ./scripts/check-source-size.sh        # 本方案会拆大文件时必跑
```

注意：在 agent shell 里跑验证脚本时，如果没有 `LANG` 环境变量，`check-docs-static.sh` 会报 Ruby US-ASCII 错误。这是环境问题不是代码问题，`export LANG=en_US.UTF-8` 即可。

### 0.5 提交信息与 PR 署名

Git commit message 结尾加：

```
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

PR 描述结尾加：

```
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

---

## 第 1 章　已验证事实（不要重新统计）

### 1.1 规模

| 指标 | 实测值 | 复核命令 |
|---|---|---|
| Swift 文件数 | 187 | `find ios/MimiRemote/Sources -name '*.swift' \| wc -l` |
| 总行数 | 113,993 | `find ios/MimiRemote/Sources -name '*.swift' -exec cat {} + \| wc -l` |
| 最大单文件 | `Features/Shell/UnifiedWorkbenchShell.swift` 1791 行 | `wc -l ios/MimiRemote/Sources/Features/Shell/UnifiedWorkbenchShell.swift` |

### 1.2 设计系统的现状：颜色和动效建好了，几何层碎成 20 份

**已建好的部分：**

| 层 | 位置 | 规模 |
|---|---|---|
| 颜色 | `Sources/State/ThemeStore.swift` 的 `ThemeTokens` | 54 个语义 Color token |
| 主题 | 同上 | 5 套预设（codex / github / xcode / gruvbox / meadow）× 明暗双色 |
| 字号档位表 | `ThemeStore.swift:773` 的 `baseSize(for:)` | 10 档，与 Apple 标准一致 |
| 动效 | `Sources/Core/Interaction/MimiInteractionFeedback.swift` 的 `MimiMotion` | 统一时长曲线 + Reduce Motion 集中降级 |

**碎掉的部分——20 个互不相识的局部尺寸枚举：**

```
ListMetrics                      ModelReasoningGridMetrics        ModelReasoningGridLayout
SessionIndexRowDensity           SettingsChoiceMetrics            SettingsLayoutMetrics
TokenActivityGridMetrics         WorkbenchChromeIconMetrics       WorkbenchPageLayout
WorkbenchSidebarSurfaceMetrics   WorkbenchSidebarContentLayout    WorkbenchLayout
WorkspaceIconStylePickerLayout   WorkspaceSessionFabMetrics       WorkspaceSessionRowMetrics
WorkspaceStripLayout             ConversationLayout               ConversationTimelineScrollMetrics
CodexUsageRingMetrics            ConnectionPrimaryActionsLayout
```

复核命令：

```bash
grep -rhoE '(enum|struct) \w*(Metrics|Layout|Density|Dimensions)\b' \
  ios/MimiRemote/Sources --include='*.swift' | sort -u
```

**关键判断：不是"没有设计系统"，是"有 20 套平行的局部系统"。** 每个枚举内部都自洽、注释都讲究，但互相不认识。所以整改动作是**归并**，不是**从零新建**。这个区别决定了工作量和风险等级。

### 1.3 取值分布

| 维度 | 档位数 | 实际取值 |
|---|---|---|
| 字号（字面量） | 25 | 5, 7, 8, 8.5, 9, 9.5, 10, 10.5, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 22, 24, 26, 28, 42, 43, 44 |
| 字号（含密度常量 13.5） | 26 | 上表 + 13.5（`SessionIndexRow.swift:41` 的 `previewFontSize`） |
| 圆角 | 20 | 1.5, 2.5, 3, 4, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 26, 28 |
| 间距 + 内边距 | 31 | 0,1,2,3,4,5,6,7,8,9,10,11,12,14,15,16,18,20,22,24,26,28,30,32,36,42,44,48,49,80,92 |

> ⚠️ **这四行统计的是「全仓调用点的裸字面量」，不是 1.2 节那些 Metrics 枚举里的常量。**
> 两者是不同的问题：枚举里的取值相当克制（真·间距 24 个值、真·圆角 4 个值），
> 散乱集中在没有名字的调用点。第 7 章据此重写过，别把这两组数字混用。

复核命令：

```bash
cd ios/MimiRemote
# 字号
{ grep -rhoE 'uiFont\(size: [0-9.]+' Sources --include='*.swift'
  grep -rhoE '\.system\(size: [0-9.]+' Sources --include='*.swift'; } \
  | grep -oE '[0-9.]+' | sort -gu
# 圆角
grep -rhoE 'cornerRadius: [0-9.]+' Sources --include='*.swift' | grep -oE '[0-9.]+' | sort -gu
# 间距
{ grep -rhoE '\bspacing: [0-9.]+' Sources --include='*.swift'
  grep -rhoE '\.padding\((\.(horizontal|vertical|top|bottom|leading|trailing), )?[0-9.]+\)' \
    Sources --include='*.swift'; } | grep -oE '[0-9.]+' | sort -gu
```

### 1.4 相关 Issue

`#465`（**OPEN**）英文界面多处标签、按钮与状态文案首字母小写，大小写不统一 —— 与本方案同根因（缺全局强制约定），但**不在本方案范围内**，不要顺手改。

---

## 第 2 章　核心机制：这个项目的字号是怎么工作的

**这一章是后续所有判定规则的依据。没读懂这一章就去改代码一定会改错。**

### 2.1 两条字号通路

项目里有两条完全不同的字号通路，行为不一样：

```swift
// 通路 A —— 经过 ThemeStore，会跟随用户的字号设置
themeStore.uiFont(size: 14, weight: .semibold)
themeStore.uiFont(.footnote, weight: .semibold)

// ThemeStore.swift:710-720 的实现
func scaledFontSize(_ baseSize: CGFloat) -> CGFloat {
    baseSize * CGFloat(fontScale)          // ← 乘以用户设置的倍率
}
func uiFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: scaledFontSize(size), weight: weight, design: uiFontPreset.design)
}
func uiFont(_ textStyle: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
    uiFont(size: Self.baseSize(for: textStyle), weight: weight)   // ← 查表后走同一条路
}
```

```swift
// 通路 B —— 绕过 ThemeStore，不跟随用户的字号设置
.font(.system(size: 14, weight: .semibold))
```

### 2.2 `fontScale` 的取值范围

`ThemeStore.swift:639-642`：

```swift
static let minimumFontScale = 0.85
static let maximumFontScale = 1.35
static let defaultFontScale = 1.0
static let compactIPadDefaultFontScale = 1.10   // 小屏 iPad 默认就不是 1.0
```

**推论：用户把字号拉到 1.35 时，通路 A 的文字放大 35%，通路 B 的元素纹丝不动。** 两者相邻时的光学配比会散掉 35%。这是本方案要解决的**功能性缺陷**，不是审美偏好。

注意 `compactIPadDefaultFontScale = 1.10` —— 在小屏 iPad 上**默认就不是 1.0**，所以这个缺陷在默认设置下就已经可见，不需要用户去动滑块。

### 2.3 字号档位表（唯一权威）

`ThemeStore.swift:773-798`：

| textStyle | 点数 |
|---|---|
| `.largeTitle` | 34 |
| `.title` | 28 |
| `.title2` | 22 |
| `.title3` | 20 |
| `.headline` | 17 |
| `.callout` | 16 |
| `.subheadline` | 15 |
| `.footnote` | 13 |
| `.caption` | 12 |
| `.caption2` | 11 |

**这张表就是本项目的 type scale，它已经存在且正确，不要修改它，不要新增档位。**

### 2.4 当前用量分布

| 写法 | 次数 | 判定 |
|---|---|---|
| `uiFont(.textStyle)` 语义档 | 428 | ✅ 正确，是主力写法 |
| `uiFont(size: N)` 数字档，N 在表内 | 102 | ⚠️ 行为正确但绕过了命名，应改成语义档 |
| `uiFont(size: N)` 数字档，N 在表外 | 38 | ⚠️ 需要归档到最近档位 |
| `.system(size:)` | 68 | 🔍 **必须分类处理，不能一刀切**，见第 4 章 |

---

## 第 3 章　阶段总览

| 阶段 | 内容 | 风险 | 可见收益 | 前置 |
|---|---|---|---|---|
| **P0** | 4 个肉眼可见的布局缺陷 | 低 | **高** | 无 |
| **P1** | 图标缩放行为归一 | 低 | 中 | 无 |
| **P2** | 字号档位归一 + 门禁 | 低 | 低 | P1 |
| **P3** | 间距/圆角 token + 收敛调用点字面量 | 低—中 | 中 | P2 |
| **P4** | 壳层信息架构重构 | **高** | 高 | P3 |

**推进顺序：P0 → P1 → P2 → P3 → P4，串行。**

为什么 P0 排第一：它修的是用户截图里一眼能看到的东西，改动量最小，且不依赖任何 token 体系。先做它能让"粗糙感"立刻下降一档，为后面的大改动争取耐心。

为什么 P3 必须在 P2 之后：调用点字面量没收敛前就上几何门禁，结果只会是到处写豁免注释。

> **注**：P3 原本的定位是「归并 20 个 Metrics 枚举」，2026-09-19 产出对照表后推翻了——
> 枚举本身克制，散乱在调用点。第 7 章已按修正版重写，风险等级随之从「中高」下调。

为什么 P4 单列且只给方向：它涉及产品决策（顶栏放什么、侧栏表达什么），不是能靠规则执行的任务，必须由用户先拍板。

---

## 第 4 章　P0：四个肉眼可见的布局缺陷

**Issue 标题建议**：`工作区页四处布局缺陷：胶囊名截断、左缘错位、孤立分界线、冗余身份列`
**分支**：`codex/gh-<编号>-workspace-layout-defects`
**预估**：4 个独立改动，互不依赖，可在同一 PR 内分 4 个 commit。

这四条都是在 iPad 横屏工作区页截图里直接可见的。它们不依赖任何 token 体系，先做完。

---

### P0-1　顶部工作区胶囊名被截成单个字母

**现象**：顶部胶囊行里未选中的工作区显示为「圆形头像 + 一个孤零零的字母」（如 `c`、`d`、`g`），看起来像渲染故障。

**根因**：`Sources/Features/Projects/WorkspaceStripPresentation.swift:53-74`

```swift
static func restingNameDisclosure(
    viewportWidth: CGFloat,
    projectCount: Int
) -> CGFloat {
    guard viewportWidth > 0, projectCount > 1 else { return 0 }

    let widthProgress = min(max((viewportWidth - 760) / 240, 0), 1)
    let collapsedWidth = CGFloat(projectCount + 1) * chipHeight
        + CGFloat(projectCount) * chipSpacing
    let selectedNameAllowance: CGFloat = 112
    let remainingWidth = max(
        0,
        viewportWidth - collapsedWidth - selectedNameAllowance
    )
    let restingBudget = CGFloat(projectCount - 1) * restingNameWidth
    let budgetProgress = min(max(remainingWidth / restingBudget, 0), 1)
    return min(widthProgress, budgetProgress)
}
```

这个函数返回 `0...1` 的**连续**披露进度，名称宽度按该进度插值到 `restingNameWidth = 64`。当进度落在约 `0.05...0.35` 区间时，分配给名称的宽度只够放下 1–2 个字符，于是出现单字母残片。

**修法**：把连续披露改为阈值式的全有全无。名字要么完整显示，要么完全不显示，不存在中间态。

```swift
/// 未选中胶囊的名称披露是**二值**的：要么给足 `restingNameWidth`，要么完全不给。
///
/// 这里曾经返回 0...1 的连续进度并按它插值名称宽度。连续插值在中间态会把名字
/// 截成一两个字符的残片——用户读到的不是"空间不够"，是"这个控件坏了"。
/// 一个字符的工作区名没有任何辨识价值，不如干净地退回纯头像。
static func restingNameDisclosure(
    viewportWidth: CGFloat,
    projectCount: Int
) -> CGFloat {
    guard viewportWidth > 0, projectCount > 1 else { return 0 }

    let collapsedWidth = CGFloat(projectCount + 1) * chipHeight
        + CGFloat(projectCount) * chipSpacing
    let selectedNameAllowance: CGFloat = 112
    let remainingWidth = max(
        0,
        viewportWidth - collapsedWidth - selectedNameAllowance
    )
    let restingBudget = CGFloat(projectCount - 1) * restingNameWidth

    // 宽度阈值和预算阈值都必须满足；任一不满足就退回纯头像。
    guard viewportWidth >= nameDisclosureMinimumWidth, remainingWidth >= restingBudget else {
        return 0
    }
    return 1
}
```

**阈值取值说明**：原函数用 `(viewportWidth - 760) / 240` 做线性映射，意味着 760 起步、1000 满值。改成二值后原本应取满值点 1000。

> ⚠️ **但 1000 这个值在 P0-2 改完之后会失效**（容器收窄到 920，ScrollView 实际宽度只有 700 上下，阈值永远不满足 → 名称永远不显示）。
>
> 因此这里**不要写字面量**，新增一个具名常量：
>
> ```swift
> /// 未选中胶囊开始显示名称所需的最小滚动区宽度。
> /// 实测值，校准方法见 P0-2；改动胶囊行的宽度策略后必须重新校准。
> static let nameDisclosureMinimumWidth: CGFloat = <P0-2 实测后填入>
> ```
>
> **先做 P0-2 的实测校准，拿到真实数字再回来填这个常量。**

**规则未覆盖时怎么办**：如果改完发现常用 iPad 宽度下名称全都不显示了（即体验反而变差），**停下来问用户**是要降低阈值还是要改用其他方案（如 hover/长按显示名称）。不要自己反复调阈值。

**验证**：
1. 找到调用 `restingNameDisclosure` 的地方（`grep -rn 'restingNameDisclosure' ios/MimiRemote/Sources`），确认调用方能接受二值返回。
2. 在 iPad 13" 横屏 + 侧栏展开、iPad 13" 横屏 + 侧栏收起、iPad mini 竖屏三种情况下，确认胶囊要么显示完整名字要么只有头像，**不存在 1–3 个字符的名字**。

**完成标准**：任何视口宽度下，未选中胶囊上不会出现被截断的工作区名。

---

### P0-2　顶部胶囊行与下方列表左缘不对齐

**现象**：顶部工作区胶囊行的左边缘明显比下方会话列表的左边缘更靠左，两条左缘差了约 100pt。

**根因**：两个容器各自决定宽度策略，互不知情。

`Sources/Features/Projects/WorkspaceRootView.swift:779` —— 胶囊行是**全宽 + 固定内边距**：

```swift
.padding(.horizontal, WorkspaceStripLayout.horizontalPadding)   // 24pt，全宽
```

`Sources/Features/Projects/WorkspaceDetailView.swift:78-79` —— 列表是**居中 + 最大宽度**：

```swift
.frame(maxWidth: 920, alignment: .leading)
.frame(maxWidth: .infinity, alignment: .center)
```

讽刺的是 `WorkspaceStripPresentation.swift:26` 定义了共享常量但没人用：

```swift
/// 胶囊行、状态行与详情内容共用同一个最大宽度，宽屏下三者左右边界一致。
static let maxContentWidth: CGFloat = 920
```

注释描述的是**意图**，代码没有实现它。复核：

```bash
grep -rn 'maxContentWidth' ios/MimiRemote/Sources --include='*.swift'
# 只有定义，没有使用点
```

**修法**：让胶囊行采用和列表相同的宽度策略。修改 `WorkspaceRootView.swift:779` 附近：

```swift
.padding(.horizontal, WorkspaceStripLayout.horizontalPadding)
// 胶囊行与下方列表共用同一条内容宽度轨道，否则宽屏下两条左缘会差出上百 pt。
// 920 这个数字由 WorkspaceStripLayout.maxContentWidth 单独持有，
// 两处各写一个字面量时，改了一处另一处会静默保持旧行为。
.frame(maxWidth: WorkspaceStripLayout.maxContentWidth, alignment: .leading)
.frame(maxWidth: .infinity, alignment: .center)
```

同时把 `WorkspaceDetailView.swift:78` 的字面量 `920` 换成常量引用：

```swift
.frame(maxWidth: WorkspaceStripLayout.maxContentWidth, alignment: .leading)
```

**⚠️ 必须注意：胶囊行有两个独立的宽度观测值，改宽度策略会同时影响它们。**

| 状态变量 | 定义 | 观测位置 | 观测对象 | 喂给谁 |
|---|---|---|---|---|
| `workspaceStripViewportWidth` | `WorkspaceRootView.swift:264` | `:741-746` | 横向 **ScrollView** 的宽 | `restingNameDisclosure`（P0-1 改的那个） |
| `workspaceStripContainerWidth` | `WorkspaceRootView.swift:267` | `:783-787` | 整条胶囊行 HStack 的宽 | `usesInlineRuntimePicker`（`:438-443`） |

两者不相等：ScrollView 的宽 = 容器宽 − 内边距 − Runtime 筛选器 − 分隔线。

**修饰符顺序决定观测到什么。** `.frame(maxWidth:)` 必须加在 `.onGeometryChange` **之前**，观测值才会是收窄后的宽度；加在之后则观测到的仍是全宽。本方案要的是前者（两个观测值都反映真实可用宽度）。

**因此改完必须重新校准两个阈值：**

1. `inlineRuntimePickerMinimumWidth = 640`（`WorkspaceStripPresentation.swift:31`）
   收窄后容器宽最大 920，减去两侧 `horizontalPadding` 24 → 872 > 640，**应该仍然成立**。但要实测确认宽屏 iPad 上 Runtime 筛选器没有掉回独立一行。

2. **P0-1 的阈值必须重算，不能用 1000。** 收窄后 ScrollView 的实际宽度会远小于 920（要再扣掉 Runtime 筛选器约 158pt + 分隔约 9pt），落在 700 上下。用 1000 做阈值会导致**名称永远不显示**。

**重算方法（不要猜，实测）**：在 `:744` 的 `action:` 闭包里临时加一行打印，在目标设备上读出真实值，再据此定阈值：

```swift
} action: { width in
    print("[strip] viewportWidth = \(width)")   // 临时，校准后删除
    guard width > 0, workspaceStripViewportWidth != width else { return }
    workspaceStripViewportWidth = width
}
```

要读的三个场景：iPad 13" 横屏 + 侧栏展开 / iPad 13" 横屏 + 侧栏收起 / iPad mini 竖屏。阈值取「侧栏展开的横屏能满足、mini 竖屏不满足」的那个值，并把实测数字写进 `WorkspaceStripPresentation.swift` 的注释里。

> ⚠️ **P0-1 和 P0-2 有耦合，必须在同一个 commit 里一起做完并一起验证。** 不要先合并其中一个：单独合 P0-2 会让 P0-1 的阈值失效，单独合 P0-1 则等于按旧宽度校准，P0-2 一来就白做。

**完成标准**：宽屏 iPad 上，胶囊行最左侧胶囊的左边缘与列表第一行状态圈的左边缘在同一条竖线上。

---

### P0-3　「12 小时前」分界线孤立悬在列表顶部

**现象**：会话列表最顶部出现一行「12 小时前」，它上面什么都没有，读起来像是整个列表的标题，但实际语义是「以下是 12 小时前的会话」。

**根因**：`Sources/Features/Projects/WorkspaceDetailView.swift:238-256`

```swift
let firstStaleIndex = group == .recent
    ? WorkspaceSessionAgeBoundary.firstStaleIndex(
        in: sessions,
        excludingSessionIDs: sessionStore.pinnedSessionIDs,
        now: currentDate()
    )
    : nil

if let firstStaleIndex {
    let currentSessions = Array(sessions.prefix(firstStaleIndex))
    let staleSessions = Array(sessions.dropFirst(firstStaleIndex))

    VStack(alignment: .leading, spacing: 0) {
        if !currentSessions.isEmpty {
            sessionRowsStack(sessions: currentSessions, ...)
        }

        staleBoundaryHeader(rowDensity: rowDensity, tokens: tokens)   // ← 无条件渲染

        sessionRowsStack(sessions: staleSessions, ...)
    }
}
```

`Sources/Features/Projects/WorkspaceRootView.swift:117-128` 的 `firstStaleIndex` 在「最新一条会话本身就超过 12 小时」时返回 `0`：

```swift
static func firstStaleIndex(
    in sessions: [AgentSession],
    excludingSessionIDs: Set<SessionID> = [],
    now: Date = Date()
) -> Int? {
    sessions.firstIndex { session in
        !excludingSessionIDs.contains(session.id) &&
        now.timeIntervalSince(SessionIndexStore.orderingDate(for: session)) > staleInterval
    }
}
```

返回 `0` 时 `currentSessions` 为空，分界线上方没有任何内容——**一条只有下半边的分界线**。

**修法**：在 `firstStaleIndex` 返回 `0` 时不走分段分支。修改 `WorkspaceDetailView.swift` 的条件：

```swift
// 分界线的意义是"上面是新的、下面是旧的"。索引为 0 时上半边是空的，
// 它就退化成一个悬在列表顶部的标题，反而会被读成整段列表的名字。
// 此时整段都是旧会话，不需要再分界。
if let firstStaleIndex, firstStaleIndex > 0 {
```

**不要**改 `firstStaleIndex` 函数本身返回 `nil`——那个函数的语义是「第一个陈旧会话的下标」，`0` 是合法答案。判断该不该画分界线是调用方的职责。

**测试**：如果 `WorkspaceSessionAgeBoundary` 有对应单元测试，补一条 `firstStaleIndex == 0` 时不渲染分界线的断言。查找：

```bash
grep -rn 'firstStaleIndex\|WorkspaceSessionAgeBoundary' ios/MimiRemote/Tests
```

**完成标准**：当列表中所有会话都超过 12 小时时，列表顶部不出现「12 小时前」。

---

### P0-4　每行右侧重复显示同一个工作区名

**现象**：会话列表每一行的右下角都显示 `codex-ipad-agent`，12 行就重复 12 次。而顶部胶囊行已经选中了这个工作区，整页本来就按它过滤。

**根因**：`Sources/Features/Projects/WorkspaceDetailView.swift:325-326`

```swift
// 这一页的项目是恒定的；没有区分价值的分支时用目录末段区分 worktree。
identityFallback: .directory,
```

意图是「有 worktree 分化时用目录末段区分」，但当会话**没有分支信息**且**没有 worktree 分化**时，`.directory` 回退成了主工作区目录名本身，也就是页面顶部已经显示过的那个名字。

`Sources/Features/Sessions/SessionIndexRow.swift:672-713` 的 `identityColumn` 只判断「文本非空」就渲染，不判断「这个文本是否有区分价值」。

**修法**：在 `WorkspaceDetailView` 计算身份列内容时，如果该值在**当前可见的全部会话里完全一致**，就不显示。

`SessionIndexRow.swift` 已有同类先例可参照——`branch` 参数是通过 `SessionListPresentation.branchToDisplay(_:among:)` 算出来的，那个函数就是「在一组值里只保留有区分度的部分」。先读它：

```bash
grep -rn 'func branchToDisplay' -A 25 ios/MimiRemote/Sources/Features/Sessions/SessionListPresentation.swift
```

**优先方案**：为 `identityFallback` 增加同样的「同组去重」语义，复用 `branchToDisplay` 的判定思路，不要新写一套。

**次选方案**（若优先方案改动面过大）：在 `WorkspaceDetailView` 里预先计算一个布尔值，当所有会话的 directory 末段相同时传 `identityFallback: .none`（如果该枚举没有 `.none`，则改传一个让 `identityColumn` 不渲染的值）。

**规则未覆盖时怎么办**：先读 `identityFallback` 的枚举定义和全部使用点再决定。如果发现 `.directory` 在**会话 tab**（不是工作区 tab）里也在用且那里是有意义的，**只改工作区 tab 的传参，不要改枚举语义**。

```bash
grep -rn 'identityFallback' ios/MimiRemote/Sources --include='*.swift'
```

**完成标准**：工作区页在只有一个目录、无 worktree 分化时，行内不再显示重复的工作区名；存在多个 worktree 时仍能看出区别。

---

### P0 整体验证

由于 P0 全是视觉改动，**必须出图验收，不能只靠编译通过**。

```bash
# 模拟器上跑起来看（优先，真机 UI 测试握手自 09-11 起被拒，退出码 74）
# 用 --debug-open-mac-connection 之类的调试参数直达工作区页
```

已知：`main` 上快照测试基线已有 18 个 precision 失败（Conversation / SkillModelPicker），**这些与 P0 无关**，不要试图修它们。P0 只需确认**没有新增**失败项。

---

## 第 5 章　P1：图标缩放行为归一

**Issue 标题建议**：`SF Symbol 图标缩放行为不统一：43 处不跟随用户字号设置`
**分支**：`codex/gh-<编号>-icon-scale-consistency`
**前置**：无
**风险**：低（行为变更明确，无架构改动）

---

### 5.1 问题陈述

同一个 App 里，SF Symbol 图标分成了行为不同的两派：

| 写法 | 数量 | 是否跟随用户字号设置 |
|---|---|---|
| `Image(systemName:).font(themeStore.uiFont(...))` | 113 | ✅ 跟随 |
| `Image(systemName:).font(.system(size: N))` | 43 | ❌ 不跟随 |

复核命令：

```bash
cd ios/MimiRemote
grep -rn 'Image(systemName' -A 1 Sources --include='*.swift' | grep -c 'uiFont'       # 113
grep -rn 'Image(systemName' -A 1 Sources --include='*.swift' | grep -c 'system(size:' # 43
```

**后果**：用户把字号从 0.85 调到 1.35（或仅仅是在小屏 iPad 上使用默认的 1.10），那 113 处图标跟着文字一起放大，43 处纹丝不动。同一行里图标和文字的光学配比散掉，行与行之间的图标大小关系也乱掉。

**这是本方案里唯一的功能性缺陷，其余都是一致性问题。优先级因此高于 P2。**

---

### 5.2 分类规则（决策树，逐条套用，不要跳过）

全仓 68 处 `.system(size:)` 调用**不能一刀切替换**。按下表分类，只改分类 A：

```
遇到一处 .system(size: X)
│
├─ X 是 scaled(...) 调用？
│    → 【分类 C：已正确】不要改。scaled() 内部已乘 fontScale。
│
├─ 所在文件是 ShareJourneyView.swift 且 X 形如 `N * scale`？
│    → 【分类 E：分享卡】不要改。这里的 scale 是海报渲染比例
│      （proxy.size.width / 360），与用户字号无关，改了会撑破固定比例卡片。
│
├─ X 是由容器尺寸推导的（如 size * 0.58、avatarDiameter * 0.58、size * 8 / 9）？
│    → 【分类 D：随容器】不要改。这类字形要填满一个已确定尺寸的圆/方框，
│      让它再乘一次 fontScale 会溢出容器。
│
├─ X 是命名常量（SettingsLayoutMetrics.symbolPointSize / WorkbenchChromeIconMetrics.symbolSize）？
│    → 【分类 B：符号常量】改法见 5.4，统一在常量定义处接入缩放。
│
├─ 这个 modifier 作用在 Text(...) 上？
│    → 【分类 A-Text】改成 themeStore.uiFont(...)。见 5.3。
│
└─ 这个 modifier 作用在 Image(systemName:) / Label 上？
     → 【分类 A-Icon】改成 themeStore.uiFont(...)。见 5.3。
```

**分类统计**（已实测）：

| 分类 | 数量 | 处理 |
|---|---|---|
| A-Text（裸字面量在 Text 上） | 5 | 改 |
| A-Icon（裸字面量在 Image 上） | 28 | 改 |
| B（符号点尺寸常量） | 10 | 在常量定义处改 |
| C（`scaled()`） | 8 | 不改 |
| D（随容器推导） | 2 | 不改 |
| E（ShareJourneyView 海报比例） | 14 | 不改 |
| 待人工判定 | 1 | 见 5.5 |

---

### 5.3 分类 A 改动清单（精确到行）

> ⚠️ **行号会随着你自己的编辑而漂移。** 改完第一处后，后续位置请用文件名 + 原字号重新 grep 定位，不要盲信下表行号。
>
> 重新定位命令：`grep -n '\.system(size: <N>' ios/MimiRemote/Sources/<文件路径>`

**A-Text（5 处）**——作用在 `Text` 上：

| 文件 | 行 | 原字号 | 改为 |
|---|---|---|---|
| `Features/Diagnostics/DoctorView.swift` | 477 | 11 | `themeStore.uiFont(.caption2, ...)`，保留 `design: .monospaced` |
| `Features/Diagnostics/DoctorView.swift` | 579 | 12 | `themeStore.uiFont(.caption, ...)` |
| `Features/Projects/WorkspaceAppearancePickers.swift` | 126 | 26 | **例外，见下方说明** |
| `Features/Projects/WorktreeManagementViews.swift` | 432 | 10 | `themeStore.uiFont(size: 11, ...)`（10 不在档表，归到 `.caption2`=11） |
| `Features/Settings/SettingsDetailViews.swift` | 983 | 15 | `themeStore.uiFont(.subheadline, ...)` |

> **`WorkspaceAppearancePickers.swift:126` 是例外，不要改。** 该处是 `Text(emoji).font(.system(size: 26)).frame(width: 44, height: 44)` —— emoji 字形要填满一个固定 44×44 的选择格。乘上 fontScale 会让 emoji 溢出格子。归入分类 D 处理（不改）。

`DoctorView.swift:477` 带 `design: .monospaced`，`uiFont` 不接受 design 参数。该处改用 `codeFont`：

```swift
// 改前
.font(.system(size: 11, design: .monospaced))
// 改后 —— codeFont 同样经过 scaledFontSize，且保留等宽
.font(themeStore.codeFont(.caption2))
```

**A-Icon（28 处）**——作用在 `Image(systemName:)` / `Label` 上：

```
Features/Conversation/Timeline/ConversationTimelineView.swift:1574   17pt → .headline
Features/Projects/WorkspaceRootView.swift:494                        14pt → size: 15 (.subheadline)
Features/Projects/WorkspaceSessionRuntimePicker.swift:102            11pt → .caption2
Features/Projects/WorkspaceSessionRuntimePicker.swift:261            11pt → .caption2
Features/Projects/WorkspaceSessionRuntimePicker.swift:343            13pt → .footnote
Features/Sessions/SessionListView.swift:477                          24pt → size: 24（表外，见下）
Features/Settings/ConnectionSpeedTestView.swift:484                  13pt → .footnote
Features/Settings/QRCodeScannerSheet.swift:145                       44pt → size: 44（表外，见下）
Features/Settings/QRCodeScannerSheet.swift:170                       42pt → size: 42（表外，见下）
Features/Settings/SettingsChoiceRow.swift:267                        14pt → size: 15 (.subheadline)
Features/Settings/SettingsDetailViews.swift:933                       9pt → size: 11 (.caption2)
Features/Settings/SettingsView.swift:1167                            13pt → .footnote
Features/Settings/SettingsView.swift:1212                            20pt → .title3
Features/Settings/SettingsView.swift:1241                            13pt → .footnote
Features/Settings/ShareJourneyView.swift:115                         18pt → size: 17 (.headline)
Features/Shell/HostSwitcherMenu.swift:248                             9pt → size: 11 (.caption2)
Features/Shell/UnifiedWorkbenchShell.swift:511                       18pt → size: 17 (.headline)
Features/Shell/UnifiedWorkbenchShell.swift:545                       18pt → size: 17 (.headline)
Features/Shell/WorkbenchSidebarComponents.swift:96                   14pt → size: 15 (.subheadline)
Features/Shell/WorkbenchSidebarComponents.swift:220                  12pt → .caption
Features/Shell/WorkbenchSidebarComponents.swift:521                  17pt → .headline
ProfileRootView.swift:147                                            19pt → .title3 (20)
ProfileRootView.swift:177                                            13pt → .footnote
ProfileRootView.swift:216                                            13pt → .footnote
ProfileRootView.swift:242                                            14pt → size: 15 (.subheadline)
ProfileRootView.swift:413                                            22pt → .title2
ProfileRootView.swift:763                                            17pt → .headline
ProfileRootView.swift:790                                            13pt → .footnote
```

**表外大字号的处理**（`SessionListView.swift:477` 的 24、`QRCodeScannerSheet.swift:145/170` 的 44/42）：

这三处是空态/扫码页的大号装饰性图标，最近档位（`.title`=28、`.largeTitle`=34）与原值差距过大，直接归档会明显改变视觉。**这三处改成 `themeStore.uiFont(size: <原值>)` 即可**——目的是让它跟随字号设置，档位归一留给 P2 处理。

另外 `QRCodeScannerSheet.swift:145/170` 的 44 和 42 相差 2pt 且都是同一个页面的状态图标，**大概率应该是同一个值**。改的时候统一成 44 并加注释说明。

**改法模板**：

```swift
// 改前
Image(systemName: "arrow.clockwise")
    .font(.system(size: 14, weight: .semibold))

// 改后
Image(systemName: "arrow.clockwise")
    .font(themeStore.uiFont(.subheadline, weight: .semibold))
```

**前置检查**：目标 View 必须能访问 `themeStore`。如果该 View 没有 `@EnvironmentObject var themeStore: ThemeStore`（或等价注入），**先确认注入方式再改**：

```bash
grep -n 'themeStore' ios/MimiRemote/Sources/<目标文件>  | head -3
```

若该 View 完全没有 themeStore（例如是个纯展示的小组件），**不要为了改这一行而给它加依赖注入**——记录下来，在 PR 描述里列为「已知遗留」，交给用户决定。

---

### 5.4 分类 B：符号点尺寸常量（10 处）

这 10 处都写成 `.font(.system(size: <常量>))`，常量定义在：

```
Sources/WorkbenchChrome.swift:711              static let symbolSize: CGFloat = 15
Sources/Features/Settings/SettingsView.swift:12  static let symbolPointSize: CGFloat = 18
```

**不要逐个改调用点**，在调用点改会让 10 处各写一遍缩放逻辑。正确做法是让调用点统一走 `themeStore.uiFont(size:)`：

```swift
// 改前
.font(.system(size: SettingsLayoutMetrics.symbolPointSize, weight: .regular))
// 改后
.font(themeStore.uiFont(size: SettingsLayoutMetrics.symbolPointSize, weight: .regular))
```

常量定义本身不动（它是基准值，缩放由 `uiFont` 施加）。

**但有一个必须先确认的前提**：`SettingsView.swift:535` 有 `var symbolPointSize: CGFloat = SettingsLayoutMetrics.symbolPointSize`，说明某些调用点允许覆盖这个值。改之前先看这些覆盖值是不是已经手工乘过缩放了（若是，会双重缩放）：

```bash
grep -rn 'symbolPointSize' ios/MimiRemote/Sources --include='*.swift'
```

**如果发现任何一处已经手工乘过 fontScale 或 scaledFontSize，停下来问用户**，不要自行判断该去掉哪一层。

---

### 5.5 待人工判定的 1 处

`Features/Projects/WorkspaceAppearancePickers.swift:159`（24pt）—— 自动分类器无法确定它作用在 `Text` 还是 `Image` 上。

**处理方式**：打开文件读上下文 10 行，按 5.2 的决策树归类后再动。如果它和 126 行一样是固定格子里的 emoji，归入分类 D 不改。

---

### 5.6 P1 验证

**功能验证（必做）**：

1. 启动 App → 设置 → 把字号倍率拉到最大（1.35）。
2. 逐页检查：工作区页、会话页、设置页、诊断页、我的页。
3. **验收标准：每一行里的图标都和它旁边的文字等比例变大，没有任何图标保持原大小。**
4. 再拉到最小（0.85）重复一遍。

**回归验证**：

```bash
# 改完后，剩余的 .system(size:) 应该只剩分类 C/D/E，总数应为 8 + 2 + 14 + 1(例外) = 25 左右
cd ios/MimiRemote
grep -rn '\.system(size:' Sources --include='*.swift' | grep -v 'ThemeStore.swift' | wc -l
```

**完成标准**：`grep` 剩余结果全部可归入分类 C/D/E，且每一处都有注释说明为什么它不该缩放。

---

## 第 6 章　P2：字号档位归一 + 门禁

**Issue 标题建议**：`字号档位归一：38 处表外字号归档，102 处数字档改语义档，加静态门禁`
**分支**：`codex/gh-<编号>-font-scale-consolidation`
**前置**：P1 必须已合并（否则两个分支会在同一批文件上冲突）
**风险**：低（行为不变，仅取值变化），但**有可见的视觉变化**，需出图验收

---

### 6.1 目标

1. 消灭 `uiFont(size: N)` 中 N 不在档位表内的 38 处。
2. 把 N 在档位表内的 102 处改成语义写法（`uiFont(.footnote)` 而不是 `uiFont(size: 13)`）。
3. 加门禁，防止回退。

**注意第 2 项是纯命名改动，行为完全不变**（`uiFont(.footnote)` 就是 `uiFont(size: 13)`）。它的价值是让下一个人一眼看出这是档位内的值。如果时间紧张，第 2 项可以拆到后续 PR，**但第 1 项和第 3 项必须一起做**——否则门禁会立刻挂掉。

---

### 6.2 归档规则

**规则**：取档位表里最接近的值；距离相等时**取较大的那个**（缩小文字会伤可读性）。

档位表（唯一权威，来自 `ThemeStore.swift:773`）：`11, 12, 13, 15, 16, 17, 20, 22, 28, 34`

| 表外值 | 出现次数 | 归档到 | 语义名 | 视觉变化 |
|---|---|---|---|---|
| 5 | 1 | 11 | `.caption2` | **+120%，极大** |
| 7 | 1 | 11 | `.caption2` | +57%，大 |
| 8 | 1 | 11 | `.caption2` | +38%，大 |
| 9 | 7 | 11 | `.caption2` | +22%，明显 |
| 10 | 3 | 11 | `.caption2` | +10%，轻微 |
| 10.5 | 1 | 11 | `.caption2` | +5%，几乎无感 |
| 13.5 | 1 | 13 | `.footnote` | −4%，几乎无感 |
| 14 | 14 | **逐处判定** | 见下 | — |
| 18 | 3 | 17 | `.headline` | −6%，轻微 |
| 19 | 3 | 20 | `.title3` | +5%，轻微 |
| 24 | 2 | 22 | `.title2` | −8%，轻微 |
| 26 | 2 | 28 | `.title` | +8%，轻微 |

**14pt 不适用机械规则**：13 和 15 到 14 的距离相等，且它有 14 处用量（是最常见的表外值）。**逐处按上下文判定**：

- 在**密集列表行 / 徽章 / 元数据**里 → 归到 **13**（`.footnote`）
- 在**独立标签 / 按钮文字 / 卡片正文**里 → 归到 **15**（`.subheadline`）

14pt 的 14 处位置：

```
Features/Conversation/ModelReasoningGridPicker.swift:597
Features/Conversation/Timeline/ConversationActivityRows.swift:104
Features/Conversation/Timeline/ConversationProcessGroupRow.swift:70
Features/Conversation/Timeline/ConversationProcessGroupRow.swift:249
Features/Inspector/SessionInspectorView.swift:17
Features/Projects/ProjectSidebarView.swift:444
Features/Projects/ProjectSidebarView.swift:846
Features/Projects/ProjectSidebarView.swift:877
Features/Projects/ProjectSidebarView.swift:1291
Features/Projects/ProjectSidebarView.swift:1313
Features/Projects/ProjectSidebarView.swift:1348
Features/Projects/ProjectSidebarView.swift:1357
Features/Projects/ProjectSidebarView.swift:1598
Features/Sessions/SessionListView.swift:365
```

**5pt 那一处必须单独确认**（`Features/Conversation/Timeline/ConversationActivityRows.swift:130`）：5pt 字在任何情况下都读不清，它很可能不是文字，而是某种指示器的尺寸被写成了字号。**打开看，如果它不是给人读的文字，就不要机械归档到 11pt**——那会让一个原本不可见的元素突然变得显眼。规则未覆盖，交给用户判断。

---

### 6.3 其余表外值的完整位置清单

```
 5pt ×1   Features/Conversation/Timeline/ConversationActivityRows.swift:130
 7pt ×1   Features/Shell/WorkbenchSidebarComponents.swift:613
 8pt ×1   Features/Conversation/ModelReasoningGridPicker.swift:558
 9pt ×7   Features/Conversation/ModelReasoningGridPicker.swift:566
          Features/Conversation/SkillInterfaceViews.swift:468
          Features/Conversation/SkillInterfaceViews.swift:537
          Features/Projects/ProjectSidebarView.swift:1792
          Features/Projects/WorkspaceRootView.swift:1534
          Features/Sessions/SessionListView.swift:917
          Features/Settings/TokenActivityView.swift:288
10pt ×3   Features/Projects/ProjectSidebarView.swift:1797
          Features/Projects/ProjectSidebarView.swift:1811
          Features/Projects/WorktreeManagementViews.swift:679
10.5pt ×1 Features/Shell/WorkbenchSidebarComponents.swift:658
18pt ×3   Features/Conversation/SkillInterfaceViews.swift:436
          Features/Inspector/GitQuickPublishView.swift:203
          Features/Shell/WorkbenchSidebarComponents.swift:280
19pt ×3   Features/Conversation/ComposerAttachmentViews.swift:849
          Features/Conversation/ComposerRequestCards.swift:160
          Features/Projects/WorktreeManagementViews.swift:375
24pt ×2   Features/Conversation/ComposerAttachmentViews.swift:1047
          Features/Conversation/Timeline/ConversationTimelineView.swift:1116
26pt ×2   Features/Conversation/SkillInterfaceViews.swift:286
          Features/Projects/ProjectSidebarView.swift:959
13.5pt ×1 Features/Sessions/SessionIndexRow.swift:41（是 previewFontSize 常量，不是调用点）
```

重新定位命令（行号漂移后用）：

```bash
cd ios/MimiRemote
grep -rn 'uiFont(size: 9[,)]' Sources --include='*.swift'
```

**⚠️ 9pt 的 7 处和 8pt / 10pt 中，有一部分很可能是徽章角标数字**（如「9+」计数徽章）。这类字形装在固定尺寸的小圆里，放大 22% 可能会溢出。**改完必须逐个出图看徽章有没有被撑破。**

---

### 6.4 门禁脚本

新建 `scripts/check-ios-typography.sh`。内容如下，可直接使用：

```bash
#!/usr/bin/env bash
set -euo pipefail

# 字号必须走 ThemeStore 的档位表，否则用户的全局字号设置对它无效，
# 且档位会持续发散。豁免项必须写进 allowlist 并注明原因。

python3 - <<'PY'
from pathlib import Path
import re
import sys

ROOT = Path("ios/MimiRemote/Sources")
# 与 ThemeStore.baseSize(for:) 保持一致。改这里之前先改那里。
SCALE = {11, 12, 13, 15, 16, 17, 20, 22, 28, 34}

# 整文件豁免：该文件内所有 .system(size:) 都有同一个正当理由。
# 只有"全文件同因"才配用这一级；否则用下面的按行豁免。
SYSTEM_FONT_FILE_ALLOWLIST = {
    "Features/Conversation/MarkdownStyle.swift":
        "内部 scaled() 已乘 fontScale，全文件同因",
    "Features/Settings/ShareJourneyView.swift":
        "分享海报按 proxy.size.width/360 等比渲染，与用户字号无关，全文件同因",
}

# 按行豁免：同一文件里只有个别位置该豁免，其余仍须走 ThemeStore。
# 行号会漂移，每次改动这些文件后必须核对本表。
SYSTEM_FONT_LINE_ALLOWLIST = {
    "Features/Projects/WorkspaceAppearancePickers.swift:126":
        "emoji 字形填满固定 44x44 选择格，再乘缩放会溢出",
    "Features/Projects/WorkspaceAppearancePickers.swift:159":
        "同上（P1 已人工确认）",
    "Features/Shell/HostSwitcherMenu.swift:427":
        "头像首字母按容器直径推导 size*8/9",
    "Features/Shell/HostSwitcherMenu.swift:454":
        "头像首字母按容器直径推导 size*8/9",
    "Features/Settings/SettingsDetailViews.swift:914":
        "头像首字母按 avatarDiameter 推导",
    "Features/Projects/WorkspaceRootView.swift:83":
        "工作区头像首字母按容器直径推导 size*0.58",
    "Features/Projects/WorkspaceDetailView.swift:470":
        "浮动按钮图标按浮起状态切换固定尺寸",
}

# 允许留在表外的字号，每条都要写原因。
SIZE_ALLOWLIST = {
    # "Features/Foo/Bar.swift:123": "原因",
}

errors = []
system_font = re.compile(r"\.system\(size:")
ui_font_literal = re.compile(r"uiFont\(size:\s*([0-9]+(?:\.[0-9]+)?)")

for path in sorted(ROOT.rglob("*.swift")):
    rel = str(path.relative_to(ROOT))
    if rel == "State/ThemeStore.swift":
        continue
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        key = f"{rel}:{lineno}"
        if (
            system_font.search(line)
            and rel not in SYSTEM_FONT_FILE_ALLOWLIST
            and key not in SYSTEM_FONT_LINE_ALLOWLIST
        ):
            errors.append(
                f"{key} 直接用了 .system(size:)，绕过 ThemeStore 的字号缩放。"
                f" 改用 themeStore.uiFont(...)，或加进 SYSTEM_FONT_LINE_ALLOWLIST 并注明原因。"
            )
        for match in ui_font_literal.finditer(line):
            value = float(match.group(1))
            if value not in SCALE and key not in SIZE_ALLOWLIST:
                errors.append(
                    f"{key} 字号 {match.group(1)}pt 不在档位表 {sorted(SCALE)} 内。"
                    f" 归到最接近的档位（相等时取大），或加进 SIZE_ALLOWLIST 并注明原因。"
                )

if errors:
    print("iOS 字号门禁失败：", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    sys.exit(1)

print("iOS 字号门禁通过")
PY
```

**接入 CI**：编辑 `.github/workflows/ios-ci.yml`，在既有的 `check-ios-localization.sh` 步骤旁边加一步：

```yaml
      - name: 字号档位门禁
        run: bash ./scripts/check-ios-typography.sh
```

同时把 `scripts/check-ios-typography.sh` 加进 `ios-ci.yml` 顶部的 `paths:` 触发列表（对照第 39–52 行既有条目的写法）。

**别忘了**：`chmod +x scripts/check-ios-typography.sh`。

**脚本自检（确认你没抄错）**：在 P1 已合并、P2 尚未开始的状态下跑这个脚本，预期输出应该是：

```
退出码       1
违规总数     81
  其中 .system(size:) 类   43
  其中 字号档位类           38
```

如果你拿到的数字和这个差很多，说明豁免表抄错了或路径写错了，**先修脚本再改代码**。验证命令：

```bash
out=$(bash ./scripts/check-ios-typography.sh 2>&1); echo "退出码: $?"
echo "总数: $(echo "$out" | grep -c '^  - ')"
echo "system: $(echo "$out" | grep -c 'system(size:)')"
echo "档位:   $(echo "$out" | grep -c '不在档位表')"
```

另外确认 P1 的目标**没有**被误豁免（下面两条应该都能命中）：

```bash
bash ./scripts/check-ios-typography.sh 2>&1 \
  | grep -E 'WorkspaceRootView.swift:494|ProfileRootView.swift:177'
```

---

### 6.5 P2 验证

```bash
# 门禁自检：改之前跑一次应该失败，改完跑一次应该通过
bash ./scripts/check-ios-typography.sh
```

**出图验收（必做）**：9pt→11pt 那 7 处和 5/7/8pt 那 3 处是本阶段视觉变化最大的地方。逐个截图对比，重点看：

- 徽章/角标有没有被文字撑破
- 密集列表行的行高有没有跳变
- 原本刻意做小的次级信息有没有变得喧宾夺主

**完成标准**：门禁通过，且上述三类问题一个都没有。

---

## 第 7 章　P3：几何 token（现状对照表已交付，勿重做）

**Issue 标题建议**：`建立间距与圆角 token，收敛调用点字面量`
**分支**：`codex/gh-<编号>-geometry-tokens`
**前置**：P2 必须已合并
**风险**：低—中

> **本章已于 2026-09-19 重写。** 上一版把目标定成「归并 20 个局部尺寸枚举」，那是错的：
> 枚举不是问题所在，动它们反而会拆掉正在正常工作的东西。如果你看到的还是旧版
> （标题写着「几何 token 归并」、要求你产出对照表、风险标「中高」），说明文档没更新到位，
> 以本章为准。

---

### 7.1 先读这一节：上一版错在哪

旧版第 7 章要求执行模型「先产出 20 个枚举的现状对照表，再把它们归并成一套 token」，
并给了归档规则：间距归 4 的倍数、圆角归 4 档。

**对照表现在已经产出（见 7.2），套上去发现归档规则会造成实际损害：**

- `tableWidthThreshold = 600`、`minimumContainerWidth = 860`、`nameDisclosureMinimumWidth = 640`
  是**设备宽度断点**。把它们归到间距刻度，布局判定直接改变。P0 阶段刚因为这个阈值失准
  让工作区胶囊名彻底消失过一次——这不是假想风险。
- `minimumHitTarget = 44` 是 Apple 的最小命中尺寸，不是「间距档位 44」。
- `standardRowHeight = 52` / `deviceRowHeight = 64` / `accessibilityRowHeight = 76` 是一个行高族，
  彼此相差 12 是有意的。拆进通用间距刻度，这个关系就没了。

**更根本的一处混淆**：本文档 1.3 节量出的「间距 31 档、圆角 20 档」是**全仓调用点字面量**
的统计，不是这些枚举的统计。枚举本身相当克制——真·间距只有 24 个值、其中仅 7 个离开 4pt 网格，
真·圆角只有 4 个值。

**结论：散乱在没有名字的调用点字面量里，不在枚举里。** 本章因此不再动枚举结构。

---

### 7.2 现状对照表（已交付，不要重新生成）

14 个常量表，共 73 个数值常量。另有 6 个只有计算属性、没有数值常量的布局值类型
（`ModelReasoningGridLayout`、`WorkbenchSidebarContentLayout`、`WorkbenchLayout`、
`ConversationTimelineScrollMetrics`、`CodexUsageRingMetrics`、`ConnectionPrimaryActionsLayout`），
本章完全不涉及它们。

按语义分类：

| 类别 | 个数 | 取值 | 本章是否处理 |
|---|---|---|---|
| 阈值 / 断点 | 14 | 600, 860, 480, 640, 640, 820, 920, 560, 380, 240, 440, 300, 112, 34 | ❌ **禁止改动** |
| 组件固有尺寸 | 30 | 44, 56, 52, 64, 76, 28, 40, 54, 36, 72, 30, 20, 19, 86, 4, 22, 15, 18, 32, 16… | ❌ **禁止改动** |
| 命中区 | 2 | 44, 44 | ❌ **禁止改动** |
| **真·间距 / 内边距** | 24 | 0,3,6,6,6,8,8,8,8,10,12,12,12,14,16,16,20,20,20,20,22,24,24,24 | ✅ |
| **真·圆角** | 4 | 12, 16, 18, 22 | ✅ |

**73 个里只有 28 个在本章范围内。**

复核命令（只用于核对，不要据此重新分类）：

```bash
cd ios/MimiRemote
for n in ListMetrics ModelReasoningGridMetrics SessionIndexRowDensity SettingsChoiceMetrics \
         SettingsLayoutMetrics TokenActivityGridMetrics WorkbenchChromeIconMetrics \
         WorkbenchPageLayout WorkbenchSidebarSurfaceMetrics WorkspaceIconStylePickerLayout \
         WorkspaceSessionFabMetrics WorkspaceSessionRowMetrics WorkspaceStripLayout \
         ConversationLayout; do
  echo "=== $n ==="
  grep -rn "\(enum\|struct\) $n\b" -A 80 Sources --include='*.swift' \
    | grep -oE 'static (let|var) \w+: CGFloat = [0-9.]+' | head -20
done
```

> ⚠️ 用 `grep -A <n>` 取声明体会**串读相邻声明**。`WorkbenchChrome.swift` 里
> `WorkbenchChromeIconMetrics` / `WorkbenchPageLayout` / `WorkbenchSidebarSurfaceMetrics` /
> `WorkbenchLayout` 四个挨在一起，`WorkspaceSessionPresentation.swift` 里
> `WorkspaceSessionFabMetrics` / `WorkspaceSessionRowMetrics` 挨在一起。上表是用花括号配对
> 提取的，准确；如果你自己重跑 grep 得到不同数字，那是串读，不是上表有误。

---

### 7.3 三步改动

#### 步骤 ①　建 token（只覆盖 28 个）

新建 `Sources/Core/Interaction/MimiGeometry.swift`（与 `MimiMotion` 同层——它们是同一类东西：
全项目共用的设计基元）。

```swift
import CoreGraphics

/// 全项目共用的间距与圆角刻度。
///
/// 这套刻度**只**覆盖间距和圆角。断点（`tableWidthThreshold`）、组件固有尺寸
/// （`standardRowHeight`）、命中区（`minimumHitTarget`）都不在这里——它们各自属于
/// 具体组件的词汇表，通用刻度表达不了它们之间的关系。
enum MimiGeometry {
    /// 间距刻度。档位由现存 24 个真实取值的分布定出，不是拍脑袋的等比数列。
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 20
        static let xl: CGFloat = 24
    }

    /// 圆角刻度。现状本来就是 4 档，这里只是固化，不做归并。
    /// 四档对应四种承载物，从控件到浮层逐级放大。
    enum Radius {
        /// 行内控件、胶囊
        static let control: CGFloat = 12
        /// 分组面板
        static let panel: CGFloat = 16
        /// 侧栏等浮起材质
        static let surface: CGFloat = 18
        /// 内容主面板
        static let content: CGFloat = 22
    }
}
```

新增文件后**必须**执行 `cd ios/MimiRemote && xcodegen generate`，否则文件不进 target。

#### 步骤 ②　7 个离网间距值逐个判定

24 个间距值里有 7 个不在 4pt 网格上，**每一个都要单独看上下文，不要机械归档**：

| 常量 | 值 | 所在 | 判定要点 |
|---|---|---|---|
| `markerContentSpacing` | 6 | `ListMetrics` | Markdown 列表 marker 与正文的间距。归 8 会让列表明显变松，归 4 会挤。**先出图对比再定** |
| `sectionHeaderBottomSpacing` | 6 | `WorkspaceSessionRowMetrics` | 小节标题到首行的距离。与 `sectionBoundarySpacing=22` 是一对，要一起调 |
| `sectionBoundarySpacing` | 22 | `WorkspaceSessionRowMetrics` | 归 `xl`(24)。与上一条配对验证 |
| `spacing` | 3 | `TokenActivityGridMetrics` | 热力图格距，**很可能是有意做紧的**。归 4 会让整张图变宽，可能撑破 `totalHeight=86`。**倾向保留，加注释说明** |
| `controlPadding` | 10 | `WorkbenchPageLayout` | 归 `s`(12) |
| `groupedPanelPadding` | 14 | `WorkbenchPageLayout` | 归 `m`(16) |
| `compactHostSwitcherCenterOffset` | 0 | `WorkbenchChromeIconMetrics` | 0 是「不偏移」，不是间距档位。**保持字面量 0** |

**规则未覆盖时怎么办**：以上任何一条出图后觉得变化明显，停下来问用户，不要自行在档位之间反复试。

#### 步骤 ③　枚举内部改引用 token

枚举的**名字、结构、成员全部保留**，只把那 28 个成员的右值换成 token 引用：

```swift
enum WorkspaceStripLayout {
    // 引用 token 的（间距/圆角）
    static let chipSpacing = MimiGeometry.Spacing.xs          // 原 8
    static let horizontalPadding = MimiGeometry.Spacing.xl    // 原 24

    // 保持原样的（固有尺寸）
    static let chipHeight: CGFloat = 44
    static let stripHeight: CGFloat = 56
    static let chipIconSize: CGFloat = 28
    static let addChipVisualSize: CGFloat = 34
    static let restingNameWidth: CGFloat = 64

    // 保持原样的（断点）——注释里的实测依据必须保留
    static let maxContentWidth: CGFloat = 920
    static let inlineRuntimePickerMinimumWidth: CGFloat = 640
    static let nameDisclosureMinimumWidth: CGFloat = 640
}
```

**禁止改动清单（本章最重要的一节）**：

- 任何名字里含 `Threshold`、`MinimumWidth`、`MaximumWidth`、`minimumContainer`、`maxContent` 的常量
- 任何值为 44 且名字含 `HitTarget` 的常量
- `standardRowHeight` / `deviceRowHeight` / `accessibilityRowHeight` 三个一组
- `symbolSize` / `symbolFrame` / `symbolPointSize` / `iconSlot` / `toolbarCircleDiameter`
- `diameter` / `inlineDiameter`（FAB 尺寸）
- 6 个无数值常量的布局值类型，整个不碰
- P0 阶段在 `WorkspaceStripPresentation.swift` 写下的实测宽度注释表，**一个字都不要删**

---

### 7.4 步骤 ④　门禁：只管调用点，不管枚举

这一步才是真正减少散乱的地方——1.3 节量的 31 档间距、20 档圆角都在调用点。

扩展 `scripts/check-ios-typography.sh`，或新建 `scripts/check-ios-geometry.sh`：

- `cornerRadius:` 后面只允许跟 `MimiGeometry.Radius.*` 或某个 `*Metrics/*Layout` 成员，不允许裸字面量
- `.padding(...)` / `spacing:` 的裸字面量必须是 4 的倍数，或引用 token / 枚举成员
- **枚举定义所在的文件整体豁免**——它们是 token 的消费者和固有尺寸的持有者，不该受调用点规则约束

豁免表沿用 P2 的两级粒度（文件级 + 行级），每条写原因。

**门禁必须在步骤 ①②③ 全部完成后才接入 CI**，中途接入会一直挂红。

---

### 7.5 分批推进

调用点收敛涉及面广，按页面分批，每批一个 commit，每批出图：

1. 工作区页（`Features/Projects/`）——P0 刚改过，最熟悉
2. 会话列表（`Features/Sessions/`）
3. 设置页（`Features/Settings/`）
4. 会话详情（`Features/Conversation/`）——最敏感，放最后
5. 壳层与其余（`Features/Shell/`、`WorkbenchChrome.swift`）

每批确认：iPad 横屏 / iPad 竖屏 / iPhone 竖屏三种布局下没有元素重叠、留白塌陷或圆角倒挂。

> ⚠️ **圆角倒挂是硬约束**：嵌套容器必须外大内小，否则内层顶破外层圆弧。
> 四档 `control(12) < panel(16) < surface(18) < content(22)` 本身是升序的，
> 但要确认实际嵌套关系没有「外层用 control、内层用 content」这种倒置。发现倒置**停下来问用户**，
> 不要自行调整档位定义。

---

### 7.6 P3 完成标准

- `MimiGeometry.swift` 建立并进入 target（`xcodegen generate` 已跑）
- 28 个真·间距/圆角成员引用 token；7 个离网值各有明确判定与注释
- 禁止改动清单里的常量**一个都没变**（用 `git diff` 逐条核对）
- 调用点裸 `cornerRadius:` 字面量归零，`.padding()` 字面量全部落 4pt 网格或引用具名值
- 门禁接入 CI 且通过
- 5 个批次各自出图验收通过
- 全量测试失败集合相对基线**没有变大**（判读法见 1.1 节与 P2 的验证一节；注意用例级与断言级两个计数口径不能混比）

## 第 8 章　P4：壳层信息架构（只给方向，不给施工图）

**状态**：**未定方案，不要开始实现。**
**前置**：P3 合并，且**用户已就本章的三个决策点拍板**。

---

### 8.1 为什么这一章没有施工图

前面三个阶段都是「有唯一正确答案」的任务——档位表已存在、4pt 网格是行业标准、圆角倒挂有硬约束。执行模型可以靠规则推进。

这一章不同。它要回答的是产品问题：

- 顶栏应该放什么？
- 侧栏应该表达「导航模式」还是「对象模型」？
- 用户打开 App 第一屏应该落在哪里？

这些没有技术上的正确答案，**必须由用户决定**。执行模型在这一章的任务是**提供选项和代价分析**，不是做决定。

---

### 8.2 已识别的问题（事实部分）

**问题 1：顶栏同高度并存 5 种控件语言**

在 iPad 横屏工作区页，顶部一条水平带里同时有：

1. 连接状态胶囊（「这台电脑 / 已连接」，带绿点）
2. 侧栏开关按钮
3. 工作区标签条（头像胶囊 + 名称）
4. 「+」虚线圆（添加工作区）
5. Codex | Claude 分段控件（Runtime 筛选）

这五者分属不同层级（设备 / 视图 / 对象 / 创建动作 / 过滤器），但视觉上等重并排，用户无法从布局推断层级。

**问题 2：`UnifiedWorkbenchShell.swift` 是 1791 行的单个 View**

```bash
wc -l ios/MimiRemote/Sources/Features/Shell/UnifiedWorkbenchShell.swift   # 1791
```

壳层没有被拆解，就没有一个地方在做「信息层级」这个决策。每个控件各自长出来，这是问题 1 的结构性成因。

**问题 3：图标语言 5 套并存**

| 来源 | 规模 | 复核 |
|---|---|---|
| SF Symbols | 234 处 | `grep -rho 'systemName:' ios/MimiRemote/Sources --include='*.swift' \| wc -l` |
| 工作区角色插画 | 129 个 imageset | `ls ios/MimiRemote/Resources/Assets.xcassets/WorkspaceCharacters \| wc -l` |
| emoji | 用户自选 | — |
| 自定义 Shape 图标 | 7 个类型 | `grep -rlE 'struct \w+(Icon\|Glyph\|Badge\|Mark)\b' ios/MimiRemote/Sources --include='*.swift'` |
| 品牌资产 imageset | Claude / OpenAI / GitHub / Linux | `ls ios/MimiRemote/Resources/Assets.xcassets` |

**注意**：129 个插画是工作区头像的个性化池子，**这是产品功能，不是设计债**，不要提议删掉它们。要收敛的是**导航和控件**里的图标语言，不是用户自选的头像。

**问题 4：状态槽的空心虚线环被读成「未完成」**

`SessionIndexRow` 的 idle 占位（`showsIdleStateGlyph: true`）给每一行都画了一枚灰环，设计意图是「让前导列每行都有内容，好当小节标题的对齐基准线」（见 `WorkspaceDetailView.swift:327-328` 的注释）。

但用户读到的是「一堆没做完的待办」。**设计意图和实际读法背离**，这是需要用户确认的取舍，不是 bug。

---

### 8.3 三个待决策点（提交给用户，不要自行选择）

**决策点 A：侧栏表达什么？**

| 选项 | 说明 | 代价 |
|---|---|---|
| A1 保持现状 | 侧栏 = 导航模式（会话 / 工作区两个 tab）+ 最近列表 | 零 |
| A2 改为对象模型 | 侧栏 = 工作区树，每个工作区下挂会话，可展开、可就地新建 | 大。需重做侧栏数据源与状态管理 |
| A3 折中 | 保留两个 tab，但工作区 tab 的侧栏改为可展开树 | 中 |

> 背景：已归档的「工作区页方案 C」决策要求**保留三 tab**，且控制层用扁平磨砂不用 Liquid Glass（用户明确要求）。A2 与「保留三 tab」可能冲突，选之前需确认。

**决策点 B：顶栏收敛到什么程度？**

| 选项 | 说明 |
|---|---|
| B1 只留内容标题 | 工作区切换移入侧栏，Runtime 筛选移入设置或会话内 |
| B2 留内容标题 + 工作区切换 | Runtime 筛选移走 |
| B3 保持现状但做视觉分层 | 用材质/尺寸把 5 种控件分出主次，不改功能位置 |

**决策点 C：idle 状态环去留？**

| 选项 | 说明 | 副作用 |
|---|---|---|
| C1 保留 | 维持对齐基准线 | 继续被读成「待办」 |
| C2 去掉 | 消除误读 | 小节标题失去对齐基准，需另找基准线（见 `WorkspaceDetailView.swift:224-226` 注释说明的历史问题） |
| C3 换形态 | 改成极淡的点或留白占位，保留占位但不画环 | 需重新验证色觉障碍下的可读性 |

---

### 8.4 本章的正确推进方式

1. 执行模型把 8.2（事实）和 8.3（选项）整理后交给用户。
2. 用户就 A / B / C 三点各选一个。
3. **用户拍板后，再写 P4 的施工图**，重新走一遍本文档 P0–P3 的详细程度。
4. 拆 `UnifiedWorkbenchShell.swift` 是 P4 的前置技术工作，可以在决策未定时先做——**纯拆分、不改行为**，用 `scripts/check-source-size.sh` 验证。

---

## 附录 A　一页速查

### A.1 关键数字

```
187 个 Swift 文件 / 113,993 行
字号档位表：11 12 13 15 16 17 20 22 28 34（ThemeStore.swift:773）
fontScale 范围：0.85 – 1.35，默认 1.0，小屏 iPad 默认 1.10
当前字号档位：26（目标 10）
当前圆角档位：20（目标 4）
当前间距档位：31（目标 全部落 4pt 网格）
局部尺寸枚举：20 个（目标 归并到 1 套 token + 保留各自的布局策略）
```

### A.2 全部复核命令

```bash
cd ios/MimiRemote

# 规模
find Sources -name '*.swift' | wc -l
find Sources -name '*.swift' -exec cat {} + | wc -l

# 字号
grep -rhoE 'uiFont\(size: [0-9.]+' Sources --include='*.swift' | grep -oE '[0-9.]+' | sort -g | uniq -c
grep -rhoE 'uiFont\(\.[a-zA-Z0-9]+' Sources --include='*.swift' | sort | uniq -c | sort -rn
grep -rn '\.system(size:' Sources --include='*.swift' | grep -v ThemeStore.swift | wc -l

# 图标缩放两派
grep -rn 'Image(systemName' -A 1 Sources --include='*.swift' | grep -c 'uiFont'
grep -rn 'Image(systemName' -A 1 Sources --include='*.swift' | grep -c 'system(size:'

# 圆角与间距
grep -rhoE 'cornerRadius: [0-9.]+' Sources --include='*.swift' | grep -oE '[0-9.]+' | sort -gu
grep -rhoE '\bspacing: [0-9.]+' Sources --include='*.swift' | grep -oE '[0-9.]+' | sort -gu

# 局部尺寸枚举
grep -rhoE '(enum|struct) \w*(Metrics|Layout|Density|Dimensions)\b' Sources --include='*.swift' | sort -u
```

### A.3 每个阶段的一句话

| 阶段 | 一句话 | 完成标准 |
|---|---|---|
| P0 | 修 4 个截图里一眼可见的布局缺陷 | 胶囊名不截断、左缘对齐、无孤立分界线、无冗余身份列 |
| P1 | 让 43 处不跟随字号设置的图标跟上 | 字号拉到 1.35 时所有图标等比变大 |
| P2 | 38 处表外字号归档 + 门禁 | `check-ios-typography.sh` 通过 |
| P3 | 建间距/圆角 token（只覆盖 73 个常量里的 28 个），收敛调用点字面量 | 调用点圆角字面量归零，间距全在 4pt 网格；禁改清单一条未动 |
| P4 | 壳层信息架构 | **待用户决策，暂不实现** |

---

## 附录 B　这份方案纠正了此前分析里的哪些结论

如果你读过更早的那版分析，以下结论**已被实测推翻**，以本文档为准：

| 旧结论 | 实测 | 影响 |
|---|---|---|
| 「字体没有 type scale」 | **错。** `ThemeStore.swift:718` 有语义 API，`:773` 有 10 档标准表，全仓用了 428 次，是主力写法 | 工作量从「新建一层」降为「归位 38 处 + 加门禁」 |
| 「设计系统只建了一半」 | **不准确。** 几何层不是没建，是建成了 20 套互不相识的局部枚举 | 动作从「新建」改为「归并」，风险等级上调 |
| 「68 处 `.system(size:)` 都绕过缩放，用户拖字号纹丝不动」 | **大幅高估。** 68 处里 8 处 `scaled()` 已正确、14 处是分享海报比例、2 处随容器推导、1 处 emoji 填格——真正该改的是 33 处（28 图标 + 5 文字） | P1 范围缩小，但**图标两派分裂（113 vs 43）这个更清晰的问题被识别出来**，仍是唯一的功能性缺陷 |
| 「14 种圆角」 | **低估。** 实际 20 种 | P3 工作量上调 |
| 「间距 25 档，1/3/5/7/9/11/13/15/17 都在用」 | **数偏低且例子有误。** 实际 31 档，13 和 17 并不在用 | 归档清单以本文档 1.3 节为准 |
| 「#465 已归档」 | **错。** #465 是 OPEN | 不要当成已完成的先例引用 |
| 「P3 = 归并 20 个 Metrics 枚举」 | **瞄错靶子。** 对照表显示 14 个常量表共 73 个数值常量，其中只有 28 个是真·间距/圆角；其余 14 个是设备断点、30 个是组件固有尺寸、2 个是命中区，归档规则套上去会改变布局判定 | 第 7 章已于 2026-09-19 重写：不动枚举结构，只建 token + 收敛调用点，风险从「中高」降到「低—中」 |
| 「间距 31 档、圆角 20 档」＝枚举的问题 | **口径混淆。** 那是全仓**调用点裸字面量**的统计；枚举里真·间距只有 24 个值、仅 7 个离网，真·圆角只有 4 个值 | 收敛目标从枚举改为调用点 |
