// Content rendered inside a detached (floating) panel window.
//
// The native side hides the macOS title bar and makes the window movable by its
// body, so this content fills the whole window. We render our own slim header
// (themed via PanelTheme) that hosts the snap-back controls.
//
// Each window gets its OWN MaterialApp — a detached window is a sibling Flutter
// *view*, not a descendant of the main window's Navigator/Overlay, so without a
// local MaterialApp its menus/tooltips would throw "No Overlay widget found".
// That MaterialApp uses a neutral, untinted theme derived from PanelTheme.

import 'package:flutter/material.dart';

import 'panel.dart';
import 'panel_config.dart';
import 'panel_manager.dart';

class FloatingPanelContent extends StatelessWidget {
  const FloatingPanelContent({super.key, required this.panelId});

  final String panelId;

  @override
  Widget build(BuildContext context) {
    final PanelManager manager = PanelScope.of(context);
    final PanelDescriptor descriptor = manager.descriptor(panelId);
    final PanelTheme t = manager.config.themeOf(context);
    final Brightness brightness = MediaQuery.platformBrightnessOf(context);

    // Neutral Material theme just so the window has an Overlay/Navigator for
    // tooltips and the dock menu — no surface tint, colors from PanelTheme.
    final ColorScheme scheme = ColorScheme.fromSeed(seedColor: t.accent, brightness: brightness).copyWith(
      surface: t.overlayBackground,
      onSurface: t.text,
      primary: t.accent,
      surfaceTint: const Color(0x00000000),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorScheme: scheme, scaffoldBackgroundColor: t.surface),
      // A Material ancestor establishes the default text style (without one,
      // WidgetsApp shows its red/yellow "missing style" debug text) and hosts
      // ink for the header buttons.
      home: Material(
        color: t.surface,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Column(
            children: <Widget>[
              _FloatingHeader(panelId: panelId, descriptor: descriptor, manager: manager, theme: t),
              Expanded(child: ColoredBox(color: t.surface, child: descriptor.builder(context))),
            ],
          ),
        ),
      ),
    );
  }
}

class _FloatingHeader extends StatelessWidget {
  const _FloatingHeader({required this.panelId, required this.descriptor, required this.manager, required this.theme});

  final String panelId;
  final PanelDescriptor descriptor;
  final PanelManager manager;
  final PanelTheme theme;

  @override
  Widget build(BuildContext context) {
    final PanelDockStrings str = manager.config.strings;
    final PanelTheme t = theme;

    return Container(
      height: 44,
      padding: const EdgeInsets.only(left: 14, right: 6),
      decoration: BoxDecoration(
        color: t.floatingHeader,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: <Widget>[
          // The title area is the window's drag handle: pressing it asks AppKit
          // to start a native window-move (the Flutter view otherwise consumes
          // the mouse, so isMovableByWindowBackground alone doesn't fire here).
          Expanded(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => manager.beginFloatingWindowDrag(panelId),
              // Fill the full header height so the whole strip is draggable, not
              // just the centered text band.
              child: SizedBox(
                height: double.infinity,
                child: Row(
                  children: <Widget>[
                    Icon(descriptor.icon ?? Icons.drag_indicator, size: 16, color: t.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        descriptor.title,
                        style: (t.titleTextStyle ?? const TextStyle(fontSize: 13)).copyWith(fontWeight: FontWeight.w600, color: t.text),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _HeaderButton(tooltip: str.minimizeWindowTooltip, icon: Icons.remove, color: t.mutedText, onPressed: () => manager.minimizeFloating(panelId)),
          PopupMenuButton<DockSide>(
            tooltip: str.dockMenuTooltip,
            position: PopupMenuPosition.under,
            icon: Icon(Icons.dock, size: 18, color: t.mutedText),
            onSelected: (DockSide side) => manager.redock(panelId, toSide: side),
            itemBuilder: (BuildContext context) => <PopupMenuEntry<DockSide>>[
              for (final DockSide side in DockSide.values) PopupMenuItem<DockSide>(value: side, child: Text(str.dockMenuItemLabel(side))),
            ],
          ),
          const SizedBox(width: 2),
          _HeaderButton(tooltip: str.snapBackTooltip, icon: Icons.login, color: t.accent, onPressed: () => manager.redock(panelId)),
        ],
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.tooltip, required this.icon, required this.color, required this.onPressed});

  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(iconSize: 18, visualDensity: VisualDensity.compact, color: color, icon: Icon(icon), onPressed: onPressed),
    );
  }
}
