import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

import '../../auth/views/login_screen.dart';
import '../services/local_server_service.dart'; // Importamos el servidor local

class QrScreen extends StatefulWidget {
  const QrScreen({super.key});

  @override
  State<QrScreen> createState() => _QrScreenState();
}

class _QrScreenState extends State<QrScreen> {
  String _accessToken = "";
  String _numeroEmpleado = "";
  String _qrPayload = "";
  String _ipLocal = ""; // Guardará la IP de la tablet
  
  Timer? _timerRotacion;
  bool _cargando = true;
  bool _offlineMode = false;

  // Instanciamos el servicio del servidor
  final LocalServerService _serverService = LocalServerService();

  @override
  void initState() {
    super.initState();
    _inicializarGafete();
  }

  Future<void> _inicializarGafete() async {
    await _validarEstadoDelToken();
    
    if (_accessToken.isNotEmpty) {
      // 🚀 1. Encendemos el servidor local usando el token del Admin
      _ipLocal = await _serverService.obtenerIPLocal();
      await _serverService.iniciarServidor(_accessToken);

      // 2. Dibujamos el primer código QR
      _actualizarPayloadQR();
      
      // 3. AHORA SÍ quitamos la pantalla de carga
      setState(() {
        _cargando = false;
      });

      // 4. Inicia el cronómetro para cambiar el QR cada 10 segundos
      _timerRotacion = Timer.periodic(const Duration(seconds: 10), (timer) {
        _actualizarPayloadQR();
      });
    }
  }

  Future<void> _validarEstadoDelToken() async {
    final prefs = await SharedPreferences.getInstance();
    final expiresAt = prefs.getInt('expires_at') ?? 0;
    final int tiempoActualEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    setState(() {
      _numeroEmpleado = prefs.getString('numero_empleado') ?? "Desconocido";
    });

    if (tiempoActualEpoch < expiresAt) {
      _accessToken = prefs.getString('access_token') ?? '';
      _offlineMode = true; 
    } else {
      await _refrescarToken(prefs);
    }
  }

  Future<void> _refrescarToken(SharedPreferences prefs) async {
    final refreshToken = prefs.getString('refresh_token');
    final url = Uri.parse('https://controldeasistenciastec.com/2sis/web/api/users/refresh'); 

    try {
      final respuesta = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'refresh_token': refreshToken}),
      );

      if (respuesta.statusCode == 200) {
        final datos = json.decode(respuesta.body);
        await prefs.setString('access_token', datos['access_token']);
        await prefs.setString('refresh_token', datos['refresh_token']);
        await prefs.setInt('expires_at', datos['expires_at']);
        
        _accessToken = datos['access_token'];
        _offlineMode = false;
      } else {
        _cerrarSesionForzada('Tu sesión ha expirado. Inicia sesión nuevamente.');
      }
    } catch (e) {
      _cerrarSesionForzada('Token expirado y no hay conexión a internet para renovarlo.');
    }
  }

  void _actualizarPayloadQR() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      // 🚀 4. AHORA DIBUJAMOS LA IP Y EL PUERTO EN LUGAR DEL TOKEN
      _qrPayload = json.encode({
        'ip': _ipLocal,
        'puerto': 8080,
        'ts': timestamp
      });
    });
  }

  void _cerrarSesionForzada(String mensaje) async {
    _timerRotacion?.cancel();
    _serverService.detenerServidor(); // Apagamos el servidor local
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(mensaje)));
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
    }
  }

  @override
  void dispose() {
    _timerRotacion?.cancel();
    _serverService.detenerServidor(); // Apagamos el servidor local al salir
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Checador Activo'),
        actions: [
          IconButton(icon: const Icon(Icons.logout), onPressed: () => _cerrarSesionForzada('Sesión cerrada'))
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'IP Red Local: $_ipLocal:8080', // Mostramos la IP en pantalla para verificar
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blue),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 20, spreadRadius: 5)],
                    ),
                    child: QrImageView(
                      data: _qrPayload,
                      version: QrVersions.auto,
                      size: 250.0,
                    ),
                  ),
                  const SizedBox(height: 30),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _offlineMode ? Icons.cloud_off : Icons.cloud_done,
                        color: _offlineMode ? Colors.orange : Colors.green,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _offlineMode ? 'Operando sin conexión' : 'Conectado al servidor',
                        style: TextStyle(
                          color: _offlineMode ? Colors.orange : Colors.green,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text('El código se actualiza cada 10 segundos', style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
    );
  }
}