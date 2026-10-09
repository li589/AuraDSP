#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // 默认尺寸是「外框」尺寸（含非客户区边框，本机实测约 15×38）。
  // 目标客户区 1360×862：左栏 216 + 左右页边距 32×2 + 内容上限 1080 = 1360，
  // 保证默认尺寸下 contentMaxW 能被真正取到，而不是被边框吃掉 15px。
  Win32Window::Size size(1376, 900);
  // 最小尺寸须在 Create 之前设置（Create 时按 DPI 缩放并交给 WM_GETMINMAXINFO）。
  // 外框 1176×800 → 客户区约 1161×762，低于此值左栏 + 内容区会把 8pt 留白压塌。
  window.SetMinimumSize(Win32Window::Size(1176, 800));
  if (!window.Create(L"AuraDSP", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
