// The docked workspace UI.
//
// Each dock region holds an ordered list of *groups* laid out along the
// region's axis (bottom/center = side-by-side columns, left/right = stacked
// rows), with splitters between groups. Tabs are draggable:
//   * drop on a group's CENTER  -> add as a tab to that group
//   * drop on a group's leading/trailing EDGE -> new group beside it (split)
//   * drop on an empty region's edge -> create the first group there
//   * drop outside the window -> tear off into a floating OS window
//
// All colors come from `PanelTheme` (see PanelDockConfig.themeOf), not Material's
// ColorScheme, so the dock has no Material surface tint and can be themed
// arbitrarily. Tabs can be rendered by `PanelDockConfig.tabBuilder`.
//
// Platform-generic: no windowing/native imports. Detaching is delegated to the
// manager's backend via `manager.detach(id)`.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kPrimaryButton, kSecondaryMouseButton;
import 'package:flutter/material.dart' show Colors, Icons, Tooltip, IconButton, VisualDensity;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:hit/hit.dart';

import 'panel.dart';
import 'panel_config.dart';
import 'panel_manager.dart';
import 'panel_windowing.dart';

/// Drag payload for a tab being dragged.
class _TabDrag {
  const _TabDrag(this.panelId);
  final String panelId;
}

/// The root workspace widget. Render it in the body of your main window's
/// container. All sizing/labels/capabilities/colors come from the
/// [PanelManager]'s `PanelDockConfig` (provided via [PanelScope]).
class PanelDock extends StatelessWidget {
  const PanelDock({super.key});

  @override
  Widget build(BuildContext context) {
    final PanelManager manager = PanelScope.of(context);
    void detach(String id) => manager.detach(id);

    // Right-click cancels the in-flight tab drag (returns the panel to its
    // original dock) — see PanelManager.cancelDrag. The listener lives at the
    // dock root so it catches the click wherever the drag is over the dock.
    return Listener(
      onPointerDown: (PointerDownEvent event) {
        if (event.buttons & kSecondaryMouseButton != 0) {
          manager.cancelDrag();
        }
      },
      onPointerMove: (PointerMoveEvent event) {
        // Flutter's Windows mouse model keeps ONE pointer for the cursor, so a
        // right-click during an active drag shows up as a move with updated
        // buttons (0x3 = left|right), not a new pointer-down.
        if (event.buttons & kSecondaryMouseButton != 0) {
          manager.cancelDrag();
        }
      },
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: _DockArea(manager: manager, onDetach: detach)),
          if (manager.isDragging)
            Positioned.fill(child: _EmptyRegionTargets(manager: manager)),
          if (manager.externalHoverSide != null)
            Positioned.fill(
              child: _NativeDropZoneOverlay(
                manager: manager,
                activeSide: manager.externalHoverSide!,
              ),
            ),
        ],
      ),
    );
  }
}

class _DockArea extends StatelessWidget {
  const _DockArea({required this.manager, required this.onDetach});

  final PanelManager manager;
  final ValueChanged<String> onDetach;

  @override
  Widget build(BuildContext context) {
    final PanelDockConfig cfg = manager.config;
    final PanelTheme t = cfg.themeOf(context);
    return ColoredBox(
      color: t.background,
      child: Padding(
        padding: t.panelPadding,
        child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
            double leftW = manager.sizeOf(DockSide.left);
            double rightW = manager.sizeOf(DockSide.right);
            final bool hasLeft = manager.hasPanels(DockSide.left) && !manager.isCollapsed(DockSide.left);
            final bool hasRight = manager.hasPanels(DockSide.right) && !manager.isCollapsed(DockSide.right);
            final double sidesAvail = (c.maxWidth - cfg.minCenterWidth).clamp(0.0, c.maxWidth);
            final double usedLeft = hasLeft ? leftW : 0;
            final double usedRight = hasRight ? rightW : 0;
            if (usedLeft + usedRight > sidesAvail && usedLeft + usedRight > 0) {
              final double scale = sidesAvail / (usedLeft + usedRight);
              leftW *= scale;
              rightW *= scale;
            }
            final double bottomMax = (c.maxHeight - cfg.minCenterHeight).clamp(cfg.minDockExtent, c.maxHeight);
            final double bottomH = manager.sizeOf(DockSide.bottom).clamp(cfg.minDockExtent, bottomMax);

            final List<Widget> row = <Widget>[];
            if (manager.hasPanels(DockSide.left)) {
              row.add(_sideDock(DockSide.left, leftW));
              if (!manager.isCollapsed(DockSide.left)) {
                row.add(_splitter(t, Axis.vertical, (double d) => manager.setSize(DockSide.left, manager.sizeOf(DockSide.left) + d)));
              }
            }
            row.add(Expanded(child: _CenterArea(manager: manager, onDetach: onDetach)));
            if (manager.hasPanels(DockSide.right)) {
              if (!manager.isCollapsed(DockSide.right)) {
                row.add(_splitter(t, Axis.vertical, (double d) => manager.setSize(DockSide.right, manager.sizeOf(DockSide.right) - d)));
              }
              row.add(_sideDock(DockSide.right, rightW));
            }

            Widget content = Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: row);
            if (manager.hasPanels(DockSide.bottom)) {
              content = Column(
                children: <Widget>[
                  Expanded(child: content),
                  if (!manager.isCollapsed(DockSide.bottom))
                    _splitter(t, Axis.horizontal, (double d) => manager.setSize(DockSide.bottom, manager.sizeOf(DockSide.bottom) - d)),
                  _bottomDock(bottomH),
                ],
              );
            }
            // One scope over the whole workspace delivers overflow hits for
            // splitter handles that are wider than their visible gap (see
            // [_SplitterState.build] / `splitterGap`).
            return HitScope(child: content);
            },
          ),
      ),
    );
  }

  Widget _splitter(PanelTheme t, Axis axis, ValueChanged<double> onDrag) => _Splitter(
        axis: axis,
        theme: t,
        enabled: manager.config.allowResize,
        hitSize: manager.config.splitterHitSize,
        visualGap: manager.config.splitterGap,
        duration: manager.config.splitterDuration,
        onDrag: onDrag,
      );

  Widget _sideDock(DockSide side, double width) {
    if (manager.isCollapsed(side)) {
      return _CollapsedDock(manager: manager, side: side, axis: Axis.vertical, extent: manager.config.collapsedExtent);
    }
    return SizedBox(width: width, child: _RegionView(manager: manager, side: side, axis: Axis.vertical, onDetach: onDetach));
  }

  Widget _bottomDock(double height) {
    if (manager.isCollapsed(DockSide.bottom)) {
      return _CollapsedDock(manager: manager, side: DockSide.bottom, axis: Axis.horizontal, extent: manager.config.collapsedExtent);
    }
    return SizedBox(
      height: height,
      child: _RegionView(manager: manager, side: DockSide.bottom, axis: Axis.horizontal, onDetach: onDetach),
    );
  }
}

class _CenterArea extends StatelessWidget {
  const _CenterArea({required this.manager, required this.onDetach});

  final PanelManager manager;
  final ValueChanged<String> onDetach;

  @override
  Widget build(BuildContext context) {
    final PanelTheme t = manager.config.themeOf(context);
    if (!manager.hasPanels(DockSide.center)) {
      return DragTarget<_TabDrag>(
        onAcceptWithDetails: (DragTargetDetails<_TabDrag> d) {
          manager.addPanelAsTab(d.data.panelId, DockSide.center, 0);
          manager.endDrag();
        },
        builder: (BuildContext context, List<_TabDrag?> cand, _) {
          final bool active = cand.isNotEmpty;
          return Container(
            color: active ? Color.alphaBlend(t.accent.withValues(alpha: 0.12), t.surface) : t.surface,
            alignment: Alignment.center,
            child: Text(
              manager.isDragging ? manager.config.strings.dropHere : manager.config.strings.emptyCenter,
              style: TextStyle(color: t.mutedText, fontSize: 13),
            ),
          );
        },
      );
    }
    return _RegionView(manager: manager, side: DockSide.center, axis: Axis.horizontal, onDetach: onDetach);
  }
}

/// Lays out a region's groups along [axis] with weighted splitters between them.
class _RegionView extends StatelessWidget {
  const _RegionView({required this.manager, required this.side, required this.axis, required this.onDetach});

  final PanelManager manager;
  final DockSide side;
  final Axis axis;
  final ValueChanged<String> onDetach;

  @override
  Widget build(BuildContext context) {
    final int n = manager.groupCount(side);
    final bool horizontal = axis == Axis.horizontal;
    final PanelTheme t = manager.config.themeOf(context);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double total = horizontal ? c.maxWidth : c.maxHeight;
        final List<Widget> children = <Widget>[];
        for (int gi = 0; gi < n; gi++) {
          if (gi > 0) {
            final int leftIndex = gi - 1;
            children.add(_Splitter(
              axis: horizontal ? Axis.vertical : Axis.horizontal,
              theme: t,
              enabled: manager.config.allowResize,
              hitSize: manager.config.splitterHitSize,
              visualGap: manager.config.splitterGap,
              duration: manager.config.splitterDuration,
              onDrag: (double d) => manager.adjustGroupWeights(side, leftIndex, d, total),
            ));
          }
          final int flex = (manager.groupWeight(side, gi) * 1000).round().clamp(1, 1 << 22);
          children.add(Expanded(
            flex: flex,
            child: PanelGroup(manager: manager, side: side, groupIndex: gi, axis: axis, onDetach: onDetach),
          ));
        }
        return horizontal
            ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
      },
    );
  }
}

/// A single tab group (one leaf of a region).
class PanelGroup extends StatelessWidget {
  const PanelGroup({
    super.key,
    required this.manager,
    required this.side,
    required this.groupIndex,
    required this.axis,
    required this.onDetach,
  });

  final PanelManager manager;
  final DockSide side;
  final int groupIndex;
  final Axis axis;
  final ValueChanged<String> onDetach;

  @override
  Widget build(BuildContext context) {
    final PanelTheme t = manager.config.themeOf(context);
    final List<PanelDescriptor> panels = manager.panelsInGroup(side, groupIndex);
    final String? activeId = manager.activeInGroup(side, groupIndex);
    PanelDescriptor? active;
    for (final PanelDescriptor p in panels) {
      if (p.id == activeId) {
        active = p;
        break;
      }
    }
    active ??= panels.isEmpty ? null : panels.first;

    final Widget group = DecoratedBox(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(t.panelRadius),
        // The resting hairline is themeable away; clicking a panel no longer
        // paints a focus ring (focus is tracked internally for split/merge keys).
        border: t.showPanelBorder ? Border.all(color: t.border, width: 1) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _TabStrip(
            manager: manager,
            side: side,
            groupIndex: groupIndex,
            panels: panels,
            activeId: active?.id,
            canSplit: panels.length >= 2,
            onDetach: onDetach,
          ),
          if (t.tabDividerThickness > 0) Container(height: t.tabDividerThickness, color: t.border),
          Expanded(
            child: active == null
                ? const SizedBox.shrink()
                : KeyedSubtree(key: ValueKey<String>('panel-body-${active.id}'), child: active.builder(context)),
          ),
        ],
      ),
    );

    // The drop-zone overlay covers only the body (below the tab strip), leaving
    // the strip free for tab drag-to-reorder targets.
    final double stripH = manager.config.tabStripHeight + t.tabDividerThickness;
    final Widget body = !manager.isDragging
        ? group
        : Stack(
            children: <Widget>[
              Positioned.fill(child: group),
              Positioned(
                top: stripH,
                left: 0,
                right: 0,
                bottom: 0,
                child: _GroupDropZones(manager: manager, side: side, groupIndex: groupIndex, axis: axis),
              ),
            ],
          );
    // Clicking anywhere in the group focuses it (target for split/merge keys).
    return Listener(
      onPointerDown: (_) => manager.setFocusedGroup(side, groupIndex),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(t.panelRadius),
        child: body,
      ),
    );
  }
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.manager,
    required this.side,
    required this.groupIndex,
    required this.panels,
    required this.activeId,
    required this.canSplit,
    required this.onDetach,
  });

  final PanelManager manager;
  final DockSide side;
  final int groupIndex;
  final List<PanelDescriptor> panels;
  final String? activeId;
  final bool canSplit;
  final ValueChanged<String> onDetach;

  @override
  Widget build(BuildContext context) {
    final PanelDockConfig cfg = manager.config;
    final PanelTheme t = cfg.themeOf(context);
    final PanelDockStrings str = cfg.strings;
    final bool showCollapse = cfg.allowCollapse && side != DockSide.center && groupIndex == 0;
    return Container(
      height: cfg.tabStripHeight,
      color: t.tabBar,
      child: Row(
        children: <Widget>[
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: <Widget>[
                for (final PanelDescriptor p in panels)
                  _Tab(manager: manager, side: side, groupIndex: groupIndex, descriptor: p, selected: p.id == activeId, onDetach: onDetach),
              ],
            ),
          ),
          if (cfg.allowSplit && canSplit)
            _StripButton(
              tooltip: str.splitTooltip,
              color: t.mutedText,
              icon: side == DockSide.bottom || side == DockSide.center ? Icons.splitscreen : Icons.horizontal_split,
              onPressed: () => manager.splitActiveGroup(side, groupIndex),
            ),
          if (cfg.allowDetach && manager.supportsDetach && activeId != null && manager.descriptor(activeId!).detachable)
            _StripButton(tooltip: str.detachTooltip, color: t.mutedText, icon: Icons.open_in_new, onPressed: () => onDetach(activeId!)),
          if (showCollapse)
            _StripButton(tooltip: str.minimizeDock(side), color: t.mutedText, icon: Icons.remove, onPressed: () => manager.toggleCollapsed(side)),
        ],
      ),
    );
  }
}

class _StripButton extends StatelessWidget {
  const _StripButton({required this.tooltip, required this.icon, required this.color, required this.onPressed});

  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        iconSize: 15,
        visualDensity: VisualDensity.compact,
        color: color,
        icon: Icon(icon),
        onPressed: onPressed,
      ),
    );
  }
}

class _Tab extends StatefulWidget {
  const _Tab({
    required this.manager,
    required this.side,
    required this.groupIndex,
    required this.descriptor,
    required this.selected,
    required this.onDetach,
  });

  final PanelManager manager;
  final DockSide side;
  final int groupIndex;
  final PanelDescriptor descriptor;
  final bool selected;
  final ValueChanged<String> onDetach;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  bool _hovered = false;

  /// The dragged tab's pill, captured once the drag feedback has laid out.
  /// The image is handed to the windowing backend so it can keep the pill
  /// visible on the cursor even after the pointer leaves the main window.
  final GlobalKey _dragFeedbackKey = GlobalKey();

  /// Room reserved around the pill when capturing so its drop shadow isn't
  /// clipped. Must match [PanelDragImage.anchorOffset] (the pill content's
  /// offset within the captured image) so the overlay lines up with the
  /// in-window feedback.
  static const double _dragShadowMargin = 16.0;

  /// Keeps the pill's top-left under the cursor (the same visual as
  /// [pointerDragAnchorStrategy]) while compensating for the shadow margin
  /// added around the captured feedback: the feedback box is pulled back by
  /// the margin, so the pill inside it lands exactly where the un-padded
  /// feedback used to.
  static Offset _dragAnchorStrategy(
    Draggable<Object> draggable,
    BuildContext context,
    Offset position,
  ) {
    return const Offset(_dragShadowMargin, _dragShadowMargin);
  }

  /// Captures the in-flight drag feedback (the pill) and forwards it to the
  /// backend for display on the cursor outside the main window. Runs one
  /// frame after the drag starts so the feedback is laid out and painted.
  /// Fail-soft: no external drag image just means the pill disappears at the
  /// window edge (the pre-existing behavior).
  Future<void> _captureDragImage() async {
    final BuildContext? boundaryContext = _dragFeedbackKey.currentContext;
    final RenderRepaintBoundary? boundary =
        boundaryContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null || boundary.debugNeedsPaint) return;
    final double dpr = View.of(boundaryContext!).devicePixelRatio;
    try {
      final ui.Image image = await boundary.toImage(pixelRatio: dpr);
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final int w = image.width;
      final int h = image.height;
      image.dispose();
      if (data == null || !widget.manager.isDragging) return;
      widget.manager.showDragImage(PanelDragImage(
        rgba: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        width: w,
        height: h,
        logicalSize: Size(w / dpr, h / dpr),
        anchorOffset: const Offset(_dragShadowMargin, _dragShadowMargin),
      ));
    } catch (_) {
      // Fail soft: tearing off still works without the external drag image.
    }
  }

  Widget _label(BuildContext context, PanelTheme t, {required bool selected, required bool hovered}) {
    final PanelTabSpec spec = PanelTabSpec(descriptor: widget.descriptor, selected: selected, hovered: hovered, theme: t);
    final Widget? custom = widget.manager.config.tabBuilder?.call(context, spec);
    return custom ?? _TabLabel(spec: spec, duration: widget.manager.config.hoverDuration);
  }

  /// One half of a tab's reorder hit area. Dropping here inserts the dragged
  /// panel before (left half) or after (right half) this tab, drawing an accent
  /// insertion line at the corresponding edge while hovered.
  Widget _reorderHalf(PanelTheme t, int idx, bool before) {
    return DragTarget<_TabDrag>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (DragTargetDetails<_TabDrag> d) {
        widget.manager.movePanelToGroupAt(d.data.panelId, widget.side, widget.groupIndex, before ? idx : idx + 1);
        widget.manager.endDrag();
      },
      builder: (BuildContext context, List<_TabDrag?> cand, _) => Container(
        alignment: before ? Alignment.centerLeft : Alignment.centerRight,
        child: Container(width: 2.5, height: double.infinity, color: cand.isNotEmpty ? t.accent : const Color(0x00000000)),
      ),
    );
  }

  /// A drop target over the dragged tab (and the no-op gaps right next to it)
  /// that simply ends the drag — so dropping a tab back on itself cancels
  /// cleanly instead of tearing it off into a floating window.
  Widget _noopHalf(PanelTheme t) {
    return DragTarget<_TabDrag>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (_) => widget.manager.endDrag(),
      builder: (BuildContext context, List<_TabDrag?> cand, _) {
        final bool active = cand.isNotEmpty;
        return Container(
          color: active ? t.accent.withValues(alpha: 0.16) : null,
          alignment: Alignment.center,
          child: active
              ? Icon(Icons.undo, size: 14, color: t.accent)
              : null,
        );
      },
    );
  }

  /// Overlays the tab with before/after reorder targets while a drag is active.
  ///
  /// Any *other* group accepts an insertion at any tab (so a tab can join even a
  /// single-tab group). The *source* group only offers the meaningful slots:
  /// the gaps immediately around the dragged tab are no-ops, so they're hidden
  /// (e.g. dragging `main.dart` shows no indicator right next to itself).
  ///
  /// The dragged tab's own slot is a silent drop-to-return target: dropping
  /// there cancels the drag and returns the panel to its original dock. It
  /// renders no affordance — the tab looks normal, with no overlay on the
  /// label.
  Widget _wrapReorder(PanelTheme t, Widget content) {
    final PanelManager m = widget.manager;
    if (!m.isDragging) return content;
    final List<PanelDescriptor> panels = m.panelsInGroup(widget.side, widget.groupIndex);
    final int idx = panels.indexWhere((PanelDescriptor p) => p.id == widget.descriptor.id);
    if (idx < 0) return content;

    final bool isSource = m.isDragSource(widget.side, widget.groupIndex);
    final int draggedIdx = isSource ? panels.indexWhere((PanelDescriptor p) => p.id == m.draggedPanelId) : -1;

    // The dragged tab's own slot: dropping here cancels (returns the panel to
    // its original position) instead of tearing it off. No visible affordance
    // — the tab renders normally.
    if (isSource && idx == draggedIdx) {
      return DragTarget<_TabDrag>(
        onWillAcceptWithDetails: (_) => true,
        onAcceptWithDetails: (_) => widget.manager.endDrag(),
        builder: (BuildContext context, List<_TabDrag?> cand, _) => content,
      );
    }

    // A gap is a no-op if it sits immediately before/after the dragged tab.
    // before-half = gap `idx`; after-half = gap `idx + 1`.
    final bool showBefore = !isSource || (idx != draggedIdx && idx != draggedIdx + 1);
    final bool showAfter = !isSource || (idx != draggedIdx && idx != draggedIdx - 1);
    if (!showBefore && !showAfter) return content;

    // StackFit.passthrough forwards the tab strip's tight height to [content],
    // so the tab keeps its full height during a drag (a loose Stack would let
    // the label shrink to its intrinsic height and look smaller).
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        content,
        Positioned.fill(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(child: showBefore ? _reorderHalf(t, idx, true) : _noopHalf(t)),
              Expanded(child: showAfter ? _reorderHalf(t, idx, false) : _noopHalf(t)),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final PanelTheme t = widget.manager.config.themeOf(context);

    return Draggable<_TabDrag>(
      data: _TabDrag(widget.descriptor.id),
      dragAnchorStrategy: _dragAnchorStrategy,
      onDragStarted: () {
        widget.manager.beginDrag(side: widget.side, group: widget.groupIndex, panelId: widget.descriptor.id);
        if (widget.manager.supportsDragImage) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            // The tab's State may already be unmounted (the dock swaps the
            // group's tree to show drop zones), so gate on the feedback
            // context — it lives in the overlay and stays alive for the drag.
            if (widget.manager.isDragging && _dragFeedbackKey.currentContext != null) {
              _captureDragImage().ignore();
            }
          });
        }
      },
      onDragEnd: (_) {
        // `endDrag` hides the drag image (covers drops that dispose the
        // Draggable before this callback would run).
        widget.manager.endDrag();
      },
      onDraggableCanceled: (_, _) {
        final bool cancelled = widget.manager.consumeDragCancel();
        // Hide before detaching so the overlay doesn't linger over the
        // freshly-opened floating window.
        widget.manager.hideDragImage();
        if (!cancelled &&
            widget.manager.config.allowDetach &&
            widget.manager.supportsDetach &&
            widget.manager.descriptor(widget.descriptor.id).detachable) {
          widget.onDetach(widget.descriptor.id);
        }
        widget.manager.endDrag();
      },
      feedback: ListenableBuilder(
        listenable: widget.manager,
        // While the backend's overlay is visible (pill poking out of the
        // window or the cursor outside), it draws the pill itself — hide the
        // Flutter feedback so the two never render simultaneously. The pill
        // subtree is built once here (pre-drag) to avoid rebuilding it with a
        // deactivated context mid-drag.
        builder: (BuildContext context, Widget? child) =>
            widget.manager.dragImageActive ? const SizedBox.shrink() : child!,
        child: RepaintBoundary(
          key: _dragFeedbackKey,
          child: Padding(
            // Room for the pill's shadow so the capture isn't clipped.
            padding: const EdgeInsets.all(_dragShadowMargin),
            child: _DragFeedback(theme: t, child: _label(context, t, selected: true, hovered: false)),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: _label(context, t, selected: widget.selected, hovered: false)),
      child: _wrapReorder(
        t,
        MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          cursor: SystemMouseCursors.click,
          child: Listener(
            // Record the pointer that pressed the tab so ESC / right-click
            // can cancel the drag that (possibly) starts from it.
            onPointerDown: (PointerDownEvent event) {
              if (event.buttons & kPrimaryButton != 0) {
                widget.manager.noteDragPointer(event.pointer);
              }
            },
            child: GestureDetector(
              onTap: () => widget.manager.setActiveInGroup(widget.side, widget.groupIndex, widget.descriptor.id),
              child: _label(context, t, selected: widget.selected, hovered: _hovered),
            ),
          ),
        ),
      ),
    );
  }
}

class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.theme, required this.child});
  final PanelTheme theme;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.tabActive,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.border),
        boxShadow: <BoxShadow>[BoxShadow(color: const Color(0x33000000), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), child: child),
    );
  }
}

/// Default tab label (icon + title), themed via [PanelTheme]. Replace wholesale
/// with `PanelDockConfig.tabBuilder` for arbitrary tab rendering.
class _TabLabel extends StatelessWidget {
  const _TabLabel({required this.spec, required this.duration});

  final PanelTabSpec spec;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final PanelTheme t = spec.theme;
    final Color bg = spec.selected ? t.tabActive : (spec.hovered ? t.tabHover : const Color(0x00000000));
    final TextStyle base = t.tabTextStyle ?? const TextStyle(fontSize: 13);
    // Rounded/pill tabs indicate selection by fill (a uniform radius can't be
    // combined with a single-side underline); square tabs use the underline.
    final bool rounded = t.tabRadius != BorderRadius.zero;
    return AnimatedContainer(
      duration: duration,
      curve: Curves.easeOut,
      margin: rounded ? const EdgeInsets.symmetric(vertical: 4, horizontal: 2) : EdgeInsets.zero,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: rounded ? t.tabRadius : null,
        border: (!rounded && t.tabUnderlineThickness > 0)
            ? Border(bottom: BorderSide(color: spec.selected ? t.accent : const Color(0x00000000), width: t.tabUnderlineThickness))
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (spec.descriptor.icon != null) ...<Widget>[
            Icon(spec.descriptor.icon, size: 15, color: spec.selected ? t.accent : t.mutedText),
            const SizedBox(width: 6),
          ],
          Text(
            spec.descriptor.title,
            style: base.copyWith(
              fontWeight: spec.selected ? FontWeight.w600 : FontWeight.w400,
              color: spec.selected ? t.text : t.mutedText,
            ),
          ),
        ],
      ),
    );
  }
}

/// In-group drop zones shown during a drag: center = add tab, leading/trailing
/// edge = split into a new group. Paints a clear preview of where it'll land.
class _GroupDropZones extends StatefulWidget {
  const _GroupDropZones({required this.manager, required this.side, required this.groupIndex, required this.axis});

  final PanelManager manager;
  final DockSide side;
  final int groupIndex;
  final Axis axis;

  @override
  State<_GroupDropZones> createState() => _GroupDropZonesState();
}

enum _Drop { before, tab, after }

class _GroupDropZonesState extends State<_GroupDropZones> {
  _Drop? _hover;

  void _accept(_Drop kind, String id) {
    switch (kind) {
      case _Drop.tab:
        widget.manager.addPanelAsTab(id, widget.side, widget.groupIndex);
      case _Drop.before:
        widget.manager.splitBeside(id, widget.side, widget.groupIndex, before: true);
      case _Drop.after:
        widget.manager.splitBeside(id, widget.side, widget.groupIndex, before: false);
    }
    // The move rebuilds the tree and may dispose the source Draggable before its
    // onDragEnd fires, so end the drag explicitly here.
    widget.manager.endDrag();
  }

  @override
  Widget build(BuildContext context) {
    final bool horizontal = widget.axis == Axis.horizontal;
    final bool allowSplit = widget.manager.config.allowSplit;
    final double edge = widget.manager.config.dropEdgeFraction;
    final PanelTheme t = widget.manager.config.themeOf(context);

    // Dragging a tab back onto its own group returns it to its original
    // dock — the whole group body is a "drop to return" zone (no add-tab, no
    // split-out here; splitting stays available via other groups / the split
    // button).
    final bool isSource = widget.manager.isDragSource(widget.side, widget.groupIndex);
    final List<_Drop> kinds;
    if (isSource) {
      kinds = const <_Drop>[];
    } else if (!allowSplit) {
      kinds = const <_Drop>[_Drop.tab];
    } else {
      kinds = _Drop.values;
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double w = c.maxWidth;
        final double h = c.maxHeight;

        Rect? preview;
        if (_hover == _Drop.tab) {
          preview = Rect.fromLTWH(0, 0, w, h);
        } else if (_hover == _Drop.before) {
          preview = horizontal ? Rect.fromLTWH(0, 0, w * 0.5, h) : Rect.fromLTWH(0, 0, w, h * 0.5);
        } else if (_hover == _Drop.after) {
          preview = horizontal ? Rect.fromLTWH(w * 0.5, 0, w * 0.5, h) : Rect.fromLTWH(0, h * 0.5, w, h * 0.5);
        }

        Rect zoneRect(_Drop kind) {
          if (kind == _Drop.tab) {
            if (!allowSplit) return Rect.fromLTWH(0, 0, w, h);
            return horizontal ? Rect.fromLTWH(w * edge, 0, w * (1 - 2 * edge), h) : Rect.fromLTWH(0, h * edge, w, h * (1 - 2 * edge));
          }
          if (kind == _Drop.before) {
            return horizontal ? Rect.fromLTWH(0, 0, w * edge, h) : Rect.fromLTWH(0, 0, w, h * edge);
          }
          return horizontal ? Rect.fromLTWH(w * (1 - edge), 0, w * edge, h) : Rect.fromLTWH(0, h * (1 - edge), w, h * edge);
        }

        return Stack(
          children: <Widget>[
            // The source group: the whole body is a "drop to return" zone —
            // dropping anywhere here ends the drag and returns the panel to
            // its original position (no accidental tear-off). Painted with a
            // visible accent affordance, stronger while hovered.
            if (isSource)
              Positioned.fill(
                child: DragTarget<_TabDrag>(
                  onWillAcceptWithDetails: (_) => true,
                  onAcceptWithDetails: (_) => widget.manager.endDrag(),
                  builder: (BuildContext context, List<_TabDrag?> cand, _) {
                    final bool active = cand.isNotEmpty;
                    return Container(
                      margin: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: active
                            ? t.accent.withValues(alpha: 0.18)
                            : t.accent.withValues(alpha: 0.05),
                        border: Border.all(
                          color: active
                              ? t.accent
                              : t.accent.withValues(alpha: 0.45),
                          width: active ? 2 : 1,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        widget.manager.config.strings.dropToReturn,
                        style: TextStyle(
                          color: t.accent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (preview != null) Positioned.fromRect(rect: preview, child: _previewBox(t, _hover!)),
            for (final _Drop kind in kinds)
              Positioned.fromRect(
                rect: zoneRect(kind),
                child: DragTarget<_TabDrag>(
                  onWillAcceptWithDetails: (_) {
                    setState(() => _hover = kind);
                    return true;
                  },
                  onLeave: (_) {
                    if (_hover == kind) setState(() => _hover = null);
                  },
                  onAcceptWithDetails: (DragTargetDetails<_TabDrag> d) => _accept(kind, d.data.panelId),
                  builder: (_, _, _) => const SizedBox.expand(),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _previewBox(PanelTheme t, _Drop kind) {
    final PanelDockStrings str = widget.manager.config.strings;
    return IgnorePointer(
      child: Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: t.accent.withValues(alpha: 0.26),
          border: Border.all(color: t.accent, width: 2),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(kind == _Drop.tab ? str.addTab : str.newGroup, style: TextStyle(color: t.accent, fontWeight: FontWeight.w700)),
      ),
    );
  }
}

/// A collapsed (minimized) dock rendered as a thin strip that restores on tap.
class _CollapsedDock extends StatelessWidget {
  const _CollapsedDock({required this.manager, required this.side, required this.axis, required this.extent});

  final PanelManager manager;
  final DockSide side;
  final Axis axis;
  final double extent;

  @override
  Widget build(BuildContext context) {
    final PanelTheme t = manager.config.themeOf(context);
    final String title = manager.panelsIn(side).map((PanelDescriptor p) => p.title).join('  ·  ');
    final Widget labelText = Text(
      title.isEmpty ? side.label : title,
      style: TextStyle(fontSize: 12, color: t.mutedText),
      overflow: TextOverflow.ellipsis,
    );

    return GestureDetector(
      onTap: () => manager.toggleCollapsed(side),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(t.panelRadius),
          child: Container(
            width: axis == Axis.vertical ? extent : null,
            height: axis == Axis.horizontal ? extent : null,
            color: t.tabBar,
            padding: const EdgeInsets.all(6),
            child: axis == Axis.vertical
                ? Column(
                    children: <Widget>[
                      Icon(side == DockSide.left ? Icons.chevron_right : Icons.chevron_left, size: 16, color: t.mutedText),
                      const SizedBox(height: 8),
                      Expanded(child: RotatedBox(quarterTurns: 1, child: Center(child: labelText))),
                    ],
                  )
                : Row(
                    children: <Widget>[
                      Icon(Icons.keyboard_arrow_up, size: 16, color: t.mutedText),
                      const SizedBox(width: 8),
                      Expanded(child: labelText),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// A draggable splitter; renders a static 1px divider when [enabled] is false.
class _Splitter extends StatefulWidget {
  const _Splitter({
    required this.axis,
    required this.theme,
    required this.onDrag,
    this.enabled = true,
    this.hitSize = 8,
    this.visualGap,
    this.duration = const Duration(milliseconds: 100),
  });

  final Axis axis;
  final PanelTheme theme;
  final ValueChanged<double> onDrag;
  final bool enabled;
  final double hitSize;

  /// Visual gap width; null keeps the classic transparent band.
  final double? visualGap;

  final Duration duration;

  @override
  State<_Splitter> createState() => _SplitterState();
}

class _SplitterState extends State<_Splitter> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final bool vertical = widget.axis == Axis.vertical;
    final PanelTheme t = widget.theme;

    if (!widget.enabled) {
      return SizedBox(width: vertical ? 1 : null, height: vertical ? null : 1, child: ColoredBox(color: t.splitter));
    }

    final double? gap = widget.visualGap;
    final Color lineColor = _active ? t.splitterActive : Colors.transparent;
    final double thickness = _active ? 2 : 1;

    // Classic line: a centered 1–2px handle that only appears while active.
    final Widget line = AnimatedContainer(
      duration: widget.duration,
      width: vertical ? thickness : double.infinity,
      height: vertical ? double.infinity : thickness,
      color: lineColor,
    );

    // Shared interaction surface: [hitSize] wide with the hover cursor and
    // drag gestures. When [gap] is set this is larger than the visible gap
    // (hit/paint separation); otherwise it is the whole splitter band.
    final Widget interaction = MouseRegion(
      cursor: vertical ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _active = true),
      onExit: (_) => setState(() => _active = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: vertical ? (_) => setState(() => _active = true) : null,
        onHorizontalDragEnd: vertical ? (_) => setState(() => _active = false) : null,
        onHorizontalDragUpdate: vertical ? (DragUpdateDetails d) => widget.onDrag(d.delta.dx) : null,
        onVerticalDragStart: vertical ? null : (_) => setState(() => _active = true),
        onVerticalDragEnd: vertical ? null : (_) => setState(() => _active = false),
        onVerticalDragUpdate: vertical ? null : (DragUpdateDetails d) => widget.onDrag(d.delta.dy),
        child: Center(child: line),
      ),
    );

    if (gap != null) {
      // Hit/paint separation (via package:hit): the visible gap (layout) is
      // [gap] px and stays plain background, while the resize handle is the
      // larger [hitSize] px centered on it — e.g. a 2px gap with a 5px grab
      // area. No resting divider is drawn; the accent line only appears while
      // hovering/dragging. Requires a [HitScope] ancestor covering the
      // overflow, which the dock area provides.
      return HitLayer(
        alignment: Alignment.center,
        hitChild: SizedBox(
          width: vertical ? widget.hitSize : double.infinity,
          height: vertical ? double.infinity : widget.hitSize,
          child: interaction,
        ),
        paintChild: SizedBox(
          width: vertical ? gap : null,
          height: vertical ? null : gap,
        ),
      );
    }

    return SizedBox(
      width: vertical ? widget.hitSize : null,
      height: vertical ? null : widget.hitSize,
      child: interaction,
    );
  }
}

/// Thin edge targets to dock a dragged tab into a currently-empty side region.
class _EmptyRegionTargets extends StatelessWidget {
  const _EmptyRegionTargets({required this.manager});

  final PanelManager manager;

  bool _empty(DockSide side) => !manager.hasPanels(side);

  @override
  Widget build(BuildContext context) {
    const double strip = 70;
    return Stack(
      children: <Widget>[
        if (_empty(DockSide.left)) Positioned(left: 0, top: 0, bottom: 0, width: strip, child: _edge(context, DockSide.left)),
        if (_empty(DockSide.right)) Positioned(right: 0, top: 0, bottom: 0, width: strip, child: _edge(context, DockSide.right)),
        if (_empty(DockSide.bottom)) Positioned(left: strip, right: strip, bottom: 0, height: strip, child: _edge(context, DockSide.bottom)),
      ],
    );
  }

  Widget _edge(BuildContext context, DockSide side) {
    final PanelTheme t = manager.config.themeOf(context);
    return DragTarget<_TabDrag>(
      onAcceptWithDetails: (DragTargetDetails<_TabDrag> d) {
        manager.addPanelAsTab(d.data.panelId, side, 0);
        manager.endDrag();
      },
      builder: (BuildContext context, List<_TabDrag?> cand, _) {
        final bool active = cand.isNotEmpty;
        return Container(
          margin: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: t.accent.withValues(alpha: active ? 0.28 : 0.12),
            border: Border.all(color: t.accent.withValues(alpha: active ? 0.9 : 0.45), width: active ? 2 : 1),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(manager.config.strings.dockIntoLabel(side), textAlign: TextAlign.center, style: TextStyle(color: t.accent, fontWeight: FontWeight.w600)),
        );
      },
    );
  }
}

/// Single drop-target preview shown while a detached OS window is dragged over
/// the main window (Stage 2). Animates to the exact area the panel will occupy.
class _NativeDropZoneOverlay extends StatelessWidget {
  const _NativeDropZoneOverlay({required this.manager, required this.activeSide});

  final PanelManager manager;
  final DockSide activeSide;

  @override
  Widget build(BuildContext context) {
    final PanelTheme t = manager.config.themeOf(context);
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          final double w = c.maxWidth;
          final double h = c.maxHeight;
          double extent(DockSide side, double fallback, double maxFrac, double full) {
            final double v = (manager.hasPanels(side) && !manager.isCollapsed(side)) ? manager.sizeOf(side) : fallback;
            return v.clamp(0.0, full * maxFrac);
          }

          final double leftW = extent(DockSide.left, w * 0.18, 0.45, w);
          final double rightW = extent(DockSide.right, w * 0.20, 0.45, w);
          final double bottomH = extent(DockSide.bottom, h * 0.22, 0.55, h);
          final double rowH = h - bottomH;
          Rect target = switch (activeSide) {
            DockSide.left => Rect.fromLTWH(0, 0, leftW, rowH),
            DockSide.right => Rect.fromLTWH(w - rightW, 0, rightW, rowH),
            DockSide.bottom => Rect.fromLTWH(0, rowH, w, bottomH),
            DockSide.center => Rect.fromLTWH(leftW, 0, (w - leftW - rightW).clamp(0.0, w), rowH),
          };

          final int groups = manager.groupCount(activeSide);
          if (!manager.config.redockAsTab && groups >= 1) {
            final double frac = 1 / (groups + 1);
            final bool rowAxis = activeSide == DockSide.bottom || activeSide == DockSide.center;
            if (rowAxis) {
              final double nw = target.width * frac;
              target = Rect.fromLTWH(target.right - nw, target.top, nw, target.height);
            } else {
              final double nh = target.height * frac;
              target = Rect.fromLTWH(target.left, target.bottom - nh, target.width, nh);
            }
          }

          return Stack(
            children: <Widget>[
              AnimatedPositioned(
                duration: manager.config.hoverDuration,
                curve: Curves.easeOut,
                left: target.left,
                top: target.top,
                width: target.width,
                height: target.height,
                child: Container(
                  margin: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.26),
                    border: Border.all(color: t.accent, width: 2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Text(manager.config.strings.dockMenuItemLabel(activeSide), style: TextStyle(color: t.accent, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
