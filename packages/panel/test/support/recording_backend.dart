// Test double for [PanelWindowingBackend]: records the seam calls a real
// platform backend would receive, and lets a test drive the backend-side
// outcomes (a hover report, a release commit) by hand.

import 'package:flutter/widgets.dart';
import 'package:panel/panel.dart';

/// One `openTearOff` call, with the geometry the dock measured.
class TearOffCall {
  const TearOffCall({
    required this.id,
    required this.origin,
    required this.paneRect,
    required this.headerHeight,
    required this.pointerInPane,
  });

  final String id;
  final DockSide origin;
  final Rect paneRect;
  final double headerHeight;
  final Offset pointerInPane;

  @override
  String toString() => 'TearOffCall($id, $origin, $paneRect)';
}

/// A [PanelWindowingBackend] that records instead of opening windows.
///
/// [supportsDetach] is switchable so a test can prove the tear-off path is
/// inert on a platform without windowing (web, the default backend).
class RecordingBackend extends PanelWindowingBackend {
  RecordingBackend({this.supportsDetachOverride = true});

  bool supportsDetachOverride;

  final List<String> calls = <String>[];
  final List<TearOffCall> tearOffs = <TearOffCall>[];
  final List<String> opened = <String>[];
  final List<String> closed = <String>[];
  final List<String> dims = <String>[];

  /// Panels a test wants the backend to consider "open", newest last.
  final List<String> openIds = <String>[];

  @override
  bool get supportsDetach => supportsDetachOverride;

  @override
  void open(PanelDescriptor descriptor, {required DockSide origin}) {
    calls.add('open:${descriptor.id}');
    opened.add(descriptor.id);
    openIds.add(descriptor.id);
  }

  /// When true (the default), [openTearOff] reports the window-first path: a
  /// [TearOffHandle] whose [TearOffHandle.onReady] the test fires via
  /// [markTearOffReady]. When false, [openTearOff] returns null and the
  /// manager falls back to removing the pane then calling [open].
  bool windowFirstTearOff = true;

  /// The readiness callbacks handed out by [openTearOff], keyed by panel id.
  /// A test calls [markTearOffReady] to simulate the window's first frame.
  final Map<String, VoidCallback> _readyCallbacks = <String, VoidCallback>{};

  /// Simulates the torn-off window having painted its first frame.
  void markTearOffReady(String id) => _readyCallbacks.remove(id)?.call();

  @override
  TearOffHandle? openTearOff(
    PanelDescriptor descriptor, {
    required DockSide origin,
    required Rect paneRect,
    required double headerHeight,
    required Offset pointerInPane,
  }) {
    calls.add('openTearOff:${descriptor.id}');
    tearOffs.add(TearOffCall(
      id: descriptor.id,
      origin: origin,
      paneRect: paneRect,
      headerHeight: headerHeight,
      pointerInPane: pointerInPane,
    ));
    opened.add(descriptor.id);
    openIds.add(descriptor.id);
    if (!windowFirstTearOff) return null;
    final TearOffHandle handle = TearOffHandle();
    _readyCallbacks[descriptor.id] = () => handle.onReady?.call();
    return handle;
  }

  @override
  void close(String id) {
    calls.add('close:$id');
    closed.add(id);
    openIds.remove(id);
  }

  @override
  void setTearOffDim(String id, bool dimmed) {
    calls.add('dim:$id:$dimmed');
    dims.add('$id:$dimmed');
  }
}
