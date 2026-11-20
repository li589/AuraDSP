"use strict";

/* ============================================================
   波形场：首屏底部 13 条横向波形，连续相位推进。
   两条酸绿高亮线暗示正在被处理的通道；离开视口停算。
   ============================================================ */

(function () {
  var canvas = document.getElementById("field");
  if (!canvas) return;
  var ctx = canvas.getContext("2d");
  var W = 0, H = 0, dpr = 1;
  var running = false;

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    W = canvas.clientWidth;
    H = canvas.clientHeight;
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (REDUCED) draw(0);
  }

  var LINES = 13;

  function draw(t) {
    ctx.clearRect(0, 0, W, H);
    var mid = H / 2;
    for (var k = 0; k < LINES; k++) {
      var f = k - (LINES - 1) / 2;              /* -6..6 */
      var yBase = mid + f * (H / LINES) * 0.92;
      var amp = (H / LINES) * (0.32 + 0.1 * Math.cos(f * 0.7));
      var hi = (k === 4 || k === 8);
      ctx.beginPath();
      for (var x = 0; x <= W; x += 4) {
        var u = x / W;
        var env = Math.sin(u * Math.PI);        /* 两端收束 */
        var y = yBase + Math.sin(u * 9.5 + t * 0.00042 + k * 2.3) * amp * env
                      + Math.sin(u * 23.0 - t * 0.00027 + k * 1.1) * amp * 0.34 * env;
        if (x === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      }
      ctx.strokeStyle = hi ? "rgba(212,255,63,.5)" : "rgba(246,244,238,.13)";
      ctx.lineWidth = hi ? 1.1 : 1;
      ctx.stroke();
    }
  }

  function frame(ts) {
    if (!running) return;
    if (!document.hidden) draw(ts);
    requestAnimationFrame(frame);
  }

  resize();
  window.addEventListener("resize", resize);

  if (REDUCED) { draw(0); return; }

  var io = new IntersectionObserver(function (en) {
    var vis = en[0].isIntersecting;
    if (vis && !running) { running = true; requestAnimationFrame(frame); }
    if (!vis) running = false;
  }, { threshold: 0.02 });
  io.observe(canvas);
})();
