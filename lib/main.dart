import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'features/auth/views/login_screen.dart';
import 'features/qr_generator/views/qr_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final hasToken = prefs.getString('access_token') != null;

  runApp(MiGeneradorQR(hasToken: hasToken));
}

class MiGeneradorQR extends StatelessWidget {
  final bool hasToken;
  const MiGeneradorQR({super.key, required this.hasToken});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Generador QR',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E293B), // Tono oscuro minimalista
          background: const Color(0xFFF8FAFC),
        ),
        useMaterial3: true,
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          filled: true,
          fillColor: Colors.white,
        ),
      ),
      home: hasToken ? const QrScreen() : const LoginScreen(),
    );
  }
}