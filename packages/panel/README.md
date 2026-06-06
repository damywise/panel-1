# panel

IDE-style **dockable / tabbed / splittable / detachable** panels for Flutter.
Platform-generic and web-capable: docking, tabs, side-by-side splits,
drag-and-drop, layout persistence and keyboard shortcuts work everywhere.

Detaching panels into separate OS windows is delegated to a
`PanelWindowingBackend`; the default makes detach a no-op. A platform package
such as [`panel_macos`](https://pub.dev/packages/panel_macos) supplies a real
backend (borderless OS windows + drag-back snapping).

## Usage

```dart
import 'package:flutter/material.dart';
import 'package:panel/panel.dart';

final manager = PanelManager(config: const PanelDockConfig())
  ..registerPanel(PanelDescriptor(id: 'explorer', title: 'Explorer',
      builder: (_) => const Explorer()), side: DockSide.left)
  ..registerPanel(PanelDescriptor(id: 'editor', title: 'Editor',
      builder: (_) => const Editor()), side: DockSide.center);

// Expose the manager, then render a PanelDock in your Scaffold body:
PanelScope(
  manager: manager,
  child: MaterialApp(home: Scaffold(body: PanelDock())),
);
```

* `PanelDescriptor` — describes a panel (id, title, icon, content builder).
* `PanelManager` — owns placement (a `ChangeNotifier`); expose via `PanelScope`.
* `PanelDockConfig` / `PanelDockStrings` — all sizing, capabilities and labels.
* `PanelDock` — the workspace widget.

See the [example](https://github.com/your-org/panel/tree/main/example) and the
repository docs for the full picture, including the macOS detach backend.
