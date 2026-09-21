import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:http/http.dart' as http;

class LocalServerService {
  HttpServer? _server;

  /// Inicia el servidor en el puerto 8080
  Future<void> iniciarServidor(String tokenAdministrador) async {
    // Si ya hay un servidor corriendo, lo detenemos antes de crear otro
    detenerServidor();

    final app = Router();

    // Definimos la ruta POST que los celulares de los empleados van a consumir
    app.post('/registrar', (Request request) async {
      try {
        print('--- [SERVER LOCAL] Petición recibida de un empleado ---');
        
        // 1. Leer los datos que mandó el celular del empleado (correo, password, etc.)
        final payloadCuerpo = await request.readAsString();
        final Map<String, dynamic> datosEmpleado = json.decode(payloadCuerpo);

        // 2. Reenviar esos datos al servidor real en Internet (controldeasistenciastec.com)
        final urlBackend = Uri.parse('https://controldeasistenciastec.com/2sis/web/api/asistencias/registrar');
        
        final respuestaBackend = await http.post(
          urlBackend,
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            // Inyectamos el token del administrador si el backend lo requiere
            'Authorization': 'Bearer $tokenAdministrador', 
          },
          body: json.encode({
            'datetime': datosEmpleado['datetime'], // La hora que mandó el empleado
            'deviceId': '541657958', // El ID fijo de esta Tablet
            'employeeNumber': datosEmpleado['employeeNumber'], // El número del empleado que se logueó en su celular
            'serviceKey': '226BRF1JQY', // La llave secreta que solo tiene la tablet
          }),
        );

        // 3. Devolverle la respuesta al celular del empleado
        if (respuestaBackend.statusCode == 200 || respuestaBackend.statusCode == 201) {
          print('--- [SERVER LOCAL] Asistencia registrada con éxito en la nube ---');
          return Response.ok(
            json.encode({'status': 'success', 'mensaje': '¡Asistencia registrada!'}), 
            headers: {'Content-Type': 'application/json'}
          );
        } else {
          print('--- [SERVER LOCAL] Error del backend: ${respuestaBackend.body} ---');
          return Response.internalServerError(
            body: json.encode({'status': 'error', 'mensaje': 'El sistema web rechazó el registro.'}),
            headers: {'Content-Type': 'application/json'}
          );
        }
      } catch (e) {
        return Response.internalServerError(
          body: json.encode({'status': 'error', 'mensaje': 'Fallo de conexión local: $e'}),
          headers: {'Content-Type': 'application/json'}
        );
      }
    });

    // Levantamos el servidor para que escuche en todas las interfaces de red local (Wi-Fi)
    // Usamos el puerto 8080 (puedes cambiarlo si está ocupado)
    _server = await shelf_io.serve(app, InternetAddress.anyIPv4, 8080);
    print('✅ Servidor de la Tablet escuchando en el puerto ${_server!.port}');
  }

  /// Detiene el servidor para liberar memoria
  void detenerServidor() {
    if (_server != null) {
      _server!.close(force: true);
      print('🛑 Servidor local detenido.');
    }
  }

  /// Utilidad para obtener la IP local de la Tablet (Ej: 192.168.1.50)
  Future<String> obtenerIPLocal() async {
    for (var interface in await NetworkInterface.list()) {
      for (var addr in interface.addresses) {
        // Filtramos para obtener la dirección IPv4 de la red Wi-Fi
        if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
          return addr.address;
        }
      }
    }
    return '127.0.0.1'; // IP de respaldo
  }
}