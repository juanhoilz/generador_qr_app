import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:convert';

import '../../qr_generator/views/qr_screen.dart';
import '../../../core/api_config.dart';
import '../styles/login_colors.dart';

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
      SnackBar(content: Text(mensaje), backgroundColor: LoginColors.error),
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

  InputDecoration _decoration(String label, IconData icon) {
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: color, width: width),
        );

    return InputDecoration(
      labelText: label,
      floatingLabelBehavior: FloatingLabelBehavior.always,
      labelStyle: const TextStyle(color: LoginColors.secondary, fontSize: 16),
      floatingLabelStyle: const TextStyle(color: LoginColors.secondary),
      prefixIcon: Icon(icon, color: LoginColors.secondary),
      filled: true,
      fillColor: LoginColors.field,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      enabledBorder: border(LoginColors.border),
      focusedBorder: border(LoginColors.primary, 2),
      errorBorder: border(LoginColors.error),
      focusedErrorBorder: border(LoginColors.error, 2),
      errorStyle: const TextStyle(color: LoginColors.error),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: LoginColors.background,
      body: Stack(
        children: [
          const Positioned.fill(child: _LoginBackground()),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 32,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (constraints.maxHeight - 64).clamp(
                      0,
                      double.infinity,
                    ),
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          // Superficie de cristal sin el coste de un desenfoque.
                          color: LoginColors.field.withValues(alpha: 0.90),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: LoginColors.field),
                          boxShadow: [
                            BoxShadow(
                              color: LoginColors.text.withValues(alpha: 0.06),
                              blurRadius: 32,
                              offset: const Offset(0, 12),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Center(
                              child: Container(
                                width: 120,
                                height: 120,
                                decoration: BoxDecoration(
                                  color: LoginColors.text,
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                child: Image.asset(
                                  'assets/images/iconoqrasistra.png',
                                  fit: BoxFit.contain,
                                  semanticLabel: 'Logo de Asistra',
                                ),
                              ),
                            ),
                            const SizedBox(height: 24),
                            const Text(
                              'Acceso Administrativo',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: LoginColors.text,
                                fontSize: 28,
                                height: 1.2,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 32),
                            TextField(
                              controller: _emailController,
                              style: const TextStyle(
                                fontSize: 16,
                                color: LoginColors.text,
                              ),
                              cursorColor: LoginColors.primary,
                              decoration: _decoration(
                                'Correo electrónico',
                                Icons.email_outlined,
                              ),
                            ),
                            const SizedBox(height: 24),
                            TextField(
                              controller: _passwordController,
                              obscureText: !_passwordVisible,
                              style: const TextStyle(
                                fontSize: 16,
                                color: LoginColors.text,
                              ),
                              cursorColor: LoginColors.primary,
                              decoration:
                                  _decoration(
                                    'Contraseña',
                                    Icons.lock_outline,
                                  ).copyWith(
                                    suffixIcon: IconButton(
                                      constraints: const BoxConstraints(
                                        minWidth: 48,
                                        minHeight: 48,
                                      ),
                                      color: LoginColors.secondary,
                                      tooltip: _passwordVisible
                                          ? 'Ocultar contraseña'
                                          : 'Mostrar contraseña',
                                      icon: Icon(
                                        _passwordVisible
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                      ),
                                      onPressed: () {
                                        setState(
                                          () => _passwordVisible =
                                              !_passwordVisible,
                                        );
                                      },
                                    ),
                                  ),
                            ),
                            const SizedBox(height: 32),
                            ElevatedButton(
                              style: ButtonStyle(
                                minimumSize: const WidgetStatePropertyAll(
                                  Size(double.infinity, 56),
                                ),
                                padding: const WidgetStatePropertyAll(
                                  EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 16,
                                  ),
                                ),
                                elevation: const WidgetStatePropertyAll(0),
                                backgroundColor:
                                    WidgetStateProperty.resolveWith((states) {
                                      if (states.contains(
                                        WidgetState.disabled,
                                      )) {
                                        return LoginColors.secondary;
                                      }
                                      if (states.contains(
                                        WidgetState.pressed,
                                      )) {
                                        return LoginColors.pressed;
                                      }
                                      return LoginColors.primary;
                                    }),
                                foregroundColor: const WidgetStatePropertyAll(
                                  LoginColors.onPrimary,
                                ),
                                overlayColor: WidgetStatePropertyAll(
                                  LoginColors.onPrimary.withValues(alpha: 0.12),
                                ),
                                side: WidgetStateProperty.resolveWith(
                                  (states) => BorderSide(
                                    color: states.contains(WidgetState.focused)
                                        ? LoginColors.text
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                                shape: WidgetStatePropertyAll(
                                  RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                              ),
                              onPressed: _isLoading ? null : _iniciarSesion,
                              child: _isLoading
                                  ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: LoginColors.onPrimary,
                                        semanticsLabel: 'Iniciando sesión',
                                      ),
                                    )
                                  : const Text(
                                      'Continuar',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoginBackground extends StatelessWidget {
  const _LoginBackground();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topLeft,
            radius: 1.1,
            colors: [LoginColors.turquoise, LoginColors.background],
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.bottomRight,
              radius: 0.9,
              colors: [LoginColors.lavender, Color(0x00EEEAF7)],
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topRight,
                radius: 0.7,
                colors: [LoginColors.ice, Color(0x00EAF3FA)],
              ),
            ),
            child: SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}
