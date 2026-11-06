import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api_config.dart';

class DeviceApiException implements Exception {
  final int status;
  final String message;
  DeviceApiException(this.status, this.message);
  @override
  String toString() => message;
}

class DeviceRegistration {
  DeviceRegistration(this.prefs, {http.Client? client})
    : client = client ?? http.Client();

  final SharedPreferences prefs;
  final http.Client client;
  static const channel = MethodChannel('generador_qr_app/device');
  String uuid = '';
  String codigo = '';
  String nombre = '';
  String modelo = '';
  String estado = 'sin_registro';
  String? venceEn;
  bool autorizado = false;
  bool offline = false;
  String get scope =>
      '${ApiConfig.baseUrl}|${prefs.getString('device_owner')}|$uuid';
  String get cacheKey => 'device_approval:$scope';

  static String newCode() {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();
    return List.generate(
      8,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  static String newUuid() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> initialize() async {
    uuid = prefs.getString('device_uuid') ?? newUuid();
    await prefs.setString('device_uuid', uuid);
    codigo = prefs.getString('device_code') ?? newCode();
    await prefs.setString('device_code', codigo);
    final info = await channel.invokeMapMethod<String, dynamic>('info');
    modelo = info?['modelo'] as String? ?? '';
    if (modelo.isEmpty) {
      throw StateError('No se pudo obtener el modelo del equipo.');
    }
    nombre = prefs.getString('device_name') ?? 'Tablet $modelo';
    if (nombre.length > 150) nombre = nombre.substring(0, 150);
    if (modelo.length > 100) modelo = modelo.substring(0, 100);
    if (prefs.getString('device_owner') == null) {
      throw StateError('Inicia sesión nuevamente para vincular este equipo.');
    }
    autorizado = prefs.getBool(cacheKey) ?? false;
  }

  Map<String, Object?> get payload => {
    'uuid': uuid,
    'codigo': codigo,
    'nombre': nombre,
    'modelo': modelo,
    'numero_serie': null,
    'puerto': 8080,
  };

  Future<void> refresh(String token, {bool renew = false}) async {
    offline = false;
    try {
      // Consultar antes de reenviar evita renovar una solicitud resuelta.
      try {
        await _request(token);
        if (renew && ['rechazado', 'vencido'].contains(estado)) {
          codigo = newCode();
          await prefs.setString('device_code', codigo);
          await _request(token, register: true);
        }
      } on DeviceApiException catch (e) {
        if (e.status != 404) rethrow;
        await _setAuthorized(false);
        if (renew) {
          codigo = newCode();
          await prefs.setString('device_code', codigo);
        }
        await _request(token, register: true);
      }
    } on SocketException {
      offline = true;
      // Solo una aprobación confirmada previamente admite trabajo offline.
    } on TimeoutException {
      offline = true;
    } on http.ClientException {
      offline = true;
    } catch (_) {
      await _setAuthorized(false);
      rethrow;
    }
  }

  Future<void> _request(String token, {bool register = false}) async {
    final headers = {
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    final response =
        await (register
                ? client.post(
                    ApiConfig.endpoint('dispositivos-moviles/solicitudes'),
                    headers: headers,
                    body: jsonEncode(payload),
                  )
                : client.get(
                    ApiConfig.endpoint('dispositivos-moviles/estado')
                        .replace(queryParameters: {'uuid': uuid}),
                    headers: headers,
                  ))
            .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200 && response.statusCode != 201) {
      String message =
          'Error HTTP ${response.statusCode} al validar el equipo.';
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['message'] is String) message = body['message'];
      } on FormatException {
        /* Puede venir HTML de Apache. */
      }
      throw DeviceApiException(response.statusCode, message);
    }
    final body = jsonDecode(response.body);
    if (body is! Map ||
        body['uuid'] != uuid ||
        body['autorizado'] is! bool ||
        ![
          'pendiente',
          'aprobado',
          'rechazado',
          'vencido',
        ].contains(body['estado']) ||
        (body['autorizado'] == true && body['estado'] != 'aprobado')) {
      throw const FormatException('Respuesta de aprobación inválida.');
    }
    estado = body['estado'] as String;
    venceEn = body['vence_en'] as String?;
    await _setAuthorized(body['autorizado'] == true && estado == 'aprobado');
  }

  Future<void> _setAuthorized(bool value) async {
    autorizado = value;
    await prefs.setBool(cacheKey, value);
  }

  void close() => client.close();

  Future<void> invalidate() => _setAuthorized(false);
}
