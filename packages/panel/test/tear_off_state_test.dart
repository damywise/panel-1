// The tear-off state machine: what the manager does at the drag threshold, on
// release, on a drop commit, and on a cancel.
//
// These are the invariants the dock and the platform backend rely on, stated
// without any windowing: the panel leaves the dock exactly once, the backend
// receives the pane's own rect, and every exit path returns the manager to a
// consistent (dock xor float) placement.

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

  group('content keys', () {
    test('are stable per panel and reused by contentOf', () {
      final PanelManager manager = managerWith(backend: RecordingBackend());
      expect(manager.contentKeyOf('captions'),
          same(manager.contentKeyOf('captions')));
      expect(manager.contentKeyOf('captions'),
          isNot(same(manager.contentKeyOf('timeline'))));
    });

    test('honour a key declared on the descriptor', () {
      final PanelManager manager = PanelManager(
        windowing: RecordingBackend(),
      );
      final GlobalKey declared = GlobalKey();
      manager.registerPanel(PanelDescriptor(
        id: 'p',
        title: 'P',
        contentKey: declared,
        builder: (_) => const SizedBox.shrink(),
      ));
      expect(manager.contentKeyOf('p'), same(declared));
    });
  });

  group('beginTearOff', () {
    test('moves the panel out of the dock and hands the backend the pane rect',
        () {
      final RecordingBackend backend = RecordingBackend();
      final PanelManager manager = managerWith(backend: backend);

      manager.beginTearOff(
        'captions',
        paneRect: pane,
        headerHeight: header,
        pointerInPane: const Offset(20, 12),
      );

      expect(manager.isTornOff('captions'), isTrue);
      expect(manager.tearOffId, 'captions');
      expect(manager.isFloating('captions'), isTrue);
      expect(manager.isDragging, isFalse);
      // Left its group entirely, so nothing paints it in the dock.
      expect(
        manager.panelsIn(DockSide.right).map((PanelDescriptor d) => d.id),
        isNot(contains('captions')),
      );
      expect(backend.tearOffs, hasLength(1));
      final TearOffCall call = backend.tearOffs.single;
      expect(call.id, 'captions');
      expect(call.origin, DockSide.right);
      expect(call.paneRect, pane);
      expect(call.headerHeight, header);
      expect(call.pointerInPane, const Offset(20, 12));
      // The hover preview is live from the first frame: the pane is being
      // dragged, even though Flutter's own drag was cancelled.
      expect(manager.isExternalDragging, isTrue);
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
