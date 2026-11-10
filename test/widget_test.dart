import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generador_qr_app/main.dart';
import 'package:generador_qr_app/features/auth/views/login_screen.dart';

void main() {
  testWidgets('Muestra el acceso administrativo sin sesión', (tester) async {
    await tester.pumpWidget(const MiGeneradorQR(hasToken: false));
    expect(find.text('Acceso Administrativo'), findsOneWidget);
    expect(find.text('Continuar'), findsOneWidget);
    expect(find.byIcon(Icons.logout), findsNothing);
  });

  for (final size in [
    const Size(320, 568),
    const Size(430, 932),
    const Size(768, 1024),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Acceso desplazable: $size, texto $scale y teclado', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const LoginScreen(),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final logo = tester.widget<Image>(find.byType(Image));
        expect(logo.fit, BoxFit.contain);
        await tester.enterText(
          find.byType(TextField).first,
          'admin@example.com',
        );
        await tester.enterText(find.byType(TextField).last, 'contraseña');
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byTooltip('Mostrar contraseña'));
        await tester.tap(find.byTooltip('Mostrar contraseña'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField).last).obscureText,
          isFalse,
        );
        expect(find.text('Correo electrónico'), findsOneWidget);
        expect(find.text('Contraseña'), findsOneWidget);
        await tester.ensureVisible(find.byType(ElevatedButton));
        await tester.pumpAndSettle();
        expect(find.byType(ElevatedButton).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
