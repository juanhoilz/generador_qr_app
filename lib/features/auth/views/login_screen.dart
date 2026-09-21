import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../../qr_generator/views/qr_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;

  Future<void> _iniciarSesion() async {
    setState(() => _isLoading = true);
    final url = Uri.parse('https://controldeasistenciastec.com/2sis/web/api/users/authentication');

    try {
      final respuesta = await http.post(
        url,
        headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
        body: json.encode({
          'email': _emailController.text.trim(),
          'password': _passwordController.text.trim(),
        }),
      );

      if (respuesta.statusCode == 200) {
        final datos = json.decode(respuesta.body);

        final accessToken = datos['access_token'] as String?;
        if (accessToken == null || accessToken.isEmpty) {
          _mostrarError('La respuesta de autenticación no contiene un token válido');
          return;
        }

        final selfInfoUrl = Uri.parse('https://controldeasistenciastec.com/2sisc/web/api/users/self-info');
        final selfInfoRespuesta = await http.get(
          selfInfoUrl,
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer $accessToken',
          },
        );

        if (selfInfoRespuesta.statusCode != 200) {
          _mostrarError('No se pudo validar el rol del usuario');
          return;
        }

        final selfInfo = json.decode(selfInfoRespuesta.body);
        final rol = _extraerRol(selfInfo);
        if (rol == null || rol.toLowerCase() != 'administrador') {
          _mostrarError('Solo los usuarios administradores pueden iniciar sesión');
          return;
        }

        // Guardado local de credenciales y tiempos de expiración
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('access_token', accessToken);
        await prefs.setString('refresh_token', datos['refresh_token'] as String);
        await prefs.setInt('expires_at', datos['expires_at'] as int);
        await prefs.setString('numero_empleado', datos['numero_empleado'] as String);

        if (mounted) {
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const QrScreen()));
        }
      } else {
        _mostrarError('Credenciales incorrectas');
      }
    } catch (e) {
      _mostrarError('Error de red. Se requiere internet para el primer inicio de sesión.');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _mostrarError(String mensaje) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(mensaje), backgroundColor: Colors.red));
  }

  String? _extraerRol(dynamic selfInfo) {
    final usuario = selfInfo is Map<String, dynamic> && selfInfo['data'] is Map<String, dynamic>
        ? selfInfo['data'] as Map<String, dynamic>
        : selfInfo;

    if (usuario is! Map<String, dynamic>) return null;

    final rol = usuario['role'] ?? usuario['rol'];
    if (rol is String) return rol.trim();
    if (rol is Map<String, dynamic>) {
      final nombre = rol['name'] ?? rol['nombre'];
      return nombre is String ? nombre.trim() : null;
    }

    final roles = usuario['roles'];
    if (roles is List) {
      for (final elemento in roles) {
        final nombre = elemento is String
            ? elemento
            : elemento is Map<String, dynamic>
                ? elemento['name'] ?? elemento['nombre']
                : null;
        if (nombre is String && nombre.trim().toLowerCase() == 'administrador') {
          return nombre.trim();
        }
      }
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.qr_code_scanner, size: 80, color: Color(0xFF1E293B)),
              const SizedBox(height: 40),
              const Text('Acceso Administrativo', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 30),
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Correo electrónico', prefixIcon: Icon(Icons.email)),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Contraseña', prefixIcon: Icon(Icons.lock)),
              ),
              const SizedBox(height: 32),
              _isLoading
                  ? const CircularProgressIndicator()
                  : SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1E293B),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _iniciarSesion,
                        child: const Text('Generar Gafete', style: TextStyle(fontSize: 16)),
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}