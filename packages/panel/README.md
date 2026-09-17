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

## Tearing a panel off

Dragging a tab out of the workspace does not produce a ghost. The **pane becomes a
window**: the backend is handed the pane's own rect (`openTearOff`), the pane's
live content is reparented into it by a `GlobalKey` (so scroll offsets,
controllers and running animations survive), and it follows the cursor until
release. Released over a dock zone it re-docks; released anywhere else it stays
floating; `Esc` puts it back where it came from.

`PanelDockConfig.tearOffOnDragStart` picks *when*:

- `false` (default) — past `popOutDistance` (8 px, the Chrome/libnativeapi
  threshold) **and** once the pointer leaves the dock's bounds. While the pointer
  is still over the dock the drag stays an ordinary dock drag — reorder, split,
  drop on another group or region — because every one of those targets lives
  inside the dock, and tearing off early would make them all unreachable (Chrome
  gates tab detach on leaving the window for the same reason).
- `true` — the pane is a window from the drag's **own first frame**, with no
  threshold and no need to leave the dock, and **the tab pill is never drawn**
  (the pane is the drag visual, so its feedback is suppressed). No drop preview and
  no tab reorder either; the torn-off pane still re-docks when dropped on a dock
  zone, and `Esc` puts it back. This is the right behavior when the point of the
  gesture is the window itself (pulling a panel onto another monitor) and the wrong
  one when in-dock rearrangement matters more. Trade-off: a mouse only starts a
  drag above `kPrecisePointerHitSlop` (1.0, resolved strictly), so ~2 px, and a
  *click* that jitters is a drag too — it flashes a window, which then re-docks and
  activates the tab. Default is `false` partly for exactly that reason.

Either way a tab that is not its group's active one tears off fine: the rect comes
from the group's body slot, which is shared by all of its tabs.

Two contracts make that work, and a backend must honour both:

1. `PanelManager.contentOf(id, context)` wraps every panel body — the docked
   group **and** the detached window. Rendering `descriptor.builder` directly
   instead of through `contentOf` silently breaks state survival.
2. `openTearOff`'s `paneRect` is the pane's full rect (tab strip **and** body)
   in the main window's logical coordinates, and it is a **content** rect. Size the
   new surface's *client area* to it and add a header exactly `headerHeight` tall:
   the content then keeps the height it had docked, so nothing reflows. If the
   platform's window API separates frame from client area (Win32 does), grow the
   rect by that non-client padding before placing the window — otherwise the
   content is inset and shortened by the border.

Below the threshold, and for backends whose `supportsDetach` is false, the
legacy path still runs: a captured drag-image pill, with the panel detached on
release outside the window (`open`). Set `tearOffEnabled: false` to keep that
behavior with a detaching backend.

See the [example](https://github.com/your-org/panel/tree/main/example) and the
repository docs for the full picture, including the macOS detach backend.
