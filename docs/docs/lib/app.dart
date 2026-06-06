import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'components/live_demo.dart';
import 'slides.dart';

// The whole site is a single slide deck (see web/deck.css + web/deck.js for the
// scroll-snap behavior). Static slides are markup rendered via `raw()`; the
// interactive slides each embed a *different* real package:panel demo as a
// Flutter island (one shared engine, several views).
class App extends StatelessComponent {
  const App({super.key});

  @override
  Component build(BuildContext context) {
    return Component.fragment([
      div([], id: 'progress'),
      nav([], id: 'dots'),
      div([Component.text('scroll / ↓ / space')], classes: 'hint'),
      main_(id: 'deck', [
        RawText(heroHtml),
        _demoSlide(
          demo: 'intro',
          dataTitle: 'Live demo',
          kicker: 'Live · in your browser',
          title: 'A dockable workspace',
          desc: [
            Component.text('The real '),
            code([Component.text('package:panel')]),
            Component.text(
              ' dock. Drag a tab to dock or split it, drag a splitter to resize, '
              'click a tab to focus.',
            ),
          ],
        ),
        RawText(blockA),
        _demoSlide(
          demo: 'regions',
          dataTitle: 'Regions',
          kicker: 'Layout · Regions',
          title: 'Regions hold panels; add them live',
          desc: [
            Component.text(
              'Each side is a region holding side-by-side groups of tabs. '
              'Use the buttons to add panels and watch them dock; drag a tab onto a group '
              'edge to split it.',
            ),
          ],
        ),
        _demoSlide(
          demo: 'drag',
          dataTitle: 'Drag',
          kicker: 'Interactions · Drag',
          title: "Drag a tab, it knows where it'll land",
          desc: [
            Component.text(
              'A tab can move between groups. Dropping on an edge makes '
              'a new group (with a live preview); the center adds a tab.',
            ),
          ],
        ),
        RawText(blockB),
        _demoSlide(
          demo: 'themes',
          dataTitle: 'Themes',
          kicker: 'Theming · PanelTheme',
          title: 'Themeable, no Material tint',
          desc: [
            Component.text('The dock paints from a '),
            code([Component.text('PanelTheme')]),
            Component.text(
              ': colors, tab shape (square / rounded / pill) and chrome '
              '(borders, dividers). Pick one:',
            ),
          ],
        ),
        RawText(blockC),
      ]),
    ]);
  }
}

// A slide whose visual is a live, embedded Flutter demo selected by [demo].
Component _demoSlide({
  required String demo,
  required String dataTitle,
  required String kicker,
  required String title,
  required List<Component> desc,
}) {
  return section(
    classes: 'demo',
    attributes: {'data-title': dataTitle},
    [
      div([Component.text(kicker)], classes: 'kicker'),
      h2([Component.text(title)]),
      p(desc),
      // .embed is the responsive box; .embed-stage is the fixed 920x560 surface
      // deck.js scales to fit it.
      div([
        div([LiveDemo(name: demo)], classes: 'embed-stage'),
      ], classes: 'embed'),
    ],
  );
}
