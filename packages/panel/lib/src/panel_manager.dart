// Core state for the dockable panel framework.
//
// [PanelManager] is a [ChangeNotifier] that owns:
//   * the registry of all [PanelDescriptor]s,
//   * where each panel currently lives: a [DockSide] region is an ordered list
//     of *groups* (each a tab strip) laid out along the region's axis, so panels
//     can sit side-by-side; or a panel can be floating in its own OS window,
//   * per-region layout state (active group, region size, collapsed/minimized)
//     and per-group weights,
//   * the live drag/drop state used to paint drop zones.
//
// This file is platform-generic: it has NO dependency on the experimental
// windowing APIs or any native code. Detaching is delegated to a
// [PanelWindowingBackend] (see panel_windowing.dart); the default backend makes
// it a no-op, so the core compiles and runs anywhere (including web).

import 'dart:async';

import 'package:flutter/gestures.dart' show GestureBinding, PointerCancelEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;

import 'panel.dart';
import 'panel_config.dart';
import 'panel_windowing.dart';

/// A tabbed group of panels within a region.
class _Group {
  _Group({this.weight = 1.0});
  final List<String> panelIds = <String>[];
  String? activeId;
  double weight;
}

/// A dock region: an ordered list of [_Group]s laid out along the region axis.
class _Region {
  _Region(this.size);
  final List<_Group> groups = <_Group>[];
  int activeGroup = 0;
  bool collapsed = false;
  double size;
}

/// Owns all panel placement and drives the UI via [ChangeNotifier].
///
/// Construct one, [registerPanel] your panels, expose it via [PanelScope], and
/// render a `PanelDock`. All tunables live in [config]. Detaching panels into
/// external windows is delegated to [windowing] (a [PanelWindowingBackend]);
/// the default backend disables detaching so the core runs on any platform.
class PanelManager extends ChangeNotifier {
  PanelManager({
    this.config = const PanelDockConfig(),
    PanelWindowingBackend windowing = const DisabledWindowing(),
  }) {
    _windowing = windowing;
    _regions = <DockSide, _Region>{
      for (final DockSide side in DockSide.values) side: _Region(config.initialSize(side)),
    };
    _windowing.attach(this);
  }

  /// Immutable configuration shared by the manager and the widgets.
  final PanelDockConfig config;

  /// Backend that hosts detached panels (OS windows). Defaults to a no-op.
  late final PanelWindowingBackend _windowing;

  /// Whether the active backend can detach panels into external windows.
  bool get supportsDetach => _windowing.supportsDetach;

  final Map<String, PanelDescriptor> _descriptors = <String, PanelDescriptor>{};
  late final Map<DockSide, _Region> _regions;
  // id -> the dock it should snap back to. Generic (no platform types).
  final Map<String, DockSide> _floatingOrigin = <String, DockSide>{};

  /// Mints (and remembers) the [GlobalKey] on each group's body slot — the
  /// `Expanded` under the tab strip that hosts the active panel's content.
  /// [paneRect] measures a torn-off pane's rect through it: every tab of a
  /// group shares that one slot, so the key is on the *slot*, not the content
  /// (a detached window is a separate FlutterView, so a content GlobalKey
  /// could never reparent there anyway — there is nothing to preserve).
  final Map<String, GlobalKey> _bodyKeys = <String, GlobalKey>{};

  // ---- Tear-off state ------------------------------------------------------

  /// The panel currently being torn off (dragged as its own window), if any.
  ///
  /// Distinct from [_isDragging]: the Flutter tab drag is *cancelled* the
  /// moment the pane becomes a window (the backend owns the gesture from then
  /// on), but the dock still suppresses the legacy detach path and the pill
  /// until the tear-off finishes.
  String? _tearOffId;

  /// Whether the torn-off pane is still docked, waiting for the window's
  /// first frame before it is removed (the window-first path of
  /// [beginTearOff]). While true the panel is already floating
  /// ([_floatingOrigin] is set) but has not left its dock group yet.
  bool _tearOffPendingDetach = false;

  /// Safety net for [_tearOffPendingDetach]: if the window never reports a
  /// first frame, the pane is detached anyway after this long.
  Timer? _tearOffDetachTimer;

  /// How long [_detachTornOffPane] waits for the window's first frame before
  /// detaching anyway.
  static const Duration _tearOffDetachTimeout = Duration(milliseconds: 600);

  // ---- Drag/drop state -----------------------------------------------------
  bool _isDragging = false;
  DockSide? _dragSide;
  int _dragGroup = -1;
  String? _dragPanelId;

  /// Whether a tab is currently being dragged (drives the drop-zone overlays).
  bool get isDragging => _isDragging;

  /// The panel id of the in-flight tab drag, if any.
  String? get draggedPanelId => _dragPanelId;

  /// Whether group [gi] of [side] is the group the in-flight drag came from.
  /// Drop targets use this to suppress no-op "drop onto yourself" actions.
  bool isDragSource(DockSide side, int gi) => _dragSide == side && _dragGroup == gi;

  /// The panel's docked pane rect (tab strip **and** body) in the main view's
  /// logical coordinates, measured live from the group's body slot.
  ///
  /// This is what a tear-off hands the backend: the pane keeps its own rect, so
  /// the window needs no reflow — only a header of [headerHeight] where the tab
  /// strip was.
  ///
  /// The body slot is the `Expanded` under the tab strip — the *last* child of
  /// the group, filling its width — so the group is the slot's rect grown
  /// upwards by [headerHeight] (the strip plus its divider). Every tab of a
  /// group shares that one slot, so the measurement is the same whichever tab
  /// is dragged — an inactive tab tears off to exactly the rect it would have
  /// had docked.
  ///
  /// Null when the panel is not currently hosted (or not laid out yet), in
  /// which case a tear-off is skipped rather than guessed at.
  Rect? paneRect(String id, {required double headerHeight}) {
    final ({DockSide side, int gi})? loc = _locOf(id);
    if (loc == null) return null;
    final BuildContext? context = bodyKeyOf(loc.side, loc.gi).currentContext;
    if (context == null) return null;
    final RenderObject? renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    final Size size = renderObject.size;
    if (size.isEmpty) return null;
    final Offset topLeft = renderObject.localToGlobal(Offset.zero);
    return Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy - headerHeight,
      size.width,
      size.height + headerHeight,
    );
  }

  /// The workspace's own bounds in the main view's logical coordinates, as last
  /// reported by the dock. Null until the dock has laid out.
  Rect? get dockRect => _dockRect;
  Rect? _dockRect;

  /// Backend/UI hook: the dock reports its bounds so a tab drag can tell "still
  /// over the workspace" (a dock drag) from "taken out of the workspace" (a
  /// tear-off).
  void reportDockRect(Rect rect) {
    if (_dockRect == rect) return;
    _dockRect = rect;
  }

  /// Called by the UI when a tab drag begins, with the tab's origin group and id.
  void beginDrag({DockSide? side, int? group, String? panelId}) {
    _isDragging = true;
    _dragSide = side;
    _dragGroup = group ?? -1;
    _dragPanelId = panelId;
    _updateEscHandler();
    notifyListeners();
  }

  /// Whether a tab drag turns its pane into a window at all — either at the
  /// [PanelDockConfig.popOutDistance] threshold, or immediately (see
  /// [tearOffAtDragStart]) — instead of waiting for a release outside the
  /// window.
  bool get tearOffOnDrag => config.tearOffEnabled && supportsDetach;

  /// Whether a tab drag must tear its pane off at the drag's **own start**,
  /// without waiting for [PanelDockConfig.popOutDistance] or for the pointer to
  /// leave the dock ([PanelDockConfig.tearOffOnDragStart]).
  bool get tearOffAtDragStart => tearOffOnDrag && config.tearOffOnDragStart;

  /// Whether dragging [id]'s tab may tear it off right now.
  bool canTearOff(String id) =>
      tearOffOnDrag && (_descriptors[id]?.detachable ?? true);

  /// The panel currently being torn off, if any.
  String? get tearOffId => _tearOffId;

  /// Whether [id] is the panel currently being torn off.
  bool isTornOff(String id) => _tearOffId != null && _tearOffId == id;

  /// Whether [id]'s tear-off is still warming up: the window exists but has
  /// not painted its first frame, so the pane is still docked.
  ///
  /// A detached-window host uses this to keep the window hidden while it warms
  /// up — dimming or revealing it now would show a window that has not painted
  /// its content yet.
  bool isTearOffPending(String id) => _tearOffId == id && _tearOffPendingDetach;

  /// Tears [id] out of the dock into a floating window **at the pane's own
  /// rect**, for the drag-threshold gesture.
  ///
  /// [paneRect] is the docked pane's rect (tab strip + body) in the main
  /// view's logical coordinates; [headerHeight] is the chrome the floating
  /// window adds above the content, so the content keeps exactly the height it
  /// had docked. [pointerInPane] is where the cursor was inside [paneRect] at
  /// the moment of the tear-off, so the window tracks the cursor with the
  /// grabbed point pinned.
  ///
  /// The in-flight Flutter tab drag is cancelled here (the pointer is routed a
  /// [PointerCancelEvent]) — the window that owns the gesture may never see the
  /// release, so the backend tracks the cursor from now on and finishes with
  /// [endExternalDrag].
  ///
  /// The window is created **before** the pane leaves the dock whenever the
  /// backend supports it: [PanelWindowingBackend.openTearOff] returning a
  /// [TearOffHandle] means the window exists (hidden) and will report its first
  /// frame through [TearOffHandle.onReady]; only then is the pane removed, so
  /// it never disappears while the window spins up. A backend that cannot do
  /// that returns null and the pane is removed first, as before.
  void beginTearOff(
    String id, {
    required Rect paneRect,
    required double headerHeight,
    required Offset pointerInPane,
  }) {
    if (_tearOffId != null) return;
    if (!canTearOff(id)) return;
    final DockSide origin = _locOf(id)?.side ?? DockSide.right;
    _tearOffId = id;

    // Mark the detach pending BEFORE openTearOff: the window is created hidden
    // and stays that way (the backend's dim/reveal honors isTearOffPending)
    // until the pane has left the dock and the window has painted its content.
    _tearOffPendingDetach = true;
    final TearOffHandle? handle;
    try {
      handle = _windowing.openTearOff(
        _descriptors[id]!,
        origin: origin,
        paneRect: paneRect,
        headerHeight: headerHeight,
        pointerInPane: pointerInPane,
      );
    } catch (_) {
      _tearOffPendingDetach = false;
      _tearOffId = null;
      rethrow;
    }
    if (handle != null) {
      _floatingOrigin[id] = origin;
      _tearOffDetachTimer = Timer(_tearOffDetachTimeout, () {
        // The window never reported a first frame: detach anyway — a flash of
        // empty dock is better than a pane that can never leave.
        _detachTornOffPane(id);
      });
      handle.onReady = () => _detachTornOffPane(id);
    } else {
      // No window was created by openTearOff (unsupported platform, or the
      // backend could not host it). Remove the pane now and open the window in
      // the old order — the pane is gone for the window-creation window.
      _tearOffPendingDetach = false;
      _removeFromDock(id);
      _floatingOrigin[id] = origin;
      _windowing.open(_descriptors[id]!, origin: origin);
    }

    // Hand the gesture to the backend: cancel the Flutter drag first, so its
    // `onDraggableCanceled` can't also detach the panel (consumeDragCancel).
    _dragCancelRequested = true;
    _updateEscHandler();
    final int? pointer = _dragPointerId;
    if (pointer != null) {
      GestureBinding.instance.pointerRouter
          .route(PointerCancelEvent(pointer: pointer));
    }
    _externalDragging = true;
    notifyListeners();
  }

  /// Removes the torn-off pane from the dock — the deferred half of
  /// [beginTearOff]'s window-first path.
  ///
  /// Called by the backend's [TearOffHandle.onReady] once the window has
  /// painted its first frame, or by the safety timer if that never arrives.
  /// The pane leaves the dock here; the window's own copy of the content was
  /// already built while hidden, so the reveal that follows shows it painted.
  void _detachTornOffPane(String id) {
    if (_tearOffId != id || !_tearOffPendingDetach) return;
    _tearOffPendingDetach = false;
    _tearOffDetachTimer?.cancel();
    _tearOffDetachTimer = null;
    _removeFromDock(id);
    notifyListeners();
  }

  /// Called by the UI when a tab drag ends.
  ///
  /// Also hides the drag image. Doing it here (rather than only in the
  /// Draggable callbacks) covers every end path: dropping on a target can
  /// dispose the source Draggable before `onDragEnd` fires, which would
  /// otherwise leave the backend's cursor tracker running forever.
  void endDrag() {
    hideDragImage();
    if (!_isDragging) return;
    _isDragging = false;
    _dragSide = null;
    _dragGroup = -1;
    _dragPanelId = null;
    _dragPointerId = null;
    _updateEscHandler();
    notifyListeners();
  }

  /// Registers/removes the ESC handler according to whether *any* drag (a tab
  /// drag or a tear-off) is in flight.
  void _updateEscHandler() {
    final bool want = _isDragging || _tearOffId != null;
    if (want == _escHandlerRegistered) return;
    if (want) {
      HardwareKeyboard.instance.addHandler(_onHardwareKey);
    } else {
      HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    }
    _escHandlerRegistered = want;
  }

  // ---- Drag cancellation --------------------------------------------------
  //
  // ESC and right-click cancel the in-flight drag, returning the panel to its
  // original location — no detach, no move. The drag itself is cancelled by
  // routing a synthetic [PointerCancelEvent] for the drag's pointer through
  // the binding's pointer router, which makes the Draggable's avatar finish
  // as a cancel (and run `onDraggableCanceled`, which then checks
  // [consumeDragCancel] so it doesn't tear the panel off).

  int? _dragPointerId;
  bool _dragCancelRequested = false;
  bool _escHandlerRegistered = false;

  /// Records the pointer that went down on a tab — the pointer that will
  /// drive the drag, if one starts — so [cancelDrag] can target the right
  /// drag.
  void noteDragPointer(int pointer) => _dragPointerId = pointer;

  bool _onHardwareKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        (_isDragging || _tearOffId != null)) {
      cancelDrag();
      return true;
    }
    return false;
  }

  /// Cancels the in-flight drag or tear-off (ESC / right-click): the panel
  /// returns to its original location — no detach, no move.
  ///
  /// A tear-off is already a window, so cancelling it means re-docking the
  /// panel (which destroys the window and stops the backend's tracker); a tab
  /// drag is cancelled by routing a synthetic [PointerCancelEvent] through the
  /// binding's pointer router, which makes the Draggable's avatar finish as a
  /// cancel (and run `onDraggableCanceled`, which then checks
  /// [consumeDragCancel] so it doesn't tear the panel off).
  void cancelDrag() {
    final String? torn = _tearOffId;
    if (torn != null) {
      redock(torn);
      return;
    }
    if (!_isDragging) return;
    _dragCancelRequested = true;
    final int? pointer = _dragPointerId;
    if (pointer != null) {
      GestureBinding.instance.pointerRouter
          .route(PointerCancelEvent(pointer: pointer));
    }
  }

  /// Returns whether the in-flight drag was cancelled via [cancelDrag], and
  /// clears the flag. Consumed by the Draggable's `onDraggableCanceled` so a
  /// deliberate cancel doesn't tear the panel off.
  bool consumeDragCancel() {
    final bool v = _dragCancelRequested;
    _dragCancelRequested = false;
    return v;
  }

  // ---- Registration --------------------------------------------------------

  /// Registers [descriptor] and docks it as a tab in [side]'s first group.
  void registerPanel(PanelDescriptor descriptor, {DockSide side = DockSide.right, bool activate = true}) {
    _descriptors[descriptor.id] = descriptor;
    final _Region region = _regions[side]!;
    if (region.groups.isEmpty) region.groups.add(_Group());
    final _Group g = region.groups.first;
    g.panelIds.add(descriptor.id);
    if (activate || g.activeId == null) g.activeId = descriptor.id;
    notifyListeners();
  }

  /// The descriptor registered for [id].
  PanelDescriptor descriptor(String id) => _descriptors[id]!;

  /// The [GlobalKey] on the body slot of the group at ([side], [gi]) — the
  /// `Expanded` that hosts the active panel's content. [paneRect] measures a
  /// torn-off pane's rect through it. Stable for the manager's lifetime.
  GlobalKey bodyKeyOf(DockSide side, int gi) {
    return _bodyKeys['${side.name}:$gi'] ??=
        GlobalKey(debugLabel: 'panel-body-${side.name}-$gi');
  }

  /// Builds [id]'s content.
  ///
  /// The panel's [State] does not survive a tear-off or re-dock: a detached
  /// window is a separate FlutterView with its own element tree, so there is
  /// no element to carry across — each host builds its own. State that must
  /// survive should live in the descriptor/provider layer, not widget State.
  Widget contentOf(String id, BuildContext context) {
    return _descriptors[id]!.builder(context);
  }

  // ---- Region / group queries ---------------------------------------------

  /// Whether [side] currently has any docked panels.
  bool hasPanels(DockSide side) => _regions[side]!.groups.isNotEmpty;

  /// Whether [side]'s dock is collapsed (minimized to a strip).
  bool isCollapsed(DockSide side) => _regions[side]!.collapsed;

  /// Current extent (width for left/right, height for bottom) of [side].
  double sizeOf(DockSide side) => _regions[side]!.size;

  /// Number of side-by-side groups in [side].
  int groupCount(DockSide side) => _regions[side]!.groups.length;

  /// All panels in [side], across every group, in visual order.
  List<PanelDescriptor> panelsIn(DockSide side) => _regions[side]!
      .groups
      .expand((_Group g) => g.panelIds)
      .map((String id) => _descriptors[id]!)
      .toList(growable: false);

  /// Panels in group [gi] of [side] (empty if out of range).
  List<PanelDescriptor> panelsInGroup(DockSide side, int gi) {
    final List<_Group> groups = _regions[side]!.groups;
    if (gi < 0 || gi >= groups.length) return const <PanelDescriptor>[];
    return groups[gi].panelIds.map((String id) => _descriptors[id]!).toList(growable: false);
  }

  /// The selected panel id of group [gi] in [side], or null.
  String? activeInGroup(DockSide side, int gi) {
    final List<_Group> groups = _regions[side]!.groups;
    if (gi < 0 || gi >= groups.length) return null;
    final _Group g = groups[gi];
    return g.panelIds.contains(g.activeId) ? g.activeId : (g.panelIds.isEmpty ? null : g.panelIds.first);
  }

  /// Active panel of the region's active group (handy for summaries).
  String? activeIdOf(DockSide side) => activeInGroup(side, _regions[side]!.activeGroup);

  /// Relative flex weight of group [gi] within [side].
  double groupWeight(DockSide side, int gi) {
    final List<_Group> groups = _regions[side]!.groups;
    return (gi >= 0 && gi < groups.length) ? groups[gi].weight : 1.0;
  }

  /// Whether [id] is currently in a detached (floating) window.
  bool isFloating(String id) => _floatingOrigin.containsKey(id);

  /// Ids of all panels currently floating.
  Iterable<String> get floatingIds => _floatingOrigin.keys;

  // ---- Region / group mutations -------------------------------------------

  /// Selects [id] as the active tab of group [gi] in [side].
  void setActiveInGroup(DockSide side, int gi, String id) {
    final _Region r = _regions[side]!;
    if (gi < 0 || gi >= r.groups.length) return;
    r.groups[gi].activeId = id;
    r.activeGroup = gi;
    notifyListeners();
  }

  /// Collapses/restores [side]'s dock (minimize to a strip).
  void toggleCollapsed(DockSide side) {
    _regions[side]!.collapsed = !_regions[side]!.collapsed;
    notifyListeners();
  }

  /// Sets [side]'s extent, clamped to `config.minDockExtent`.
  void setSize(DockSide side, double size) {
    _regions[side]!.size = size.clamp(config.minDockExtent, 1600);
    notifyListeners();
  }

  /// Shifts weight between group [gi] and [gi+1] by [deltaPx] of [totalPx].
  void adjustGroupWeights(DockSide side, int gi, double deltaPx, double totalPx) {
    final List<_Group> groups = _regions[side]!.groups;
    if (gi < 0 || gi + 1 >= groups.length || totalPx <= 0) return;
    final double sum = groups.fold(0.0, (double a, _Group g) => a + g.weight);
    final double shift = (deltaPx / totalPx) * sum;
    final double minW = sum * config.minGroupFraction;
    final double a = groups[gi].weight + shift;
    final double b = groups[gi + 1].weight - shift;
    if (a < minW || b < minW) return;
    groups[gi].weight = a;
    groups[gi + 1].weight = b;
    notifyListeners();
  }

  /// Adds [id] into the group at ([side], [gi]) as a tab.
  void addPanelAsTab(String id, DockSide side, int gi) {
    final _Region r = _regions[side]!;
    if (gi < 0 || gi >= r.groups.length) {
      _addAsNewGroup(id, side, r.groups.length);
      return;
    }
    final _Group target = r.groups[gi];
    final ({DockSide side, int gi})? loc = _locOf(id);
    if (loc != null && identical(_regions[loc.side]!.groups[loc.gi], target)) {
      target.activeId = id;
      r.activeGroup = gi;
      notifyListeners();
      return;
    }
    _removeFromDock(id);
    target.panelIds.add(id);
    target.activeId = id;
    r.activeGroup = r.groups.indexOf(target);
    notifyListeners();
  }

  /// Inserts [id] into group [gi] of [side] at tab position [index]. Reorders
  /// within the same group (used by tab drag-to-reorder) or moves [id] in from
  /// another group/window at that position.
  void movePanelToGroupAt(String id, DockSide side, int gi, int index) {
    final _Region r = _regions[side]!;
    if (gi < 0 || gi >= r.groups.length) {
      _addAsNewGroup(id, side, r.groups.length);
      return;
    }
    final _Group target = r.groups[gi];
    final ({DockSide side, int gi})? loc = _locOf(id);
    final bool sameGroup = loc != null && identical(_regions[loc.side]!.groups[loc.gi], target);

    if (sameGroup) {
      final int old = target.panelIds.indexOf(id);
      if (old < 0) return;
      int insert = index;
      if (old < insert) insert -= 1; // account for the removal shift
      insert = insert.clamp(0, target.panelIds.length - 1);
      if (insert == old) {
        target.activeId = id;
        r.activeGroup = gi;
        notifyListeners();
        return;
      }
      target.panelIds.removeAt(old);
      target.panelIds.insert(insert, id);
      target.activeId = id;
      r.activeGroup = gi;
      notifyListeners();
      return;
    }

    _removeFromDock(id);
    final int insert = index.clamp(0, target.panelIds.length);
    target.panelIds.insert(insert, id);
    target.activeId = id;
    r.activeGroup = r.groups.indexOf(target);
    notifyListeners();
  }

  /// Splits: puts [id] into a NEW group beside the group at ([side], [gi]).
  /// [before] places it on the leading side of that group.
  void splitBeside(String id, DockSide side, int gi, {required bool before}) {
    final _Region r = _regions[side]!;
    if (gi < 0 || gi >= r.groups.length) {
      _addAsNewGroup(id, side, r.groups.length);
      return;
    }
    final _Group ref = r.groups[gi];
    final ({DockSide side, int gi})? loc = _locOf(id);
    // Dropping a single-panel group beside itself is a no-op.
    if (loc != null && identical(_regions[loc.side]!.groups[loc.gi], ref) && ref.panelIds.length == 1) {
      return;
    }
    final double w = ref.weight;
    _removeFromDock(id);
    final _Group g = _Group(weight: w)
      ..panelIds.add(id)
      ..activeId = id;
    int idx = r.groups.indexOf(ref);
    idx = idx < 0 ? r.groups.length : (before ? idx : idx + 1);
    r.groups.insert(idx, g);
    r.activeGroup = idx;
    r.collapsed = false;
    notifyListeners();
  }

  /// Split button: pops the active panel of group [gi] into a new group after it.
  void splitActiveGroup(DockSide side, int gi) {
    final _Region r = _regions[side]!;
    if (gi < 0 || gi >= r.groups.length) return;
    final _Group g = r.groups[gi];
    if (g.panelIds.length < 2 || g.activeId == null) return;
    splitBeside(g.activeId!, side, gi, before: false);
  }

  /// Merges group [gi] into an adjacent group (collapsing a split). Its panels
  /// become tabs of the neighbor; no-op if the region has a single group.
  void mergeGroup(DockSide side, int gi) {
    final _Region r = _regions[side]!;
    if (r.groups.length < 2 || gi < 0 || gi >= r.groups.length) return;
    final _Group from = r.groups[gi];
    final int targetIndex = gi > 0 ? gi - 1 : gi + 1;
    final _Group target = r.groups[targetIndex];
    target.panelIds.addAll(from.panelIds);
    target.activeId = from.activeId ?? target.activeId;
    r.groups.removeAt(gi);
    r.activeGroup = r.groups.indexOf(target);
    _focusedGroup = r.activeGroup;
    notifyListeners();
  }

  // ---- Focus & keyboard ----------------------------------------------------

  DockSide? _focusedSide;
  int _focusedGroup = 0;

  /// The dock side that currently holds keyboard/interaction focus.
  DockSide? get focusedSide => _focusedSide;

  /// Index of the focused group within [focusedSide].
  int get focusedGroup => _focusedGroup;

  /// Whether group [gi] of [side] is the focused group.
  bool isFocusedGroup(DockSide side, int gi) => _focusedSide == side && _focusedGroup == gi;

  /// Records the focused group (e.g. on click); also makes it the active group.
  void setFocusedGroup(DockSide side, int gi) {
    final _Region r = _regions[side]!;
    final int clamped = gi.clamp(0, r.groups.isEmpty ? 0 : r.groups.length - 1);
    if (_focusedSide == side && _focusedGroup == clamped) return;
    _focusedSide = side;
    _focusedGroup = clamped;
    r.activeGroup = clamped;
    notifyListeners();
  }

  /// Splits the focused group's active panel into a new adjacent group.
  void splitFocused() {
    if (_focusedSide != null) splitActiveGroup(_focusedSide!, _focusedGroup);
  }

  /// Merges the focused group into its neighbor.
  void mergeFocused() {
    if (_focusedSide != null) mergeGroup(_focusedSide!, _focusedGroup);
  }

  void _addAsNewGroup(String id, DockSide side, int atIndex) {
    final _Region r = _regions[side]!;
    _removeFromDock(id);
    final _Group g = _Group()
      ..panelIds.add(id)
      ..activeId = id;
    final int idx = atIndex.clamp(0, r.groups.length);
    r.groups.insert(idx, g);
    r.activeGroup = idx;
    r.collapsed = false;
    notifyListeners();
  }

  // ---- Detach / re-dock ----------------------------------------------------

  /// Tears [id] out of the dock into an external window via the [windowing]
  /// backend. No-op if the backend doesn't support detaching.
  void detach(String id) {
    if (!_windowing.supportsDetach) return;
    if (_floatingOrigin.containsKey(id)) return;
    if (!(_descriptors[id]?.detachable ?? true)) return;
    final DockSide origin = _locOf(id)?.side ?? DockSide.right;
    _removeFromDock(id);
    _floatingOrigin[id] = origin;
    notifyListeners();
    _windowing.open(_descriptors[id]!, origin: origin);
  }

  /// Snaps a floating panel back into the dock on [toSide] (defaults to its
  /// origin). When [toGroup] names an existing group of that side, the panel
  /// merges in as a **tab** of it (Resolve: dropping a panel on a docked
  /// group's center adds it as a tab). [toSplit] is an insertion index: the
  /// panel lands as a new group inserted *before* the group at that index
  /// (Resolve: dropping on a group's edge splits beside it). With neither, it
  /// lands as a new group at the region's end.
  ///
  /// Also ends a tear-off on [id]: the window is destroyed, the backend's
  /// cursor tracker notices and stops, and the dock builds the panel's content
  /// fresh — a detached window is a separate FlutterView, so there is no
  /// element to carry back (the panel's State does not survive).
  void redock(String id, {DockSide? toSide, int toGroup = -1, int toSplit = -1}) {
    // A window-first tear-off may still be docked (waiting for the window's
    // first frame): ending it detaches the pane, so the pane is guaranteed to
    // be out of the dock before it is re-added below.
    if (_tearOffId == id) _endTearOff();
    final DockSide? origin = _floatingOrigin.remove(id);
    if (origin == null) return;
    final DockSide target = toSide ?? origin;
    final _Region r = _regions[target]!;
    final bool merge =
        toGroup >= 0 && toGroup < r.groups.length;
    if (merge) {
      // Drop on a group's center: become a tab of that group.
      final _Group g = r.groups[toGroup];
      g.panelIds.add(id);
      g.activeId = id;
      r.activeGroup = toGroup;
    } else if (toSplit >= 0 && toSplit <= r.groups.length) {
      // Drop on a group's edge: split a new group in at that index — the same
      // position the in-dock before/after drop zones commit.
      final _Group g = _Group()
        ..panelIds.add(id)
        ..activeId = id;
      r.groups.insert(toSplit, g);
      r.activeGroup = toSplit;
    } else if (config.redockAsTab && r.groups.isNotEmpty) {
      final _Group g = r.groups.last;
      g.panelIds.add(id);
      g.activeId = id;
      r.activeGroup = r.groups.length - 1;
    } else {
      r.groups.add(_Group()
        ..panelIds.add(id)
        ..activeId = id);
      r.activeGroup = r.groups.length - 1;
    }
    r.collapsed = false;
    notifyListeners();
    _windowing.close(id);
  }

  /// Starts a backend window-move for the floating panel [id] (e.g. so a custom
  /// header can act as the window's drag handle).
  void beginFloatingWindowDrag(String id) {
    if (_floatingOrigin.containsKey(id)) _windowing.beginWindowDrag(id);
  }

  /// Brings the floating window for [id] to the front.
  void focusFloating(String id) => _windowing.focus(id);

  /// Minimizes the floating window for [id].
  void minimizeFloating(String id) => _windowing.minimize(id);

  // ---- Drag image (tear-off preview) --------------------------------------

  /// Whether the active backend can paint a drag image on the cursor while a
  /// tab is dragged outside the main window.
  bool get supportsDragImage => _windowing.supportsDragImage;

  /// Backend hook: show [image] following the cursor while a tab is dragged
  /// outside the main window.
  void showDragImage(PanelDragImage image) => _windowing.showDragImage(image);

  /// Backend hook: hide the drag image shown by [showDragImage].
  void hideDragImage() => _windowing.hideDragImage();

  bool _dragImageActive = false;

  /// Whether the backend's drag image is currently visible on the cursor.
  ///
  /// While true, the dock hides its own Flutter drag feedback so the overlay
  /// (which polls the cursor on a timer) and the pointer-synced feedback never
  /// render the pill twice — the overlay covers the poke-out/outside cases
  /// where the feedback would be clipped or invisible anyway.
  bool get dragImageActive => _dragImageActive;

  /// Backend hook: report whether the drag image is currently visible.
  void setDragImageActive(bool active) {
    if (_dragImageActive == active) return;
    _dragImageActive = active;
    notifyListeners();
  }

  // ---- External (backend-driven) drag-back snapping ------------------------
  //
  // A windowing backend that can track a detached window being dragged reports
  // the live pointer here so the main window paints a snap-back target, then
  // commits the drop. All geometry is backend-agnostic.

  bool _externalDragging = false;
  DockSide? _externalHoverSide;

  /// The group within [externalHoverSide] the dragged window currently
  /// targets, or -1 for "new group / whole side". Resolved by
  /// [_zoneForPanelOverMain] from the dragged window's rect.
  int _externalHoverGroup = -1;

  /// The insertion index within [externalHoverSide] where an edge drop makes a
  /// new group (a split), or -1 when the drop is a tab merge / append-at-end.
  /// Resolved by [_zoneForPanelOverMain].
  int _externalHoverSplit = -1;

  /// Whether a detached window is currently being dragged over the workspace.
  bool get isExternalDragging => _externalDragging;

  /// The dock the dragged window currently hovers over, if any.
  DockSide? get externalHoverSide => _externalHoverSide;

  /// The group index within [externalHoverSide] the dragged window targets
  /// (for a tab merge), or -1 when it would land as a new group / the whole
  /// side. Mirrors the in-dock drop zones: center of a group = tab, its
  /// leading/trailing edge = split beside it.
  int get externalHoverGroup => _externalHoverGroup;

  /// The insertion index within [externalHoverSide] where an edge drop splits
  /// a new group (before the group at that index), or -1 for a tab merge /
  /// append-at-end. Lets the preview paint the split at the *aimed* position
  /// instead of always at the region's trailing end.
  int get externalHoverSplit => _externalHoverSplit;

  /// Backend hook: report the live [pointer] and the dragged window's
  /// [windowRect] relative to the main window rect [main] while a detached
  /// window is dragged.
  ///
  /// All geometry is in the main view's **logical** pixels — the units this
  /// manager's config and layout are written in (`leftDockSize`,
  /// `sizeOf(side)`, …). A backend reading physical pixels from the OS must
  /// divide by the view's device pixel ratio first, or the zones below are
  /// wrong on any scaled display.
  ///
  /// [windowRect] is the dragged window's own frame. Hit-testing it — not just
  /// the cursor — is what lets a large window (e.g. Preview) dock when its body
  /// covers a zone even though the title bar the user grabbed sits outside the
  /// main window's frame.
  void updateExternalDragHover(Offset pointer, Rect main, {Rect? windowRect}) {
    _externalDragging = true;
    final ({DockSide side, int group, int split})? zone =
        _zoneForPanelOverMain(pointer, main, windowRect);
    final DockSide? side = zone?.side;
    final int group = zone?.group ?? -1;
    final int split = zone?.split ?? -1;
    if (side == _externalHoverSide &&
        group == _externalHoverGroup &&
        split == _externalHoverSplit) {
      return; // avoid rebuild storms at 60fps
    }
    _externalHoverSide = side;
    _externalHoverGroup = group;
    _externalHoverSplit = split;
    // Over a zone the pane goes translucent, so the landing rect stays readable
    // *through* the pane being dragged (Resolve previews the exact extent the
    // clip will occupy; a tear-off must not hide the preview it is aiming at).
    final String? torn = _tearOffId;
    if (torn != null) _windowing.setTearOffDim(torn, side != null);
    notifyListeners();
  }

  /// Ends the in-flight tear-off: clears the hover preview and puts the
  /// window's opacity back (it is either about to be destroyed or to stay
  /// floating, and a floating pane is never dimmed).
  ///
  /// If the pane was still docked waiting for the window's first frame (the
  /// window-first path), it is detached now — the gesture is over, so there is
  /// no more first frame to wait for.
  void _endTearOff() {
    final String? id = _tearOffId;
    _tearOffId = null;
    _externalDragging = false;
    _externalHoverSide = null;
    _externalHoverGroup = -1;
    _externalHoverSplit = -1;
    if (id != null) {
      _windowing.setTearOffDim(id, false);
      if (_tearOffPendingDetach) _detachTornOffPane(id);
    }
    _updateEscHandler();
  }

  /// Backend hook: the drag ended. If [commitId] is over a dock zone, it
  /// re-docks there; otherwise the drag indicator is just cleared and the
  /// panel stays floating where it was released.
  ///
  /// [pointer]/[windowRect] are the release point in the main view's logical
  /// coordinates, exactly as reported to [updateExternalDragHover]. When given,
  /// the zone is resolved at the release point — the last hover report can be
  /// stale (the backend polls at ~8 ms, so a fast release lands before the next
  /// tick clears a zone the cursor already left). When omitted, the last hover
  /// report is used, for callers that only know the gesture ended.
  void endExternalDrag({String? commitId, Offset? pointer, Rect? main, Rect? windowRect}) {
    DockSide? side = _externalHoverSide;
    int group = _externalHoverGroup;
    int split = _externalHoverSplit;
    if (pointer != null && main != null) {
      final ({DockSide side, int group, int split})? zone =
          _zoneForPanelOverMain(pointer, main, windowRect);
      side = zone?.side;
      group = zone?.group ?? -1;
      split = zone?.split ?? -1;
    }
    _externalDragging = false;
    _externalHoverSide = null;
    _externalHoverGroup = -1;
    _externalHoverSplit = -1;
    if (commitId != null && side != null && _floatingOrigin.containsKey(commitId)) {
      // Clears the tear-off state itself.
      redock(commitId, toSide: side, toGroup: group, toSplit: split);
      return;
    }
    if (commitId != null && commitId == _tearOffId) _endTearOff();
    notifyListeners();
  }

  /// Maps the live pointer (and the dragged window's rect) onto a dock zone of
  /// the main window, using the actual dock extents so the highlighted preview
  /// matches where the panel will land. Returns null when neither the pointer
  /// nor the dragged window is over the main window.
  ///
  /// The returned `group` is the index of an existing group to merge into as a
  /// tab when the drop lands on a group's center (Resolve: dropping a panel on
  /// a docked group's middle adds it as a tab; its edges split beside it). The
  /// returned `split` is the insertion index for an edge drop — a new group
  /// inserted *before* the group at that index — so a drop near the top of a
  /// left/right dock splits at the top, not at the region's trailing end. Both
  /// -1 means "the whole side / append a new group at the end".
  ({DockSide side, int group, int split})? _zoneForPanelOverMain(
    Offset pointer,
    Rect main,
    Rect? windowRect,
  ) {
    // The drop point is the cursor — that's the user's aim, same as upstream.
    // A large window is grabbed by its title bar, so the cursor can sit outside
    // `main` while the window body covers a dock zone; only then fall back to
    // the window's center (a window that merely overlaps `main` doesn't aim).
    final bool pointerInMain = main.contains(pointer);
    final Offset probe = pointerInMain
        ? pointer
        : (windowRect != null ? windowRect.center : pointer);
    if (!main.contains(probe)) return null;

    // The extent a region actually occupies on screen. An expanded dock is
    // `sizeOf`; a collapsed one is only the thin `collapsedExtent` strip (not
    // the fallback — otherwise the strip's dead band would swallow a chunk of
    // the neighboring region, e.g. the lower part of center resolving to a
    // collapsed bottom dock). An empty region keeps the fallback so it stays a
    // valid drop target.
    double extent(DockSide side, double fallback, double maxFrac, double full) {
      final double v;
      if (!hasPanels(side)) {
        v = fallback;
      } else if (isCollapsed(side)) {
        v = config.collapsedExtent;
      } else {
        v = sizeOf(side);
      }
      return v.clamp(0.0, full * maxFrac);
    }

    // Region extents — the same fallbacks `_NativeDropZoneOverlay` paints, so
    // the highlighted target is exactly the rect the panel will occupy.
    final double leftW = extent(DockSide.left, main.width * 0.18, 0.45, main.width);
    final double rightW = extent(DockSide.right, main.width * 0.20, 0.45, main.width);
    final double bottomH = extent(DockSide.bottom, main.height * 0.22, 0.55, main.height);
    final double rowH = main.height - bottomH;
    final double x = probe.dx - main.left;
    final double y = probe.dy - main.top;

    final DockSide side;
    if (y > rowH) {
      side = DockSide.bottom;
    } else if (x < leftW) {
      side = DockSide.left;
    } else if (x > main.width - rightW) {
      side = DockSide.right;
    } else {
      side = DockSide.center;
    }
    final ({int group, int split}) hit =
        _groupAtProbe(side, probe, main, leftW, rightW, bottomH);
    return (side: side, group: hit.group, split: hit.split);
  }

  /// Resolves where in [side]'s groups the probe lands. `group` is the index
  /// of an existing group to merge into as a tab (its center); `split` is the
  /// insertion index for an edge drop — a new group inserted *before* the group
  /// at that index — matching the in-dock before/after split. Both -1 means
  /// "append a new group at the end" (empty space past the last group).
  ///
  /// Groups are laid out along the region axis (left/right stack vertically,
  /// bottom/center side-by-side) weighted by [groupWeight]. Each region only
  /// occupies its own slice of `main` — left/right span [0, rowH), bottom spans
  /// [rowH, height), center spans [leftW, width-rightW) — so the probe is mapped
  /// inside that region rect, the same rect the drop overlay highlights.
  ({int group, int split}) _groupAtProbe(
    DockSide side,
    Offset probe,
    Rect main,
    double leftW,
    double rightW,
    double bottomH,
  ) {
    final _Region r = _regions[side]!;
    if (r.groups.isEmpty || r.collapsed) return (group: -1, split: -1);
    final bool horizontal =
        side == DockSide.bottom || side == DockSide.center;

    // The region's own rect in main-window coordinates (matches the overlay).
    final Rect region = switch (side) {
      DockSide.left => Rect.fromLTWH(main.left, main.top, leftW, main.height - bottomH),
      DockSide.right => Rect.fromLTWH(main.right - rightW, main.top, rightW, main.height - bottomH),
      DockSide.bottom => Rect.fromLTWH(main.left, main.bottom - bottomH, main.width, bottomH),
      DockSide.center => Rect.fromLTWH(
          main.left + leftW,
          main.top,
          (main.width - leftW - rightW).clamp(0.0, main.width),
          main.height - bottomH,
        ),
    };
    if (!region.contains(probe)) return (group: -1, split: -1);

    final double full = horizontal ? region.width : region.height;
    final double pos = horizontal ? probe.dx - region.left : probe.dy - region.top;
    if (full <= 0 || pos < 0 || pos > full) return (group: -1, split: -1);

    final double total =
        r.groups.fold(0.0, (double a, _Group g) => a + g.weight);
    if (total <= 0) return (group: r.groups.length - 1, split: -1);
    double acc = 0;
    for (int i = 0; i < r.groups.length; i++) {
      final double w = r.groups[i].weight / total * full;
      final double start = acc;
      final double end = acc + w;
      acc = end;
      if (pos >= start && pos < end) {
        // Inside this group: center = tab merge; leading edge = split before
        // it (insert at i); trailing edge = split after it (insert at i+1).
        // Reuse the in-dock edge fraction so the external drop matches the
        // in-dock `_GroupDropZones` before/tab/after affordance.
        final double edge = config.dropEdgeFraction * w;
        if (!config.allowSplit) return (group: i, split: -1);
        if (pos < start + edge) return (group: -1, split: i);
        if (pos > end - edge) return (group: -1, split: i + 1);
        return (group: i, split: -1);
      }
    }
    // Past the last group's end (a trailing gap): append at the end.
    return (group: -1, split: -1);
  }

  // ---- Persistence ---------------------------------------------------------

  Timer? _saveTimer;
  bool _restoring = false;

  @override
  void notifyListeners() {
    super.notifyListeners();
    if (config.storage == null || _restoring) return;
    // Debounce: coalesce rapid changes (drags, resizes) into one write.
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), () {
      config.storage?.write(saveLayout());
    });
  }

  /// Synchronously persists the current layout if a [config.storage] is set.
  void saveNow() {
    if (config.storage != null) {
      config.storage?.write(saveLayout());
    }
  }

  /// Serializes the current docked layout to a JSON-encodable map. Floating
  /// windows are not persisted (they re-dock on restore).
  Map<String, Object?> saveLayout() {
    return <String, Object?>{
      'version': 1,
      'regions': <String, Object?>{
        for (final DockSide side in DockSide.values)
          side.name: <String, Object?>{
            'size': _regions[side]!.size,
            'collapsed': _regions[side]!.collapsed,
            'activeGroup': _regions[side]!.activeGroup,
            'groups': <Object?>[
              for (final _Group g in _regions[side]!.groups)
                <String, Object?>{'active': g.activeId, 'panels': List<String>.from(g.panelIds)},
            ],
          },
      },
    };
  }

  /// Restores a layout produced by [saveLayout]. Only currently-registered
  /// panels are placed; unknown ids are ignored and any registered panel not in
  /// [data] is appended to the center so nothing is lost.
  void loadLayout(Map<String, Object?> data) {
    final Object? regionsData = data['regions'];
    if (regionsData is! Map) return;
    final Set<String> known = _descriptors.keys.toSet();
    final Set<String> placed = <String>{};

    for (final DockSide side in DockSide.values) {
      final _Region r = _regions[side]!;
      final Object? rd = regionsData[side.name];
      r.groups.clear();
      if (rd is Map) {
        r.size = (rd['size'] as num?)?.toDouble() ?? config.initialSize(side);
        r.collapsed = rd['collapsed'] as bool? ?? false;
        final Object? groups = rd['groups'];
        if (groups is List) {
          for (final Object? gd in groups) {
            if (gd is! Map) continue;
            final List<String> ids = <String>[
              for (final Object? id in (gd['panels'] as List? ?? const <Object?>[]))
                if (id is String && known.contains(id) && !placed.contains(id) && !isFloating(id)) id,
            ];
            if (ids.isEmpty) continue;
            placed.addAll(ids);
            String? active = gd['active'] as String?;
            if (active == null || !ids.contains(active)) active = ids.first;
            r.groups.add(_Group()
              ..panelIds.addAll(ids)
              ..activeId = active);
          }
        }
        r.activeGroup = ((rd['activeGroup'] as num?)?.toInt() ?? 0).clamp(0, r.groups.isEmpty ? 0 : r.groups.length - 1);
      } else {
        r.size = config.initialSize(side);
        r.collapsed = false;
        r.activeGroup = 0;
      }
    }

    // Don't lose registered, non-floating panels that weren't in the layout.
    final List<String> orphans = <String>[
      for (final String id in known)
        if (!placed.contains(id) && !isFloating(id)) id,
    ];
    if (orphans.isNotEmpty) {
      final _Region c = _regions[DockSide.center]!;
      if (c.groups.isEmpty) c.groups.add(_Group());
      c.groups.last.panelIds.addAll(orphans);
      c.groups.last.activeId ??= orphans.first;
    }
    notifyListeners();
  }

  /// Reads and applies a layout from `config.storage`, if any. Call after
  /// registering all panels (e.g. on startup).
  Future<void> restore() async {
    final PanelStorage? s = config.storage;
    if (s == null) return;
    _saveTimer?.cancel();
    _saveTimer = null;
    _restoring = true;
    try {
      final Map<String, Object?>? data = await s.read();
      if (data != null) loadLayout(data);
    } finally {
      _restoring = false;
    }
  }

  // ---- Internals -----------------------------------------------------------

  ({DockSide side, int gi})? _locOf(String id) {
    for (final MapEntry<DockSide, _Region> e in _regions.entries) {
      for (int i = 0; i < e.value.groups.length; i++) {
        if (e.value.groups[i].panelIds.contains(id)) return (side: e.key, gi: i);
      }
    }
    return null;
  }

  /// Removes [id] from its dock group (if any), pruning the group when it
  /// becomes empty. No-op for floating panels.
  void _removeFromDock(String id) {
    final ({DockSide side, int gi})? loc = _locOf(id);
    if (loc == null) return;
    final _Region r = _regions[loc.side]!;
    final _Group g = r.groups[loc.gi];
    g.panelIds.remove(id);
    if (g.activeId == id) {
      g.activeId = g.panelIds.isEmpty ? null : g.panelIds.last;
    }
    if (g.panelIds.isEmpty) {
      r.groups.removeAt(loc.gi);
      if (r.activeGroup >= r.groups.length) {
        r.activeGroup = r.groups.isEmpty ? 0 : r.groups.length - 1;
      }
    }
  }

  @override
  void dispose() {
    if (_escHandlerRegistered) {
      HardwareKeyboard.instance.removeHandler(_onHardwareKey);
      _escHandlerRegistered = false;
    }
    _tearOffId = null;
    _tearOffPendingDetach = false;
    _tearOffDetachTimer?.cancel();
    _tearOffDetachTimer = null;
    _saveTimer?.cancel();
    if (config.storage != null) {
      config.storage?.write(saveLayout());
    }
    for (final String id in _floatingOrigin.keys.toList()) {
      _windowing.close(id);
    }
    _floatingOrigin.clear();
    super.dispose();
  }
}

/// Exposes the [PanelManager] to the widget tree, including the detached
/// window subtrees (rendered as sibling views by the framework's
/// `WindowManager`, so they still inherit ancestors placed above `MaterialApp`).
class PanelScope extends InheritedNotifier<PanelManager> {
  const PanelScope({super.key, required PanelManager manager, required super.child})
      : super(notifier: manager);

  static PanelManager of(BuildContext context) {
    final PanelScope? scope = context.dependOnInheritedWidgetOfExactType<PanelScope>();
    assert(scope != null, 'No PanelScope found in context');
    return scope!.notifier!;
  }
}
