#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 第十轮项 1：OnCreate 时保存的顶层窗口句柄。OnDestroy 被调用时
  // 基类的 window_handle_ 可能已被清零，靠它撤销 GWLP_USERDATA
  // 分发关联（见 flutter_window.cpp OnDestroy 的 v2 修复说明）。
  HWND self_hwnd_ = nullptr;

  // 第十轮项 1：销毁开始旗标；MessageHandler 见之直走基类处理，
  // 不再把消息交给控制器 proc。
  bool destroying_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
