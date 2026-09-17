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

import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'panel.dart';
import 'panel_manager.dart';

/// A rasterized image of a tab being dragged (the pill the user sees), shown
/// on the cursor while the pointer is outside the main window.
///
/// Produced by the dock (captured from the drag feedback) and handed to a
/// [PanelWindowingBackend] that knows how to paint an image on the cursor
/// (e.g. via an OS overlay window). The core never renders it itself.
@immutable
class PanelDragImage {
  const PanelDragImage({
    required this.rgba,
    required this.width,
    required this.height,
    required this.logicalSize,
    required this.anchorOffset,
  });

  /// Raw non-premultiplied RGBA pixels (`width * height * 4` bytes).
  final Uint8List rgba;

  /// Pixel dimensions of [rgba].
  final int width;
  final int height;

  /// The image's size in logical pixels (what the user saw in the dock).
  final Size logicalSize;

  /// Where the pointer sits within the image, in logical pixels, so a backend
  /// can anchor the image to the cursor exactly where the in-window feedback
  /// was before the pointer left the window.
  final Offset anchorOffset;
}

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

  /// Opens an external surface for [descriptor] **at the pane's own rect**, for
  /// the immediate (drag-out) tear-off.
  ///
  /// This is the libnativeapi gesture: once the drag has passed
  /// [PanelDockConfig.popOutDistance] and the pointer has left the dock, the
  /// docked pane stops being docked and starts being a window — no ghost, no
  /// small pill, the pane itself — and follows the cursor with the grabbed point
  /// pinned under it until release.
  ///
  /// Geometry is in the main window's **logical** view coordinates:
  ///
  /// * [paneRect] — the docked pane's rect (tab strip **and** body). Its size
  ///   is what the new surface should be, so the content does not reflow.
  /// * [headerHeight] — the chrome the surface adds *above* the content (title
  ///   strip). The surface should render a header exactly this tall and size
  ///   itself to `paneRect.size`, which leaves the content the same height it
  ///   had docked (`paneRect.height - headerHeight`).
  /// * [pointerInPane] — where the cursor was inside [paneRect] when the pointer
  ///   went **down** (not where it crossed the threshold), so the surface can
  ///   anchor the grabbed point under the cursor and travel exactly as far as the
  ///   pointer did from the press.
  ///
  /// The backend owns the gesture from here on: the window that received the
  /// press may never see the release, so it must track the global cursor and
  /// finish by calling [PanelManager.endExternalDrag] (which re-docks over a
  /// zone, or leaves the panel floating) and, for a cancel, stopping its own
  /// tracker. The default implementation ignores the geometry and calls
  /// [open], so backends that only support release-to-detach keep working.
  void openTearOff(
    PanelDescriptor descriptor, {
    required DockSide origin,
    required Rect paneRect,
    required double headerHeight,
    required Offset pointerInPane,
  }) {
    open(descriptor, origin: origin);
  }

  /// Dims (or un-dims) the surface hosting [id] while it hovers over a dock
  /// zone, so the main window's "it lands *here*" preview stays visible
  /// underneath the surface the user is dragging.
  ///
  /// Called by [PanelManager] every time the hovered zone of an in-flight
  /// tear-off changes (never for a plain window move). Default: no-op.
  void setTearOffDim(String id, bool dimmed) {}

  /// Destroys the external surface for panel [id] (called on re-dock/close).
  void close(String id);

  /// Minimizes the external surface for [id], if the platform supports it.
  void minimize(String id) {}

  /// Brings the external surface for [id] to the front.
  void focus(String id) {}

  /// Begins a platform window-move for [id] (e.g. so a custom header can act as
  /// the window's drag handle).
  void beginWindowDrag(String id) {}

  /// Whether this backend can paint a drag image on the cursor while a tab is
  /// dragged outside the main window. When false, the dock skips capturing the
  /// image and [showDragImage]/[hideDragImage] are never called.
  bool get supportsDragImage => false;

  /// Shows [image] following the cursor while a tab is dragged outside the
  /// main window. The backend decides where/whether to display it (the default
  /// does nothing). Called at drag start; always followed by [hideDragImage]
  /// when the drag ends.
  void showDragImage(PanelDragImage image) {}

  /// Hides (and releases) the drag image shown by [showDragImage].
  void hideDragImage() {}
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
