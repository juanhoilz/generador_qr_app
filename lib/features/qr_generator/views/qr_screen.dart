import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/session.dart';
import '../../auth/views/login_screen.dart';
import '../../device/device_registration.dart';
import '../services/local_server_service.dart';

class QrScreen extends StatefulWidget {
  const QrScreen({super.key});
  @override
  State<QrScreen> createState() => _QrScreenState();
}

class _QrScreenState extends State<QrScreen> with WidgetsBindingObserver {
  SharedPreferences? _prefs;
  DeviceRegistration? _device;
  LocalServerService? _server;
  Timer? _poll;
  Timer? _rotation;
  Future<bool>? _checking;
  bool _busy = false;
  bool _loading = true;
  bool _sessionValid = false;
  bool _allowed = false;
  bool _leaving = false;
  String? _error;
  String _ip = '';
  String _qr = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _device = DeviceRegistration(_prefs!);
      await _device!.initialize();
      if (!mounted || _leaving) return;
      await _update();
      if (!mounted || _leaving) return;
      _poll = Timer.periodic(
        const Duration(seconds: 15),
        (_) => unawaited(_update()),
      );
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _authorize({bool renew = false}) {
    if (_leaving || !mounted) return Future.value(false);
    return _checking ??= _check(renew).whenComplete(() => _checking = null);
  }

  Future<bool> _check(bool renew) async {
    try {
      _sessionValid = await Session.refreshIfNeeded(_prefs!);
      if (_leaving || !mounted) return false;
      if (_sessionValid) {
        await _device!.refresh(
          _prefs!.getString('access_token')!,
          renew: renew,
        );
      } else {
        _device!.offline = true;
      }
      _allowed = _device!.autorizado;
      _error = null;
    } catch (e) {
      _allowed = false;
      await _device!.invalidate();
      _error = '$e';
    }
    if (_leaving || !mounted) return false;
    setState(() {});
    return _allowed;
  }

  Future<void> _update({bool renew = false}) async {
    if (_busy || _leaving || _device == null) return;
    setState(() => _busy = true);
    try {
      final allowed = await _authorize(renew: renew);
      if (!mounted || _leaving) return;
      if (allowed && _server == null) {
        _ip = await LocalServerService.obtenerIPLocal();
        if (!mounted || _leaving) return;
        final server = LocalServerService(
          // La comprobación remota corre cada 15 s. El teléfono solo espera 5 s;
          // aquí se exige la aprobación ya confirmada, sin otra espera de red.
          authorize: () async =>
              mounted && !_leaving && _allowed && _device!.autorizado,
          token: () => _prefs!.getString('access_token') ?? '',
          canSend: () =>
              _sessionValid &&
              !_device!.offline &&
              (_prefs!.getInt('expires_at') ?? 0) >
                  DateTime.now().millisecondsSinceEpoch ~/ 1000,
          uuid: _device!.uuid,
          scope: _device!.scope,
        );
        _server = server;
        try {
          await server.iniciarServidor();
        } catch (_) {
          await server.detenerServidor();
          _server = null;
          rethrow;
        }
        if (!mounted || _leaving) {
          await server.detenerServidor();
          return;
        }
        _rotate();
        _rotation = Timer.periodic(
          const Duration(seconds: 10),
          (_) => _rotate(),
        );
      } else if (!allowed) {
        _rotation?.cancel();
        final server = _server;
        _server = null;
        await server?.detenerServidor();
        _qr = '';
      }
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _rotate() {
    if (!mounted || _leaving) return;
    setState(
      () => _qr = jsonEncode({
        'ip': _ip,
        'puerto': 8080,
        'ts': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  Future<void> _logout() async {
    _leaving = true;
    _poll?.cancel();
    _rotation?.cancel();
    await _server?.detenerServidor();
    // Esperar las escrituras de renovación antes de limpiar la sesión.
    await _checking;
    if (_prefs != null) await Session.clear(_prefs!);
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_update());
  }

  @override
  void dispose() {
    _leaving = true;
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _rotation?.cancel();
    unawaited(_server?.detenerServidor());
    _device?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final device = _device;
    final active = _allowed && _server != null && _qr.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(active ? 'Checador activo' : 'Autorización de tablet'),
        actions: [
          IconButton(icon: const Icon(Icons.logout), onPressed: _logout),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (active) ...[
                        Text('IP Red Local: $_ip:8080'),
                        const SizedBox(height: 20),
                        QrImageView(
                          data: _qr,
                          size: 250,
                          backgroundColor: Colors.white,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          device!.offline
                              ? 'Sin conexión al servidor. Guardando localmente.'
                              : 'Tablet aprobada y conectada',
                        ),
                        const Text('El QR se actualiza cada 10 segundos.'),
                      ] else ...[
                        const Icon(Icons.phonelink_lock, size: 64),
                        const SizedBox(height: 16),
                        Text(
                          _error != null
                              ? 'No se pudo habilitar el checador'
                              : device?.offline == true
                              ? 'Conecta la tablet para verificar su aprobación'
                              : 'Estado: ${device?.estado ?? 'sin registro'}',
                          style: Theme.of(context).textTheme.titleLarge,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'En el panel web abre Asistencias → Dispositivos móviles. '
                          'Usa este código para aprobar la tablet. Hasta entonces no se recibirán asistencias.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        SelectableText(
                          device?.codigo ?? '',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        if (device?.venceEn != null)
                          Text('Vigencia del código: ${device!.venceEn}'),
                      ],
                      const SizedBox(height: 20),
                      if (device != null) ...[
                        Text(device.nombre),
                        SelectableText(
                          'UUID: ${device.uuid}',
                          textAlign: TextAlign.center,
                        ),
                      ],
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      const SizedBox(height: 12),
                      if (_busy) const LinearProgressIndicator(),
                      TextButton(
                        onPressed: _busy ? null : () => _update(),
                        child: const Text('Consultar estado'),
                      ),
                      if (['vencido', 'rechazado'].contains(device?.estado) ||
                          (_error != null && !active))
                        TextButton(
                          onPressed: _busy ? null : () => _update(renew: true),
                          child: const Text(
                            'Generar nuevo código y solicitar aprobación',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
