import 'package:jaspr/jaspr.dart';
import 'package:jaspr_flutter_embed/jaspr_flutter_embed.dart';

// The Flutter widget is imported only on the web (the server can't import
// Flutter) and as a deferred library so it doesn't block hydration.
@Import.onWeb('../widgets/panel_demo.dart', show: [#PanelDemoWidget])
import 'embedded_panel.imports.dart' deferred as panel;

class EmbeddedPanel extends StatelessComponent {
  const EmbeddedPanel({super.key, this.name = 'intro'});

  /// Which demo to render (see PanelDemoWidget): intro / regions / drag / themes.
  final String name;

  @override
  Component build(BuildContext context) {
    // No ViewConstraints: the Flutter view sizes to its host element (the
    // responsive .embed box, web/deck.css), so its on-screen size matches its
    // logical size and pointer hit-testing is correct. The demo itself scales a
    // fixed 920x560 design to that size with a Flutter FittedBox (see
    // PanelDemoWidget), which keeps hit-testing correct — unlike a CSS transform
    // on the host element, which Flutter ignores when mapping pointers.
    return FlutterEmbedView.deferred(
      loadLibrary: panel.loadLibrary(),
      builder: () => panel.PanelDemoWidget(name: name),
    );
  }
}
