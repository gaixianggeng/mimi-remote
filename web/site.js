/* Mimi Remote — site behaviour. Four small jobs, no framework:
     1. language     [data-i18n] / [data-i18n-alt] / [data-i18n-label] / [data-href-zh]
     2. appearance   light <-> dark, remembered; follows the system until chosen
     3. screenshots  [data-shot="name"] -> ./assets/shots/name-<zh|en>-<light|dark>.webp
                     ([data-shot-theme] pins one appearance regardless of the page's)
     4. polish       header hairline + reveal-on-scroll

   English lives in index.html and is read back from the markup on load, so each
   language has exactly one source. Screenshots come from web/capture-screenshots.sh. */
(function () {
  "use strict";

  var LANG_KEY = "mimi-lang";
  var THEME_KEY = "mimi-theme";
  var root = document.documentElement;

  /* ---------------------------------------------------------- 1. language */

  var ZH = {
    "meta.title": "Mimi Remote — 离开电脑，会话不断",
    "meta.description": "Mimi Remote 是 Codex 与 Claude Code 的原生 iPhone、iPad 客户端：在任何地方接着电脑上的会话，Agent 需要你时及时提醒，内置 Tailcat 随时连回电脑。",

    "skip": "跳到正文",

    "nav.handoff": "接力",
    "nav.devices": "多设备",
    "nav.connect": "连接",
    "nav.notify": "通知",
    "nav.design": "设计",
    "nav.get": "下载",

    "hero.eyebrow": "为 Codex 与 Claude Code 打造",
    "hero.title": "离开电脑，<br>会话不断。",
    "hero.lede": "Mimi Remote 是 Codex 与 Claude Code 的原生 iPhone、iPad 客户端。任务继续在你的电脑上运行，你在任何地方都能跟进进度、继续对话、处理审批。",
    "cta.appstore": "在 App Store 下载",
    "cta.testflight": "加入 TestFlight 测试",
    "cta.host": "下载电脑端",
    "hero.meta": "iPhone 与 iPad · 支持 Mac、Windows、Linux 电脑 · 开源",

    "overview.title": "为离开电脑的每个时刻<br>而设计。",
    "ov.1.t": "无缝接力",
    "ov.1.n": "Codex 会话在电脑与手机之间接力，上下文完整保留。",
    "ov.2.t": "多台电脑",
    "ov.2.n": "Mac、Windows、Linux 各自保存，轻点即可切换。",
    "ov.3.t": "内置 Tailcat",
    "ov.3.n": "不用另装 VPN App，在任何网络都能连回电脑。",
    "ov.4.t": "及时通知",
    "ov.4.n": "审批、回复与失败，锁屏第一时间提醒。",
    "ov.5.t": "顺手好用",
    "ov.5.n": "审批、排队、切换模型，都在输入框旁边。",
    "ov.6.t": "精致好看",
    "ov.6.n": "为 iPhone 与 iPad 分别打磨，深浅色同样用心。",

    "handoff.eyebrow": "无缝接力",
    "handoff.title": "在电脑上开始，<br>在手机上接着聊。",
    "handoff.body": "Mimi 与 Codex Desktop、Codex CLI 连接同一个 App Server。在任何一端开始的会话，另一端都能直接打开——历史、上下文和正在运行的任务一样不少。不用复制粘贴，也不用重新交代背景。",
    "term.user": "帮我检查这次 README 改动，确认安装步骤和安全边界与代码一致。",
    "term.agent": "我会核对源码构建和配对流程，并把主运行时与可选运行时的边界拆开说明。",
    "handoff.link": "同一个会话",
    "handoff.chip1": "历史完整",
    "handoff.chip2": "进度实时同步",
    "handoff.chip3": "Claude Code 同样适用",
    "handoff.fine": "与 Codex Desktop、CLI 共享会话目前支持 Mac 与 Linux 电脑。",

    "devices.eyebrow": "多设备",
    "devices.title": "一部手机，<br>管好每一台电脑。",
    "devices.body": "家里的 Mac Studio、出差带的 MacBook、公司的 Windows 工作站，各自保存为独立连接，凭据分别存进钥匙串。轻点一下就能切换；iPad 上能力完全一致，布局更宽。",
    "devices.mac": "菜单栏 App，服务状态、额度与配对一目了然。",
    "devices.win": "托盘 App 与用户级服务，支持 Windows 10 / 11。",
    "devices.linux": "桌面托盘与 systemd 用户服务。",

    "connect.eyebrow": "远程连接",
    "connect.title": "在哪里，<br>都能连回电脑。",
    "connect.body": "Mimi 内置 Tailcat。在电脑上生成二维码，用手机扫一下就完成配对，不用另装 VPN App。网络允许时点对点直连，不允许时自动走加密中转；私钥始终只留在你自己的设备里。",
    "route.tc": "内置，扫码一次，之后在任何网络都能连。",
    "route.ts": "已经在用 tailnet？直接连就行。",
    "route.lan.t": "局域网",
    "route.lan": "同一网络下直接连接，不需要任何额外设置。",
    "route.direct": "点对点直连",
    "route.relay": "必要时经加密中转",
    "route.computer": "你的电脑",

    "notify.eyebrow": "通知",
    "notify.title": "需要你的时候，<br>第一时间知道。",
    "notify.body": "Agent 想运行命令、修改文件或需要你补充信息时，带着会话标题的通知会直接送达；任务回复、失败或中断也会及时提醒。审批在通知里就能允许或拒绝。",
    "notify.privacy": "默认关闭。开启后，离开电脑的只有固定格式的状态信息，不含你的代码、提示词或对话；会话标题在手机本地补全。",
    "lock.date": "9月12日 星期六",
    "lock.now": "现在",
    "lock.n1.t": "整理开源发布说明",
    "lock.n1.b": "Codex 在 Demo Mac Studio 上等待审批 · 运行命令",
    "lock.allow": "仅允许一次",
    "lock.deny": "拒绝",
    "lock.n2.t": "检查连接恢复测试",
    "lock.n2.time": "2 分钟前",
    "lock.n2.b": "已回复，点按查看。",
    "lock.n3.t": "完善示例项目文档",
    "lock.n3.time": "18 分钟前",
    "lock.n3.b": "任务未能完成，点按查看原因。",

    "easy.eyebrow": "好用",
    "easy.title": "复杂的工作，<br>在手机上也轻松。",
    "easy.body": "消息、推理、命令、工具调用与审批，整理成一条清晰易读的时间线。模型、推理强度、Skill、权限和排队中的下一步，都在输入框旁边。",
    "mini.1.t": "就地审批",
    "mini.1.n": "仅一次、本会话或始终允许，不用离开当前会话。",
    "mini.2.t": "排队下一步",
    "mini.2.n": "当前任务还在运行，就能把后续指令排进队列。",
    "mini.3.t": "随时切换模型",
    "mini.3.n": "每一轮都能调整模型、推理强度和速度。",
    "mini.4.t": "语音、图片与文件",
    "mini.4.n": "语音输入、附上截图，用快速查看预览文件。",
    "mini.5.t": "断线自动恢复",
    "mini.5.n": "自动重连，诊断信息一点即看。",
    "mini.6.t": "需要时也能用 Git",
    "mini.6.n": "查看 Diff、管理 Worktree，提交并创建草稿 PR。",

    "design.eyebrow": "好看",
    "design.title": "为 iPhone 打磨，<br>也为 iPad 打磨。",
    "design.body": "从里到外都是原生 SwiftUI。iPhone 单手就能够到一切，iPad 把同样的会话展开成多栏工作台。浅色和深色同样用心，还有多套主题与工作区图标，调成你喜欢的样子。",
    "design.legend": "浅色与深色 · 多套主题 · 工作区图标",
    "design.try": "切换本页深浅色",

    "trust.1.t": "开源",
    "trust.1.n": "App、电脑端服务与 Claude 桥接，代码全部公开在 GitHub。",
    "trust.2.t": "数据留在你的电脑",
    "trust.2.n": "项目文件、会话历史和运行时凭据，都留在你自己的电脑上。",
    "trust.3.t": "沿用你的 Agent 账号",
    "trust.3.n": "直接使用电脑上已登录的 Codex 或 Claude Code，Mimi 不接触这些凭据。",

    "final.title": "把你的 Agent 带在身边。",
    "final.sub": "需要 iOS / iPadOS 18 或更高版本，以及一台装有 Codex CLI 的 Mac、Windows 或 Linux 电脑。",

    "footer.docs": "文档",
    "footer.privacy": "隐私",
    "footer.terms": "条款",
    "footer.support": "支持",
    "footer.fine": "Mimi Remote 是独立的开源项目，与 OpenAI、Anthropic、Tailscale 均无关联。",

    "alt.heroIpad": "iPad 上的 Mimi Remote：左侧是会话侧栏，右侧对话正在等待审批。",
    "alt.heroPhone": "iPhone 上的会话列表，进行中的任务排在最上方。",
    "alt.handoff": "同一段对话，在 iPhone 上接着进行。",
    "alt.devices": "iPhone 上的「Mac 连接」页面，列出两台已保存的电脑。",
    "alt.easy": "对话中的审批卡片：拒绝、仅允许一次、本会话允许、始终允许此工具。",
    "alt.designLight": "浅色模式下 iPhone 的工作区。",
    "alt.designIpad": "iPad 上的工作区视图。",
    "alt.designDark": "深色模式下 iPhone 的会话列表。",

    "label.diagram": "手机与电脑点对点直连；无法直连时自动改走加密中转。",
    "label.lock": "锁屏上的 Mimi Remote 通知：一条带「仅允许一次」和「拒绝」的审批请求、一条已回复提醒，以及一条任务未完成提醒。",
    "label.trust": "开源与隐私"
  };

  var EN = {};   /* filled from the markup by captureEnglish() */

  var LANG_LABEL = { en: "中文", zh: "EN" };            /* the button names the *other* language */
  var LANG_ARIA  = { en: "切换到中文", zh: "Switch to English" };
  var THEME_ARIA = {
    en: { light: "Switch to dark appearance", dark: "Switch to light appearance" },
    zh: { light: "切换到深色外观", dark: "切换到浅色外观" }
  };

  var lang  = root.getAttribute("data-lang") === "zh" ? "zh" : "en";
  var theme = root.getAttribute("data-theme") === "dark" ? "dark" : "light";
  var metaDescription = document.querySelector('meta[name="description"]');

  function each(selector, fn) {
    Array.prototype.forEach.call(document.querySelectorAll(selector), fn);
  }
  function readStored(key, allowed) {
    try {
      var v = localStorage.getItem(key);
      return allowed.indexOf(v) > -1 ? v : null;
    } catch (e) { return null; }
  }
  function store(key, value) {
    try { localStorage.setItem(key, value); } catch (e) {}
  }

  function captureEnglish() {
    EN["meta.title"] = document.title;
    if (metaDescription) EN["meta.description"] = metaDescription.getAttribute("content");
    each("[data-i18n]", function (el) { EN[el.getAttribute("data-i18n")] = el.innerHTML; });
    each("[data-i18n-alt]", function (el) { EN[el.getAttribute("data-i18n-alt")] = el.getAttribute("alt"); });
    each("[data-i18n-label]", function (el) { EN[el.getAttribute("data-i18n-label")] = el.getAttribute("aria-label"); });
    each("[data-href-zh]", function (el) { el.setAttribute("data-href-en", el.getAttribute("href")); });
  }

  function applyLang(next, remember) {
    lang = next;
    var dict = lang === "zh" ? ZH : EN;

    root.setAttribute("data-lang", lang);
    root.setAttribute("lang", lang === "zh" ? "zh-Hans" : "en");
    document.title = dict["meta.title"];
    if (metaDescription) metaDescription.setAttribute("content", dict["meta.description"]);

    each("[data-i18n]", function (el) {
      var v = dict[el.getAttribute("data-i18n")];
      if (v != null && el.innerHTML !== v) el.innerHTML = v;
    });
    each("[data-i18n-alt]", function (el) {
      var v = dict[el.getAttribute("data-i18n-alt")];
      if (v != null) el.setAttribute("alt", v);
    });
    each("[data-i18n-label]", function (el) {
      var v = dict[el.getAttribute("data-i18n-label")];
      if (v != null) el.setAttribute("aria-label", v);
    });
    each("[data-href-zh]", function (el) {
      el.setAttribute("href", el.getAttribute(lang === "zh" ? "data-href-zh" : "data-href-en"));
    });
    each("[data-lang-toggle]", function (btn) {
      btn.textContent = LANG_LABEL[lang];
      btn.setAttribute("aria-label", LANG_ARIA[lang]);
    });

    labelThemeToggles();
    paintShots();
    if (remember) store(LANG_KEY, lang);
  }

  /* ------------------------------------------------------- 2. appearance */

  function labelThemeToggles() {
    each("[data-theme-toggle]", function (btn) {
      /* text buttons carry their own translated label */
      if (!btn.hasAttribute("data-i18n")) btn.setAttribute("aria-label", THEME_ARIA[lang][theme]);
    });
  }

  function applyTheme(next, remember) {
    theme = next;
    root.setAttribute("data-theme", theme);
    labelThemeToggles();
    paintShots();
    if (remember) store(THEME_KEY, theme);
  }

  /* ------------------------------------------------------ 3. screenshots */

  function paintShots() {
    each("[data-shot]", function (img) {
      var t = img.getAttribute("data-shot-theme") || theme;
      var src = "./assets/shots/" + img.getAttribute("data-shot") + "-" + lang + "-" + t + ".webp";
      if (img.getAttribute("src") !== src) img.setAttribute("src", src);
    });
  }

  /* ----------------------------------------------------------- 4. polish */

  /* One scroll listener drives both the header hairline and the reveals.
     Reveals are a plain "is its top above the fold yet?" sweep rather than an
     IntersectionObserver: a fast flick or an anchor jump can carry an element
     past the viewport without crossing a threshold, and an observer would then
     never fire, leaving that section invisible. */
  function polish() {
    var header = document.querySelector("[data-header]");
    var pending = root.classList.contains("has-reveal")
      ? Array.prototype.slice.call(document.querySelectorAll(".reveal"))
      : [];
    var ticking = false;

    function update() {
      ticking = false;
      if (header) header.classList.toggle("is-scrolled", window.scrollY > 4);
      if (pending.length) {
        var fold = window.innerHeight * 0.92;
        pending = pending.filter(function (el) {
          if (el.getBoundingClientRect().top >= fold) return true;
          el.classList.add("is-in");
          return false;
        });
      }
    }
    function schedule() {
      if (!ticking) { ticking = true; requestAnimationFrame(update); }
    }

    addEventListener("scroll", schedule, { passive: true });
    addEventListener("resize", schedule, { passive: true });
    update();
  }

  /* -------------------------------------------------------------- start */

  function init() {
    captureEnglish();
    applyLang(lang, false);
    applyTheme(theme, false);

    each("[data-lang-toggle]", function (btn) {
      btn.addEventListener("click", function () { applyLang(lang === "en" ? "zh" : "en", true); });
    });
    each("[data-theme-toggle]", function (btn) {
      btn.addEventListener("click", function () { applyTheme(theme === "light" ? "dark" : "light", true); });
    });

    /* Follow the system until the visitor picks an appearance themselves. */
    if (window.matchMedia && !readStored(THEME_KEY, ["light", "dark"])) {
      var mq = matchMedia("(prefers-color-scheme: dark)");
      var onSystem = function (e) {
        if (!readStored(THEME_KEY, ["light", "dark"])) applyTheme(e.matches ? "dark" : "light", false);
      };
      if (mq.addEventListener) mq.addEventListener("change", onSystem);
      else if (mq.addListener) mq.addListener(onSystem);
    }

    polish();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
