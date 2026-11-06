import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:convert';

import '../../qr_generator/views/qr_screen.dart';
import '../../../core/api_config.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _passwordVisible = false;

  Future<void> _iniciarSesion() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    var etapa = 'autenticación';
    final reloj = Stopwatch()..start();
    final url = ApiConfig.endpoint('users/authentication');

    _logLogin('POST $url — iniciando intento de login');
    try {
      final respuesta = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: json.encode({
              'email': _emailController.text.trim(),
              'password': _passwordController.text,
            }),
          )
          .timeout(const Duration(seconds: 15));
      _logRespuesta(etapa, respuesta);

      if (respuesta.statusCode == 200) {
        final datos = json.decode(respuesta.body);

        final accessToken = datos['access_token'] as String?;
        if (accessToken == null || accessToken.isEmpty) {
          _mostrarError(
            'La respuesta de autenticación no contiene un token válido',
          );
          return;
        }

        etapa = 'validación del administrador';
        final selfInfoUrl = ApiConfig.endpoint('users/self-info');
        _logLogin('GET $selfInfoUrl — consultando rol');
        final selfInfoRespuesta = await http
            .get(
              selfInfoUrl,
              headers: {
                'Accept': 'application/json',
                'Authorization': 'Bearer $accessToken',
              },
            )
            .timeout(const Duration(seconds: 15));
        _logRespuesta(etapa, selfInfoRespuesta);

        if (selfInfoRespuesta.statusCode != 200) {
          _mostrarError(
            'No se pudo validar el rol del usuario (HTTP ${selfInfoRespuesta.statusCode}).',
          );
          return;
        }

        final selfInfo = json.decode(selfInfoRespuesta.body);
        if (selfInfo is! Map<String, dynamic> ||
            selfInfo['id'] is! int ||
            selfInfo['personal_id'] is! int) {
          _mostrarError('La cuenta debe tener usuario y empleado válidos.');
          return;
        }
        final rol = _extraerRol(selfInfo);
        if (rol == null || rol.toLowerCase() != 'administrador') {
          _mostrarError(
            'Solo los usuarios administradores pueden iniciar sesión',
          );
          return;
        }

        _logLogin('Rol de administrador validado');
        etapa = 'guardado de sesión';
        // Guardado local de credenciales y tiempos de expiración
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('session_api', ApiConfig.baseUrl);
        await prefs.setString(
          'device_owner',
          '${selfInfo['id']}|${selfInfo['personal_id']}',
        );
        await prefs.setString('access_token', accessToken);
        await prefs.setString(
          'refresh_token',
          datos['refresh_token'] as String,
        );
        await prefs.setInt('expires_at', datos['expires_at'] as int);
        await prefs.setString(
          'numero_empleado',
          datos['numero_empleado'] as String,
        );

        _logLogin('Login correcto. Abriendo autorización de tablet');
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const QrScreen()),
          );
        }
      } else {
        _mostrarError(
          respuesta.statusCode == 401 || respuesta.statusCode == 403
              ? 'El servidor rechazó el acceso (HTTP ${respuesta.statusCode}). Verifica tus credenciales.'
              : 'Error del servidor al iniciar sesión (HTTP ${respuesta.statusCode}).',
        );
      }
    } on TimeoutException {
      _logLogin('ERROR en $etapa: el servidor no respondió en 15 segundos');
      _mostrarError(
        'El servidor tardó demasiado. Verifica la red local y que Apache esté iniciado.',
      );
    } on SocketException catch (e) {
      _logLogin(
        'ERROR de conexión en $etapa: ${e.message}; código SO=${e.osError?.errorCode}',
      );
      _mostrarError(
        'No se pudo conectar con el servidor local. Revisa la IP, Wi-Fi y Apache.',
      );
    } on http.ClientException catch (e) {
      _logLogin('ERROR HTTP/red en $etapa: ${e.message}');
      _mostrarError(
        'Fallo de conexión con el servidor local. Consulta los logs [LOGIN].',
      );
    } on FormatException {
      _logLogin(
        'ERROR en $etapa: la respuesta no tiene el formato JSON esperado',
      );
      _mostrarError(
        'El servidor devolvió una respuesta inválida. Revisa la URL y los logs [LOGIN].',
      );
    } catch (e, stack) {
      _logLogin(
        'ERROR en $etapa: ${e.runtimeType} (formato de datos o almacenamiento)',
      );
      if (kDebugMode) {
        debugPrintStack(label: '[LOGIN] Traza de $etapa', stackTrace: stack);
      }
      _mostrarError(
        'No se pudo completar el login. Consulta los logs [LOGIN].',
      );
    } finally {
      _logLogin('Intento finalizado en ${reloj.elapsedMilliseconds} ms');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _logLogin(String message) {
    if (!kDebugMode) return;
    // No imprimir cuerpos HTTP: pueden incluir tokens, datos personales o HTML.
    var safe = message;
    for (final value in [
      _passwordController.text,
      _emailController.text.trim(),
    ]) {
      if (value.isNotEmpty) safe = safe.replaceAll(value, '[oculto]');
    }
    debugPrint('[LOGIN] $safe');
  }

  void _logRespuesta(String etapa, http.Response response) {
    _logLogin(
      '$etapa: HTTP ${response.statusCode}; '
      'Content-Type=${response.headers['content-type'] ?? 'sin indicar'}; '
      '${response.bodyBytes.length} bytes',
    );
  }

  void _mostrarError(String mensaje) {
    _logLogin('ERROR: $mensaje');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(mensaje), backgroundColor: Colors.red),
    );
  }

  String? _extraerRol(dynamic selfInfo) {
    final usuario =
        selfInfo is Map<String, dynamic> &&
            selfInfo['data'] is Map<String, dynamic>
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
        if (nombre is String &&
            nombre.trim().toLowerCase() == 'administrador') {
          return nombre.trim();
        }
      }
    }

    return null;
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
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
              const Icon(
                Icons.qr_code_scanner,
                size: 80,
                color: Color(0xFF1E293B),
              ),
              const SizedBox(height: 40),
              const Text(
                'Acceso Administrativo',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 30),
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Correo electrónico',
                  prefixIcon: Icon(Icons.email),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: !_passwordVisible,
                decoration: InputDecoration(
                  labelText: 'Contraseña',
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    tooltip: _passwordVisible
                        ? 'Ocultar contraseña'
                        : 'Mostrar contraseña',
                    icon: Icon(
                      _passwordVisible
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () {
                      setState(() => _passwordVisible = !_passwordVisible);
                    },
                  ),
                ),
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
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _iniciarSesion,
                        child: const Text(
                          'Continuar',
                          style: TextStyle(fontSize: 16),
                        ),
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
