import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_config.dart';

class Session {
  static Future<void> clear(SharedPreferences prefs) async {
    for (final key in [
      'access_token',
      'refresh_token',
      'expires_at',
      'numero_empleado',
      'device_owner',
      'session_api',
    ]) {
      await prefs.remove(key);
    }
  }

  // False significa que la red no permitió renovar, no que se aprobó el token.
  static Future<bool> refreshIfNeeded(SharedPreferences prefs) async {
    if (prefs.getString('session_api') != ApiConfig.baseUrl) {
      throw StateError('Inicia sesión en el servidor configurado.');
    }
    if ((prefs.getInt('expires_at') ?? 0) >
        DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30) {
      return true;
    }
    try {
      final response = await http
          .post(
            ApiConfig.endpoint('users/authentication/refresh-token'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'refresh_token': prefs.getString('refresh_token'),
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        throw StateError(
          'No se pudo renovar la sesión. Inicia sesión nuevamente.',
        );
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      await prefs.setString('access_token', body['access_token'] as String);
      await prefs.setString('refresh_token', body['refresh_token'] as String);
      await prefs.setInt('expires_at', body['expires_at'] as int);
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    } on http.ClientException {
      return false;
    }
  }
}
