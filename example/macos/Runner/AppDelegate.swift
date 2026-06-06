import Cocoa
import FlutterMacOS

// The ONLY macOS-native code the example owns: a headless multi-window engine
// bootstrap. The dock's native behavior (title-bar hiding, drag-back) ships in
// the `panel_macos` plugin and registers via GeneratedPluginRegistrant.
//
// In multi-window mode Dart creates every window (including the main one) via
// the windowing APIs, so the runner must NOT attach a FlutterViewController up
// front — doing so makes `enableMultiView` abort on the first window.
@main
class AppDelegate: FlutterAppDelegate {
  var engine: FlutterEngine?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let engine = FlutterEngine(name: "panel", project: nil)
    engine.run(withEntrypoint: nil)
    RegisterGeneratedPlugins(registry: engine)
    self.engine = engine
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
