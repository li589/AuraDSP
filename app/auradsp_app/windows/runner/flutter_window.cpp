#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 第十轮项 1：保存顶层窗口句柄供 OnDestroy 撤销分发关联用
  // （届时基类 window_handle_ 可能已被清零）。
  self_hwnd_ = GetHandle();

  bool start_in_tray = false;
  for (const auto& arg : project_.dart_entrypoint_arguments()) {
    if (arg == "--tray" || arg == "-tray" || arg == "--minimized") {
      start_in_tray = true;
      break;
    }
  }

  if (!start_in_tray) {
    flutter_controller_->engine()->SetNextFrameCallback([&]() {
      this->Show();
    });
  }

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // 第十轮项 1（v2，结构性修复）：第九轮 361afd78 的成员移空
  // 没拦住同签名崩溃——vm-win10 pid 9884 dump（2026-11-11
  // 18:11）完整栈实证：补丁 obj 已重编、装机 exe 与 dist
  // 哈希一致，修复在场仍崩，入口仍为本函数调
  // FlutterDesktopViewControllerDestroy 后子窗口销毁回调重入
  // MessageHandler。微观机制未定（疑成员置空存储被沉降），
  // 本版不依赖成员守卫，改为在销毁控制器之前先切断分发链：
  //   1) destroying_ 旗标——MessageHandler 首行见之直走基类；
  //   2) 撤销 GWLP_USERDATA 关联——WindowProc 的
  //      GetThisFromHandle 落空，重入消息直达 DefWindowProc，
  //      根本进不了 MessageHandler。
  destroying_ = true;
  if (self_hwnd_ != nullptr &&
      Win32Window::GetThisFromHandle(self_hwnd_) == this) {
    SetWindowLongPtr(self_hwnd_, GWLP_USERDATA, 0);
  }
  if (flutter_controller_) {
    // 先把成员移空再销毁控制器（第九轮项 4 定罪）：直接对成员
    // 赋 nullptr 时，控制器析构在赋值完成前运行，其间销毁子
    // 视图 HWND 会把窗口消息同步重入 MessageHandler，成员仍
    // 指向半析构的控制器 → HandleTopLevelWindowProc 解引用
    // 引擎内部已释放指针（rcx=0）→ 退出时崩溃（vm-win10
    // 2026-11-11 dump：flutter_windows+0x1e220，c0000005 →
    // c000041d FATAL_USER_CALLBACK_EXCEPTION；同签名 10-24
    // 旧版已现）。移空后重入消息只走基类默认处理，安全。
    auto controller = std::move(flutter_controller_);
    controller.reset();
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 第十轮项 1：销毁开始后不再把任何消息交给控制器 proc
  // （与 OnDestroy 的分发关联撤销双保险）。
  if (destroying_) {
    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      // 同上：控制器销毁后仍可能收到该消息，裸解引用即空指针。
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
