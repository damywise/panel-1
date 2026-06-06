/// macOS backend for `package:panel`: detached panels become real borderless
/// top-level windows (Flutter windowing) with native chrome and drag-back
/// snapping (FFI to AppKit).
///
/// Usage:
/// ```dart
/// final backend = MacosWindowingBackend();
/// final manager = PanelManager(config: const PanelDockConfig(), windowing: backend);
/// // ...inside your MaterialApp, above the PanelDock:
/// MacosPanelHost(backend: backend, child: const Workspace());
/// ```
///
/// Requires Flutter's experimental windowing feature (main/master channel +
/// `flutter config --enable-windowing`) and the macOS multi-window runner
/// bootstrap — see the package README.
library;

export 'src/macos_windowing.dart' show MacosWindowingBackend, MacosPanelHost;
