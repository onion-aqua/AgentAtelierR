#include "flutter_window.h"

#include <optional>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

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
  // Desktop window controls used by the Flutter UI.
  auto window_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "agentatelier/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "setBorderless") {
      const auto* enabled = std::get_if<bool>(call.arguments());
      if (!enabled) {
        result->Error("invalid_argument", "Expected a boolean.");
        return;
      }
      const HWND hwnd = GetHandle();
      if (!framed_style_) framed_style_ = GetWindowLongPtr(hwnd, GWL_STYLE);
      RECT client{};
      GetClientRect(hwnd, &client);
      POINT origin{0, 0};
      ClientToScreen(hwnd, &origin);
      const LONG_PTR style = *enabled
          ? ((framed_style_ & ~WS_OVERLAPPEDWINDOW) | WS_POPUP)
          : framed_style_;
      RECT frame{0, 0, client.right, client.bottom};
      AdjustWindowRectExForDpi(&frame, static_cast<DWORD>(style), FALSE,
          static_cast<DWORD>(GetWindowLongPtr(hwnd, GWL_EXSTYLE)), GetDpiForWindow(hwnd));
      SetWindowLongPtr(hwnd, GWL_STYLE, style);
      SetWindowPos(hwnd, nullptr, origin.x + frame.left, origin.y + frame.top,
          frame.right - frame.left, frame.bottom - frame.top,
          SWP_FRAMECHANGED | SWP_NOZORDER | SWP_NOACTIVATE);
      result->Success();
      return;
    }
    if (call.method_name() == "startDrag" || call.method_name() == "startResize") {
      ReleaseCapture();
      PostMessage(GetHandle(), WM_SYSCOMMAND,
          call.method_name() == "startDrag" ? SC_MOVE | HTCAPTION : SC_SIZE | WMSZ_BOTTOMRIGHT, 0);
      result->Success();
      return;
    }
    if (call.method_name() == "minimize") {
      ShowWindow(GetHandle(), SW_MINIMIZE);
      result->Success();
      return;
    }
    if (call.method_name() == "close") {
      PostMessage(GetHandle(), WM_CLOSE, 0, 0);
      result->Success();
      return;
    }
    if (call.method_name() == "setAlwaysOnTop") {
      const auto* value = std::get_if<bool>(call.arguments());
      if (value) {
        SetWindowPos(GetHandle(), *value ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        result->Success();
      } else {
        result->Error("invalid_argument", "Expected a boolean.");
      }
      return;
    }
    result->NotImplemented();
  });
  window_channel_ = std::move(window_channel);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  window_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
