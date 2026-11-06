import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:sqflite/sqflite.dart';
import 'package:generador_qr_app/features/qr_generator/services/local_server_service.dart';

class MemoryDatabase implements Database {
  final rows = <Map<String, Object?>>[];
  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    rows.add({'id': rows.length + 1, ...values});
    return rows.length;
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    return rows
        .where(
          (r) =>
              r['device_uuid'] == whereArgs![0] && r['scope'] == whereArgs[1],
        )
        .toList();
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    rows.removeWhere((r) => r['id'] == whereArgs![0]);
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late MemoryDatabase db;
  late LocalServerService service;
  var approved = false;
  var connected = false;
  var sends = 0;
  var status = 200;
  var responseBody = '{}';
  late List<Map<String, dynamic>> sentBodies;
  setUp(() {
    approved = false;
    connected = false;
    sends = 0;
    status = 200;
    responseBody = '{}';
    sentBodies = [];
    db = MemoryDatabase();
    service = LocalServerService(
      authorize: () async => approved,
      token: () => 'token',
      canSend: () => connected,
      uuid: 'tablet',
      scope: 'local|owner',
      database: db,
      client: MockClient((request) async {
        sends++;
        sentBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(
          body.keys,
          unorderedEquals(['employeeNumber', 'datetime', 'deviceId']),
        );
        expect(body['deviceId'], 'tablet');
        expect(request.headers['Authorization'], 'Bearer token');
        return http.Response(
          responseBody,
          status,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
  });
  tearDown(() => service.detenerServidor());
  Future<Response> register([String? body]) async => service.handler(
    Request(
      'POST',
      Uri.parse('http://localhost/registrar'),
      body:
          body ??
          jsonEncode({
            'employeeNumber': '123',
            'datetime': '2026-10-05T10:00:00',
          }),
    ),
  );

  test(
    'el teléfono no puede aportar ni reemplazar la identidad de estación',
    () async {
      approved = true;
      for (final online in [false, true]) {
        connected = online;
        for (final key in [
          'deviceId',
          'uuid',
          'serviceKey',
          'tipo_dispositivo',
        ]) {
          final response = await register(
            jsonEncode({
              'employeeNumber': '123',
              'datetime': '2026-10-05T10:00:00',
              key: 'otra-estacion',
            }),
          );
          expect(response.statusCode, 400);
        }
      }
      expect(db.rows, isEmpty);
      expect(sends, 0);
    },
  );
  test(
    'envío inmediato y sincronización usan la misma identidad móvil',
    () async {
      approved = true;
      await register();
      connected = true;
      await service.synchronize();
      await register();
      expect(sentBodies, hasLength(2));
      expect(sentBodies.first, sentBodies.last);
      expect(sentBodies.first, {
        'employeeNumber': '123',
        'datetime': '2026-10-05T10:00:00',
        'deviceId': 'tablet',
      });
    },
  );
  test('sin aprobación bloquea envío y almacenamiento offline', () async {
    expect((await register()).statusCode, 403);
    expect(db.rows, isEmpty);
    expect(sends, 0);
  });
  test(
    'identifica rechazos 404 de PHP sin guardar ni exponer valores',
    () async {
      approved = true;
      connected = true;
      status = 404;
      final cases = {
        'No se encontró el personal con numero de empleado: secreto':
            'Revisa la cuenta del empleado',
        'No se encontró el dispositivo con Id: secreto': 'Dispositivos móviles',
      };
      for (final entry in cases.entries) {
        for (final error in [
          entry.key,
          jsonEncode({'errorMessage': entry.key}),
        ]) {
          responseBody = jsonEncode({'errorMessage': error});
          final response = await register();
          expect(response.statusCode, 502);
          final message = jsonDecode(await response.readAsString())['mensaje'];
          expect(message, contains(entry.value));
          expect(message, isNot(contains('secreto')));
        }
      }
      expect(db.rows, isEmpty);
    },
  );
  test('404 HTML o JSON desconocido conserva el rechazo sin guardar', () async {
    approved = true;
    connected = true;
    status = 404;
    for (final body in ['<html>Not found</html>', '{}', 'null']) {
      responseBody = body;
      final response = await register();
      expect(response.statusCode, 502);
      expect(
        jsonDecode(await response.readAsString())['mensaje'],
        contains('Verifica la URL'),
      );
    }
    expect(db.rows, isEmpty);
  });
  test('aprobado guarda offline y sincroniza al recuperar red', () async {
    approved = true;
    expect((await register()).statusCode, 200);
    expect(db.rows.single['device_uuid'], 'tablet');
    expect(sends, 0);
    connected = true;
    await service.synchronize();
    expect(db.rows, isEmpty);
    expect(sends, 1);
  });
  test('denegación posterior bloquea sincronización sin borrar cola', () async {
    approved = true;
    await register();
    approved = false;
    connected = true;
    await service.synchronize();
    expect(db.rows, hasLength(1));
    expect(sends, 0);
  });
  test('rechazo HTTP conserva la cola', () async {
    approved = true;
    await register();
    connected = true;
    status = 401;
    await service.synchronize();
    expect(db.rows, hasLength(1));
    expect(sends, 1);
  });
  test('no envía filas antiguas sin identidad ni de otro entorno', () async {
    approved = true;
    connected = true;
    db.rows.addAll([
      {'id': 1},
      {'id': 2, 'device_uuid': 'tablet', 'scope': 'production'},
    ]);
    await service.synchronize();
    expect(sends, 0);
    expect(db.rows, hasLength(2));
  });
  test('JSON inválido se rechaza con 400 y no se guarda', () async {
    approved = true;
    expect((await register('{')).statusCode, 400);
    expect((await register('{}')).statusCode, 400);
    expect(db.rows, isEmpty);
  });
  test('acepta fecha con diagonales y la reenvía sin cambiarla', () async {
    approved = true;
    connected = true;
    final response = await register(
      jsonEncode({'employeeNumber': '4', 'datetime': '2026/09/07 11:20:50'}),
    );
    expect(response.statusCode, 200);
    expect(sentBodies.single['employeeNumber'], '4');
    expect(sentBodies.single['datetime'], '2026/09/07 11:20:50');
  });
  test('fecha con diagonales se conserva offline y al sincronizar', () async {
    approved = true;
    expect(
      (await register(
        jsonEncode({'employeeNumber': '4', 'datetime': '2026/09/07 11:20:50'}),
      )).statusCode,
      200,
    );
    expect(db.rows.single['datetime'], '2026/09/07 11:20:50');
    connected = true;
    await service.synchronize();
    expect(sentBodies.single['datetime'], '2026/09/07 11:20:50');
    expect(db.rows, isEmpty);
  });
  test('fechas con diagonales inválidas no se envían ni guardan', () async {
    approved = true;
    connected = true;
    for (final date in [
      null,
      123,
      '',
      '2026/02/30 11:20:50',
      '2026/09/07 24:00:00',
      '2026/13/07 11:20:50',
      '07/09/2026 11:20:50',
    ]) {
      final response = await register(
        jsonEncode({'employeeNumber': '4', 'datetime': date}),
      );
      expect(response.statusCode, 400);
      expect(
        jsonDecode(await response.readAsString())['mensaje'],
        contains('datetime'),
      );
    }
    expect(sends, 0);
    expect(db.rows, isEmpty);
  });
  test('error identifica employeeNumber ausente o inválido', () async {
    approved = true;
    for (final employee in [null, 4, '   ']) {
      final response = await register(
        jsonEncode({
          'employeeNumber': employee,
          'datetime': '2026/09/07 11:20:50',
        }),
      );
      expect(response.statusCode, 400);
      expect(
        jsonDecode(await response.readAsString())['mensaje'],
        contains('employeeNumber'),
      );
    }
    expect(sends, 0);
    expect(db.rows, isEmpty);
  });
}
