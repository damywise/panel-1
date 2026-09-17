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

  /// Mints (and remembers) the [GlobalKey] wrapping each panel's content, so
  /// the same element moves between the docked group and the torn-off window.
  /// See [PanelDescriptor.contentKey] and [contentOf].
  final Map<String, GlobalKey> _contentKeys = <String, GlobalKey>{};

  // ---- Tear-off state ------------------------------------------------------

  /// The panel currently being torn off (dragged as its own window), if any.
  ///
  /// Distinct from [_isDragging]: the Flutter tab drag is *cancelled* the
  /// moment the pane becomes a window (the backend owns the gesture from then
  /// on), but the dock still suppresses the legacy detach path and the pill
  /// until the tear-off finishes.
  String? _tearOffId;

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
  /// logical coordinates, measured live from [contentKeyOf].
  ///
  /// This is what a tear-off hands the backend: the pane keeps its own rect, so
  /// the window needs no reflow — only a header of [headerHeight] where the tab
  /// strip was.
  ///
  /// The content is the *last* child of the group and fills its width, so the
  /// group is the content's rect grown upwards by [headerHeight] (the strip plus
  /// its divider). That one measurement covers the strip's height, the divider
  /// and any dock padding without a second key on the group.
  ///
  /// Null when the panel is not currently hosted (or not laid out yet), in which
  /// case a tear-off is skipped rather than guessed at.
  Rect? paneRect(String id, {required double headerHeight}) {
    // A group renders only its ACTIVE panel's content, so a tab that is not the
    // active one has no render box of its own. Every tab of a group shares the
    // group's single body slot, so measuring the active sibling gives exactly the
    // rect the dragged tab would occupy — which is what a tear-off needs.
    final String measured = _mountedSiblingOf(id) ?? id;
    final BuildContext? context = contentKeyOf(measured).currentContext;
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

  /// The panel of [id]'s group whose content is actually mounted, when [id]'s
  /// own content is not (i.e. [id] is not its group's active tab).
  String? _mountedSiblingOf(String id) {
    if (contentKeyOf(id).currentContext != null) return null;
    final ({DockSide side, int gi})? loc = _locOf(id);
    if (loc == null) return null;
    final String? active = activeInGroup(loc.side, loc.gi);
    return (active == null || active == id) ? null : active;
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
    _removeFromDock(id);
    _floatingOrigin[id] = origin;
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
    _windowing.openTearOff(
      _descriptors[id]!,
      origin: origin,
      paneRect: paneRect,
      headerHeight: headerHeight,
      pointerInPane: pointerInPane,
    );
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

  /// The [GlobalKey] wrapping [id]'s content subtree — see
  /// [PanelDescriptor.contentKey]. Stable for the manager's lifetime.
  GlobalKey contentKeyOf(String id) {
    final GlobalKey? declared = _descriptors[id]?.contentKey;
    if (declared != null) return declared;
    return _contentKeys[id] ??=
        GlobalKey(debugLabel: 'panel-content-$id');
  }

  /// Builds [id]'s content, wrapped in its stable [GlobalKey].
  ///
  /// **Both** hosts must render panels through this — the docked group and the
  /// detached window — so the element moves instead of being rebuilt when a
  /// panel is torn off or re-docked. That is what preserves the content's
  /// [State]: scroll offsets, controllers, text fields, running animations.
  Widget contentOf(String id, BuildContext context) {
    return KeyedSubtree(
      key: contentKeyOf(id),
      child: _descriptors[id]!.builder(context),
    );
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

  /// Snaps a floating panel back into the dock as a new group on [toSide]
  /// (defaults to its origin), so it lands beside whatever is already there.
  ///
  /// Also ends a tear-off on [id]: the window is destroyed, the backend's
  /// cursor tracker notices and stops, and the content is reparented back into
  /// the dock by its [GlobalKey].
  void redock(String id, {DockSide? toSide}) {
    if (_tearOffId == id) _endTearOff();
    final DockSide? origin = _floatingOrigin.remove(id);
    if (origin == null) return;
    final DockSide target = toSide ?? origin;
    final _Region r = _regions[target]!;
    if (config.redockAsTab && r.groups.isNotEmpty) {
      final _Group g = r.groups.last;
      g.panelIds.add(id);
      g.activeId = id;
    } else {
      r.groups.add(_Group()
        ..panelIds.add(id)
        ..activeId = id);
    }
    r.activeGroup = r.groups.length - 1;
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

  /// Whether a detached window is currently being dragged over the workspace.
  bool get isExternalDragging => _externalDragging;

  /// The dock the dragged window currently hovers over, if any.
  DockSide? get externalHoverSide => _externalHoverSide;

  /// Backend hook: report the live [pointer] relative to the main window rect
  /// [main] while a detached window is dragged.
  ///
  /// Both are in the main view's **logical** pixels — the units this manager's
  /// config and layout are written in (`leftDockSize`, `sizeOf(side)`, …). A
  /// backend reading physical pixels from the OS must divide by the view's device
  /// pixel ratio first, or the zones below are wrong on any scaled display.
  void updateExternalDragHover(Offset pointer, Rect main) {
    _externalDragging = true;
    final DockSide? side = _zoneForPanelOverMain(pointer, main);
    if (side == _externalHoverSide) return; // avoid rebuild storms at 60fps
    _externalHoverSide = side;
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
  void _endTearOff() {
    final String? id = _tearOffId;
    _tearOffId = null;
    _externalDragging = false;
    _externalHoverSide = null;
    if (id != null) _windowing.setTearOffDim(id, false);
    _updateEscHandler();
  }

  /// Backend hook: the drag ended. If [commitId] is over a dock zone, it
  /// re-docks there; otherwise the drag indicator is just cleared and the
  /// panel stays floating where it was released.
  void endExternalDrag({String? commitId}) {
    final DockSide? side = _externalHoverSide;
    _externalDragging = false;
    _externalHoverSide = null;
    if (commitId != null && side != null && _floatingOrigin.containsKey(commitId)) {
      // Clears the tear-off state itself.
      redock(commitId, toSide: side);
      return;
    }
    if (commitId != null && commitId == _tearOffId) _endTearOff();
    notifyListeners();
  }

  /// Maps the live pointer onto a dock zone of the main window, using the
  /// actual dock extents so the highlighted preview matches where the panel
  /// will land. Returns null when the pointer isn't over the main window (so no
  /// drop indicator shows until the dragged window is actually over us).
  DockSide? _zoneForPanelOverMain(Offset pointer, Rect main) {
    if (!main.contains(pointer)) return null;

    double extent(DockSide side, double fallback, double maxFrac, double full) {
      final double v = (hasPanels(side) && !isCollapsed(side)) ? sizeOf(side) : fallback;
      return v.clamp(0.0, full * maxFrac);
    }

    final double leftW = extent(DockSide.left, main.width * 0.18, 0.45, main.width);
    final double rightW = extent(DockSide.right, main.width * 0.20, 0.45, main.width);
    final double bottomH = extent(DockSide.bottom, main.height * 0.22, 0.55, main.height);
    final double x = pointer.dx - main.left;
    final double y = pointer.dy - main.top;

    if (y > main.height - bottomH) return DockSide.bottom;
    if (x < leftW) return DockSide.left;
    if (x > main.width - rightW) return DockSide.right;
    return DockSide.center;
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
