#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Same class name as win32_window.cpp registers.
constexpr wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// The demo `--profile=name` (or `--profile name`), so two profiles can run
// side by side. Only 1-20 lowercase letters or digits count, as in the app.
std::wstring ProfileName(const std::vector<std::string> &args) {
  std::string value;
  for (size_t i = 0; i < args.size(); i++) {
    if (args[i].rfind("--profile=", 0) == 0) {
      value = args[i].substr(10);
    } else if (args[i] == "--profile" && i + 1 < args.size()) {
      value = args[i + 1];
    }
  }
  if (value.empty() || value.size() > 20) return L"";
  for (char c : value) {
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))) return L"";
  }
  return std::wstring(value.begin(), value.end());
}

// Brings the first copy's window forward, also when it is hidden in the
// tray or minimized.
void ShowRunningWindow(const std::wstring &title) {
  HWND window = ::FindWindowW(kWindowClassName, title.c_str());
  if (window == nullptr) return;
  if (!::IsWindowVisible(window)) {
    ::ShowWindow(window, SW_SHOW);
  }
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  }
  ::SetForegroundWindow(window);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();

  // One window per user and profile: a second launch shows the first one.
  const std::wstring profile = ProfileName(command_line_arguments);
  const std::wstring title =
      profile.empty() ? L"Veritra" : L"Veritra (" + profile + L")";
  HANDLE instance_mutex = ::CreateMutexW(
      nullptr, FALSE, (L"Local\\VeritraSingleInstance-" + profile).c_str());
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ShowRunningWindow(title);
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1100, 760);
  if (!window.Create(title, origin, size)) {
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
