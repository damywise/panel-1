// The seam that keeps the core platform-generic.
//
// [PanelManager] never imports the experimental windowing APIs or any native
// code. Instead it talks to a [PanelWindowingBackend]: an abstraction for
// "give this detached panel an external surface (a real OS window)" plus the
// hooks a backend uses to drive drag-back snapping.
//
// The default [DisabledWindowing] makes detaching a no-op, so the core compiles
// and runs anywhere (including web). A platform package (e.g. `panel_macos`)
// supplies a real backend.

import 'panel.dart';
import 'panel_manager.dart';

/// Backend that hosts detached panels in external surfaces (OS windows).
///
/// Implementations live in platform packages. The manager calls [open]/[close]
/// when a panel is detached/re-docked, and the backend reports drag-back via
/// [PanelManager.updateExternalDragHover] / [PanelManager.endExternalDrag].
abstract class PanelWindowingBackend {
  const PanelWindowingBackend();

  /// Whether detaching is available. When false, `PanelManager.detach` is a
  /// no-op (the dock/tabs/splits still work — e.g. on web).
  bool get supportsDetach;

  /// Called once when this backend is attached to [manager].
  void attach(PanelManager manager) {}

  /// Opens an external surface hosting the panel [descriptor]. [origin] is the
  /// dock the panel came from (so it can snap back there by default).
  void open(PanelDescriptor descriptor, {required DockSide origin});

  /// Destroys the external surface for panel [id] (called on re-dock/close).
  void close(String id);

  /// Minimizes the external surface for [id], if the platform supports it.
  void minimize(String id) {}

  /// Brings the external surface for [id] to the front.
  void focus(String id) {}

  /// Begins a platform window-move for [id] (e.g. so a custom header can act as
  /// the window's drag handle).
  void beginWindowDrag(String id) {}
}

/// The default backend: detaching is unsupported, everything else still works.
class DisabledWindowing extends PanelWindowingBackend {
  const DisabledWindowing();

  @override
  bool get supportsDetach => false;

  @override
  void open(PanelDescriptor descriptor, {required DockSide origin}) {}

  @override
  void close(String id) {}
}
