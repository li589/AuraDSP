"use strict";

/* ============================================================
   站点行为：跑马灯 / 分段浏览器 / 计数 / 入场 / 导航高亮 /
   滚动进度 / 顶栏状态 / 回顶
   ============================================================ */

/* 名录跑马灯：23 个单元名 ×2 无缝循环 */
(function () {
  var el = document.getElementById("ticker");
  if (!el) return;
  var names = [];
  STAGES.forEach(function (s) { s.units.forEach(function (u) { names.push(u[0]); }); });
  var html = "";
  for (var pass = 0; pass < 2; pass++) {
    names.forEach(function (n) { html += "<span>" + n + "</span>"; });
  }
  el.innerHTML = html;
})();

/* 分段浏览器：tab 切换（点击 / 方向键），列表错峰淡入 */
(function () {
  var tabs = document.getElementById("exTabs");
  if (!tabs) return;
  var unitsEl = document.getElementById("exUnits");
  var idxEl = document.getElementById("exIdx");
  var nameEl = document.getElementById("exName");
  var descEl = document.getElementById("exDesc");
  var barEl = document.getElementById("exBar");
  var metaEl = document.getElementById("exMeta");
  var current = 0;

  tabs.innerHTML = STAGES.map(function (s, i) {
    return '<button type="button" role="tab" id="tab-' + s.id + '" aria-controls="exUnits" aria-selected="' +
      (i === 0) + '" data-i="' + i + '">' +
      '<i>' + s.num + '</i><b>' + s.name + '</b><em>' + s.en + '</em></button>';
  }).join("");

  barEl.innerHTML = STAGES.map(function () { return "<i></i>"; }).join("");

  function pad2(v) { return (v < 10 ? "0" : "") + v; }

  function render(i, animate) {
    current = i;
    var s = STAGES[i];
    var buttons = tabs.querySelectorAll("button");
    for (var b = 0; b < buttons.length; b++) {
      buttons[b].setAttribute("aria-selected", String(b === i));
    }
    var bars = barEl.querySelectorAll("i");
    for (var j = 0; j < bars.length; j++) bars[j].classList.toggle("on", j === i);

    idxEl.textContent = s.num + " / 04";
    nameEl.textContent = s.name;
    descEl.textContent = s.desc;
    metaEl.textContent = s.units.length + " 个单元 · " + s.en;

    unitsEl.innerHTML = s.units.map(function (u, k) {
      var delay = animate && !REDUCED
        ? ' class="anim" style="animation-delay:' + (k * 0.032).toFixed(3) + 's"'
        : "";
      return "<li" + delay + ">" +
        '<span class="no">' + pad2(k + 1) + '</span>' +
        '<span class="nm">' + u[0] + '</span>' +
        '<span class="ds">' + u[1] + '</span></li>';
    }).join("");
  }

  tabs.addEventListener("click", function (e) {
    var btn = e.target.closest ? e.target.closest("button[data-i]") : null;
    if (btn) render(parseInt(btn.getAttribute("data-i"), 10), true);
  });
  tabs.addEventListener("keydown", function (e) {
    if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
    var d = e.key === "ArrowRight" ? 1 : -1;
    var next = (current + d + STAGES.length) % STAGES.length;
    render(next, true);
    var btns = tabs.querySelectorAll("button");
    if (btns[next]) btns[next].focus();
  });

  render(0, false);
})();

/* 计数：进入视口时 easeOutCubic 滚到目标值 */
(function () {
  var els = document.querySelectorAll("[data-count]");
  if (!els.length) return;
  function run(el) {
    var target = parseInt(el.getAttribute("data-count"), 10);
    if (REDUCED) { el.textContent = String(target); return; }
    var t0 = null, dur = 1150;
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

/* 入场：.rv 进入视口加 .in */
(function () {
  var els = document.querySelectorAll(".rv");
  if (!("IntersectionObserver" in window)) {
    els.forEach(function (el) { el.classList.add("in"); });
    return;
  }
  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (en) {
      if (en.isIntersecting) { en.target.classList.add("in"); io.unobserve(en.target); }
    });
  }, { threshold: 0.12, rootMargin: "0px 0px -6% 0px" });
  els.forEach(function (el) { io.observe(el); });
})();

/* 顶栏状态 / 滚动进度 / 回顶 */
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

/* 导航高亮：中带检测当前区块 */
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
  }, { rootMargin: "-38% 0px -55% 0px" });
  ["believe", "anatomy", "platforms", "engineering", "start"].forEach(function (id) {
    var s = document.getElementById(id);
    if (s) io.observe(s);
  });
})();
