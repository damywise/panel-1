import 'package:jaspr/jaspr.dart';

import 'embedded_panel.dart';

// A @client island: only this subtree hydrates on the client (mounting Flutter)
// while the rest of the deck stays static pre-rendered HTML. [name] selects
// which demo to embed (intro / regions / drag / themes) and is serialized to
// the client as a component parameter.
@client
class LiveDemo extends StatelessComponent {
  const LiveDemo({super.key, this.name = 'intro'});

  final String name;

  @override
  Component build(BuildContext context) {
    return EmbeddedPanel(name: name);
  }
}
