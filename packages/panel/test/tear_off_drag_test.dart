// The tear-off as the user performs it: press a tab, drag it out of the
// workspace, and the pane is gone from the dock — its content now hosted by the
// backend's window.
//
// The window itself is faked (a `Column` with a strip on top of
// `PanelManager.contentOf`) because that is the contract the platform backend
// honours: build the panel's content, size the surface to the rect it was
// handed. The panel's `State` does NOT survive the move — a real detached
// window is a separate FlutterView, so there is no element to carry across;
// each host builds its own.

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/panel.dart';

import 'support/recording_backend.dart';

void main() {
  const Size viewSize = Size(1400, 1000);
  const double strip = 38 + 1; // tabStripHeight + tabDividerThickness

  /// The rect the backend must be handed for [find.byType]'s panel: the docked
  /// pane's rect, tab strip included, measured the same way the dock measures it.
  Rect paneRectAround(WidgetTester tester, Finder body) {
    final RenderBox box = tester.renderObject<RenderBox>(body);
    final Offset topLeft = box.localToGlobal(Offset.zero);
    return Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy - strip,
      box.size.width,
      box.size.height + strip,
    );
  }

  testWidgets('a tab dragged out of the workspace tears the pane off',
      (WidgetTester tester) async {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final RecordingBackend backend = RecordingBackend();
    final PanelManager manager = PanelManager(windowing: backend)
      ..registerPanel(
        PanelDescriptor(
          id: 'captions',
          title: 'Captions',
          builder: (_) => const _Probe(),
        ),
        side: DockSide.right,
      )
      ..registerPanel(
        const PanelDescriptor(
          id: 'preview',
          title: 'Preview',
          builder: _filler,
        ),
        side: DockSide.center,
      );

    final ValueNotifier<bool> floating = ValueNotifier<bool>(false);
    addTearDown(floating.dispose);

    await tester.pumpWidget(
        _harness(manager, floating, windowPanelId: 'captions'));
    await tester.pumpAndSettle();

    final _ProbeState probe = tester.state<_ProbeState>(find.byType(_Probe));
    probe.controller.jumpTo(600);
    await tester.pump();

    final Rect expectedPane = paneRectAround(tester, find.byType(_Probe));
    final Offset press = tester.getCenter(find.text('Captions'));

    final TestGesture gesture = await tester.startGesture(
      press,
      // A mouse resolves the drag recognizer at the precise-pointer slop (1 px),
      // so every move after that reaches `onDragUpdate` with a real position —
      // which is the desktop gesture the threshold is measured against.
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    await gesture.moveBy(const Offset(4, 0));
    await tester.pump();
    expect(backend.tearOffs, isEmpty,
        reason: 'below the pop-out distance nothing at all happens');

    // Well past the threshold, but still over the dock: every drop target of the
    // workspace lives here (reorder, split, another group, another region), so
    // this must stay an ordinary dock drag.
    await gesture.moveTo(const Offset(900, 300));
    await tester.pump();
    expect(backend.tearOffs, isEmpty,
        reason: 'inside the dock the drag must stay droppable');
    expect(manager.isTornOff('captions'), isFalse);

    // Off the dock entirely: the window is created while the pane is still
    // docked (the window-first path), so the pane only leaves once the window
    // reports its first frame.
    await gesture.moveTo(const Offset(1500, 500));
    await tester.pump();

    expect(backend.tearOffs, hasLength(1));
    // Still docked: the window has not painted yet, so the pane has not moved.
    expect(find.text('Captions'), findsOneWidget,
        reason: 'the pane stays docked until the window is ready');

    // The app's window host renders the detached window in the same turn the
    // pane leaves the dock (`registry.register` inside `openTearOff`), so the
    // content key always has a host and never leaves the tree.
    backend.markTearOffReady('captions');
    floating.value = true;
    await tester.pump();

    expect(backend.tearOffs, hasLength(1));
    final TearOffCall call = backend.tearOffs.single;
    expect(call.id, 'captions');
    expect(call.origin, DockSide.right);
    expect(call.paneRect, expectedPane);
    expect(call.headerHeight, strip);
    expect(call.pointerInPane, press - expectedPane.topLeft,
        reason: 'the anchor is where the pointer went down, so the window '
            'travels exactly as far as the pointer did');
    expect(manager.isTornOff('captions'), isTrue);
    expect(find.text('Captions'), findsNothing,
        reason: 'the pane left the dock for good');

    // The pane's State does not survive the tear-off: the window's copy is a
    // fresh element (a real detached window is a separate FlutterView, so no
    // element could cross anyway). The probe's scroll offset resets.
    expect(
      identical(tester.state<_ProbeState>(find.byType(_Probe)), probe),
      isFalse,
      reason: 'each host builds its own element — State does not cross views',
    );
    expect(tester.state<_ProbeState>(find.byType(_Probe)).controller.offset, 0);

    await gesture.up();
    await tester.pumpAndSettle();
    // Releasing must not double-detach or re-dock: the backend owns the rest.
    expect(backend.closed, isEmpty);
    expect(manager.isTornOff('captions'), isTrue);
  });

  testWidgets('with tearOffOnDragStart the pane is a window on the drag\'s own '
      'first frame — no tab pill, nothing docked is dropped onto',
      (WidgetTester tester) async {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final RecordingBackend backend = RecordingBackend();
    // libnativeapi's `detachable_window_example`: the window *is* the drag
    // visual, so the gesture never waits for a threshold or for the pointer to
    // leave the dock.
    final PanelManager manager = PanelManager(
      windowing: backend,
      config: const PanelDockConfig(tearOffOnDragStart: true),
    )
      ..registerPanel(
        PanelDescriptor(
          id: 'captions',
          title: 'Captions',
          builder: (_) => const _Probe(),
        ),
        side: DockSide.right,
      )
      ..registerPanel(
        const PanelDescriptor(
          id: 'preview',
          title: 'Preview',
          builder: _filler,
        ),
        side: DockSide.center,
      );

    final ValueNotifier<bool> floating = ValueNotifier<bool>(false);
    addTearDown(floating.dispose);

    await tester.pumpWidget(
        _harness(manager, floating, windowPanelId: 'captions'));
    await tester.pumpAndSettle();

    final _ProbeState probe = tester.state<_ProbeState>(find.byType(_Probe));
    probe.controller.jumpTo(600);
    await tester.pump();

    final Rect expectedPane = paneRectAround(tester, find.byType(_Probe));
    final Offset press = tester.getCenter(find.text('Captions'));

    final TestGesture gesture = await tester.startGesture(
      press,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    // TWO pixels — the smallest movement a mouse can turn into a drag at all
    // (`ImmediateMultiDragGestureRecognizer` resolves above
    // `kPrecisePointerHitSlop`, which is 1.0, strictly) — and still inside the
    // dock, with no frame in between: immediate mode has no threshold, so this is
    // already a complete tear-off. The tear-off runs on a microtask (the
    // recognizer only owns the drag after `onDragStarted` returns), which lands
    // before the next frame is ever built — so the tab's `childWhenDragging`, the
    // reorder halves and the drag pill are all never painted. If the tear-off
    // regressed to a threshold gate, this would see nothing.
    await gesture.moveBy(const Offset(-2, 0));
    backend.markTearOffReady('captions');
    floating.value = true;
    await tester.pump();

    expect(backend.tearOffs, hasLength(1),
        reason: 'the pane left at the drag\'s own start, inside the dock');
    final TearOffCall call = backend.tearOffs.single;
    expect(call.id, 'captions');
    expect(call.origin, DockSide.right);
    expect(call.paneRect, expectedPane);
    expect(call.headerHeight, strip);
    expect(call.pointerInPane, press - expectedPane.topLeft,
        reason: 'anchored on the press, so the window does not jump');
    expect(manager.isTornOff('captions'), isTrue);
    // The label survives in no form at all: not as the docked tab, and not as a
    // drag pill left in the overlay — which is the whole point of this mode (the
    // window is the drag, so a ghost of the tab must never be drawn).
    expect(find.text('Captions'), findsNothing);
    // The tear-off cancelled the Flutter drag, and `endDrag` still has to run:
    // `Draggable`'s own `onDragEnd` callback is gated on its element still being
    // mounted (it never is — the tab left the dock), but `onDraggableCanceled` is
    // not, and that is what clears the dock's dragging state. If it did not run,
    // the dock would sit in drag mode forever, drawing drop zones over a pane
    // that re-docked.
    expect(manager.isDragging, isFalse,
        reason: 'the dock must not stay in drag mode after a tear-off');

    // Same contract as the thresholded tear-off above: the window's copy is a
    // fresh element, the pane's State does not survive.
    expect(
      identical(tester.state<_ProbeState>(find.byType(_Probe)), probe),
      isFalse,
      reason: 'each host builds its own element — State does not cross views',
    );
    expect(tester.state<_ProbeState>(find.byType(_Probe)).controller.offset, 0);

    // The tear-off cancels the Flutter drag: the release belongs to the backend
    // (which re-docks or leaves the panel floating), so it must not also detach.
    await gesture.up();
    await tester.pumpAndSettle();
    expect(backend.closed, isEmpty);
    expect(manager.isTornOff('captions'), isTrue);
  });

  testWidgets('an inactive tab tears off too (its group shares one body slot)',
      (WidgetTester tester) async {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final RecordingBackend backend = RecordingBackend();
    // The app's own default shape: the right dock holds an active panel plus one
    // the user never selected, so only the active one's content is mounted.
    final PanelManager manager = PanelManager(windowing: backend)
      ..registerPanel(
        PanelDescriptor(
          id: 'captions',
          title: 'Captions',
          builder: (_) => const _Probe(),
        ),
        side: DockSide.right,
      )
      ..registerPanel(
        const PanelDescriptor(
          id: 'inspector',
          title: 'Inspector',
          builder: _filler,
        ),
        side: DockSide.right,
        activate: false,
      );

    final ValueNotifier<bool> floating = ValueNotifier<bool>(false);
    addTearDown(floating.dispose);

    await tester.pumpWidget(
        _harness(manager, floating, windowPanelId: 'inspector'));
    await tester.pumpAndSettle();

    expect(find.text('Inspector'), findsOneWidget);
    final Rect expectedPane = paneRectAround(tester, find.byType(_Probe));

    // The strip scrolls, so the last tab can be partly out of its viewport (and
    // under the strip's own buttons): press the visible left end of its label.
    final Rect label = tester.getRect(find.text('Inspector'));
    final TestGesture gesture = await tester.startGesture(
      Offset(label.left + 8, label.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    // The drag's first update reports the press position, so a second move is
    // what carries a real position (see the comment on the gesture in the test
    // above).
    await gesture.moveBy(const Offset(4, 0));
    await tester.pump();
    await gesture.moveTo(const Offset(1500, 500));
    backend.markTearOffReady('inspector');
    floating.value = true;
    await tester.pump();

    expect(backend.tearOffs, hasLength(1));
    expect(backend.tearOffs.single.id, 'inspector');
    expect(backend.tearOffs.single.paneRect, expectedPane,
        reason: 'an unmounted tab must still measure its group\u2019s pane');

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a released tear-off that lands nowhere stays a floating window',
      (WidgetTester tester) async {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final RecordingBackend backend = RecordingBackend();
    final PanelManager manager = PanelManager(windowing: backend)
      ..registerPanel(
        const PanelDescriptor(id: 'preview', title: 'Preview', builder: _filler),
        side: DockSide.center,
      );

    final ValueNotifier<bool> floating = ValueNotifier<bool>(false);
    addTearDown(floating.dispose);

    await tester.pumpWidget(
        _harness(manager, floating, windowPanelId: 'preview'));
    await tester.pumpAndSettle();

    manager.beginTearOff(
      'preview',
      paneRect: const Rect.fromLTWH(10, 20, 300, 400),
      headerHeight: 39,
      pointerInPane: const Offset(5, 5),
    );
    backend.markTearOffReady('preview');
    floating.value = true;
    await tester.pump();

    const Rect main = Rect.fromLTWH(0, 0, 1400, 1000);
    manager.updateExternalDragHover(const Offset(40, 400), main);
    expect(manager.externalHoverSide, DockSide.left);
    expect(backend.dims, <String>['preview:true']);

    // Off every zone: the release must leave the window where it is.
    manager.updateExternalDragHover(const Offset(-400, 400), main);
    expect(manager.externalHoverSide, isNull);
    manager.endExternalDrag(commitId: 'preview');
    await tester.pumpAndSettle();

    expect(backend.closed, isEmpty);
    expect(manager.isFloating('preview'), isTrue);
    expect(backend.dims.last, 'preview:false');
    expect(find.byType(PanelDock), findsNothing);
  });
}

Widget _harness(
  PanelManager manager,
  ValueListenable<bool> floating, {
  required String windowPanelId,
}) {
  return PanelScope(
    manager: manager,
    child: MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<bool>(
          valueListenable: floating,
          builder: (BuildContext context, bool isFloating, _) => isFloating
              ? _FakeWindow(manager: manager, panelId: windowPanelId)
              : const PanelDock(),
        ),
      ),
    ),
  );
}

/// Stands in for a detached window: the panel's own content, hosted through the
/// manager's key, under a strip of its own.
class _FakeWindow extends StatelessWidget {
  const _FakeWindow({required this.manager, required this.panelId});

  final PanelManager manager;
  final String panelId;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 39, child: ColoredBox(color: Color(0xFF202020))),
        Expanded(child: manager.contentOf(panelId, context)),
      ],
    );
  }
}

/// A panel whose identity is observable: if the element is rebuilt instead of
/// moved, this `State` (and its scroll offset) is a different object.
class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final ScrollController controller = ScrollController();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: controller,
      itemCount: 60,
      itemBuilder: (BuildContext context, int index) =>
          SizedBox(height: 40, child: Text('row $index')),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

Widget _filler(BuildContext context) => const SizedBox.shrink();
