// C ABI for the native macOS dock helper. This header is the ffigen input
// (see ffigen.yaml) that generates lib/panels/panes_dock_bindings.dart. The
// implementations are the `@_cdecl` functions in macos/Runner/AppDelegate.swift.
//
// It is NOT compiled into the Runner target — Swift's `@_cdecl` exports the
// symbols directly into the executable, which Dart resolves via
// DynamicLibrary.executable().
#ifndef PANES_DOCK_H
#define PANES_DOCK_H

// Streamed continuously while a detached panel window is dragged. All values
// share a top-left origin coordinate space. `token` is heap-allocated by the
// native side (strdup) and must be freed by the Dart callback.
typedef void (*PanesDragCallback)(const char *token,
                                  double x, double y, double w, double h,
                                  double mainX, double mainY, double mainW, double mainH,
                                  double pointerX, double pointerY);

// Fired once when a dragged panel window is released. `token` is heap-allocated
// (strdup) and must be freed by the Dart callback.
typedef void (*PanesDropCallback)(const char *token);

// Registers the reverse callbacks (NativeCallable function pointers).
void panes_dock_register(PanesDragCallback drag, PanesDropCallback drop);

// Hides the title bar of the detached window whose title equals `token`,
// positions it at the pointer, and starts reporting its drags.
void panes_dock_decorate(const char *token);

// Makes the main window's title bar transparent/full-size (keeps traffic lights).
void panes_dock_decorate_main(void);

// Begins a native window-move for `token` using the in-flight mouse event,
// so a Flutter-drawn header can act as the window's drag handle.
void panes_dock_start_window_drag(const char *token);

#endif // PANES_DOCK_H
