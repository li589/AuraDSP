"use strict";

/* ============================================================
   AuraDSP 宣传页交互逻辑
   1. Hero 录音室控制台：动态频谱仪 Canvas、主旁路开关、双通道 VU 表、机架卡片轮播
   2. Section 02 音频总线机架：阶段切换与 23 单元实时检查器
   3. Section 03 驱动形态：Windows / Linux / Android 选项卡
   4. 通用能力：跑马灯 / 入场动效 / 计数滚动 / 滚动进度 / 顶栏状态 / 回顶 / 导航高亮
   ============================================================ */

var REDUCED = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/* ==================== 1. Hero 录音室控制台 ==================== */
(function () {
  var bench = document.getElementById("heroWorkbench");
  if (!bench) return;

  var masterBypassBtn = document.getElementById("heroMasterBypass");
  var masterBypassTxt = document.getElementById("masterBypassTxt");
  var isMasterBypassed = false;

  var meterL = document.getElementById("heroMeterL");
  var meterR = document.getElementById("heroMeterR");

  var canvas = document.getElementById("heroSpectrumCanvas");
  var ctx = canvas ? canvas.getContext("2d") : null;
  var specActiveUnitName = document.getElementById("specActiveUnitName");

  var rackTrack = document.getElementById("rackTrack");
  var rackCards = document.querySelectorAll(".rack-card");
  var prevBtn = document.getElementById("rackPrevBtn");
  var nextBtn = document.getElementById("rackNextBtn");
  var rackDots = document.querySelectorAll(".r-dot");

  var activeUnitKey = "eq";
  var activeUnitLabel = "15 段参量双四阶均衡 · 激活";

  var UNIT_NAMES = {
    eq: "15 段参量双四阶均衡 · 激活",
    tube: "电子管软饱和与偶次谐波 · 激活",
    convolver: "分块脉冲响应卷积 (IR) · 激活",
    spatial: "3D 空间立体声展宽 · 激活",
    limiter: "超前预测真峰值限幅 (-0.1 dBTP) · 激活"
  };

  /* ----- 1.1 主旁路切换 ----- */
  if (masterBypassBtn) {
    masterBypassBtn.addEventListener("click", function () {
      isMasterBypassed = !isMasterBypassed;
      masterBypassBtn.classList.toggle("bypassed", isMasterBypassed);
      masterBypassBtn.classList.toggle("active", !isMasterBypassed);
      if (masterBypassTxt) {
        masterBypassTxt.textContent = isMasterBypassed ? "全局物理旁路 (Bypass)" : "引擎处理中";
      }
      if (specActiveUnitName) {
        specActiveUnitName.textContent = isMasterBypassed ? "全链路物理旁路 · 0 开销直通" : activeUnitLabel;
      }
      rackCards.forEach(function (c) {
        c.style.opacity = isMasterBypassed ? "0.45" : "1";
      });
    });
  }

  /* ----- 1.2 双通道 VU 表动画 ----- */
  var meterPhase = 0;
  function updateMeters() {
    if (REDUCED) return;
    meterPhase += 0.08;
    if (isMasterBypassed) {
      if (meterL) meterL.style.height = "42%";
      if (meterR) meterR.style.height = "40%";
    } else {
      var dL = Math.sin(meterPhase) * 12 + Math.cos(meterPhase * 2.3) * 6;
      var dR = Math.sin(meterPhase + 1.1) * 10 + Math.sin(meterPhase * 1.7) * 7;
      if (meterL) meterL.style.height = Math.max(18, Math.min(92, 68 + dL)) + "%";
      if (meterR) meterR.style.height = Math.max(18, Math.min(92, 64 + dR)) + "%";
    }
    requestAnimationFrame(updateMeters);
  }
  requestAnimationFrame(updateMeters);

  /* ----- 1.3 全景动态频谱与传输特性 Canvas ----- */
  var specPhase = 0;
  function drawSpectrum() {
    if (!canvas || !ctx) return;
    var w = canvas.width;
    var h = canvas.height;
    ctx.clearRect(0, 0, w, h);

    // 水平参考基线 (0dB, -6dB, -12dB)
    ctx.strokeStyle = "rgba(246, 244, 238, 0.06)";
    ctx.lineWidth = 1;
    [0.25, 0.5, 0.75].forEach(function (frac) {
      ctx.beginPath();
      ctx.moveTo(0, h * frac);
      ctx.lineTo(w, h * frac);
      ctx.stroke();
    });

    specPhase += 0.035;

    // 1. 母带全频立体声底流 (淡蓝紫流光)
    ctx.beginPath();
    for (var x = 0; x <= w; x += 6) {
      var u = x / w;
      var baseY = h * 0.58;
      var busWave = Math.sin(u * 14 + specPhase * 0.8) * 6 * Math.sin(u * Math.PI)
                  + Math.sin(u * 28 - specPhase * 1.2) * 3;
      var y = isMasterBypassed ? h * 0.5 : baseY + busWave;
      if (x === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    }
    ctx.strokeStyle = "rgba(140, 170, 238, 0.35)";
    ctx.lineWidth = 1.2;
    ctx.stroke();

    // 2. 当前激活单元的声学特征传递函数 (酸绿高光)
    ctx.beginPath();
    for (var i = 0; i <= w; i += 4) {
      var normX = i / w;
      var targetY = h * 0.5;

      if (!isMasterBypassed) {
        if (activeUnitKey === "eq") {
          // 低频 120Hz 隆起 + 高频 12kHz 空气感
          var bassBell = Math.exp(-Math.pow((normX - 0.16) / 0.08, 2)) * 26;
          var midDip   = -Math.exp(-Math.pow((normX - 0.52) / 0.12, 2)) * 10;
          var airRise  = Math.exp(-Math.pow((normX - 0.86) / 0.10, 2)) * 18;
          var flutter  = Math.sin(normX * 32 + specPhase) * 2;
          targetY = h * 0.56 - (bassBell + midDip + airRise + flutter);
        } else if (activeUnitKey === "tube") {
          // 软饱和双曲正切曲线与偶次谐波泛音
          var tubeHarm = Math.sin(normX * 8 + specPhase) * 12 * Math.sin(normX * Math.PI)
                       + Math.sin(normX * 24 + specPhase * 1.5) * 5;
          targetY = h * 0.48 - tubeHarm;
        } else if (activeUnitKey === "convolver") {
          // 房间脉冲响应衰减锯齿震颤
          var env = Math.exp(-normX * 2.8);
          var roomRipples = (Math.sin(normX * 42 + specPhase * 0.5) * 14
                          + Math.sin(normX * 85) * 6) * env;
          targetY = h * 0.52 - roomRipples;
        } else if (activeUnitKey === "spatial") {
          // 立体声展宽双耳干涉谷峰
          var spat = Math.sin(normX * 18 + specPhase) * 16 * Math.sin(normX * Math.PI)
                   + Math.cos(normX * 36 - specPhase) * 8;
          targetY = h * 0.5 - spat;
        } else if (activeUnitKey === "limiter") {
          // -0.1 dBTP 砖墙天花板削平
          var raw = Math.sin(normX * 10 + specPhase) * 24 + Math.sin(normX * 22) * 8;
          var clamped = Math.max(-12, Math.min(14, raw));
          targetY = h * 0.5 - clamped;
        }
      }

      if (i === 0) ctx.moveTo(i, targetY); else ctx.lineTo(i, targetY);
    }
    ctx.strokeStyle = isMasterBypassed ? "rgba(246, 244, 238, 0.3)" : "#D4FF3F";
    ctx.lineWidth = 1.8;
    ctx.stroke();

    if (!REDUCED) {
      requestAnimationFrame(drawSpectrum);
    }
  }
  drawSpectrum();

  /* ----- 1.4 机架卡片点击聚焦与切换 ----- */
  function selectCard(idx) {
    if (idx < 0 || idx >= rackCards.length) return;
    rackCards.forEach(function (c, i) {
      var isCur = (i === idx);
      c.classList.toggle("active", isCur);
      var actSpan = c.querySelector(".rc-act");
      if (actSpan) actSpan.textContent = isCur ? "当前聚焦" : "点击聚焦";
    });

    rackDots.forEach(function (d, i) {
      d.classList.toggle("active", i === idx);
    });

    var card = rackCards[idx];
    activeUnitKey = card.getAttribute("data-unit") || "eq";
    activeUnitLabel = UNIT_NAMES[activeUnitKey] || "算法单元 · 激活";
    if (specActiveUnitName && !isMasterBypassed) {
      specActiveUnitName.textContent = activeUnitLabel;
    }

    // 平滑滚动居中
    if (rackTrack) {
      var offset = card.offsetLeft - (rackTrack.clientWidth - card.clientWidth) / 2;
      rackTrack.scrollTo({ left: Math.max(0, offset), behavior: "smooth" });
    }
  }

  rackCards.forEach(function (card, idx) {
    card.addEventListener("click", function (e) {
      // 避免点击滑块时误触发滚动
      if (e.target.tagName.toLowerCase() === "input" || e.target.classList.contains("rc-toggle") || e.target.classList.contains("rc-knob")) {
        return;
      }
      selectCard(idx);
    });
    card.addEventListener("keydown", function (e) {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        selectCard(idx);
      }
    });
  });

  // Prev / Next 按钮
  if (prevBtn) {
    prevBtn.addEventListener("click", function () {
      var curIdx = 0;
      rackCards.forEach(function (c, i) { if (c.classList.contains("active")) curIdx = i; });
      var prevIdx = (curIdx - 1 + rackCards.length) % rackCards.length;
      selectCard(prevIdx);
    });
  }
  if (nextBtn) {
    nextBtn.addEventListener("click", function () {
      var curIdx = 0;
      rackCards.forEach(function (c, i) { if (c.classList.contains("active")) curIdx = i; });
      var nextIdx = (curIdx + 1) % rackCards.length;
      selectCard(nextIdx);
    });
  }

  rackDots.forEach(function (dot) {
    dot.addEventListener("click", function () {
      var idx = parseInt(dot.getAttribute("data-idx"), 10);
      if (!isNaN(idx)) selectCard(idx);
    });
  });

  // 单卡片内独立 Bypass 开关切换
  document.querySelectorAll(".rc-toggle").forEach(function (toggle) {
    toggle.addEventListener("click", function (e) {
      e.stopPropagation();
      var isOn = toggle.classList.toggle("on");
      var card = toggle.closest(".rack-card");
      if (card) {
        card.style.opacity = isOn ? "1" : "0.5";
      }
    });
  });

  // 参数滑块实时数值联动
  document.querySelectorAll(".rc-slider").forEach(function (slider) {
    slider.addEventListener("input", function () {
      var targetId = slider.getAttribute("data-val-target");
      var unit = slider.getAttribute("data-unit") || "";
      var targetEl = document.getElementById(targetId);
      if (targetEl) {
        var val = parseFloat(slider.value);
        var sign = (val > 0 && unit === "dB") ? "+" : "";
        targetEl.textContent = sign + val + " " + unit;
      }
    });
  });
})();

/* ==================== 2. Section 02 音频总线机架与 23 单元检查器 ==================== */
(function () {
  var stageCards = document.querySelectorAll(".stage-bus-card");
  var badgeEl = document.getElementById("sipStageBadge");
  var titleEl = document.getElementById("sipStageTitle");
  var leadEl = document.getElementById("sipStageLead");
  var unitsGrid = document.getElementById("sipUnitsGrid");

  if (!stageCards.length || !unitsGrid || typeof STAGES === "undefined") return;

  var STAGE_META = {
    pre: {
      badge: "STAGE 01 / 04 · 入水净化",
      title: "前置与门限阶段算法架构 (6 个独立单元)",
      lead: "划定通带边界，切除超低频直流偏置，阻断底层噪声门限。后续所有声学单元均以此段处理结果为基准。"
    },
    vendor: {
      badge: "STAGE 02 / 04 · 经典算法链",
      title: "经典算法链与插件插槽 (12 个独立单元 · 可拖拽重排)",
      lead: "声音个性雕刻的核心矩阵。涵盖电子管饱和、参量均衡、分块脉冲卷积与动态压缩。支持在段间任意插入第三方 VST3/CLAP 插件。"
    },
    post: {
      badge: "STAGE 03 / 04 · 后级声场",
      title: "后级声场与空间声学 (3 个独立单元)",
      lead: "专为耳机监听与近场声学优化：利用双耳时间差与 M/S 声像解构，在两耳之间拉开自然的脱箱声场。"
    },
    out: {
      badge: "STAGE 04 / 04 · 输出母带",
      title: "输出与真峰值限幅 (2 个算法单元 + 4 槽 VST3/CLAP 宿主)",
      lead: "全链路终点：等响度补偿自适应校正人耳等响曲线，搭配 0.5ms 超前预测真峰值限幅器，杜绝任何破音与过载。"
    }
  };

  function pad2(n) { return (n < 10 ? "0" : "") + n; }

  function renderStageUnits(stageKey) {
    var stageObj = null;
    for (var i = 0; i < STAGES.length; i++) {
      if (STAGES[i].id === stageKey) {
        stageObj = STAGES[i];
        break;
      }
    }
    if (!stageObj) return;

    var meta = STAGE_META[stageKey] || {
      badge: "STAGE " + stageObj.num + " / 04",
      title: stageObj.name + " 阶段算法构成",
      lead: stageObj.desc
    };

    if (badgeEl) badgeEl.textContent = meta.badge;
    if (titleEl) titleEl.textContent = meta.title;
    if (leadEl) leadEl.textContent = meta.lead;

    unitsGrid.innerHTML = stageObj.units.map(function (u, idx) {
      return '<div class="sip-unit-card">' +
               '<div class="suc-top">' +
                 '<span class="suc-no">UNIT ' + pad2(idx + 1) + '</span>' +
                 '<span class="suc-type">64-bit IIR / 0 Malloc</span>' +
               '</div>' +
               '<h5 class="suc-name">' + u[0] + '</h5>' +
               '<p class="suc-desc">' + u[1] + '</p>' +
             '</div>';
    }).join("");
  }

  stageCards.forEach(function (card) {
    card.addEventListener("click", function () {
      stageCards.forEach(function (c) {
        c.classList.remove("active");
        c.setAttribute("aria-selected", "false");
      });
      card.classList.add("active");
      card.setAttribute("aria-selected", "true");
      var key = card.getAttribute("data-stage");
      if (key) renderStageUnits(key);
    });
  });

  // 默认装配 Stage 01
  renderStageUnits("pre");
})();

/* ==================== 3. Section 03 跨平台驱动形态选项卡 ==================== */
(function () {
  var platBtns = document.querySelectorAll(".plat-tab-btn");
  var platPanels = {
    win: document.getElementById("platPanelWin"),
    linux: document.getElementById("platPanelLinux"),
    android: document.getElementById("platPanelAndroid")
  };

  if (!platBtns.length) return;

  platBtns.forEach(function (btn) {
    btn.addEventListener("click", function () {
      var platKey = btn.getAttribute("data-plat");
      if (!platKey) return;

      platBtns.forEach(function (b) {
        b.classList.remove("active");
        b.setAttribute("aria-selected", "false");
      });
      btn.classList.add("active");
      btn.setAttribute("aria-selected", "true");

      for (var k in platPanels) {
        if (platPanels[k]) {
          platPanels[k].classList.toggle("active", k === platKey);
        }
      }
    });
  });
})();

/* ==================== 4. 跑马灯 / 入场 / 计数 / 滚动进度 / 导航高亮 ==================== */
// 名录跑马灯：23 个单元名 × 2 无缝循环
(function () {
  var el = document.getElementById("ticker");
  if (!el || typeof STAGES === "undefined") return;
  var names = [];
  STAGES.forEach(function (s) {
    s.units.forEach(function (u) { names.push(u[0]); });
  });
  var html = "";
  for (var pass = 0; pass < 2; pass++) {
    names.forEach(function (n) { html += "<span>" + n + "</span>"; });
  }
  el.innerHTML = html;
})();

// 入场动效：.rv 进入视口加 .in
(function () {
  var els = document.querySelectorAll(".rv");
  if (!("IntersectionObserver" in window)) {
    els.forEach(function (el) { el.classList.add("in"); });
    return;
  }
  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (en) {
      if (en.isIntersecting) {
        en.target.classList.add("in");
        io.unobserve(en.target);
      }
    });
  }, { threshold: 0.1, rootMargin: "0px 0px -4% 0px" });
  els.forEach(function (el) { io.observe(el); });
})();

// 计数滚动：[data-count]
(function () {
  var els = document.querySelectorAll("[data-count]");
  if (!els.length) return;
  function run(el) {
    var target = parseInt(el.getAttribute("data-count"), 10);
    if (REDUCED) { el.textContent = String(target); return; }
    var t0 = null, dur = 1100;
    function step(ts) {
      if (t0 === null) t0 = ts;
      var p = Math.min(1, (ts - t0) / dur);
      var e = 1 - Math.pow(1 - p, 3);
      el.textContent = String(Math.round(target * e));
      if (p < 1) requestAnimationFrame(step);
    }
    requestAnimationFrame(step);
  }
  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (en) {
      if (en.isIntersecting) { run(en.target); io.unobserve(en.target); }
    });
  }, { threshold: 0.5 });
  els.forEach(function (el) { io.observe(el); });
})();

// 顶栏状态 / 滚动进度 / 回顶
(function () {
  var top = document.getElementById("topbar");
  var bar = document.getElementById("progressBar");
  var toTop = document.getElementById("toTop");
  var ticking = false;

  function update() {
    ticking = false;
    var y = window.scrollY || 0;
    var max = document.documentElement.scrollHeight - window.innerHeight;
    if (top) top.classList.toggle("scrolled", y > 12);
    if (bar) bar.style.transform = "scaleX(" + (max > 0 ? Math.min(1, y / max) : 0) + ")";
    if (toTop) toTop.classList.toggle("show", y > window.innerHeight * 1.15);
  }
  window.addEventListener("scroll", function () {
    if (!ticking) { ticking = true; requestAnimationFrame(update); }
  }, { passive: true });
  update();

  if (toTop) {
    toTop.addEventListener("click", function () {
      window.scrollTo({ top: 0, behavior: REDUCED ? "auto" : "smooth" });
    });
  }
})();

// 导航高亮
(function () {
  var links = document.querySelectorAll("[data-nav]");
  if (!links.length || !("IntersectionObserver" in window)) return;
  var map = {};
  links.forEach(function (a) { map[a.getAttribute("data-nav")] = a; });
  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (en) {
      if (!en.isIntersecting) return;
      links.forEach(function (a) { a.classList.remove("on"); });
      var a = map[en.target.id];
      if (a) a.classList.add("on");
    });
  }, { rootMargin: "-35% 0px -55% 0px" });
  ["hero", "believe", "anatomy", "platforms", "engineering", "start"].forEach(function (id) {
    var s = document.getElementById(id);
    if (s) io.observe(s);
  });
})();
