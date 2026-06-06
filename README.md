# Panes

A reusable, IDE-style **dockable / detachable panel** framework for Flutter
desktop (macOS), built on Flutter's experimental multi-window APIs plus a thin
AppKit layer.

* Dock panels into **left / right / bottom / center** regions with resizable
  splitters and tabbed groups.
* **Reorder tabs** within a group by dragging them sideways (accent insertion line).
* **Split / merge** with the keyboard (⌘\ / ⌘⇧\) on the focused group.
* **Subdivide** a region: drag a tab to a group's edge (or use the split button)
  to place panels **side-by-side**; drop on the center to add a tab.
* **Detach** a panel (drag it out, or the ⧉ pop-out button) into a **borderless
  macOS window** that's movable by its body.
* **Drag the floating window back** onto the main window to snap it into a dock.
* **Minimize** docks to a strip; minimize floating windows via the OS.
* **System light/dark**, configurable sizes/labels/capabilities.

The framework lives in [`lib/panels/`](lib/panels/); [`lib/main.dart`](lib/main.dart)
is a runnable demo.

## Run

```bash
fvm flutter config --enable-windowing   # once (experimental feature flag)
fvm flutter run -d macos
```

Requires the **main/master** Flutter channel (the windowing APIs don't exist on
stable). See **[MANUAL.md](MANUAL.md)** for the full build/reproduction guide,
including the required macOS runner changes — or open the scrollable slideshow
walkthrough at **[docs/how-it-works.html](docs/how-it-works.html)**
(`open docs/how-it-works.html`).

## Use as a library

The public API is exported from `panels/panels.dart`. Because the windowing APIs
are experimental and `@internal`, the file that calls `runWidget` /
`RegularWindow` opts in to two analyzer ignores (as the official sample does).

```dart
// ignore_for_file: invalid_use_of_internal_member, implementation_imports
import 'package:flutter/material.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'panels/panels.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final manager = PanelManager(config: const PanelDockConfig())
    ..registerPanel(
        PanelDescriptor(id: 'explorer', title: 'Explorer',
            icon: Icons.folder, builder: (_) => const Explorer()),
        side: DockSide.left)
    ..registerPanel(
        PanelDescriptor(id: 'editor', title: 'Editor',
            builder: (_) => const Editor()),
        side: DockSide.center);

  runWidget(PanelScope(                       // expose the manager to ALL windows
    manager: manager,
    child: RegularWindow(
      controller: RegularWindowController(preferredSize: const Size(1180, 760)),
      child: const MaterialApp(home: Scaffold(body: PanelDock())),
    ),
  ));
}
```

Key types:

| Type | Role |
|------|------|
| `PanelDescriptor` | Describes one panel: `id`, `title`, `icon?`, `builder`, optional `detachedSize`. |
| `PanelManager` | Owns placement & state (`ChangeNotifier`). Construct with a `PanelDockConfig`, then `registerPanel(...)`. |
| `PanelScope` | `InheritedNotifier` that exposes the manager. **Must wrap the main `MaterialApp`** so detached windows can read it. |
| `PanelDock` | The workspace widget — put it in your main window's `Scaffold` body. |
| `PanelDockConfig` / `PanelDockStrings` | All tunables and labels. |
| `PanelTheme` | Material-independent colors (light/dark); `tabBuilder` for custom tabs. |
| `PanelStorage` | Pluggable layout persistence (`saveLayout`/`loadLayout`/`restore`). |
| `NativeDock` | Optional macOS chrome bridge over `dart:ffi` (call `NativeDock.instance.decorateMain()` after first frame to hide the main window's title bar). |

> Colors and typography come from the ambient `ThemeData`, so a workspace matches
> your app's theme and follows system light/dark automatically.

## Configuration

Everything tunable lives on `PanelDockConfig`, passed once to `PanelManager`:

```dart
PanelManager(config: const PanelDockConfig(
  // initial sizes (logical px)
  leftDockSize: 240, rightDockSize: 300, bottomDockSize: 220,
  // minimums
  minDockExtent: 120, minCenterWidth: 280, minCenterHeight: 160,
  minGroupFraction: 0.12,
  // chrome / visuals
  collapsedExtent: 36, tabStripHeight: 38, splitterHitSize: 8,
  dropEdgeFraction: 0.30,                 // edge band that triggers a split
  hoverDuration: Duration(milliseconds: 120),
  // detached windows
  defaultDetachedSize: Size(480, 600),
  detachedConstraints: BoxConstraints(minWidth: 240, minHeight: 200),
  redockAsTab: false,                     // true = merge into last group instead
  // capability toggles
  allowDetach: true, allowSplit: true, allowCollapse: true, allowResize: true,
  // native macOS chrome (no-op elsewhere)
  enableNativeChrome: true,
));
```

**Capability toggles** let you lock down the UX: `allowDetach: false` removes the
pop-out button and disables tear-off; `allowSplit: false` hides the split button
and collapses the per-group drop zones to "add as tab" only; `allowResize: false`
freezes all splitters; `allowCollapse: false` hides minimize buttons.

### Theming (Material-independent)

The dock paints from a `PanelTheme`, **not** Material's `ColorScheme`, so there's
no Material surface tint. Provide light/dark variants (chosen by platform
brightness); both default to neutral palettes:

```dart
PanelManager(config: PanelDockConfig(
  lightTheme: PanelTheme.light(),
  darkTheme: PanelTheme.dark(),            // or a fully custom PanelTheme(...)
));
```

`PanelTheme` exposes `background`, `surface`, `tabBar`, `tabActive`, `tabHover`,
`border`, `accent`, `text`, `mutedText`, `splitter`, `splitterActive`,
`floatingHeader`, `overlayBackground`, and optional `tabTextStyle`/`titleTextStyle`.

**Arbitrary tab rendering** — supply `tabBuilder` to draw tabs however you like:

```dart
PanelDockConfig(
  tabBuilder: (context, spec) => MyTab(
    title: spec.descriptor.title,
    selected: spec.selected,
    hovered: spec.hovered,
    theme: spec.theme,
  ),
);
```

### Persistence

Implement `PanelStorage` and pass it via `config.storage`; the manager
**auto-saves** the layout (debounced) on changes. Call `manager.restore()` after
registering panels (e.g. on startup) to reload:

```dart
class MyStorage implements PanelStorage {
  @override
  FutureOr<Map<String, Object?>?> read() => /* load JSON map or null */;
  @override
  FutureOr<void> write(Map<String, Object?> layout) => /* persist it */;
}

final manager = PanelManager(config: PanelDockConfig(storage: MyStorage()))
  ..registerPanel(/* ... */);
await manager.restore();          // applies the saved layout
```

`saveLayout()` / `loadLayout(map)` are also public if you want manual control.
(Floating windows aren't persisted; they re-dock on restore.) Detached windows
open on the screen/Space under the pointer.

### Keyboard shortcuts (Actions & Intents)

Splitting/merging is exposed as `SplitPanelIntent` / `MergePanelIntent`, acting
on the **focused** group (a group is focused when clicked — it gets an accent
border). Wire the defaults (⌘\ split, ⌘⇧\ merge; Ctrl on non‑Apple):

```dart
Shortcuts(
  shortcuts: defaultPanelShortcuts(),
  child: Actions(
    actions: panelActions(manager),
    child: const Focus(autofocus: true, child: PanelDock()),
  ),
);
```

Bind your own keys by mapping any `ShortcutActivator` to the intents, or call
`manager.splitFocused()` / `manager.mergeFocused()` (and `splitActiveGroup` /
`mergeGroup`) directly.

### Localization

All user-facing strings are on `PanelDockStrings` (passed via
`PanelDockConfig.strings`):

```dart
const PanelDockConfig(strings: PanelDockStrings(
  addTab: 'Ajouter un onglet',
  newGroup: 'Nouveau groupe',
  snapBackTooltip: 'Réancrer',
  dockMenuItemLabel: _frenchDock,        // String Function(DockSide)
));
```

## License / status

Built against Flutter's experimental windowing APIs, which can change in any
Flutter patch release. macOS only for the native chrome; the Dart dock itself is
platform-agnostic.
