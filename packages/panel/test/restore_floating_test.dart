// Persisted floating panels: a layout saved with
// [PanelDockConfig.persistFloating] records which panels are floating, and
// loading it into a fresh manager re-opens them as floating windows — the
// GPU-recovery restart path.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/panel.dart';

import 'support/recording_backend.dart';

/// A [PanelStorage] that captures writes and can feed a saved layout back.
class MemoryStorage implements PanelStorage {
  Map<String, Object?>? last;

  @override
  Map<String, Object?>? read() => last;

  @override
  void write(Map<String, Object?> layout) => last = layout;
}

void main() {
  PanelManager managerWith({
    required RecordingBackend backend,
    PanelDockConfig? config,
  }) {
    config ??= PanelDockConfig(persistFloating: true, storage: MemoryStorage());
    final PanelManager manager =
        PanelManager(config: config, windowing: backend);
    manager
      ..registerPanel(
        const PanelDescriptor(
          id: 'a',
          title: 'A',
          builder: _nothing,
        ),
        side: DockSide.right,
      )
      ..registerPanel(
        const PanelDescriptor(
          id: 'b',
          title: 'B',
          builder: _nothing,
        ),
        side: DockSide.bottom,
      );
    return manager;
  }

  test('saveLayout records floating panels with their origin side', () {
    final RecordingBackend backend = RecordingBackend();
    final MemoryStorage storage = MemoryStorage();
    final PanelManager manager = managerWith(
      backend: backend,
      config: PanelDockConfig(persistFloating: true, storage: storage),
    );

    manager.detach('a');
    expect(manager.isFloating('a'), isTrue);
    expect(backend.opened, <String>['a']);

    manager.saveNow();
    final Map<String, Object?> layout = storage.last!;
    final Object? floating = layout['floating'];
    expect(floating, isA<List<Object?>>());
    expect(floating, <Object?>[
      <String, Object?>{'id': 'a', 'side': DockSide.right.name},
    ]);

    // 'b' stayed docked: serialized under its region, not in 'floating'.
    final Map<String, Object?> regions =
        layout['regions']! as Map<String, Object?>;
    final Map<String, Object?> bottom =
        regions[DockSide.bottom.name]! as Map<String, Object?>;
    final List<Object?> groups = bottom['groups']! as List<Object?>;
    expect(
      (groups.single as Map<String, Object?>)['panels'],
      <String>['b'],
    );
  });

  test('loadLayout re-opens a saved floating panel as a floating window', () {
    // Session 1: detach 'a' and save.
    final RecordingBackend backend1 = RecordingBackend();
    final MemoryStorage storage = MemoryStorage();
    final PanelManager manager1 = managerWith(
      backend: backend1,
      config: PanelDockConfig(persistFloating: true, storage: storage),
    );
    manager1.detach('a');
    manager1.saveNow();
    final Map<String, Object?> data = storage.last!;

    // Session 2 (post-restart): fresh backend + manager, same registrations.
    final RecordingBackend backend2 = RecordingBackend();
    final PanelManager manager2 = managerWith(backend: backend2);
    manager2.loadLayout(data);

    expect(backend2.opened, <String>['a']);
    expect(manager2.isFloating('a'), isTrue);
    // And it is NOT docked anywhere.
    expect(
      manager2.panelsIn(DockSide.right).map((PanelDescriptor d) => d.id),
      isNot(contains('a')),
    );
    // 'b' restored docked, nothing opened for it.
    expect(
      manager2.panelsIn(DockSide.bottom).map((PanelDescriptor d) => d.id),
      <String>['b'],
    );

    // A cancel/ESC would re-dock 'a' to its recorded origin side.
    manager2.redock('a');
    expect(
      manager2.panelsIn(DockSide.right).map((PanelDescriptor d) => d.id),
      contains('a'),
    );
  });

  test('floating geometry round-trips through saveLayout/loadLayout', () {
    // Session 1: 'a' floats at a frame the backend reports.
    final RecordingBackend backend1 = RecordingBackend()
      ..geometry = <String, Rect>{
        'a': const Rect.fromLTWH(1500, 200, 500, 400),
        // A stale id the manager doesn't know is dropped.
        'ghost': const Rect.fromLTWH(0, 0, 100, 100),
        // Degenerate rect dropped too.
        'empty': const Rect.fromLTWH(0, 0, 0, 0),
      };
    final MemoryStorage storage = MemoryStorage();
    final PanelManager manager1 = managerWith(
      backend: backend1,
      config: PanelDockConfig(persistFloating: true, storage: storage),
    );
    manager1.detach('a');
    manager1.saveNow();

    final Map<String, Object?> layout = storage.last!;
    expect(
      layout['floatingGeometry'],
      <String, Object?>{
        'a': <Object?>[1500.0, 200.0, 2000.0, 600.0],
      },
    );

    // Session 2: the geometry is handed to the backend BEFORE the floating
    // panel is re-opened.
    final RecordingBackend backend2 = RecordingBackend();
    final PanelManager manager2 = managerWith(backend: backend2);
    manager2.loadLayout(layout);

    expect(backend2.restoredGeometry, <Map<String, Rect>>[
      <String, Rect>{'a': const Rect.fromLTRB(1500, 200, 2000, 600)},
    ]);
    final int restoreIndex = backend2.calls
        .indexWhere((String c) => c.startsWith('restoreFloatingGeometry'));
    final int openIndex = backend2.openIndexOf('a');
    expect(restoreIndex, isNonNegative);
    expect(openIndex, isNonNegative);
    expect(restoreIndex, lessThan(openIndex));
  });

  test('loadLayout tolerates malformed floatingGeometry entries', () {
    final RecordingBackend backend = RecordingBackend();
    final PanelManager manager = managerWith(backend: backend);
    manager.loadLayout(<String, Object?>{
      'regions': <String, Object?>{},
      'floating': <Object?>[
        <String, Object?>{'id': 'a', 'side': 'right'},
      ],
      'floatingGeometry': <Object?, Object?>{
        'a': <Object?>[10, 20, 310, 220], // valid
        'b': 'not a list',
        'c': <Object?>[1, 2, 3], // wrong length
        'd': <Object?>[1, 2, 3, double.infinity], // non-finite
        'e': <Object?>[10, 10, 10, 10], // empty rect
        42: <Object?>[0, 0, 1, 1], // non-string key
      },
    });

    expect(backend.restoredGeometry, <Map<String, Rect>>[
      <String, Rect>{'a': const Rect.fromLTRB(10, 20, 310, 220)},
    ]);
  });

  test('default config writes no floating section (regression guard)', () {
    final RecordingBackend backend = RecordingBackend();
    final PanelManager manager = managerWith(
      backend: backend,
      config: const PanelDockConfig(),
    );

    manager.detach('a');
    expect(manager.isFloating('a'), isTrue);

    final Map<String, Object?> layout = manager.saveLayout();
    expect(layout.containsKey('floating'), isFalse);
  });

  test('loadLayout tolerates malformed floating entries', () {
    final RecordingBackend backend = RecordingBackend();
    final PanelManager manager = managerWith(backend: backend);
    manager.loadLayout(<String, Object?>{
      'regions': <String, Object?>{},
      'floating': <Object?>[
        'not a map',
        <String, Object?>{'id': 42, 'side': 'right'},
        <String, Object?>{'id': 'ghost', 'side': 'right'}, // unregistered
        <String, Object?>{'id': 'a', 'side': 'nowhere'}, // bad side
        <String, Object?>{'id': 'a', 'side': 'right'}, // the only good one
      ],
    });

    expect(backend.opened, <String>['a']);
    expect(manager.isFloating('a'), isTrue);
    // Unknown/unplaceable 'ghost' is skipped, not appended to center.
    expect(
      manager.panelsIn(DockSide.center).map((PanelDescriptor d) => d.id),
      isNot(contains('ghost')),
    );
  });
}

Widget _nothing(BuildContext context) => const SizedBox.shrink();
