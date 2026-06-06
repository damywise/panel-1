// dart format off
// ignore_for_file: type=lint

// GENERATED FILE, DO NOT MODIFY
// Generated with jaspr_builder

import 'package:jaspr/server.dart';
import 'package:docs/components/live_demo.dart' as _live_demo;

/// Default [ServerOptions] for use with your Jaspr project.
///
/// Use this to initialize Jaspr **before** calling [runApp].
///
/// Example:
/// ```dart
/// import 'main.server.options.dart';
///
/// void main() {
///   Jaspr.initializeApp(
///     options: defaultServerOptions,
///   );
///
///   runApp(...);
/// }
/// ```
ServerOptions get defaultServerOptions => ServerOptions(
  clientId: 'main.client.dart.js',
  clients: {
    _live_demo.LiveDemo: ClientTarget<_live_demo.LiveDemo>(
      'live_demo',
      params: __live_demoLiveDemo,
    ),
  },
);

Map<String, Object?> __live_demoLiveDemo(_live_demo.LiveDemo c) => {
  'name': c.name,
};
