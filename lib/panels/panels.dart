/// Panes — a reusable, IDE-style dockable / detachable panel framework for
/// Flutter desktop.
///
/// Quick start:
/// ```dart
/// // ignore_for_file: invalid_use_of_internal_member, implementation_imports
/// import 'package:flutter/material.dart';
/// import 'package:flutter/src/widgets/_window.dart';
/// import 'panels/panels.dart';
///
/// void main() {
///   WidgetsFlutterBinding.ensureInitialized();
///   final manager = PanelManager(config: const PanelDockConfig())
///     ..registerPanel(PanelDescriptor(id: 'explorer', title: 'Explorer',
///         builder: (_) => const Explorer()), side: DockSide.left)
///     ..registerPanel(PanelDescriptor(id: 'editor', title: 'Editor',
///         builder: (_) => const Editor()), side: DockSide.center);
///
///   runWidget(PanelScope(
///     manager: manager,
///     child: RegularWindow(
///       controller: RegularWindowController(preferredSize: const Size(1180, 760)),
///       child: const MaterialApp(home: Scaffold(body: PanelDock())),
///     ),
///   ));
/// }
/// ```
///
/// * [PanelDescriptor] — describes a panel (id, title, icon, content builder).
/// * [PanelManager] — owns placement; create one and expose it via [PanelScope].
/// * [PanelDockConfig] / [PanelDockStrings] — all tunables and labels.
/// * [PanelDock] — the workspace widget; render it in your main window.
/// * [NativeDock] — optional macOS chrome bridge (hidden title bars + snap-back).
///
/// Requires Flutter's experimental windowing feature: build on the main/master
/// channel and run `flutter config --enable-windowing`. See `MANUAL.md`.
library;

export 'native_dock.dart' show NativeDock;
export 'panel.dart' show DockSide, DockSideLabel, PanelContentBuilder, PanelDescriptor;
export 'panel_config.dart'
    show PanelDockConfig, PanelDockStrings, PanelTheme, PanelTabSpec, PanelStorage;
export 'panel_dock.dart' show PanelDock;
export 'panel_manager.dart' show PanelManager, PanelScope;
export 'panel_shortcuts.dart' show MergePanelIntent, SplitPanelIntent, defaultPanelShortcuts, panelActions;
