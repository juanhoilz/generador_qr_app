import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class LocalServerService {
  HttpServer? _server;
  Database? _database;
  Timer? _syncTimer;
  String _tokenAdministrador = '';

  /// 1. INICIALIZAR LA BASE DE DATOS SQLITE (MODO OFFLINE)
  Future<void> _initDB() async {
    if (_database != null) return;
    
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'asistencias_offline.db');

    _database = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE asistencias_pendientes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            employeeNumber TEXT,
            datetime TEXT
          )
        ''');
      },
    );
    print('🗄️ Base de datos local (SQLite) lista.');
  }

  /// 2. INICIAR EL SERVIDOR EN LA TABLET
  Future<void> iniciarServidor(String tokenAdministrador) async {
    detenerServidor(); // Si ya hay un servidor corriendo, lo detenemos
    
    _tokenAdministrador = tokenAdministrador;
    await _initDB(); 

    final app = Router();

    // Ruta POST que los celulares de los empleados van a consumir
    app.post('/registrar', (Request request) async {
      // ⚠️ LEEMOS EL CUERPO UNA SOLA VEZ FUERA DEL TRY-CATCH
      final payloadCuerpo = await request.readAsString();
      final Map<String, dynamic> datosEmpleado = json.decode(payloadCuerpo);
      
      final String numEmpleado = datosEmpleado['employeeNumber'];
      final String horaAsistencia = datosEmpleado['datetime'];

      print('--- [SERVER LOCAL] Petición de empleado $numEmpleado recibida ---');

      try {
        final urlBackend = Uri.parse('https://controldeasistenciastec.com/2sis/web/api/asistencias/registrar');
        
        final respuestaBackend = await http.post(
          urlBackend,
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'Authorization': 'Bearer $_tokenAdministrador',
          },
          body: json.encode({
            'datetime': horaAsistencia,
            'deviceId': '541657958', // El ID fijo de esta Tablet
            'employeeNumber': numEmpleado,
            'serviceKey': '226BRF1JQY', // Llave secreta del backend
          }),
        ).timeout(const Duration(seconds: 4)); 

        if (respuestaBackend.statusCode == 200 || respuestaBackend.statusCode == 201) {
          print('✅ [SERVER LOCAL] Asistencia registrada directo en la nube.');
          return Response.ok(
            json.encode({'status': 'success', 'mensaje': '¡Asistencia registrada en línea!'}),
            headers: {'Content-Type': 'application/json'}
          );
        } else {
          print('❌ [SERVER LOCAL] Error del backend: ${respuestaBackend.body}');
          return Response.internalServerError(
            body: json.encode({'status': 'error', 'mensaje': 'El sistema web rechazó el registro.'}),
            headers: {'Content-Type': 'application/json'}
          );
        }

      } on SocketException catch (_) {
        // ERROR: NO HAY INTERNET. Rescatamos los datos.
        return await _procesarYGuardarOffline(numEmpleado, horaAsistencia);
      } on TimeoutException catch (_) {
        // ERROR: INTERNET MUY LENTO. Rescatamos los datos.
        return await _procesarYGuardarOffline(numEmpleado, horaAsistencia);
      } catch (e) {
        return Response.internalServerError(
          body: json.encode({'status': 'error', 'mensaje': 'Fallo de conexión local: $e'}),
          headers: {'Content-Type': 'application/json'}
        );
      }
    });

    // AISLAR EL SERVIDOR SOLO AL WI-FI
    final ipWifi = await obtenerIPLocal();
    _server = await shelf_io.serve(app.call, ipWifi, 8080);
    print('✅ Servidor de la Tablet escuchando exclusivamente en la IP Wi-Fi: $ipWifi:${_server!.port}');

    // INICIAR EL CRONÓMETRO DE SINCRONIZACIÓN
    _syncTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      _sincronizarPendientes();
    });
  }

  /// 3. FUNCIÓN PARA GUARDAR EN SQLITE
  Future<Response> _procesarYGuardarOffline(String numEmpleado, String horaAsistencia) async {
    print('⚠️ SIN INTERNET. Guardando empleado $numEmpleado en base de datos local...');
    
    await _database!.insert('asistencias_pendientes', {
      'employeeNumber': numEmpleado,
      'datetime': horaAsistencia
    });
    
    // Devolvemos un éxito al celular del empleado para que el usuario no vea errores
    return Response.ok(
      json.encode({'status': 'success', 'mensaje': 'Guardado localmente. Se enviará al volver la red.'}),
      headers: {'Content-Type': 'application/json'}
    );
  }

  /// 4. FUNCIÓN PARA ENVIAR LA COLA AL BACKEND
  Future<void> _sincronizarPendientes() async {
    if (_database == null) return;

    final List<Map<String, dynamic>> pendientes = await _database!.query('asistencias_pendientes');
    
    if (pendientes.isEmpty) return; 

    print('🔄 Intentando sincronizar ${pendientes.length} asistencias pendientes de la memoria...');
    final urlBackend = Uri.parse('https://controldeasistenciastec.com/2sis/web/api/asistencias/registrar');

    for (var fila in pendientes) {
      try {
        final respuesta = await http.post(
          urlBackend,
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'Authorization': 'Bearer $_tokenAdministrador',
          },
          body: json.encode({
            'datetime': fila['datetime'],
            'deviceId': '541657958',
            'employeeNumber': fila['employeeNumber'],
            'serviceKey': '226BRF1JQY',
          }),
        ).timeout(const Duration(seconds: 4));

        if (respuesta.statusCode == 200 || respuesta.statusCode == 201) {
          // Borramos de la memoria local si el backend lo aceptó
          await _database!.delete(
            'asistencias_pendientes',
            where: 'id = ?',
            whereArgs: [fila['id']],
          );
          print('✅ Asistencia offline del empleado ${fila['employeeNumber']} sincronizada a la nube.');
        }
      } catch (e) {
        // Sigue sin haber internet, cancelamos el ciclo actual
        print('❌ Falló la sincronización. Se reintentará en 1 minuto.');
        break; 
      }
    }
  }

  /// Detiene el servidor y el temporizador
  void detenerServidor() {
    _syncTimer?.cancel();
    if (_server != null) {
      _server!.close(force: true);
      print('🛑 Servidor local detenido.');
    }
  }

  /// Obtiene la IP local de la Tablet
  Future<String> obtenerIPLocal() async {
    for (var interface in await NetworkInterface.list()) {
      for (var addr in interface.addresses) {
        if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
          return addr.address;
        }
      }
    }
    return '127.0.0.1';
  }
}