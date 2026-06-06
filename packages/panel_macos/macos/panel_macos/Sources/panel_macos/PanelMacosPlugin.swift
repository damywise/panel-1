import Cocoa
import FlutterMacOS

// macOS native side of `package:panel_macos`.
//
// The dock is driven from Dart over **FFI** (see lib/src/native_dock.dart):
// forward calls are the `@_cdecl` functions below; reverse drag/drop events go
// through registered C function pointers. Dart resolves these symbols with
// `DynamicLibrary.process()` (they live in this plugin's framework). The C ABI
// is src/panes_dock.h (ffigen input).

/// Registrant. Declaring a pluginClass makes the GeneratedPluginRegistrant load
/// this framework, and the keep-alive below stops the linker from stripping the
/// `@_cdecl` entry points (which are only ever reached via dlsym).
public class PanelMacosPlugin: NSObject, FlutterPlugin {
  private static var keepAlive: [Any] = []

  public static func register(with registrar: FlutterPluginRegistrar) {
    keepAlive = [
      panes_dock_register,
      panes_dock_decorate,
      panes_dock_decorate_main,
      panes_dock_start_window_drag,
    ]
  }
}

typealias PanesDragCallback = @convention(c) (
  UnsafePointer<CChar>?, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double
) -> Void
typealias PanesDropCallback = @convention(c) (UnsafePointer<CChar>?) -> Void

/// Owns all native window/dock state and logic.
final class PanesDock: NSObject {
  static let shared = PanesDock()

  private var panels: [String: NSWindow] = [:]
  private var draggingToken: String?
  private var dragTimer: Timer?
  var dragCallback: PanesDragCallback?
  var dropCallback: PanesDropCallback?

  // MARK: Forward calls (Dart -> native)

  /// Hides the title bar of the panel window matching `token`, opens it at the
  /// pointer/active Space, and starts reporting its drags.
  func decorate(token: String, attemptsLeft: Int) {
    guard let window = NSApp.windows.first(where: { $0.title == token }) else {
      if attemptsLeft > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
          self?.decorate(token: token, attemptsLeft: attemptsLeft - 1)
        }
      }
      return
    }

    window.styleMask.insert(.fullSizeContentView)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.standardWindowButton(.closeButton)?.isHidden = true
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    window.backgroundColor = NSColor.windowBackgroundColor
    window.isOpaque = false
    window.hasShadow = true

    // Open on the Space/screen the user is actually looking at, near the
    // pointer (where the tear-off happened).
    window.collectionBehavior.insert(.moveToActiveSpace)
    let mouse = NSEvent.mouseLocation
    window.setFrameTopLeftPoint(NSPoint(x: mouse.x - 60, y: mouse.y + 12))
    window.makeKeyAndOrderFront(nil)

    panels[token] = window
    NotificationCenter.default.addObserver(
      self, selector: #selector(panelMoved(_:)), name: NSWindow.didMoveNotification, object: window)
    NotificationCenter.default.addObserver(
      self, selector: #selector(panelClosed(_:)), name: NSWindow.willCloseNotification, object: window)
  }

  /// Transparent, full-size title bar for the main window (keeps traffic lights).
  func decorateMain(attemptsLeft: Int) {
    guard let window = mainWindow() else {
      if attemptsLeft > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
          self?.decorateMain(attemptsLeft: attemptsLeft - 1)
        }
      }
      return
    }
    window.styleMask.insert(.fullSizeContentView)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
  }

  /// Begins a native window-move using the current mouse-down event, so the
  /// Flutter-drawn header acts as the window's drag handle.
  func startWindowDrag(token: String) {
    guard let window = panels[token] ?? NSApp.windows.first(where: { $0.title == token }),
      let event = NSApp.currentEvent
    else { return }
    window.performDrag(with: event)
  }

  // MARK: Drag tracking (reverse callbacks)

  @objc private func panelMoved(_ note: Notification) {
    guard let window = note.object as? NSWindow,
      let token = panels.first(where: { $0.value == window })?.key
    else { return }
    draggingToken = token
    reportDrag(token: token, window: window)
    startDragTimer()
  }

  private func startDragTimer() {
    if dragTimer != nil { return }
    dragTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      self?.tickDrag()
    }
  }

  private func stopDragTimer() {
    dragTimer?.invalidate()
    dragTimer = nil
  }

  /// Each frame while dragging: stream live geometry, detect the drop via the
  /// physical mouse-button state.
  private func tickDrag() {
    guard let token = draggingToken, let window = panels[token] else {
      stopDragTimer()
      return
    }
    if (NSEvent.pressedMouseButtons & 0x1) != 0 {
      reportDrag(token: token, window: window)
    } else {
      stopDragTimer()
      draggingToken = nil
      // `token` is freed by the Dart callback (strdup'd here).
      dropCallback?(strdup(token))
    }
  }

  /// Sends window/main frames and the pointer to Dart. The token is strdup'd and
  /// freed on the Dart side.
  private func reportDrag(token: String, window: NSWindow) {
    guard let cb = dragCallback, let main = mainWindow() else { return }
    let h = referenceHeight()
    let p = topLeft(window.frame, h)
    let m = topLeft(main.frame, h)
    let mouse = NSEvent.mouseLocation
    cb(strdup(token), p.x, p.y, p.w, p.h, m.x, m.y, m.w, m.h, Double(mouse.x), h - Double(mouse.y))
  }

  @objc private func panelClosed(_ note: Notification) {
    guard let window = note.object as? NSWindow,
      let token = panels.first(where: { $0.value == window })?.key
    else { return }
    NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: window)
    NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
    panels.removeValue(forKey: token)
    if draggingToken == token {
      stopDragTimer()
      draggingToken = nil
    }
  }

  // MARK: Helpers

  private func mainWindow() -> NSWindow? {
    return NSApp.windows
      .filter { $0.isVisible && !$0.title.hasPrefix("panel::") && $0.contentView != nil }
      .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
  }

  /// Shared reference height for the bottom-left -> top-left flip. Any constant
  /// works as long as it's applied to both frames (the flip is affine).
  private func referenceHeight() -> Double {
    return Double(NSScreen.screens.first?.frame.height ?? 0)
  }

  private func topLeft(_ f: NSRect, _ h: Double) -> (x: Double, y: Double, w: Double, h: Double) {
    return (Double(f.minX), h - Double(f.minY + f.height), Double(f.width), Double(f.height))
  }
}

// MARK: - @_cdecl C ABI (resolved from Dart via DynamicLibrary.process())

@_cdecl("panes_dock_register")
func panes_dock_register(_ drag: PanesDragCallback?, _ drop: PanesDropCallback?) {
  PanesDock.shared.dragCallback = drag
  PanesDock.shared.dropCallback = drop
}

@_cdecl("panes_dock_decorate")
func panes_dock_decorate(_ token: UnsafePointer<CChar>?) {
  guard let token = token else { return }
  PanesDock.shared.decorate(token: String(cString: token), attemptsLeft: 12)
}

@_cdecl("panes_dock_decorate_main")
func panes_dock_decorate_main() {
  PanesDock.shared.decorateMain(attemptsLeft: 12)
}

@_cdecl("panes_dock_start_window_drag")
func panes_dock_start_window_drag(_ token: UnsafePointer<CChar>?) {
  guard let token = token else { return }
  PanesDock.shared.startWindowDrag(token: String(cString: token))
}
