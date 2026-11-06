import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:generador_qr_app/features/device/device_registration.dart';
import 'package:generador_qr_app/core/session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'device_owner': '7|22'});
    prefs = await SharedPreferences.getInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          DeviceRegistration.channel,
          (_) async => {'modelo': 'Samsung SM-A546E'},
        );
  });

  Future<DeviceRegistration> device(http.Client client) async {
    final service = DeviceRegistration(prefs, client: client);
    await service.initialize();
    addTearDown(service.close);
    return service;
  }

  http.Response state(String uuid, String status, bool authorized) =>
      http.Response(
        jsonEncode({
          'uuid': uuid,
          'estado': status,
          'autorizado': authorized,
          'vence_en': '2026-10-06T12:00:00-06:00',
        }),
        200,
      );

  test('UUID v4 y código persistentes incluso al cerrar sesión', () async {
    final first = await device(MockClient((_) async => http.Response('', 500)));
    expect(
      first.uuid,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(first.codigo, matches(RegExp(r'^[A-Z0-9]{8}$')));
    await Session.clear(prefs);
    await prefs.setString('device_owner', '7|22');
    final second = await device(
      MockClient((_) async => http.Response('', 500)),
    );
    expect(second.uuid, first.uuid);
    expect(second.codigo, first.codigo);
    expect(first.payload['numero_serie'], isNull);
    expect(first.payload['puerto'], 8080);
  });

  test(
    '404 registra con el contrato PHP y Bearer sin autorizar un 201 pendiente',
    () async {
      late DeviceRegistration service;
      var posts = 0;
      service = await device(
        MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer test-token');
          if (request.method == 'GET') return http.Response('{}', 404);
          posts++;
          expect(jsonDecode(request.body), service.payload);
          return http.Response(state(service.uuid, 'pendiente', false).body, 201);
        }),
      );
      await service.refresh('test-token');
      await service.refresh('test-token');
      expect(posts, 2);
      expect(service.autorizado, isFalse);
    },
  );

  test(
    'aprobación permite offline tras reinicio, otra cuenta no la hereda',
    () async {
      late DeviceRegistration first;
      first = await device(
        MockClient((_) async => state(first.uuid, 'aprobado', true)),
      );
      await first.refresh('token');
      final offline = await device(
        MockClient((_) async => throw http.ClientException('offline')),
      );
      await offline.refresh('token');
      expect(offline.autorizado, isTrue);
      expect(offline.offline, isTrue);
      await prefs.setString('device_owner', '8|23');
      final other = await device(
        MockClient((_) async => throw http.ClientException('offline')),
      );
      await other.refresh('token');
      expect(other.autorizado, isFalse);
    },
  );

  for (final status in [401, 403, 500]) {
    test('HTTP $status no se confunde con modo offline aprobado', () async {
      var fail = false;
      late DeviceRegistration service;
      service = await device(
        MockClient(
          (_) async => fail
              ? http.Response('{}', status)
              : state(service.uuid, 'aprobado', true),
        ),
      );
      await service.refresh('token');
      fail = true;
      await expectLater(
        service.refresh('token'),
        throwsA(isA<DeviceApiException>()),
      );
      expect(service.autorizado, isFalse);
      expect(prefs.getBool(service.cacheKey), isFalse);
    });
  }

  test('respuesta de otro UUID no autoriza', () async {
    final service = await device(
      MockClient((_) async => state('otro', 'aprobado', true)),
    );
    await expectLater(service.refresh('token'), throwsFormatException);
    expect(service.autorizado, isFalse);
  });

  test(
    'renovar pendiente no cambia el código ni envía otra solicitud',
    () async {
      late DeviceRegistration service;
      service = await device(
        MockClient((request) async {
          expect(request.method, 'GET');
          return state(service.uuid, 'pendiente', false);
        }),
      );
      final original = service.codigo;
      await service.refresh('token', renew: true);
      expect(service.codigo, original);
    },
  );

  test('vencido se renueva con otro código y conserva UUID', () async {
    late DeviceRegistration service;
    service = await device(
      MockClient(
        (request) async => state(
          service.uuid,
          request.method == 'GET' ? 'vencido' : 'pendiente',
          false,
        ),
      ),
    );
    final original = service.codigo;
    final uuid = service.uuid;
    await service.refresh('token', renew: true);
    expect(service.codigo, isNot(original));
    expect(service.uuid, uuid);
    expect(service.estado, 'pendiente');
  });
}
