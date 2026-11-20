"use strict";

/* ============================================================
   图版：信号链 SVG 的生成与动效
   版面分三栏（硬约束，脚本可校验）：
     左标签栏 24–96 / 绘图区 104–538 / 右计数栏 538–588
     任何 <text> 的 x 起点不得 ≥ 104；任何曲线点不得越过 plotR。
   四段曲线四种形态族（见 PROF），首尾各 16% 用 smoothstep 窗，
   曲线离开与回到基线时相切，不留断崖与折角。
   ============================================================ */

var PROF = [
  function (u) {   /* 01 前级：细密抖动 */
    return 0.46 + 0.20 * Math.sin(u * 11.2 + 0.5)
                + 0.13 * Math.sin(u * 23.7 + 2.1)
                + 0.05 * Math.sin(u * 5.1 + 1.4);
  },
  function (u) {   /* 02 算法链：8 级上行 → 平顶 → 4 级回落 */
    var lv;
    if (u < 0.46)      lv = Math.floor((u / 0.46) * 8) / 8;
    else if (u < 0.78) lv = 1;
    else               lv = 1 - Math.floor(((u - 0.78) / 0.22) * 4) / 4;
    return 0.12 + 0.70 * lv;
  },
  function (u) {   /* 03 后级：双隆起 */
    return 0.27 + 0.40 * Math.abs(Math.sin(u * Math.PI * 2))
                + 0.06 * Math.sin(u * 9.4 + 0.8);
  },
  function (u) {   /* 04 输出：升到天花板被削平 */
    var t = 0.34 + 0.30 * Math.abs(Math.sin(u * Math.PI * 1.7 + 0.18))
                 + 0.14 * Math.sin(u * 5.4 + 0.9)
                 + 0.05 * Math.sin(u * 13.1 + 2.2);
    return t > 0.60 ? 0.60 : t;
  }
];

/* 各段相对高度：算法链最高，输出最矮 */
var PSCALE = [0.78, 1, 0.66, 0.46];

var CURVE = (function () {
  var all = [], i, x, t, max, raw;
  for (i = 0; i < PROF.length; i++) {
    raw = []; max = 0;
    for (x = 0; x <= 160; x++) {
      t = PROF[i](x / 160);
      if (t < 0) t = 0;
      raw.push(t);
      if (t > max) max = t;
    }
    for (x = 0; x < raw.length; x++) raw[x] = max > 0 ? (raw[x] / max) * PSCALE[i] : 0;
    all.push(raw);
  }
  return all;
})();

function normAt(i, u) {
  var a = CURVE[i], p, k, f;
  if (u <= 0) return a[0];
  if (u >= 1) return a[a.length - 1];
  p = u * (a.length - 1);
  k = Math.floor(p); f = p - k;
  return a[k] + (a[k + 1] - a[k]) * f;
}

var PL = { W: 600, H: 436, L: 104, R: 62, T: 56, B: 22 };

function buildPlate(svg) {
  var W = PL.W, H = PL.H, L = PL.L, R = PL.R, T = PL.T, B = PL.B;
  var plotR = W - R, span = plotR - L;
  var bandH = (H - T - B) / STAGES.length;
  var out;

  function pad2(v) { return (v < 10 ? "0" : "") + v; }

  function curveY(px, i, base, amp) {
    var u = (px - L) / span;
    if (u < 0) u = 0; else if (u > 1) u = 1;
    var e = Math.min(1, Math.min(u / 0.16, (1 - u) / 0.16));
    if (e < 0) e = 0;
    var win = e * e * (3 - 2 * e);
    return base - normAt(i, u) * win * amp;
  }

  out = '<defs>' +
      '<linearGradient id="sweepG" x1="0" y1="0" x2="0" y2="1">' +
        '<stop offset="0" stop-color="#D4FF3F" stop-opacity="0"/>' +
        '<stop offset=".2" stop-color="#D4FF3F" stop-opacity=".42"/>' +
        '<stop offset=".5" stop-color="#D4FF3F" stop-opacity=".8"/>' +
        '<stop offset=".8" stop-color="#D4FF3F" stop-opacity=".42"/>' +
        '<stop offset="1" stop-color="#D4FF3F" stop-opacity="0"/>' +
      '</linearGradient>' +
      '<linearGradient id="trailG" x1="0" y1="0" x2="1" y2="0">' +
        '<stop offset="0" stop-color="#D4FF3F" stop-opacity="0"/>' +
        '<stop offset="1" stop-color="#D4FF3F" stop-opacity=".06"/>' +
      '</linearGradient>' +
      '<linearGradient id="areaG" x1="0" y1="0" x2="0" y2="1">' +
        '<stop offset="0" stop-color="#D4FF3F" stop-opacity=".115"/>' +
        '<stop offset=".62" stop-color="#D4FF3F" stop-opacity=".075"/>' +
        '<stop offset="1" stop-color="#D4FF3F" stop-opacity=".048"/>' +
      '</linearGradient>' +
      '<clipPath id="plotClip"><rect x="' + L + '" y="' + (T - 12) + '" width="' + span +
        '" height="' + (H - B - T + 24) + '"/></clipPath>' +
    '</defs>';

  out += '<rect class="pframe" x=".5" y=".5" width="' + (W - 1) + '" height="' + (H - 1) + '"/>';
  [[9, 9, 1, 1], [W - 9, 9, -1, 1], [9, H - 9, 1, -1], [W - 9, H - 9, -1, -1]].forEach(function (c) {
    out += '<path class="pcrop" d="M' + c[0] + ' ' + c[1] + 'h' + (12 * c[2]) +
           'M' + c[0] + ' ' + c[1] + 'v' + (12 * c[3]) + '"/>';
  });

  out += '<text class="pm" x="24" y="28">signal chain</text>';
  out += '<text class="pm" x="' + (W - 24) + '" y="28" text-anchor="end">4 stages · 23 units</text>';
  out += '<line class="psep" x1="0" y1="44" x2="' + W + '" y2="44"/>';

  out += '<g class="pgrid">';
  for (var g = 0; g <= 6; g++) {
    var gx = (L + span * g / 6).toFixed(1);
    out += '<line x1="' + gx + '" y1="' + T + '" x2="' + gx + '" y2="' + (H - B) + '"/>';
  }
  out += '</g>';

  for (var si = 0; si < STAGES.length; si++) {
    var st = STAGES[si];
    var top = T + si * bandH;
    var base = +(top + bandH - 13).toFixed(1);
    var amp = +(bandH - 24).toFixed(1);

    if (si > 0) {
      out += '<line class="psep" x1="0" y1="' + top.toFixed(1) + '" x2="' + W + '" y2="' + top.toFixed(1) + '"/>';
    }

    out += '<text class="pi" x="24" y="' + Math.round(top + 22) + '">' + st.num + '</text>';
    out += '<text class="pnm" x="24" y="' + Math.round(top + 39) + '">' + st.name + '</text>';
    out += '<text class="pen" x="24" y="' + Math.round(top + 53) + '">' + st.en + '</text>';

    out += '<text class="pcnt" x="' + (W - 16) + '" y="' + Math.round(base + 4) +
           '" text-anchor="end">' + pad2(st.units.length) + '</text>';

    var pts = [];
    for (var x = 0; x <= span; x += 3) {
      pts.push((L + x).toFixed(1) + ',' + curveY(L + x, si, base, amp).toFixed(1));
    }
    var line = pts.join(' ');
    out += '<g class="bp" style="--dur:' + (7.2 + si * 0.55).toFixed(2) +
           's;--dl:' + (si * 0.4).toFixed(2) + 's">';
    out += '<polygon class="envA" points="' + line + ' ' + plotR + ',' + base + ' ' + L + ',' + base + '"/>';
    out += '<polyline class="env" points="' + line + '"/>';
    out += '</g>';

    out += '<line class="sp" x1="' + L + '" y1="' + base + '" x2="' + plotR + '" y2="' + base + '"/>';
    for (var tk = 0; tk <= 24; tk++) {
      var tx = (L + span * tk / 24).toFixed(1);
      out += '<line class="stk" x1="' + tx + '" y1="' + (base - 2.2) + '" x2="' + tx +
             '" y2="' + (base + 2.2) + '"/>';
    }

    out += '<path class="pin" d="M' + (L - 8) + ' ' + (base - 2.9) + 'L' + (L - 1.5) + ' ' + base +
           'L' + (L - 8) + ' ' + (base + 2.9) + 'Z"/>';
    out += '<path class="px" d="M' + (plotR - 6.5) + ' ' + (base - 2.9) + 'L' + plotR + ' ' + base +
           'L' + (plotR - 6.5) + ' ' + (base + 2.9) + 'Z"/>';

    var un = st.units.length;
    for (var k = 0; k < un; k++) {
      var cx = +(L + span * (k + 0.5) / un).toFixed(1);
      var cy = +curveY(cx, si, base, amp).toFixed(1);
      out += '<g class="node" data-x="' + cx + '" data-name="' + st.units[k][0] + '">' +
             '<circle class="hit" cx="' + cx + '" cy="' + cy + '" r="8"/>' +
             '<circle class="nd" cx="' + cx + '" cy="' + cy + '" r="1.65"/>' +
             '</g>';
    }
  }

  out += '<g clip-path="url(#plotClip)">' +
           '<g id="sweep" opacity=".85">' +
             '<rect x="-46" y="' + (T - 12) + '" width="46" height="' + (H - B - T + 24) +
               '" fill="url(#trailG)"/>' +
             '<line x1="0" y1="' + (T - 12) + '" x2="0" y2="' + (H - B + 12) +
               '" stroke="url(#sweepG)" stroke-width="1"/>' +
           '</g>' +
         '</g>';

  svg.innerHTML = out;
  return svg;
}

(function () {
  var plate = document.getElementById("plate");
  var svg = document.getElementById("plateSvg");
  if (!plate || !svg) return;
  buildPlate(svg);

  var capEl = document.getElementById("plateCap");
  var capBase = "23 个单元 · 4 段";

  svg.addEventListener("mouseover", function (e) {
    var g = e.target.closest ? e.target.closest("g.node") : null;
    if (!g) return;
    capEl.textContent = g.getAttribute("data-name");
    capEl.style.color = "#D4FF3F";
  });
  svg.addEventListener("mouseleave", function () {
    capEl.textContent = capBase;
    capEl.style.color = "";
  });

  if (REDUCED) return;

  /* 扫描线：14s 一程，离开视口停算；经过的节点点亮 */
  var sweep = svg.querySelector("#sweep");
  var nodes = Array.prototype.slice.call(svg.querySelectorAll("g.node"));
  var nodeX = nodes.map(function (n) { return parseFloat(n.getAttribute("data-x")); });
  var running = false, t0 = null;

  function frame(ts) {
    if (!running) return;
    if (document.hidden) { requestAnimationFrame(frame); return; }
    if (t0 === null) t0 = ts;
    var p = ((ts - t0) % 14000) / 14000;
    var sx = PL.L - 60 + p * ((PL.W - PL.R - PL.L) + 120);
    sweep.setAttribute("transform", "translate(" + sx.toFixed(1) + ",0)");
    for (var i = 0; i < nodes.length; i++) {
      var d = Math.abs(nodeX[i] - sx);
      nodes[i].classList.toggle("lit", d < 26);
    }
    requestAnimationFrame(frame);
  }

  var io = new IntersectionObserver(function (en) {
    var vis = en[0].isIntersecting;
    if (vis && !running) { running = true; t0 = null; requestAnimationFrame(frame); }
    if (!vis) running = false;
  }, { threshold: 0.05 });
  io.observe(plate);

  /* 视差：指针移动时轻微跟随，阻尼 .08；触摸与窄屏关闭 */
  if (window.matchMedia("(pointer: fine)").matches && window.innerWidth > 980) {
    var tx = 0, ty = 0, cx = 0, cy = 0, pRun = false;
    function pFrame() {
      cx += (tx - cx) * 0.08;
      cy += (ty - cy) * 0.08;
      plate.style.transform = "translate3d(" + cx.toFixed(2) + "px," + cy.toFixed(2) + "px,0)";
      if (Math.abs(tx - cx) > 0.05 || Math.abs(ty - cy) > 0.05) requestAnimationFrame(pFrame);
      else pRun = false;
    }
    function kick() { if (!pRun) { pRun = true; requestAnimationFrame(pFrame); } }
    plate.addEventListener("pointermove", function (e) {
      var r = plate.getBoundingClientRect();
      tx = ((e.clientX - r.left) / r.width - 0.5) * 11;
      ty = ((e.clientY - r.top) / r.height - 0.5) * 8;
      kick();
    });
    plate.addEventListener("pointerleave", function () { tx = 0; ty = 0; kick(); });
  }
})();
