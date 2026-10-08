#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject &project);
  virtual ~FlutterWindow();

protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

private:
  HWND CreateNativeVideoSurface();
  void DestroyNativeVideoSurface();
  void ResizeNativeVideoSurface();
  void ScheduleNativeVideoRendererResync();
  void ResyncNativeVideoRenderer(bool force_event = false);
  void SetNativeVideoSurfaceInsets(int top, int bottom);
  void CreateNativeControls();
  void DestroyNativeControls();
  void RecreateNativeControls();
  void ResizeNativeControls();
  void UpdateNativeControlsRegion();
  void BringNativeControlsToFront();
  // Whether the overlay *window* should be on screen: the chrome, or — with
  // the chrome hidden — the in-player zap banner.
  bool NativeOverlayTargetVisible() const;
  void ShowNativeControls(bool visible);
  void ApplyNativeControlsVisibility();
  void InvalidateNativeControls(bool include_subtitles = true);
  void ScheduleNativeControlsHide();
  bool IsCursorOverNativeControls() const;
  void NotifyNativeControlCommand(const std::string &command);
  void UpdateNativeControlState(const flutter::EncodableValue *args);
  // In-player live zapping (docs/player.md "Live zapping"): the `setZapBanner`
  // push, its 3 s auto-hide, and the session-teardown reset.
  void UpdateZapBanner(const flutter::EncodableValue *args);
  void HideZapBanner();
  // The `setQuickList` push: the browsable list the same key ring drives
  // (docs/player.md "The quick list"). `open: false` is a tear-down
  // instruction, not an absence.
  void UpdateQuickList(const flutter::EncodableValue *args);
  // Session teardown for both — the banner, its timer, and the quick list.
  void ResetZapBanner();
  void SetNativeWindowFullscreen(bool fullscreen);
  void SetNativeWindowMiniPlayer(bool mini);
  void RegisterNativeHdrPlayerChannel();
  void RegisterTrayChannel();
  // Answers `iptvs/clock`'s `locale` with the user's regional date/time format
  // (patterns and names), which the shared Flutter overlay's clock badge renders
  // exactly as the GDI badge here does.
  void RegisterClockChannel();

  // System tray icon (docs/player.md "Windows tray icon"): the notification-area
  // icon, its show/hide + exit menu, and the close-to-tray policy. WM_CLOSE
  // hides to the tray (keeping the app running) unless an explicit exit was
  // requested via the tray menu.
  void CreateTrayIcon();
  void DestroyTrayIcon();
  void ShowTrayMenu();
  void HideToTray();
  void RestoreFromTray();
  LRESULT HandleTrayCallback(LPARAM lparam);
  void SetAlwaysOnTop(bool on);

  // Window placement persistence (docs/player.md "System tray icon"): the last
  // position and size, kept by Dart in the keychain and applied here on boot.
  // Dart owns the preference because the keychain is Dart's; the runner owns
  // the HWND, so these two calls are the whole native surface.
  // `CurrentWindowPlacement` is read back when the window hides or the app
  // quits - never on WM_MOVE, which would keychain-write on every drag frame.
  flutter::EncodableMap CurrentWindowPlacement();
  bool ApplyWindowPlacement(const flutter::EncodableMap& args);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      native_hdr_channel_;
  // The tray-notification channel (native → Dart): carries `trayHidden` so Dart
  // can silence playback when the window hides, which the `hidden` lifecycle
  // does not reach on Windows.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      tray_channel_;
  // The regional-format channel (native → Dart): answers once at boot with the
  // patterns and names the Dart overlay's clock badge formats against.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      clock_channel_;

  // Native child HWND used by mpv for Windows HDR playback.
  HWND native_video_surface_ = nullptr;
  HWND native_controls_overlay_ = nullptr;
  int native_video_surface_top_inset_ = 0;
  int native_video_surface_bottom_inset_ = 0;
  // Remaining post-transition re-checks that mpv's VO window still matches the
  // surface (see ResyncNativeVideoRenderer).
  int native_video_resync_passes_ = 0;
  bool native_controls_visible_ = true;
  bool native_controls_region_dirty_ = true;
  bool native_controls_pinned_ = false;
  ULONGLONG native_ignore_input_until_ = 0;
  bool native_window_fullscreen_ = false;
  // Always-on-top mini-player mode. Mutually exclusive with fullscreen; both
  // save/restore through the shared *_windowed_* placement fields below.
  bool native_window_mini_ = false;
  WINDOWPLACEMENT native_windowed_placement_ = {};
  LONG_PTR native_windowed_style_ = 0;
  LONG_PTR native_windowed_ex_style_ = 0;

  // System tray icon state. `close_to_tray_` is the X-button policy (true = hide
  // to the tray and keep the app running; false = quit); `force_quit_` is set by
  // the tray "Exit" so a real close cannot be intercepted. `tray_owner_hwnd_` is
  // the top-level HWND the icon was added to, retained because OnDestroy runs
  // after the base class has already nulled its own window handle.
  bool close_to_tray_ = true;
  bool force_quit_ = false;
  bool tray_icon_created_ = false;
  HWND tray_owner_hwnd_ = nullptr;
};

#endif // RUNNER_FLUTTER_WINDOW_H_
