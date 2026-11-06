import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generador_qr_app/main.dart';

void main() {
  testWidgets('Muestra el acceso administrativo sin sesión', (tester) async {
    await tester.pumpWidget(const MiGeneradorQR(hasToken: false));
    expect(find.text('Acceso Administrativo'), findsOneWidget);
    expect(find.text('Continuar'), findsOneWidget);
    expect(find.byIcon(Icons.logout), findsNothing);
  });
}
