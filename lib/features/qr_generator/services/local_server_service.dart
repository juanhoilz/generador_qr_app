import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import '../../../core/api_config.dart';

class LocalServerService {
  LocalServerService({
    required this.authorize,
    required this.token,
    required this.canSend,
    required this.uuid,
    required this.scope,
    http.Client? client,
    this.database,
  }) : _client = client ?? http.Client();

  final Future<bool> Function() authorize;
  final String Function() token;
  final bool Function() canSend;
  final String uuid;
  final String scope;
  final http.Client _client;
  HttpServer? _server;
  Database? database;
  Timer? _syncTimer;
  bool _syncing = false;
  bool _stopped = false;

  Future<void> _initDB() async {
    if (database != null) return;
    database = await openDatabase(
      join(await getDatabasesPath(), 'asistencias_offline.db'),
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''CREATE TABLE asistencias_pendientes (
          id INTEGER PRIMARY KEY AUTOINCREMENT, employeeNumber TEXT,
          datetime TEXT, device_uuid TEXT, scope TEXT)''');
      },
      onUpgrade: (db, old, version) async {
        if (old < 2) {
          await db.execute(
            'ALTER TABLE asistencias_pendientes ADD COLUMN device_uuid TEXT',
          );
          await db.execute(
            'ALTER TABLE asistencias_pendientes ADD COLUMN scope TEXT',
          );
        }
      },
    );
  }

  Future<void> iniciarServidor() async {
    if (!await authorize()) throw StateError('Tablet sin aprobación.');
    if (_stopped) return;
    await _initDB();
    if (_stopped) return;
    final server = await shelf_io.serve(handler, await obtenerIPLocal(), 8080);
    if (_stopped) {
      await server.close(force: true);
      return;
    }
    _server = server;
    _syncTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(synchronize());
    });
    unawaited(synchronize());
  }

  Handler get handler {
    final router = Router();
    router.post('/registrar', _register);
    return router.call;
  }

  Response _reply(int code, String message) => Response(
    code,
    body: jsonEncode({
      'status': code == 200 ? 'success' : 'error',
      'mensaje': message,
    }),
    headers: {'Content-Type': 'application/json'},
  );

  Future<Response> _register(Request request) async {
    try {
      if (_stopped || !await authorize() || _stopped) {
        return _reply(
          403,
          'La tablet no está autorizada para registrar asistencias.',
        );
      }
      final dynamic data;
      try {
        data = jsonDecode(await request.readAsString());
      } on FormatException {
        return _reply(400, 'Se requiere un objeto JSON válido.');
      }
      if (data is! Map) {
        return _reply(400, 'Se requiere un objeto JSON válido.');
      }
      // La estación aporta su identidad; el teléfono solo entrega el evento.
      if (data.keys.any(
        (key) => key != 'employeeNumber' && key != 'datetime',
      )) {
        return _reply(400, 'Solo se admiten employeeNumber y datetime.');
      }
      if (data['employeeNumber'] is! String ||
          (data['employeeNumber'] as String).trim().isEmpty) {
        return _reply(
          400,
          'employeeNumber es obligatorio y debe ser texto no vacío.',
        );
      }
      if (!_isValidDate(data['datetime'])) {
        return _reply(
          400,
          'datetime es obligatorio y debe ser una fecha válida '
          '(yyyy/MM/dd HH:mm:ss o ISO 8601).',
        );
      }
      final employee = (data['employeeNumber'] as String).trim();
      final date = data['datetime'] as String;
      if (!canSend()) return await _saveOffline(employee, date);
      try {
        final response = await _send(employee, date);
        if (response.statusCode == 200 || response.statusCode == 201) {
          return _reply(200, '¡Asistencia registrada en línea!');
        }
        return _reply(502, _rejectionMessage(response));
      } on SocketException {
        return await _saveOffline(employee, date);
      } on TimeoutException {
        return await _saveOffline(employee, date);
      } on http.ClientException {
        return await _saveOffline(employee, date);
      }
    } catch (_) {
      return _reply(
        503,
        'No se pudo validar o guardar la asistencia. Reintenta.',
      );
    }
  }

  static String _rejectionMessage(http.Response response) {
    final summary =
        'El servidor rechazó la asistencia (HTTP ${response.statusCode}).';
    // Traducir los errores conocidos de PHP sin exponer claves ni datos internos.
    try {
      final body = jsonDecode(response.body);
      dynamic error = body is Map ? body['errorMessage'] : null;
      // AppException puede llegar como JSON serializado dentro de errorMessage.
      if (error is String && error.trimLeft().startsWith('{')) {
        final detail = jsonDecode(error);
        error = detail is Map ? detail['errorMessage'] : null;
      }
      if (response.statusCode == 404 && error is String) {
        if (error.startsWith(
          'No se encontró el personal con numero de empleado:',
        )) {
          return '$summary El número de empleado no existe o está inactivo en '
              'este servidor. Revisa la cuenta del empleado.';
        }
        if (error.startsWith('No se encontró el dispositivo con Id:')) {
          return '$summary La estación móvil no existe o está inactiva. '
              'Revisa su autorización en Dispositivos móviles.';
        }
      }
    } on FormatException {
      // Un proxy o servidor web puede devolver HTML en lugar de JSON.
    }
    if (response.statusCode == 404) {
      return '$summary Verifica la URL de la API y la ruta asistencias/registrar; '
          'la respuesta no identifica un empleado o estación faltante.';
    }
    if (response.statusCode == 401) {
      return '$summary La sesión de la estación no es válida. Inicia sesión nuevamente.';
    }
    if (response.statusCode == 403) {
      return '$summary La estación no está autorizada para enviar checadas. '
          'Revisa su aprobación, responsable y estado activo.';
    }
    if (response.statusCode == 400) {
      return '$summary Verifica los datos de la checada y actualiza la app '
          'al contrato móvil del servidor.';
    }
    return summary;
  }

  static bool _isValidDate(dynamic value) {
    if (value is! String) return false;
    if (!value.contains('/')) return DateTime.tryParse(value) != null;
    final match = RegExp(r'^(\d{4})/(\d{2})/(\d{2}) (\d{2}):(\d{2}):(\d{2})$')
        .firstMatch(value);
    if (match == null) return false;
    final parts = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
    final date = DateTime.utc(
      parts[0],
      parts[1],
      parts[2],
      parts[3],
      parts[4],
      parts[5],
    );
    return date.year == parts[0] &&
        date.month == parts[1] &&
        date.day == parts[2] &&
        date.hour == parts[3] &&
        date.minute == parts[4] &&
        date.second == parts[5];
  }

  Future<http.Response> _send(String employee, String date) => _client
      .post(
        ApiConfig.endpoint('asistencias/registrar'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': 'Bearer ${token()}',
        },
        body: jsonEncode({
          'datetime': date,
          'employeeNumber': employee,
          'deviceId': uuid,
        }),
      )
      .timeout(const Duration(seconds: 4));

  Future<Response> _saveOffline(String employee, String date) async {
    // Verificar de nuevo si la autorización cambió durante el intento de envío.
    if (_stopped || !await authorize() || _stopped) {
      return _reply(403, 'La tablet no está autorizada.');
    }
    await database!.insert('asistencias_pendientes', {
      'employeeNumber': employee,
      'datetime': date,
      'device_uuid': uuid,
      'scope': scope,
    });
    return _reply(200, 'Guardado localmente. Se enviará al volver la red.');
  }

  Future<void> synchronize() async {
    if (_syncing || _stopped || database == null) return;
    _syncing = true;
    try {
      if (!await authorize() || !canSend() || _stopped) return;
      final rows = await database!.query(
        'asistencias_pendientes',
        where: 'device_uuid = ? AND scope = ?',
        whereArgs: [uuid, scope],
        orderBy: 'id',
      );
      for (final row in rows) {
        if (_stopped || !await authorize() || !canSend()) break;
        final response = await _send(
          row['employeeNumber'] as String,
          row['datetime'] as String,
        );
        if (response.statusCode != 200 && response.statusCode != 201) break;
        await database!.delete(
          'asistencias_pendientes',
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
    } catch (_) {
      // Conservar la cola y reintentar en el siguiente ciclo.
    } finally {
      _syncing = false;
    }
  }

  Future<void> detenerServidor() async {
    _stopped = true;
    _syncTimer?.cancel();
    await _server?.close(force: true);
    _server = null;
    _client.close();
  }

  static Future<String> obtenerIPLocal() async {
    for (final interface in await NetworkInterface.list()) {
      for (final addr in interface.addresses) {
        if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
          return addr.address;
        }
      }
    }
    throw StateError(
      'Conecta la tablet a una red local para recibir asistencias.',
    );
  }
}
