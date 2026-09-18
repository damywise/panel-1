// The tear-off state machine: what the manager does at the drag threshold, on
// release, on a drop commit, and on a cancel.
//
// These are the invariants the dock and the platform backend rely on, stated
// without any windowing: the panel leaves the dock exactly once, the backend
// receives the pane's own rect, and every exit path returns the manager to a
// consistent (dock xor float) placement.

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/panel.dart';

import 'support/recording_backend.dart';

void main() {
  // The tear-off touches the pointer router (to cancel the Flutter drag) and
  // the hardware keyboard (ESC), both of which live on the binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  const Rect pane = Rect.fromLTWH(100, 200, 320, 260);
  const double header = 38;

  PanelManager managerWith({
    required RecordingBackend backend,
    bool detachable = true,
    PanelDockConfig config = const PanelDockConfig(),
  }) {
    final PanelManager manager =
        PanelManager(config: config, windowing: backend);
    manager
      ..registerPanel(
        PanelDescriptor(
          id: 'captions',
          title: 'Captions',
          detachable: detachable,
          builder: (_) => const SizedBox.shrink(),
        ),
        side: DockSide.right,
      )
      ..registerPanel(
        const PanelDescriptor(
          id: 'timeline',
          title: 'Timeline',
          builder: _nothing,
        ),
        side: DockSide.bottom,
      );
    return manager;
  }

  group('config defaults', () {
    test('tear-off is on by default, at the reference 8 px threshold', () {
      const PanelDockConfig config = PanelDockConfig();
      expect(config.tearOffEnabled, isTrue);
      expect(config.popOutDistance, 8.0);
    });
  });

  group('body keys', () {
    test('are stable per group slot', () {
      final PanelManager manager = managerWith(backend: RecordingBackend());
      expect(manager.bodyKeyOf(DockSide.right, 0),
          same(manager.bodyKeyOf(DockSide.right, 0)));
      expect(manager.bodyKeyOf(DockSide.right, 0),
          isNot(same(manager.bodyKeyOf(DockSide.left, 0))));
      expect(manager.bodyKeyOf(DockSide.right, 0),
          isNot(same(manager.bodyKeyOf(DockSide.right, 1))));
    });
  });

  group('beginTearOff', () {
    test('keeps the pane docked until the window is ready, then removes it',
        () {
      final RecordingBackend backend = RecordingBackend();
      final PanelManager manager = managerWith(backend: backend);

      manager.beginTearOff(
        'captions',
        paneRect: pane,
        headerHeight: header,
        pointerInPane: const Offset(20, 12),
      );

      // The window exists (the backend got the pane's rect) and the panel is
      // already floating, but the pane is still docked — it only leaves once
      // the window reports its first frame.
      expect(manager.isTornOff('captions'), isTrue);
      expect(manager.tearOffId, 'captions');
      expect(manager.isFloating('captions'), isTrue);
      expect(manager.isDragging, isFalse);
      expect(
        manager.panelsIn(DockSide.right).map((PanelDescriptor d) => d.id),
        contains('captions'),
      );
      expect(backend.tearOffs, hasLength(1));
      final TearOffCall call = backend.tearOffs.single;
      expect(call.id, 'captions');
      expect(call.origin, DockSide.right);
      expect(call.paneRect, pane);
      expect(call.headerHeight, header);
      expect(call.pointerInPane, const Offset(20, 12));
      expect(manager.isExternalDragging, isTrue);

      // First frame painted: the pane leaves the dock now, in the same turn.
      backend.markTearOffReady('captions');
      expect(
        manager.panelsIn(DockSide.right).map((PanelDescriptor d) => d.id),
        isNot(contains('captions')),
      );
      expect(manager.isFloating('captions'), isTrue);
    });

    test('falls back to remove-then-open when the backend cannot warm up', () {
      final RecordingBackend backend = RecordingBackend()
        ..windowFirstTearOff = false;
      final PanelManager manager = managerWith(backend: backend);

      manager.beginTearOff('captions',
          paneRect: pane, headerHeight: header, pointerInPane: Offset.zero);

      // The pane left immediately and the legacy open() path ran.
      expect(manager.isFloating('captions'), isTrue);
      expect(
        manager.panelsIn(DockSide.right).map((PanelDescriptor d) => d.id),
        isNot(contains('captions')),
      );
      expect(backend.opened, contains('captions'));
    });

    test('detaches anyway if the window never reports a first frame', () {
      fakeAsync((FakeAsync async) {
        final RecordingBackend backend = RecordingBackend();
        final PanelManager manager = managerWith(backend: backend);
        manager.beginTearOff('captions',
            paneRect: pane, headerHeight: header, pointerInPane: Offset.zero);

        expect(manager.panelsIn(DockSide.right), hasLength(1));
        async.elapse(const Duration(milliseconds: 700));
        expect(
          manager.panelsIn(DockSide.right).map((PanelDescriptor d) => d.id),
          isNot(contains('captions')),
        );
      });
    });

    test('is a no-op for a second panel while one is in flight', () {
      final RecordingBackend backend = RecordingBackend();
      final PanelManager manager = managerWith(backend: backend);
      manager.beginTearOff('captions',
          paneRect: pane, headerHeight: header, pointerInPane: Offset.zero);
      manager.beginTearOff('timeline',
          paneRect: pane, headerHeight: header, pointerInPane: Offset.zero);

      expect(backend.tearOffs, hasLength(1));
      expect(manager.isTornOff('timeline'), isFalse);
      expect(manager.panelsIn(DockSide.bottom), hasLength(1));
    });

    test('is a no-op when the descriptor opts out of detaching', () {
      final RecordingBackend backend = RecordingBackend();
      final PanelManager manager =
          managerWith(backend: backend, detachable: false);
      manager.beginTearOff('captions',
          paneRect: pane, headerHeight: header, pointerInPane: Offset.zero);

      expect(backend.tearOffs, isEmpty);
      expect(manager.isFloating('captions'), isFalse);
      expect(manager.panelsIn(DockSide.right), hasLength(1));
    });

    test('is a no-op when the config disables tear-off', () {
      final RecordingBackend backend = RecordingBackend();
      final PanelManager manager = managerWith(
        backend: backend,
        config: const PanelDockConfig(tearOffEnabled: false),
      );
      expect(manager.canTearOff('captions'), isFalse);
      manager.beginTearOff('captions',
          paneRect: pane, headerHeight: header, pointerInPane: Offset.zero);
      expect(backend.tearOffs, isEmpty);
    });

    test('is a no-op when the backend cannot detach', () {
      final RecordingBackend backend =
          RecordingBackend(supportsDetachOverride: false);
      final PanelManager manager = managerWith(backend: backend);
      expect(manager.tearOffOnDrag, isFalse);
      manager.beginTearOff('captions',
          paneRect: pane, headerHeight: header, pointerInPane: Offset.zero);
      expect(backend.tearOffs, isEmpty);
      expect(manager.panelsIn(DockSide.right), hasLength(1));
    });
  });

  group('dim cue', () {
    test('dims over a dock zone and restores when leaving it', () {
      final RecordingBackend backend = RecordingBackend();
      final PanelManager manager = managerWith(backend: backend);
      manager.beginTearOff('captions',
          paneRect: pane, headerHeight: header, pointerInPane: Offset.zero);

      const Rect main = Rect.fromLTWH(0, 0, 1000, 800);
      manager.updateExternalDragHover(const Offset(40, 400), main);
      expect(manager.externalHoverSide, DockSide.left);
      manager.updateExternalDragHover(Offset(-200, 400), main);
      expect(manager.externalHoverSide, isNull);

      expect(backend.dims, <String>['captions:true', 'captions:false']);
    });

    test('never dims a plain floating window (no tear-off in flight)', () {
      final RecordingBackend backend = RecordingBackend();
      final PanelManager manager = managerWith(backend: backend);
      const Rect main = Rect.fromLTWH(0, 0, 1000, 800);
      manager.updateExternalDragHover(const Offset(40, 400), main);
      expect(backend.dims, isEmpty);
    });

    test('is cleared when the tear-off ends', () {
      final RecordingBackend backend = RecordingBackend();
      final PanelManager manager = managerWith(backend: backend);
      const Rect main = Rect.fromLTWH(0, 0, 1000, 800);
      manager.beginTearOff('captions',
          paneRect: pane, headerHeight: header, pointerInPane: Offset.zero);
      manager.updateExternalDragHover(const Offset(40, 400), main);
      manager.endExternalDrag(commitId: 'captions');

      expect(backend.dims.last, 'captions:false');
    });
  });

  group('release', () {
    test('over a zone re-docks there and destroys the window', () {
      final RecordingBackend backend = RecordingBackend();
      final PanelManager manager = managerWith(backend: backend);
      manager.beginTearOff('captions',
          paneRect: pane, headerHeight: header, pointerInPane: Offset.zero);
      const Rect main = Rect.fromLTWH(0, 0, 1000, 800);
      manager.updateExternalDragHover(const Offset(40, 400), main); // left
      manager.endExternalDrag(commitId: 'captions');

      expect(backend.closed, <String>['captions']);
      expect(manager.isFloating('captions'), isFalse);
      expect(manager.isTornOff('captions'), isFalse);
      expect(manager.externalHoverSide, isNull);
      expect(
        manager.panelsIn(DockSide.left).map((PanelDescriptor d) => d.id),
        <String>['captions'],
      );
    });

    test('a collapsed dock only claims its thin strip, not the fallback band', () {
      // Regression: the zone test used the *fallback* extent for a collapsed
      // dock (h*0.22 for bottom), so the lower ~22% of the window resolved to
      // `bottom` even though the collapsed dock is only a thin strip and the
      // rest of that band is still center content — an "upper" region lighting
      // the "lower" dock.
      final RecordingBackend backend = RecordingBackend();
      final PanelManager manager = managerWith(backend: backend);
      manager.beginTearOff('captions',
          paneRect: pane, headerHeight: header, pointerInPane: Offset.zero);
      manager.toggleCollapsed(DockSide.bottom); // collapse the timeline strip
      const Rect main = Rect.fromLTWH(0, 0, 1000, 800);

      // Well inside the collapsed dock's dead band (below the old 0.78h line,
      // above the real 36px strip): must be center, not bottom.
      manager.updateExternalDragHover(const Offset(500, 700), main);
      expect(manager.externalHoverSide, DockSide.center);

      // The thin strip itself still resolves to bottom.
      manager.updateExternalDragHover(const Offset(500, 790), main);
      expect(manager.externalHoverSide, DockSide.bottom);
      manager.endExternalDrag();
    });

    test('an edge drop splits at the aimed group, not the region end', () {
      // Regression: edge probes used to collapse to "new group at end", so a
      // drop near the *top* of a left dock painted + committed a split at the
      // bottom. Now the split lands where the cursor is.
      final RecordingBackend backend = RecordingBackend();
      final PanelManager manager = managerWith(backend: backend);
      // Two stacked groups in the left dock.
      manager.registerPanel(
        const PanelDescriptor(
          id: 'explorer',
          title: 'Explorer',
          builder: _nothing,
        ),
        side: DockSide.left,
      );
      manager.registerPanel(
        const PanelDescriptor(
          id: 'search',
          title: 'Search',
          builder: _nothing,
        ),
        side: DockSide.left,
      );
      manager.splitActiveGroup(DockSide.left, 0); // search splits below explorer
      expect(manager.groupCount(DockSide.left), 2);

      manager.beginTearOff('captions',
          paneRect: pane, headerHeight: header, pointerInPane: Offset.zero);
      const Rect main = Rect.fromLTWH(0, 0, 1000, 800);

      // Probe the TOP edge of the first (top) group in the left dock: should
      // resolve to a split at index 0 (a new group above explorer), not a tab
      // and not an append at the end.
      manager.updateExternalDragHover(const Offset(40, 8), main);
      expect(manager.externalHoverSide, DockSide.left);
      expect(manager.externalHoverGroup, -1);
      expect(manager.externalHoverSplit, 0);

      manager.endExternalDrag(commitId: 'captions');
      // The new group was inserted at the top, before explorer.
      expect(manager.groupCount(DockSide.left), 3);
      expect(
        manager.panelsInGroup(DockSide.left, 0).map((d) => d.id),
        <String>['captions'],
      );
    });

    test('over a zone containing the origin re-docks silently', () {
      final RecordingBackend backend = RecordingBackend();
      final PanelManager manager = managerWith(backend: backend);
      manager.beginTearOff('captions',
          paneRect: pane, headerHeight: header, pointerInPane: Offset.zero);
      const Rect main = Rect.fromLTWH(0, 0, 1000, 800);
      manager.updateExternalDragHover(const Offset(960, 400), main); // right
      manager.endExternalDrag(commitId: 'captions');

      expect(manager.isFloating('captions'), isFalse);
      expect(manager.panelsIn(DockSide.right).map((d) => d.id), contains('captions'));
    });

    test('outside every zone leaves the window floating and opaque', () {
      final RecordingBackend backend = RecordingBackend();
      final PanelManager manager = managerWith(backend: backend);
      manager.beginTearOff('captions',
          paneRect: pane, headerHeight: header, pointerInPane: Offset.zero);
      manager.endExternalDrag(commitId: 'captions');

      expect(backend.closed, isEmpty);
      expect(manager.isFloating('captions'), isTrue);
      expect(manager.isTornOff('captions'), isFalse);
      expect(manager.isExternalDragging, isFalse);
    });
  });

  group('cancel', () {
    test('re-docks the pane to its origin and destroys the window', () {
      final RecordingBackend backend = RecordingBackend();
      final PanelManager manager = managerWith(backend: backend);
      manager.beginTearOff('captions',
          paneRect: pane, headerHeight: header, pointerInPane: Offset.zero);
      const Rect main = Rect.fromLTWH(0, 0, 1000, 800);
      manager.updateExternalDragHover(const Offset(40, 400), main); // would dock left

      manager.cancelDrag();

      expect(backend.closed, <String>['captions']);
      expect(manager.isFloating('captions'), isFalse);
      expect(manager.isTornOff('captions'), isFalse);
      expect(backend.dims.last, 'captions:false');
      // Origin, not the hovered side: a cancel undoes, it does not commit.
      expect(
        manager.panelsIn(DockSide.right).map((PanelDescriptor d) => d.id),
        contains('captions'),
      );
    });

    test('returns the panel to its original group and tab slot', () {
      // Regression: cancel used to call the generic landing path, appending a
      // NEW group at the region's end (the bottom of a left/right dock)
      // instead of restoring the panel into the group it was torn out of.
      final RecordingBackend backend = RecordingBackend();
      final PanelManager manager = managerWith(backend: backend);
      // Give 'captions' a tab-mate in the same right-dock group.
      manager.registerPanel(
        const PanelDescriptor(
          id: 'inspector',
          title: 'Inspector',
          builder: _nothing,
        ),
        side: DockSide.right,
      );
      // captions + inspector are now tabs of one group; captions is active.
      expect(manager.groupCount(DockSide.right), 1);

      manager.beginTearOff('captions',
          paneRect: pane, headerHeight: header, pointerInPane: Offset.zero);
      const Rect main = Rect.fromLTWH(0, 0, 1000, 800);
      manager.updateExternalDragHover(const Offset(40, 400), main);
      manager.cancelDrag();

      // Back in the SAME group as inspector (still one group, two tabs), not a
      // new group appended at the end. captions was the first tab originally,
      // so restoring it to tab 0 puts it ahead of inspector again.
      expect(manager.groupCount(DockSide.right), 1);
      expect(
        manager.panelsInGroup(DockSide.right, 0).map((d) => d.id),
        <String>['captions', 'inspector'],
      );
    });
  });

  group('endDrag', () {
    test('keeps a tear-off alive (the backend owns the gesture now)', () {
      final RecordingBackend backend = RecordingBackend();
      final PanelManager manager = managerWith(backend: backend);
      manager.beginDrag(side: DockSide.right, group: 0, panelId: 'captions');
      manager.beginTearOff('captions',
          paneRect: pane, headerHeight: header, pointerInPane: Offset.zero);
      manager.endDrag();

      expect(manager.isTornOff('captions'), isTrue);
      expect(manager.isDragging, isFalse);
    });
  });
}

Widget _nothing(BuildContext context) => const SizedBox.shrink();
