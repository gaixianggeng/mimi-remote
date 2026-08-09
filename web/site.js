/* Mimi Remote — marketing site behaviour.
   Four small jobs, no framework:
     1. language      [data-i18n] / [data-i18n-alt] / [data-i18n-label]
     2. appearance    light <-> dark, remembered, follows the system until chosen
     3. screenshots   [data-shot="name"] -> ./assets/name-<light|dark>.png
     4. polish        scroll-progress hairline + reveal-on-scroll

   Screenshots currently ship in one language. When language-specific captures
   exist, add them to SHOT_LANG below as  shot: { en: "file-base-name" }  and
   they will be picked up for that language automatically. */
(function () {
  "use strict";

  var LANG_KEY  = "mimi-lang";
  var THEME_KEY = "mimi-theme";

  /* ---------------------------------------------------------- 1. language */

  var DICT = {
    en: {
      "skip": "Skip to main content",

      "nav.remote": "Remote",
      "nav.runtimes": "Runtimes",
      "nav.personal": "Personal",
      "nav.cta": "TestFlight",

      "hero.eyebrow": "Coding agents, on the go",
      "hero.title": "Your agents.<br>Within reach.",
      "hero.lede": "A native iPhone and iPad client for Codex and Claude Code. Your Mac or Windows PC keeps running the work — Tailscale keeps the link private and fast. Android is coming soon.",
      "hero.cta1": "Join TestFlight",
      "hero.cta2": "View source",
      "hero.meta": "iPhone &amp; iPad · macOS &amp; Windows hosts · Android coming soon · Open source",

      "pillar.1.title": "Remote",
      "pillar.1.note": "A direct Tailscale link to your Mac or Windows PC. Fast, encrypted, and it stays up.",
      "pillar.2.title": "Runtimes",
      "pillar.2.note": "Codex and Claude Code, with sessions and workspaces each getting their own home.",
      "pillar.3.title": "Personal",
      "pillar.3.note": "Themes, workspace faces, and a light and dark mode that both got the same care.",

      "remote.eyebrow": "Remote",
      "remote.title": "A private line to your host.",
      "remote.lede": "Mimi Remote rides your own Tailscale network — a WireGuard tunnel from the device in your hand straight to the Mac or Windows PC doing the work. No relay in the middle, no port forwarding, nothing published to the open internet.",
      "remote.tunnel": "Tailscale · WireGuard",
      "remote.diagramLabel": "iPhone and iPad connect over an encrypted Tailscale tunnel to agentd on macOS or Windows, which runs Codex and Claude Code.",
      "remote.f1.title": "Direct and encrypted",
      "remote.f1.note": "Peer-to-peer WireGuard between your own devices. Keys never leave them, and no third party sits in the path.",
      "remote.f2.title": "Recovers on its own",
      "remote.f2.note": "Drop the signal and nothing is lost. Unsent instructions wait in a queue on the device and go out the moment the link returns.",
      "remote.f3.title": "Works wherever you are",
      "remote.f3.note": "Café Wi-Fi, cellular, a locked-down office network — if both ends are on your tailnet, the session is right there.",

      "devices.eyebrow": "iPhone &amp; iPad",
      "devices.title": "Two screens. Two layouts.",
      "devices.lede": "Not one interface stretched to fit. The iPad gets a standing sidebar with in-progress work and recent history in view; the iPhone gets a single column and a tab bar your thumb can reach.",
      "devices.capPad": "iPad · sidebar and list side by side",
      "devices.capPhone": "iPhone · one column, one thumb",

      "runtimes.eyebrow": "Runtimes",
      "runtimes.title": "Codex and Claude Code, side by side.",
      "runtimes.lede": "Both runtimes are first-class. Pick one when you start a session, and switch which you are looking at without leaving the screen.",
      "runtimes.sessions.head": "Sessions",
      "runtimes.sessions.body": "Every conversation across every project, grouped by when it happened and searchable in one field. Work still running is marked as running.",
      "runtimes.workspaces.head": "Workspaces",
      "runtimes.workspaces.body": "Each repository is a tab of its own, carrying its recent conversations and the branch each one ran on. Starting a new session there takes one tap.",

      "personal.eyebrow": "Personal",
      "personal.title": "Make it look like yours.",
      "personal.lede": "Eight icon sets give every workspace a face you recognise at a glance. Themes reset the whole palette. Light and dark both got the same attention — follow the system, or pin the one you like.",
      "personal.capLight": "Light · icon sets and themes",
      "personal.capDark": "Dark · same care, other end",
      "personal.try": "This page follows the same rule.",
      "personal.tryCta": "Try the other one",

      "footer.eyebrow": "Get early access",
      "footer.title": "Take your coding agents with you.",
      "footer.cta1": "Join TestFlight",
      "footer.cta2": "View source",
      "footer.docs": "Docs",
      "footer.privacy": "Privacy",
      "footer.fine": "Open-source iPhone and iPad client · macOS and Windows hosts · Android coming soon.",

      "alt.ipadWorkspace": "Mimi Remote's workspace on iPad: a sidebar of sessions and workspaces beside project tabs and recent conversations.",
      "alt.iphoneWorkspace": "The same workspace on iPhone, as a single column with a compact tab bar.",
      "alt.ipadSessions": "The session list on iPad, grouped by day, with the sidebar showing just-finished and recent work.",
      "alt.iphoneSessions": "The same session list on iPhone, one column, with a floating tab bar.",
      "alt.cropSessions": "A close crop of the session list: a day heading with several conversations beneath it.",
      "alt.cropWorkspaces": "A close crop of the workspace tabs, each project carrying its own character icon.",
      "alt.appearance": "The appearance settings on iPhone in light mode: a light/dark selector, eight workspace icon sets, and a list of themes.",
      "alt.meDark": "The same app in dark mode, showing token usage rings, a connected Mac, and the preference list."
    },

    zh: {
      "skip": "跳到主要内容",

      "nav.remote": "远程",
      "nav.runtimes": "运行时",
      "nav.personal": "个性化",
      "nav.cta": "TestFlight",

      "hero.eyebrow": "随身携带的编码 Agent",
      "hero.title": "你的 Agent，<br>触手可及。",
      "hero.lede": "为 iPhone 和 iPad 原生打造的 Codex 与 Claude Code 客户端。任务照旧跑在你的 Mac 或 Windows PC 上，Tailscale 让这条链路既私密又快；Android 即将推出。",
      "hero.cta1": "加入 TestFlight",
      "hero.cta2": "查看源码",
      "hero.meta": "iPhone 与 iPad · macOS 与 Windows 宿主 · Android 即将推出 · 开源",

      "pillar.1.title": "远程",
      "pillar.1.note": "基于 Tailscale 直连你的 Mac 或 Windows PC，快、加密，而且一直在线。",
      "pillar.2.title": "运行时",
      "pillar.2.note": "Codex 与 Claude Code 都支持，会话与工作区各有自己的位置。",
      "pillar.3.title": "个性化",
      "pillar.3.note": "主题、工作区头像，深色与浅色都被同样认真地对待。",

      "remote.eyebrow": "远程",
      "remote.title": "一条通往宿主电脑的私有链路。",
      "remote.lede": "Mimi Remote 走你自己的 Tailscale 网络——从手里的设备直达那台干活的 Mac 或 Windows PC 的 WireGuard 隧道。中间没有转发服务器，不用做端口映射，也不向公网暴露任何东西。",
      "remote.tunnel": "Tailscale · WireGuard",
      "remote.diagramLabel": "iPhone 与 iPad 通过加密的 Tailscale 隧道连到 macOS 或 Windows 上的 agentd，由它运行 Codex 与 Claude Code。",
      "remote.f1.title": "点对点加密直连",
      "remote.f1.note": "在你自己的设备之间建立 WireGuard 直连，密钥不离开设备，链路上也没有第三方。",
      "remote.f2.title": "断了自己会恢复",
      "remote.f2.note": "掉线也不会丢东西。没发出去的指令留在设备的本地队列里，连接一恢复就自动补发。",
      "remote.f3.title": "在哪都能用",
      "remote.f3.note": "咖啡馆 Wi-Fi、蜂窝网络、管得很严的公司网——只要两端都在你的 tailnet 里，会话就在手边。",

      "devices.eyebrow": "iPhone 与 iPad",
      "devices.title": "两块屏幕，两套布局。",
      "devices.lede": "不是把同一套界面拉伸了事。iPad 有常驻侧栏，进行中的任务和最近历史一直在视野里；iPhone 是单列加一条拇指够得到的标签栏。",
      "devices.capPad": "iPad · 侧栏与列表并列",
      "devices.capPhone": "iPhone · 单列，单手",

      "runtimes.eyebrow": "运行时",
      "runtimes.title": "Codex 与 Claude Code，并列支持。",
      "runtimes.lede": "两套运行时都是一等公民。开会话时选一个，想看另一个也不用离开当前页面。",
      "runtimes.sessions.head": "会话",
      "runtimes.sessions.body": "所有项目里的每一次对话，按时间分组，一个搜索框就能找到。还在跑的任务会明确标出来。",
      "runtimes.workspaces.head": "工作区",
      "runtimes.workspaces.body": "每个仓库都是一个独立的标签，带着自己的最近对话和各自所在的分支。在那里新建会话只需一次点按。",

      "personal.eyebrow": "个性化",
      "personal.title": "调成你喜欢的样子。",
      "personal.lede": "八套图标风格，让每个工作区都有一张一眼认得出的脸。主题会换掉整套配色。深色和浅色被同样认真地打磨——跟随系统，或者固定成你偏爱的那一种。",
      "personal.capLight": "浅色 · 图标风格与主题",
      "personal.capDark": "深色 · 同样的用心",
      "personal.try": "这个页面也遵守同一条规矩。",
      "personal.tryCta": "换一种看看",

      "footer.eyebrow": "抢先体验",
      "footer.title": "把你的编码 Agent 带在身边。",
      "footer.cta1": "加入 TestFlight",
      "footer.cta2": "查看源码",
      "footer.docs": "文档",
      "footer.privacy": "隐私",
      "footer.fine": "开源 iPhone 与 iPad 客户端 · macOS 与 Windows 宿主 · Android 即将推出。",

      "alt.ipadWorkspace": "Mimi Remote 在 iPad 上的工作区：侧栏是会话与工作区，右侧是项目标签和最近对话。",
      "alt.iphoneWorkspace": "同一个工作区在 iPhone 上的样子：单列布局，底部是紧凑的标签栏。",
      "alt.ipadSessions": "iPad 上的会话列表，按天分组，侧栏显示刚完成和最近的任务。",
      "alt.iphoneSessions": "同一份会话列表在 iPhone 上：单列，底部悬浮标签栏。",
      "alt.cropSessions": "会话列表的局部特写：一个日期分组下面跟着若干条对话。",
      "alt.cropWorkspaces": "工作区标签的局部特写，每个项目都带着自己的角色头像。",
      "alt.appearance": "iPhone 浅色模式下的外观设置：深浅色选择、八套工作区图标风格，以及主题列表。",
      "alt.meDark": "同一个 App 的深色模式：Token 用量圆环、已连接的 Mac，以及偏好设置列表。"
    }
  };

  /* Optional per-language screenshot overrides, e.g.
       "iphone-sessions": { en: "iphone-sessions-en" }
     Anything not listed here uses the shared capture. */
  var SHOT_LANG = {};

  var LANG_LABEL  = { en: "中文", zh: "EN" };   /* label shows the *other* language */
  var HTML_LANG   = { en: "en", zh: "zh-Hans" };
  var LANG_ARIA   = { en: "Switch to Chinese", zh: "切换到英文" };
  var THEME_ARIA  = { light: "Switch to dark appearance", dark: "切换到浅色外观" };

  var lang  = "en";
  var theme = "light";

  function readStored(key, allowed) {
    try {
      var v = localStorage.getItem(key);
      return allowed.indexOf(v) > -1 ? v : null;
    } catch (e) { return null; }
  }
  function store(key, value) {
    try { localStorage.setItem(key, value); } catch (e) {}
  }

  function detectLang() {
    var saved = readStored(LANG_KEY, ["en", "zh"]);
    if (saved) return saved;
    var list = navigator.languages || [navigator.language || "en"];
    for (var i = 0; i < list.length; i++) {
      if (/^zh\b/i.test(list[i])) return "zh";
      if (/^en\b/i.test(list[i])) return "en";
    }
    return "en";
  }

  function each(selector, fn) {
    Array.prototype.forEach.call(document.querySelectorAll(selector), fn);
  }

  /* ------------------------------------------------------ 3. screenshots */

  function paintShots() {
    each("[data-shot]", function (img) {
      var shot = img.getAttribute("data-shot");
      var override = SHOT_LANG[shot] && SHOT_LANG[shot][lang];
      img.setAttribute("src", "./assets/" + (override || shot) + "-" + theme + ".png");
    });
  }

  function applyLang(next) {
    lang = next;
    var dict = DICT[lang] || DICT.en;

    document.documentElement.setAttribute("lang", HTML_LANG[lang]);
    document.documentElement.setAttribute("data-lang", lang);

    each("[data-i18n]", function (el) {
      var v = dict[el.getAttribute("data-i18n")];
      if (v != null) el.innerHTML = v;
    });
    each("[data-i18n-alt]", function (el) {
      var v = dict[el.getAttribute("data-i18n-alt")];
      if (v != null) el.setAttribute("alt", v);
    });
    each("[data-i18n-label]", function (el) {
      var v = dict[el.getAttribute("data-i18n-label")];
      if (v != null) el.setAttribute("aria-label", v);
    });

    each("[data-lang-toggle]", function (btn) {
      btn.textContent = LANG_LABEL[lang];
      btn.setAttribute("aria-label", LANG_ARIA[lang]);
    });
    each("[data-theme-toggle]", function (btn) {
      if (!btn.hasAttribute("data-i18n")) btn.setAttribute("aria-label", THEME_ARIA[theme]);
    });

    paintShots();
    store(LANG_KEY, lang);
  }

  /* ------------------------------------------------------- 2. appearance */

  function applyTheme(next, remember) {
    theme = next;
    document.documentElement.setAttribute("data-theme", theme);
    each("[data-theme-toggle]", function (btn) {
      if (!btn.hasAttribute("data-i18n")) btn.setAttribute("aria-label", THEME_ARIA[theme]);
    });
    paintShots();
    if (remember) store(THEME_KEY, theme);
  }

  /* ----------------------------------------------------------- 4. polish */

  /* One scroll listener drives both the header hairline and the reveals.
     Reveals are a plain "is its top above the fold yet?" sweep rather than an
     IntersectionObserver: a fast flick or an anchor jump can carry an element
     from below the viewport to above it without crossing a threshold, and an
     observer would then never fire, leaving that section invisible forever. */
  function polish() {
    var bar = document.querySelector("[data-scroll-rule]");
    /* has-reveal is set by the head script only when motion is welcome; without
       it the CSS never hides anything and there is nothing to reveal. */
    var pending = document.documentElement.classList.contains("has-reveal")
      ? Array.prototype.slice.call(document.querySelectorAll(".reveal"))
      : [];

    var ticking = false;
    function update() {
      ticking = false;

      if (bar) {
        var doc = document.documentElement;
        var max = doc.scrollHeight - doc.clientHeight;
        bar.style.transform = "scaleX(" + (max > 0 ? Math.min(1, doc.scrollTop / max) : 0) + ")";
      }

      if (pending.length) {
        var fold = window.innerHeight * 0.94;
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
    var storedTheme = readStored(THEME_KEY, ["light", "dark"]);
    theme = storedTheme || document.documentElement.getAttribute("data-theme") || "light";
    applyTheme(theme, false);
    applyLang(detectLang());

    each("[data-lang-toggle]", function (btn) {
      btn.addEventListener("click", function () { applyLang(lang === "en" ? "zh" : "en"); });
    });
    each("[data-theme-toggle]", function (btn) {
      btn.addEventListener("click", function () { applyTheme(theme === "light" ? "dark" : "light", true); });
    });

    if (!storedTheme && window.matchMedia) {
      var mq = window.matchMedia("(prefers-color-scheme: dark)");
      var onSystem = function (e) {
        if (!readStored(THEME_KEY, ["light", "dark"])) applyTheme(e.matches ? "dark" : "light", false);
      };
      if (mq.addEventListener) mq.addEventListener("change", onSystem);
      else if (mq.addListener) mq.addListener(onSystem);
    }

    polish();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
