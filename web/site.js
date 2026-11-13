/* Mimi Remote — site behaviour. Four small jobs, no framework:
     1. language     [data-i18n] / [data-i18n-alt] / [data-i18n-label] / [data-href-zh]
     2. appearance   light <-> dark, remembered; follows the system until chosen
     3. screenshots  [data-shot="name"] -> ./assets/shots/name-<zh|en>-<light|dark>.webp
                     ([data-shot-theme] pins one appearance regardless of the page's;
                     the markup carries no src, so only the right copy is downloaded)
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
    "meta.title": "Mimi Remote — 用 iPhone、iPad 遥控 Codex 与 Claude Code",
    "meta.description": "用手机遥控电脑上的 Codex 和 Claude Code。Agent 继续在你的 Mac、Windows 或 Linux 电脑上运行，你在 iPhone、iPad 上看进度、回消息、批权限。开源免费。",

    "skip": "跳到正文",

    "nav.remote": "遥控",
    "nav.devices": "多台电脑",
    "nav.connect": "连接",
    "nav.compare": "对比",
    "nav.faq": "常见问题",
    "nav.get": "下载",

    "hero.eyebrow": "iPhone 与 iPad App",
    "hero.title": "用手机，遥控电脑上的<br>Codex 和 Claude&nbsp;Code。",
    "hero.lede": "Codex 和 Claude Code 继续在你的 Mac、Windows 或 Linux 电脑上干活。你在 iPhone、iPad 上看进度、回消息、批权限——不用远程桌面，也不用敲终端。",
    "cta.appstore": "在 App Store 下载",
    "cta.testflight": "加入 TestFlight 测试",
    "cta.host": "下载电脑端",
    "hero.meta": "<span>开源免费</span> · <span>无需注册</span> · <span>支持 Mac、Windows、Linux 电脑</span>",

    "overview.title": "以前要回到电脑前做的事，<br>现在拿起手机就能做。",
    "ov.1.t": "接着电脑上的会话",
    "ov.1.n": "电脑上开的会话，在手机上接着聊，不用重新交代项目背景。",
    "ov.2.t": "回消息、批权限",
    "ov.2.n": "回答提问，批准或拒绝命令，排好下一步，或者中断任务。",
    "ov.3.t": "需要你时会通知",
    "ov.3.n": "待审批、已回复和任务失败，直接推到锁屏。",
    "ov.4.t": "看进度、查改动",
    "ov.4.n": "实时看回复和工具步骤；使用 Codex 时还能看 Diff、用 Git 收尾。",
    "ov.5.t": "多台电脑、多个 Agent",
    "ov.5.n": "配对 Mac、Windows、Linux 电脑，一个 App 遥控 Codex 和 Claude Code。",
    "ov.6.t": "局域网或 Tailscale",
    "ov.6.n": "Mac、Windows 与 Linux 还可试用 Tailcat：实验性、默认关闭，初次握手经第三方中继。",

    "handoff.eyebrow": "接着电脑上的会话",
    "handoff.title": "在电脑上开始，<br>在手机上接着推进。",
    "handoff.body": "Mimi 与 Codex Desktop、Codex CLI 连接同一个 App Server。在任何一端开始的会话，另一端都能直接打开——历史、上下文和正在运行的任务一样不少。不用复制粘贴，也不用重新交代背景。",
    "term.user": "帮我检查这次 README 改动，确认安装步骤和安全边界与代码一致。",
    "term.agent": "我会核对源码构建和配对流程，并把主运行时与可选运行时的边界拆开说明。",
    "handoff.link": "同一个会话",
    "handoff.chip1": "历史完整",
    "handoff.chip2": "进度实时同步",
    "handoff.chip3": "Claude Code 同样适用",
    "handoff.fine": "与 Codex Desktop、CLI 共享会话目前支持 Mac 与 Linux 电脑。",

    "control.eyebrow": "回复与审批",
    "control.title": "回消息、批权限，<br>必要时随时叫停。",
    "control.body": "Agent 提问时，在输入框里直接回答；它要运行命令或修改文件时，可以仅允许一次、本会话允许、始终允许这个工具，或者拒绝。任务还在运行，就能排好下一条指令，也可以直接中断。",
    "mini.1.t": "就地审批",
    "mini.1.n": "仅一次、本会话或始终允许，不用离开当前会话。",
    "mini.2.t": "排队下一步",
    "mini.2.n": "当前任务还在运行，就能把后续指令排进队列。",
    "mini.3.t": "随时切换模型",
    "mini.3.n": "每一轮都能调整模型、推理强度和速度。",
    "mini.4.t": "语音、图片与文件",
    "mini.4.n": "语音输入、附上截图，用快速查看预览文件。",
    "control.fine": "新会话默认使用「完全文件访问」权限档位，Agent 执行命令和修改文件时不会逐条询问。需要逐条确认时，在 App 设置的「默认权限」中改为「请求审批」。",

    "notify.eyebrow": "通知",
    "notify.title": "需要你的时候，<br>马上就知道。",
    "notify.body": "Agent 想运行命令、修改文件或需要你补充信息时，带着会话标题的通知会直接送达；任务回复、失败或中断也会及时提醒。审批在通知里就能允许或拒绝。",
    "notify.privacy": "默认开启，可随时在 App 中关闭。离开电脑的只有固定格式的状态信息，不含你的代码、提示词或对话；会话标题在手机本地补全。",
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

    "progress.eyebrow": "进度与改动",
    "progress.title": "看它在做什么，<br>也看它改了什么。",
    "progress.body": "回复、推理、命令和工具调用，实时汇成一条清晰易读的时间线。工作区按项目把会话分成进行中、刚完成和最近。使用 Codex 时，还能查看 Diff、管理 Worktree，提交并创建草稿 PR。",
    "progress.legend": "iPhone 是紧凑的会话界面 · iPad 是多栏工作台",
    "progress.try": "切换本页深浅色",

    "devices.eyebrow": "多台电脑与多个 Agent",
    "devices.title": "一部手机，<br>多台电脑，<br>多个 Agent。",
    "devices.body": "家里的 Mac Studio、出差带的 MacBook、公司的 Windows 工作站，各自保存为独立连接，凭据分别存进钥匙串，会话仍属于各自的电脑。轻点一下就能切换。",
    "devices.hosts": "电脑",
    "devices.mac": "菜单栏 App，服务状态、额度与配对一目了然。",
    "devices.win": "托盘 App 与用户级服务，支持 Windows 10 / 11。",
    "devices.linux": "桌面托盘与 systemd 用户服务。",
    "devices.agents": "Agent",
    "agent.codex": "主运行时：会话、实时进度、审批、任务控制和项目工具。",
    "agent.claude": "会话与审批，控制项少于 Codex。",
    "agent.deepseek": "可选接入：文本会话与实时进度。",
    "tag.experimental": "实验性",

    "connect.eyebrow": "连接",
    "connect.title": "在家走局域网，<br>出门用 Tailscale。",
    "connect.body": "Mimi 只连接你配对的电脑，走可信的局域网或你自己的 Tailscale 网络。没有 Mimi 云账号、会话托管或应用层中转；可选的 Tailcat 路线会经过传输中继，见下文说明。配对只需在电脑上显示二维码、用手机扫一下。电脑端服务只应在私有网络中访问，不要暴露到公网。",
    "route.lan.t": "局域网",
    "route.lan": "在可信的局域网里直接连接，不需要任何额外设置。",
    "route.ts": "已经在用 tailnet？直接连就行。",
    "route.tc": "支持 Mac、Windows 与 Linux，默认关闭。开启后手机不装 Tailscale 也能连到电脑。",
    "connect.tailcat": "每次 Tailcat 连接都会先通过 DERP 中继发现对端并完成初始握手，随后在网络允许时将端到端加密的流量切换为直连；无法直连时继续经中继转发。即使随后直连，中继也会处理建立连接所需的网络元数据。默认中继由 Tailscale 运营，不由 Mimi Remote 运营，也可以在电脑上改为自建中继。",
    "route.direct": "直连",
    "route.relay": "必要时经加密中继",
    "route.computer": "你的电脑",

    "compare.eyebrow": "和远程桌面、SSH 终端比",
    "compare.title": "不是远程桌面，<br>也不是终端。",
    "compare.body": "Mimi Remote 只遥控 Agent 会话。要在手机上操作整台电脑或任意命令行，远程桌面和 SSH 终端更合适。",
    "cmp.rd": "远程桌面",
    "cmp.1.t": "手机上看到什么",
    "cmp.1.rd": "整个电脑屏幕，要放大才看得清",
    "cmp.1.ssh": "终端里的字符",
    "cmp.1.mimi": "为手机排版的对话、工具步骤、审批和改动",
    "cmp.2.t": "怎么回复和审批",
    "cmp.2.rd": "在小屏幕上点鼠标、打字",
    "cmp.2.ssh": "在终端里打字、按键",
    "cmp.2.mimi": "输入框和按钮",
    "cmp.3.t": "Agent 需要你时",
    "cmp.3.rd": "没有提醒",
    "cmp.3.ssh": "要另外配置",
    "cmp.3.mimi": "推送到锁屏",
    "cmp.4.t": "首次连接",
    "cmp.4.rd": "装远程控制软件并登录",
    "cmp.4.ssh": "开 SSH、配密钥、装 tmux",
    "cmp.4.mimi": "电脑上装 Mimi Remote，手机扫码",

    "trust.eyebrow": "开源",
    "trust.title": "开源免费，<br>不用注册账号。",
    "trust.1.t": "代码全部公开",
    "trust.1.n": "iPhone 与 iPad App、电脑端服务和 Claude 桥接，都在 GitHub 上。",
    "trust.2.t": "数据留在你的电脑",
    "trust.2.n": "项目文件、会话历史和运行时凭据，都留在你自己的电脑上。",
    "trust.3.t": "沿用你的 Agent 账号",
    "trust.3.n": "直接使用电脑上已登录的 Codex 或 Claude Code，Mimi 不接触这些凭据。",
    "trust.github": "在 GitHub 查看源码",

    "faq.eyebrow": "常见问题",
    "faq.title": "安装之前，<br>你可能想知道。",
    "faq.1.q": "手机要登录 OpenAI 或 Anthropic 账号吗？",
    "faq.1.a": "不用。App 只连接你配对的电脑，Agent 使用电脑上已经登录的 Codex 或 Claude Code，Mimi Remote 不接触这些凭据。",
    "faq.2.q": "电脑要一直开着吗？",
    "faq.2.a": "要。Agent 在电脑上运行，连接期间电脑需要保持唤醒和联网。",
    "faq.3.q": "会话保存在哪里？",
    "faq.3.a": "在你的电脑上，由 Codex、Claude Code 或 DeepSeek Harness 自己保存。Mimi Remote 没有云账号，也不托管会话。",
    "faq.4.q": "不在同一个网络时怎么连？",
    "faq.4.a": "用 Tailscale 让手机和电脑处在同一个私有网络。Mac、Windows 与 Linux 电脑也可以试用实验性的 Tailcat 连接，说明见<a href=\"#connect\">连接</a>一节。",
    "faq.5.q": "收费吗？",
    "faq.5.a": "App 和电脑端都免费、开源，没有内购和订阅。模型用量算在你电脑上 Codex 或 Claude Code 使用的账号上。",
    "faq.6.q": "和 OpenAI、Anthropic 官方的手机远程功能有什么不同？",
    "faq.6.a": "官方功能各自服务自家的 Agent。Mimi Remote 在一个 App 里同时连接 Codex 和 Claude Code（以及 DeepSeek Harness），电脑可以是 Mac、Windows 或 Linux，能在多台之间切换，iPad 上是多栏工作台，代码全部开源。官方功能更新很快，按你使用的工具和账号选择即可。",

    "final.title": "电脑继续干活，<br>手机上说了算。",
    "final.sub": "需要 iOS / iPadOS 18 或更高版本，以及一台装有 Codex CLI 的 Mac、Windows 或 Linux 电脑。",

    "footer.docs": "文档",
    "footer.privacy": "隐私",
    "footer.terms": "条款",
    "footer.support": "支持",
    "footer.fine": "Mimi Remote 是独立的开源项目，与 OpenAI、Anthropic、DeepSeek、Tailscale 均无关联。",

    "alt.heroIpad": "iPad 上的 Mimi Remote：左侧是会话侧栏，右侧对话正在等待审批。",
    "alt.heroPhone": "iPhone 上的会话列表，进行中的任务排在最上方。",
    "alt.handoff": "同一段对话，在 iPhone 上接着进行。",
    "alt.control": "对话中的审批卡片：拒绝、仅允许一次、本会话允许、始终允许此工具。",
    "alt.progressLight": "浅色模式下 iPhone 的工作区。",
    "alt.progressIpad": "iPad 上的工作区视图，列出一个项目进行中和最近的会话。",
    "alt.progressDark": "深色模式下 iPhone 的会话列表。",
    "alt.devices": "iPhone 上的「电脑连接」页面，列出当前电脑和另一台已保存的电脑。",

    "label.diagram": "手机能直连时直接连到电脑；经 Tailscale 或 Tailcat 时，无法直连的端到端加密流量改走中继。",
    "label.lock": "锁屏上的 Mimi Remote 通知：一条带「仅允许一次」和「拒绝」的审批请求、一条已回复提醒，以及一条任务未完成提醒。"
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
