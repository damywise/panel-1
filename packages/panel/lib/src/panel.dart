// A reusable, IDE-style dockable panel framework for Flutter desktop.
//
// This file defines the plain data types of the framework. It has no
// dependency on the (experimental) windowing APIs, so it stays trivially
// testable and import-clean.

import 'package:flutter/widgets.dart';

/// Builds the body of a panel. Receives the [BuildContext] of the host
/// (either the docked tab area in the main window, or a detached OS window).
typedef PanelContentBuilder = Widget Function(BuildContext context);

/// The dockable regions of the workspace.
///
/// [center] is the primary area (think: the editor). [left], [right] and
/// [bottom] are the side docks that hold tool panels.
enum DockSide { left, right, bottom, center }

extension DockSideLabel on DockSide {
  String get label => switch (this) {
        DockSide.left => 'Left',
        DockSide.right => 'Right',
        DockSide.bottom => 'Bottom',
        DockSide.center => 'Center',
      };

  /// Whether the region grows horizontally (side docks) or is the flexible
  /// center.
  bool get isHorizontalDock => this == DockSide.left || this == DockSide.right;
}

/// Immutable description of a panel that can be docked or detached.
///
/// A [PanelDescriptor] is registered once with the [PanelManager]; its
/// [builder] is invoked wherever the panel currently lives.
@immutable
class PanelDescriptor {
  const PanelDescriptor({
    required this.id,
    required this.title,
    required this.builder,
    this.icon,
    this.detachedSize,
    this.detachable = true,
    this.contentKey,
  });

  /// Stable, unique identifier used by the manager to track placement.
  final String id;

  /// Human-readable title shown on the tab and the detached window.
  final String title;

  /// Optional icon shown on the tab.
  final IconData? icon;

  /// Builds the panel's content.
  final PanelContentBuilder builder;

  /// Preferred size of this panel's detached floating window. When null,
  /// `PanelDockConfig.defaultDetachedSize` is used.
  final Size? detachedSize;

  /// Whether this panel may be detached into its own floating window. When
  /// false, the detach button and tab drag-tear-off are suppressed.
  final bool detachable;

  /// Optional [GlobalKey] for the panel's *content* subtree.
  ///
  /// The dock and the detached window both render the panel through
  /// [PanelManager.contentOf], which wraps [builder] in a `KeyedSubtree` with
  /// this key. Because a `GlobalKey` is unique app-wide (and detached windows
  /// are sibling views of the same `BuildOwner`), tearing a panel off moves the
  /// *existing element* into the new window instead of rebuilding it — so
  /// scroll offsets, `TabController`s, text fields and running animations
  /// survive the move, exactly as if the pane had been carried by hand.
  ///
  /// A [GlobalKey] cannot be a `const` default, so leaving this null is the
  /// normal case: [PanelManager.registerPanel] mints and remembers one per id.
  /// Supply your own only if something else needs to find the content subtree.
  final GlobalKey? contentKey;
}
