# AuraDSP 品牌标记 v1

**概念**：声波光环 A —— 字母 A 为骨架，横杠是一条平滑波形，外圈双层光环表示辐射。
**渐变**：酸绿 `#D4FF3F` → 青 `#64F0DC`（深色主题）；浅色主题使用令牌内的橄榄绿 → 深青。

## 主文件

| 文件 | 用途 |
|---|---|
| `auradsp-mark.svg` | 主标记，透明底，用于深色背景 |
| `auradsp-mark-light.svg` | 浅色背景版（olive → teal 渐变，保证对比度） |
| `auradsp-mark-mono.svg` | 单色版（`currentColor`），用于印刷/单色场景 |
| `auradsp-wordmark-light.svg` | 字标，浅色字，用于深色背景 |
| `auradsp-wordmark-dark.svg` | 字标，深色字，用于浅色背景 |
| `auradsp-lockup-dark.svg` | 横排锁定（深色背景） |
| `auradsp-lockup-light.svg` | 横排锁定（浅色背景） |
| `auradsp-app-icon.svg` | App 图标，深色圆角底 |
| `auradsp-app-icon-small.svg` | 16/20/24px 简化版（去光环、A 放大） |
| `auradsp-tray.svg` | 托盘图标，渐变，透明底 |
| `auradsp-tray-dark.svg` | 托盘图标，深色（浅色任务栏） |
| `auradsp-tray-light.svg` | 托盘图标，浅色（深色任务栏） |

字标已从 **Bricolage Grotesque 700** 转为路径（`auradsp-wordmark-*.svg`），不依赖目标机器安装字体。

## 图标导出

`icons/` 内包含：

- `auradsp-app-16/20/24/32/40/48/64/128/256/512/1024.png`
- `auradsp-tray-16 … 256.png`（渐变）
- `auradsp-tray-dark-16 … 40.png`（浅色任务栏用）
- `auradsp.ico`：16/20/24/32/40/48/64/128/256（16/20/24 使用简化版）
- `auradsp-tray.ico`：16/20/24/32/40/48/64
- `auradsp-lockup-dark.png` / `-light.png`：透明底横排锁定

## 规格

- **构图**：256 单位网格；A 顶点 `(128,52)`，双脚 `(58,198)/(198,198)`，主笔画 23；波形横杠基线 `y=150`、振幅 ±10、笔画 11，两端水平接入两腿内缘；光环 `r=94/104`。
- **颜色**：深色渐变 `#D4FF3F → #9BF873 → #64F0DC`；图标底 `#0E0F13`；浅色渐变 `#5B7A00 → #2F7D46 → #0E7C6B`。
- **最小尺寸**：符号 ≥16px；横排锁定 ≥96px 宽。16/20/24px 的 App 图标使用简化版（去光环、A 放大）；托盘图标始终使用去光环版本。
- **留白**：横排锁定四周留白 ≥ 字标大写高度的 50%。

## 重建

```powershell
python app\auradsp_app\design\logo\build_assets.py
```

依赖：Python 3、Pillow、numpy、fontTools；Windows 上安装了 Edge（`C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe`）。
脚本会重新生成全部 SVG、PNG、ICO 与 `final.html` 预览。

## 已接入 App（2026-10-28）

| App 路径 | 来源 |
|---|---|
| `app/auradsp_app/windows/runner/resources/app_icon.ico` | `icons/auradsp.ico` |
| `app/auradsp_app/assets/tray_icon.ico` | `icons/auradsp-tray.ico` |

已执行 `flutter build windows --release --no-tree-shake-icons`，exe 嵌入图标与
`data/flutter_assets/assets/tray_icon.ico` 均已更新；`dist/AuraDSP-Windows-x64` 已同步。

重新生成资产后，需要再次覆盖这两个文件并重建 App。
