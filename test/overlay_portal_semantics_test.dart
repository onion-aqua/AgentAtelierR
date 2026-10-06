import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Same topology as flutter/flutter#190431, with the accessible anchor
  // grouping used by the app's tooltip controls. Removing those boundaries
  // reproduces !child.attached on this project's Flutter 3.47 SDK.
  testWidgets('accessible tooltip anchor groups survive repeated overlays', (
    tester,
  ) async {
    final visible = OverlayPortalController();
    final sibling = OverlayPortalController();
    final anchor = OverlayPortal.overlayChildLayoutBuilder(
      controller: sibling,
      overlayChildBuilder: (_, _) => const SizedBox.shrink(),
      child: Semantics(explicitChildNodes: true, child: const Text('sibling')),
    );
    Widget changing = OverlayPortal.overlayChildLayoutBuilder(
      controller: visible,
      overlayChildBuilder: (_, _) => const Align(
        alignment: Alignment.topLeft,
        child: Text('overlay child'),
      ),
      child: Semantics(explicitChildNodes: true, child: const Text('anchor')),
    );
    changing = Overlay.wrap(child: ExcludeSemantics(child: changing));
    changing = SizedBox(width: 200, height: 100, child: changing);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Overlay.wrap(
          child: Semantics(
            container: true,
            child: Column(
              children: [
                Semantics(container: true, child: anchor),
                Semantics(container: true, child: changing),
              ],
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 2; i++) {
      visible.show();
      await tester.pumpAndSettle();
      visible.hide();
      await tester.pumpAndSettle();
    }
    expect(tester.getSemantics(find.text('sibling')).label, 'sibling');
    expect(tester.takeException(), isNull);
  });
}
