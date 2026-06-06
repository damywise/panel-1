// Bridge to the native macOS dock helper (macos/Runner/AppDelegate.swift).
//
// This talks to the native side over **FFI** rather than a method channel:
// forward calls resolve Swift `@_cdecl` symbols from the running executable,
// and reverse drag/drop events arrive through `NativeCallable.listener`
// function pointers registered with the native side. The C ABI lives in
// macos/Runner/panes_dock.h; the Dart bindings (panes_dock_bindings.dart) are
// generated from it by ffigen.

import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:ui' show Offset, Rect;

import 'package:ffi/ffi.dart';

import 'panes_dock_bindings.dart';

/// Token written as a panel window's (hidden) title so the native side can find
/// the right `NSWindow`.
String panelWindowToken(String panelId) => 'panel::$panelId';

/// Parses a [panelWindowToken] back to the panel id, or null.
String? panelIdFromToken(String token) =>
    token.startsWith('panel::') ? token.substring('panel::'.length) : null;

/// Reported native frame of a window, in Flutter logical pixels, top-left
/// origin (already converted from AppKit's bottom-left screen space natively).
class WindowFrame {
  const WindowFrame(this.token, this.rect);
  final String token;
  final Rect rect;
}

class NativeDock {
  NativeDock._();

  /// The shared instance.
  static final NativeDock instance = NativeDock._();

  static final bool _supported = Platform.isMacOS;

  /// Lazily-resolved FFI bindings to the symbols in the Runner executable.
  late final PanesDockBindings _bindings = PanesDockBindings(DynamicLibrary.executable());

  /// Called continuously while a panel window is dragged, with the dragged
  /// window frame, the main-window frame, and the live pointer location (all in
  /// a shared top-left coordinate space).
  void Function(WindowFrame panel, Rect mainFrame, Offset pointer)? onPanelDrag;

  /// Called when the user releases a panel-window drag: (token).
  void Function(String token)? onPanelDrop;

  bool _wired = false;
  NativeCallable<PanesDragCallbackFunction>? _dragCallable;
  NativeCallable<PanesDropCallbackFunction>? _dropCallable;

  /// Registers the reverse (native -> Dart) callbacks. Safe to call repeatedly.
  void ensureWired() {
    if (_wired) return;
    _wired = true;
    if (!_supported) return;
    // `.listener` posts to this isolate's event loop, so it works even when the
    // native side invokes it from AppKit's main thread.
    _dragCallable = NativeCallable<PanesDragCallbackFunction>.listener(_onDrag);
    _dropCallable = NativeCallable<PanesDropCallbackFunction>.listener(_onDrop);
    _bindings.panes_dock_register(_dragCallable!.nativeFunction, _dropCallable!.nativeFunction);
  }

  void _onDrag(
    Pointer<Char> token,
    double x,
    double y,
    double w,
    double h,
    double mainX,
    double mainY,
    double mainW,
    double mainH,
    double pointerX,
    double pointerY,
  ) {
    final String t = _takeString(token);
    onPanelDrag?.call(
      WindowFrame(t, Rect.fromLTWH(x, y, w, h)),
      Rect.fromLTWH(mainX, mainY, mainW, mainH),
      Offset(pointerX, pointerY),
    );
  }

  void _onDrop(Pointer<Char> token) {
    onPanelDrop?.call(_takeString(token));
  }

  /// Reads a C string the native side allocated with strdup, then frees it.
  String _takeString(Pointer<Char> token) {
    final String s = token.cast<Utf8>().toDartString();
    malloc.free(token);
    return s;
  }

  void _withToken(void Function(Pointer<Char>) call, String token) {
    final Pointer<Utf8> p = token.toNativeUtf8();
    try {
      call(p.cast<Char>());
    } finally {
      malloc.free(p);
    }
  }

  /// Hides the title bar of the window with [token] and makes it draggable, and
  /// starts reporting its drags.
  Future<void> decorate(String token) async {
    if (_supported) _withToken(_bindings.panes_dock_decorate, token);
  }

  /// Begins a native window-move drag for the window with [token].
  Future<void> startWindowDrag(String token) async {
    if (_supported) _withToken(_bindings.panes_dock_start_window_drag, token);
  }

  /// Makes the main window's title bar transparent/full-size.
  Future<void> decorateMain() async {
    if (_supported) _bindings.panes_dock_decorate_main();
  }
}
