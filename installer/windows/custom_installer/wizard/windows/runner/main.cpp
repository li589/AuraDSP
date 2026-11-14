#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

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

  // Single-instance guard (2026-11-14): two Setup wizards writing
  // into the same install directory corrupt each other, so the
  // wizard holds a session-local named mutex for its whole
  // lifetime. The bootstrapper only pre-checks it (fast path); the
  // authoritative check is here. The one legitimate second process
  // is the elevation handover: it carries --resume-options and
  // retries briefly while the unelevated instance exits.
  {
    auto has_arg = [&command_line_arguments](const char* token) {
      return std::find(command_line_arguments.begin(),
                       command_line_arguments.end(),
                       token) != command_line_arguments.end();
    };
    const bool resume = has_arg("--resume-options");
    const bool silent =
        has_arg("--silent") || has_arg("/silent") || has_arg("/S");
    HANDLE setup_mutex = nullptr;
    for (int attempt = 0;; ++attempt) {
      setup_mutex = ::CreateMutexW(nullptr, TRUE, L"AuraDSP-Setup-Instance");
      if (setup_mutex != nullptr &&
          ::GetLastError() != ERROR_ALREADY_EXISTS) {
        break;
      }
      if (setup_mutex != nullptr) {
        ::CloseHandle(setup_mutex);
        setup_mutex = nullptr;
      }
      if (!resume || attempt >= 60) break;
      ::Sleep(250);
    }
    if (setup_mutex == nullptr) {
      if (!silent) {
        ::MessageBoxW(
            nullptr,
            L"AuraDSP 安装程序已在运行，请切换到已打开的安装窗口继续。\n\n"
            L"Another AuraDSP Setup is already running. "
            L"Switch to the open Setup window to continue.",
            L"AuraDSP Setup", MB_OK | MB_ICONINFORMATION);
      }
      return EXIT_FAILURE;
    }
    // Intentionally never closed; released by process exit.
    static HANDLE setup_mutex_keepalive = setup_mutex;
    (void)setup_mutex_keepalive;
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(920, 600);
  if (!window.Create(L"AuraDSP Setup", origin, size)) {
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
