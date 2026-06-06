// The Flutter widgets embedded into the Jaspr deck, all compiled to web from
// the real `package:panel`. `PanelDemoWidget(name:)` dispatches to one of four
// distinct demos so each slide shows what it's talking about:
//   intro   - the full dockable workspace (drag / split / resize)
//   regions - placeholder regions + buttons that add panels live
//   drag    - an auto-playing "simulator" of a tab being dragged between groups
//   themes  - the same dock under several PanelThemes you can switch
// Detach is a no-op on web (the default DisabledWindowing backend).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:panel/panel.dart';

/// Dispatcher referenced by the Jaspr embed (kept as the single `@Import`
/// symbol). The server-side stub is `dynamic`, so adding this param needs no
/// generated-file change.
class PanelDemoWidget extends StatelessWidget {
  const PanelDemoWidget({super.key, this.name = 'intro'});

  final String name;

  @override
  Widget build(BuildContext context) {
    final Widget demo = switch (name) {
      'regions' => const _RegionsDemo(),
      'drag' => const _DragSimDemo(),
      'themes' => const _ThemesDemo(),
      _ => const _IntroDock(),
    };
    // Scale the fixed 920x560 design to the (responsive) Flutter view inside
    // Flutter, so hit-testing stays correct on any viewport.
    return _stage(demo);
  }
}

/// Forces the dock dark regardless of the visitor's OS brightness, matching the
/// dark deck.
PanelDockConfig _darkConfig() => PanelDockConfig(
      lightTheme: PanelTheme.dark(),
      darkTheme: PanelTheme.dark(),
    );

/// Monospace style for code/terminal content. Flutter web/CanvasKit can't use
/// OS fonts, so a name like 'monospace' silently falls back to a sans face;
/// google_fonts loads a real mono face the engine can render.
TextStyle _codeStyle(BuildContext context, {double size = 12.5, double height = 1.4}) =>
    GoogleFonts.robotoMono(fontSize: size, height: height, color: Theme.of(context).colorScheme.onSurface);

ThemeData _appTheme([Color? scaffold, Brightness brightness = Brightness.dark]) => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5B9DF7), brightness: brightness),
      scaffoldBackgroundColor: scaffold,
    );

/// Lays the demo out at a fixed 920x560 design size and scales it to fit the
/// (responsive) Flutter view with a Flutter-native transform, so hit-testing
/// stays correct. (A CSS transform on the host element would offset pointers.)
Widget _stage(Widget child) => FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(width: 920, height: 560, child: child),
    );

// ---------------------------------------------------------------------------
// 1. Intro: the full workspace.
// ---------------------------------------------------------------------------

class _IntroDock extends StatefulWidget {
  const _IntroDock();
  @override
  State<_IntroDock> createState() => _IntroDockState();
}

class _IntroDockState extends State<_IntroDock> {
  late final PanelManager manager;

  @override
  void initState() {
    super.initState();
    manager = PanelManager(config: _darkConfig())
      ..registerPanel(PanelDescriptor(id: 'explorer', title: 'Explorer', icon: Icons.folder_outlined, builder: (_) => const _Lines(['lib/', '  panel.dart', '  main.dart', 'web/'])), side: DockSide.left)
      ..registerPanel(PanelDescriptor(id: 'editor', title: 'main.dart', icon: Icons.description_outlined, builder: (_) => const _Code()), side: DockSide.center)
      ..registerPanel(PanelDescriptor(id: 'styles', title: 'styles.css', icon: Icons.css, builder: (_) => const _Lines(['.deck { ... }'])), side: DockSide.center, activate: false)
      ..registerPanel(PanelDescriptor(id: 'inspector', title: 'Inspector', icon: Icons.tune, builder: (_) => const _Lines(['width: 480', 'height: 600', 'docked: true'])), side: DockSide.right)
      ..registerPanel(PanelDescriptor(id: 'terminal', title: 'Terminal', icon: Icons.terminal, builder: (_) => const _Lines([r'$ flutter build web', 'Compiling… done'])), side: DockSide.bottom)
      ..registerPanel(PanelDescriptor(id: 'problems', title: 'Problems', icon: Icons.check_circle_outline, builder: (_) => const _Lines(['No problems 🎉'])), side: DockSide.bottom, activate: false);
  }

  @override
  void dispose() {
    manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _appTheme(),
      home: Scaffold(body: PanelScope(manager: manager, child: const PanelDock())),
    );
  }
}

// ---------------------------------------------------------------------------
// 2. Regions: placeholders + add panels live.
// ---------------------------------------------------------------------------

class _RegionsDemo extends StatefulWidget {
  const _RegionsDemo();
  @override
  State<_RegionsDemo> createState() => _RegionsDemoState();
}

class _RegionsDemoState extends State<_RegionsDemo> {
  late PanelManager manager;
  int _n = 0;

  @override
  void initState() {
    super.initState();
    manager = PanelManager(config: _darkConfig());
    // Seed one placeholder per region so all four regions are visible.
    _add(DockSide.left, 'Left');
    _add(DockSide.center, 'Center');
    _add(DockSide.right, 'Right');
    _add(DockSide.bottom, 'Bottom');
  }

  void _add(DockSide side, String label) {
    _n++;
    final String id = 'p$_n';
    manager.registerPanel(
      PanelDescriptor(id: id, title: label, icon: Icons.widgets_outlined, builder: (_) => _Placeholder(label)),
      side: side,
    );
  }

  @override
  void dispose() {
    manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _appTheme(const Color(0xFF1E1F22)),
      home: Scaffold(
        body: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  const Text('Add panel:', style: TextStyle(color: Color(0xFF9AA0A6), fontSize: 12)),
                  for (final (DockSide side, String label) in const <(DockSide, String)>[
                    (DockSide.left, 'Left'),
                    (DockSide.center, 'Center'),
                    (DockSide.right, 'Right'),
                    (DockSide.bottom, 'Bottom'),
                  ])
                    OutlinedButton(
                      onPressed: () => setState(() => _add(side, label)),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: const Color(0xFFE6E7E9),
                        side: const BorderSide(color: Color(0xFF3A3D42)),
                      ),
                      child: Text('+ $label'),
                    ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFF3A3D42)),
            Expanded(child: PanelScope(manager: manager, child: const PanelDock())),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. Drag: an auto-playing tab move driven on the REAL PanelDock. A scripted,
//    reversible cycle of PanelManager calls (split a tab into a new group,
//    merge it back, pull one across regions, send it home) reorganizes the
//    actual dock live, so the slide shows the real framework, not a mock.
// ---------------------------------------------------------------------------

class _DragSimDemo extends StatefulWidget {
  const _DragSimDemo();
  @override
  State<_DragSimDemo> createState() => _DragSimDemoState();
}

class _DragSimDemoState extends State<_DragSimDemo> {
  late final PanelManager manager;
  Timer? _loop;
  int _step = 0;

  @override
  void initState() {
    super.initState();
    manager = PanelManager(config: _darkConfig())
      ..registerPanel(PanelDescriptor(id: 'explorer', title: 'Explorer', icon: Icons.folder_outlined, builder: (_) => const _Lines(['lib/', 'web/'])), side: DockSide.left)
      ..registerPanel(PanelDescriptor(id: 'editor', title: 'main.dart', icon: Icons.description_outlined, builder: (_) => const _Code()), side: DockSide.center)
      ..registerPanel(PanelDescriptor(id: 'styles', title: 'styles.css', icon: Icons.css, builder: (_) => const _Lines(['.deck { ... }'])), side: DockSide.center, activate: false)
      ..registerPanel(PanelDescriptor(id: 'terminal', title: 'Terminal', icon: Icons.terminal, builder: (_) => const _Lines([r'$ flutter build web'])), side: DockSide.bottom);
    _loop = Timer(const Duration(milliseconds: 1100), _tick);
  }

  // Each tick performs one move on the real PanelManager; the dock rebuilds
  // itself (PanelScope is an InheritedNotifier). The 4 steps net to identity,
  // so the demo loops cleanly.
  void _tick() {
    switch (_step % 4) {
      case 0: // styles.css -> its own group beside the editor (an "edge" drop)
        final int gi = _groupOf(DockSide.center, 'styles');
        if (gi >= 0) manager.splitBeside('styles', DockSide.center, gi, before: false);
      case 1: // styles.css -> back as a tab in the editor group (a "center" drop)
        manager.addPanelAsTab('styles', DockSide.center, 0);
      case 2: // pull Terminal up into the editor group
        manager.addPanelAsTab('terminal', DockSide.center, 0);
      case 3: // send Terminal back down to its own region
        manager.addPanelAsTab('terminal', DockSide.bottom, 0);
    }
    _step++;
    _loop = Timer(const Duration(milliseconds: 1600), _tick);
  }

  int _groupOf(DockSide side, String id) {
    for (int i = 0; i < manager.groupCount(side); i++) {
      if (manager.panelsInGroup(side, i).any((PanelDescriptor p) => p.id == id)) return i;
    }
    return -1;
  }

  @override
  void dispose() {
    _loop?.cancel();
    manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _appTheme(const Color(0xFF1E1F22)),
      home: Scaffold(body: PanelScope(manager: manager, child: const PanelDock())),
    );
  }
}

// ---------------------------------------------------------------------------
// 4. Themes: the same dock under switchable PanelThemes.
// ---------------------------------------------------------------------------

class _ThemesDemo extends StatefulWidget {
  const _ThemesDemo();
  @override
  State<_ThemesDemo> createState() => _ThemesDemoState();
}

class _ThemesDemoState extends State<_ThemesDemo> {
  late List<({String name, PanelTheme theme})> _presets;
  int _sel = 0;
  PanelManager? _manager;

  @override
  void initState() {
    super.initState();
    _presets = <({String name, PanelTheme theme})>[
      (name: 'Dark', theme: PanelTheme.dark()),
      (name: 'Light', theme: PanelTheme.light()),
      (name: 'Ocean', theme: _ocean),
      (name: 'Sunset', theme: _sunset),
      (name: 'Mono', theme: _mono),
    ];
    _build();
  }

  void _build() {
    _manager?.dispose();
    final PanelTheme t = _presets[_sel].theme;
    _manager = PanelManager(config: PanelDockConfig(lightTheme: t, darkTheme: t))
      ..registerPanel(PanelDescriptor(id: 'files', title: 'Files', icon: Icons.folder_outlined, builder: (_) => const _Lines(['lib/', 'web/', 'pubspec.yaml'])), side: DockSide.left)
      ..registerPanel(PanelDescriptor(id: 'doc', title: 'theme.dart', icon: Icons.palette_outlined, builder: (_) => const _Code()), side: DockSide.center)
      ..registerPanel(PanelDescriptor(id: 'out', title: 'Output', icon: Icons.terminal, builder: (_) => const _Lines(['ready.'])), side: DockSide.bottom);
  }

  @override
  void dispose() {
    _manager?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PanelTheme t = _presets[_sel].theme;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // Match Material brightness to the preset so default text contrasts with
      // the (possibly light) panel surface.
      theme: _appTheme(t.background, ThemeData.estimateBrightnessForColor(t.background)),
      home: Scaffold(
        body: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (int i = 0; i < _presets.length; i++) _swatch(i),
                ],
              ),
            ),
            Expanded(child: PanelScope(manager: _manager!, child: const PanelDock())),
          ],
        ),
      ),
    );
  }

  Widget _swatch(int i) {
    final ({String name, PanelTheme theme}) p = _presets[i];
    final bool on = i == _sel;
    return InkWell(
      onTap: () => setState(() {
        _sel = i;
        _build();
      }),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: p.theme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: on ? p.theme.accent : p.theme.border, width: on ? 2 : 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(width: 12, height: 12, decoration: BoxDecoration(color: p.theme.accent, shape: BoxShape.circle)),
            const SizedBox(width: 7),
            Text(p.name, style: TextStyle(color: p.theme.text, fontSize: 12, fontWeight: on ? FontWeight.w700 : FontWeight.w400)),
          ],
        ),
      ),
    );
  }
}

const PanelTheme _ocean = PanelTheme(
  background: Color(0xFF0F1F2E),
  surface: Color(0xFF13293D),
  tabBar: Color(0xFF0E2335),
  tabActive: Color(0xFF1B3A52),
  tabHover: Color(0x1AFFFFFF),
  border: Color(0xFF20455F),
  accent: Color(0xFF34D1BF),
  text: Color(0xFFE3F2F1),
  mutedText: Color(0xFF80A4B4),
  splitter: Color(0xFF20455F),
  splitterActive: Color(0xFF34D1BF),
  floatingHeader: Color(0xFF0E2335),
  overlayBackground: Color(0xFF13293D),
  // Rounded, filled tabs.
  tabRadius: BorderRadius.all(Radius.circular(6)),
);

const PanelTheme _sunset = PanelTheme(
  background: Color(0xFF241726),
  surface: Color(0xFF31203A),
  tabBar: Color(0xFF2A1A33),
  tabActive: Color(0xFF45294F),
  tabHover: Color(0x1AFFFFFF),
  border: Color(0xFF4A2F55),
  accent: Color(0xFFFF7E6B),
  text: Color(0xFFF6E9F2),
  mutedText: Color(0xFFB48FB0),
  splitter: Color(0xFF4A2F55),
  splitterActive: Color(0xFFFF7E6B),
  floatingHeader: Color(0xFF2A1A33),
  overlayBackground: Color(0xFF31203A),
  // Pill-shaped tabs, no strip divider.
  tabRadius: BorderRadius.all(Radius.circular(18)),
  tabDividerThickness: 0,
);

const PanelTheme _mono = PanelTheme(
  background: Color(0xFF101010),
  surface: Color(0xFF1A1A1A),
  tabBar: Color(0xFF161616),
  tabActive: Color(0xFF262626),
  tabHover: Color(0x14FFFFFF),
  border: Color(0xFF333333),
  accent: Color(0xFFEDEDED),
  text: Color(0xFFEDEDED),
  mutedText: Color(0xFF8A8A8A),
  splitter: Color(0xFF333333),
  splitterActive: Color(0xFFEDEDED),
  floatingHeader: Color(0xFF161616),
  overlayBackground: Color(0xFF1A1A1A),
  // Minimal: borderless panels, no divider, fill-only tab indicator.
  showPanelBorder: false,
  tabDividerThickness: 0,
  tabUnderlineThickness: 0,
);

// ---------------------------------------------------------------------------
// Shared placeholder content.
// ---------------------------------------------------------------------------

class _Placeholder extends StatelessWidget {
  const _Placeholder(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.widgets_outlined, size: 22, color: Color(0xFF9AA0A6)),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: Color(0xFF9AA0A6), fontSize: 13)),
        ],
      ),
    );
  }
}

class _Lines extends StatelessWidget {
  const _Lines(this.lines);
  final List<String> lines;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final String l in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(l, style: _codeStyle(context, size: 12.5, height: 1.2)),
            ),
        ],
      ),
    );
  }
}

class _Code extends StatelessWidget {
  const _Code();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Text(
        "import 'package:panel/panel.dart';\n\n"
        'final manager = PanelManager()\n'
        '  ..registerPanel(explorer, side: DockSide.left)\n'
        '  ..registerPanel(editor, side: DockSide.center);\n\n'
        '// drag a tab to a group edge to split,\n'
        '// or onto the center to add a tab.',
        style: _codeStyle(context, size: 12.5, height: 1.5),
      ),
    );
  }
}

