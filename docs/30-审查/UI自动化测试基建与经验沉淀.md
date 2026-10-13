# AuraDSP UI 自动化测试基建与经验沉淀指南

> **核心目标**：彻底解决 UI 测试脚本各自为政、反复修改启动代码、坐标漂移、窗口未置顶、事件被吞噬及僵尸进程锁死等顽疾，沉淀标准化、极简化的端到端自动化测试框架。

---

## 一、历史六大踩坑与根因深度剖析

在以往的 Flutter Desktop (Windows) 自动化测试编写中，最常导致测试脚本反复修改、假通过或偶发挂起的六大根因如下：

### 1. DPI 缩放与物理坐标漂移（最隐蔽的偏差）
- **现象**：测试脚本写了 `(580, 520)`，但在高分屏（125%、150% 或 200% 缩放）下，鼠标总是点在控件外侧或空白处。
- **根因**：Windows 默认将 Python 解释器当作 System DPI 虚拟化应用，Win32 API `SetCursorPos` 使用的是操作系统物理屏幕像素，而某些屏幕度量 API 取到的是虚拟化缩放坐标，导致绝对坐标系统发生缩放形变。
- **基建根治**：在 `ui_test_kit.py` 模块导入最顶部显式声明 Per-Monitor v2 级别感知：
  ```python
  ctypes.windll.shcore.SetProcessDpiAwareness(2) # Per-Monitor v2
  ```

### 2. `WinSta0\Default` 桌面会话隔离与事件静默丢弃
- **现象**：后台执行、IDE 终端执行或沙箱调度时，`EnumWindows` 找不到窗口，`SetForegroundWindow` 失败，`mouse_event` 毫无响应。
- **根因**：Windows 服务或非交互式 shell 派生的子进程可能不在当前活动交互桌面上，线程桌面关联脱落。
- **基建根治**：在每个检索与输入动作前主动切入默认桌面，并配置 `STARTUPINFO.lpDesktop = "WinSta0\\Default"`：
  ```python
  def switch_to_default_desktop():
      h_desk = user32.OpenDesktopW("Default", 0, False, 0x01FF)
      if h_desk:
          user32.SetThreadDesktop(h_desk)
  ```

### 3. 孤儿僵尸进程互斥与文件锁死
- **现象**：前一次测试由于断言失败或 Ctrl+C 中断，`auradsp_app.exe` 残留于后台。后续测试启动时，或无法独占音频设备，或连接到旧窗口，或导致 `%APPDATA%/AuraDSP/session_state.json` 发生读写锁冲突。
- **基建根治**：启动新会话前执行幂等强杀，退出时采用 `WM_CLOSE` 优雅退出配合超时清理：
  ```python
  def kill_existing_instances():
      subprocess.run(["taskkill", "/F", "/IM", "auradsp_app.exe"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
  ```

### 4. 窗口几何随意与硬编码坐标脆弱性
- **现象**：测试脚本 A 将窗口设为 1280x720，测试脚本 B 设为 1366x860，测试脚本 C 设为 1400x900。当导航栏或列表根据窗口高度自动拉伸时，硬编码的坐标就会在不同脚本间全部错位。
- **基建根治**：全工程所有 UI 自动化统一强制归一化到 **1400 × 900 物理画布**，左上角固定在 `(80, 50)`：
  ```python
  user32.MoveWindow(hwnd, 80, 50, 1400, 900, True)
  ```

### 5. 控件状态禁用陷阱（Disabled 丢弃交互）
- **现象**：鼠标明明已经移动到滑块上按下了，但滑块纹丝不动。
- **根因**：Flutter 的 `Slider` 当外层开关（如低音、混响、电子管）处于关闭状态时，其 `onChanged` 传入 `null`，此时底层渲染树将直接忽略所有手势指针事件（PointerDown / PointerMove），任何自动化点击与拖拽都会被静默丢弃。
- **基建根治**：在交互前必须确保外层卡片开关处于开启态，或者在测试用例中明确包含先点亮开关再调参数的前置步骤。

### 6. 重复造轮子与样板代码爆炸
- **现象**：每个新测试脚本复制粘贴 150 行 Win32 GDI DC、BITMAPINFOHEADER、EnumWindows、鼠标事件封装代码，一旦修复一处 bug，其他 10 个脚本全部掉队。
- **基建根治**：统一收敛至 `test/ui/ui_test_kit.py`，对外暴露极简上下文管理器 `AuraAppSession`。

---

## 二、统一自动化测试基建体系 (`ui_test_kit.py`)

统一基建提供了高层面向对象的会话管理器：

```
AuraAppSession (Context Manager)
  ├── 启动/发现: 幂等清理旧进程 -> CreateProcessW -> 轮询探测 HWND
  ├── 几何归一: MoveWindow(80, 50, 1400, 900) -> 确保物理尺寸固定
  ├── 焦点控制: ensure_foreground (SW_RESTORE -> TOPMOST -> NOTOPMOST)
  ├── 语义导航: navigate_to("effects" | "chain" | "plugins" | "liveprog" | "settings")
  ├── 键鼠交互: click(rx, ry), double_click(rx, ry), drag(rx0, rx1, ry)
  ├── 高清捕获: capture(filepath, local_box=None) (自动建立目录)
  ├── 差分断言: assert_images_differ(img1, img2, min_pixels=20)
  └── 优雅收工: __exit__ -> WM_CLOSE -> 等待落盘 -> 彻底回收资源
```

### 导航标准相对坐标速查表（1400 × 900 标准画布）

| 页面/功能 | 语义方法 | 映射相对坐标 (x, y) | 说明 |
| :--- | :--- | :--- | :--- |
| **效果器面板** | `app.navigate_to("effects")` | `(36, 120)` | 左侧导航栏第 1 项 |
| **处理链页面** | `app.navigate_to("chain")` | `(36, 175)` | 左侧导航栏第 2 项 |
| **插件中心** | `app.navigate_to("plugins")` | `(36, 230)` | 左侧导航栏第 3 项 |
| **Liveprog 脚本** | `app.navigate_to("liveprog")` | `(36, 285)` | 左侧导航栏第 4 项 |
| **系统设置弹窗** | `app.navigate_to("settings")` | `(1360, 28)` | 顶栏右上角设置齿轮按钮 |

---

## 三、极简编写新 UI 自动化测试模板

借助 `AuraAppSession`，编写一个新测试仅需 **3~10 行代码**，无需处理任何底层 Win32 API：

```python
# -*- coding: utf-8 -*-
"""示例：新建 UI 验证测试脚本"""

from ui_test_kit import AuraAppSession
import time

def test_feature():
    # 1. 使用上下文管理器启动并归一化画布
    with AuraAppSession(title="新功能验证测试") as app:
        # 2. 语义化导航至目标页面
        app.navigate_to("plugins")
        time.sleep(1.0)
        
        # 3. 截取基线截图
        img_before = app.capture("docs/ui-redesign/step1_baseline.png")
        
        # 4. 执行操作（例如点击操作按钮）
        app.click(1220, 142)
        time.sleep(1.0)
        
        # 5. 截取后置截图并执行真实视觉差分断言
        img_after = app.capture("docs/ui-redesign/step2_clicked.png")
        diff_count = app.assert_images_differ(img_before, img_after, min_diff_pixels=50, label="插件扫描")
        print(f"验证通过！视觉变化像素: {diff_count}")

if __name__ == "__main__":
    test_feature()
```

---

## 四、UI 自动化测试维护 Checklist

编写或修改 UI 自动化脚本时，请逐项核对：

- [ ] **是否使用了 `AuraAppSession`**：严禁私自使用 `subprocess.Popen` 或裸调 Win32 API 启动应用；
- [ ] **是否使用了 `navigate_to()`**：严禁硬编码左侧导航栏图标坐标；
- [ ] **是否做了视觉差分断言 (`assert_images_differ`)**：严禁“点击后无论画面是否变化都直接当做 PASS”；
- [ ] **控件是否处于已激活状态**：若要拖拽滑块，必须先确保卡片主开关已开启；
- [ ] **截图保存路径是否规范**：统一保存至 `docs/ui-redesign/` 目录，命名风格为 `模块_阶段_序号_描述.png`；
- [ ] **测试文件存放位置**：测试脚本统一存放在 `test/ui/`，并接入 `test/runner.py --ui` 统一测试入口。
