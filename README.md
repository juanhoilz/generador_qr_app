# Generador QR: aprobación de tablets

La tablet recibe las asistencias de los teléfonos por `POST /registrar` (puerto 8080).
Antes de habilitar ese servidor o mostrar el QR, debe obtener aprobación del panel web.

## Prueba local

Servidor predeterminado: `http://192.168.1.16/horaexactaapp/web/api`.
Login, renovación, aprobación y envío de asistencias usan la misma base. Las sesiones
anteriores de producción obligan a iniciar sesión de nuevo; no se envían sus tokens al servidor local.

1. Conectar la tablet y los teléfonos a la LAN donde está XAMPP.
2. Ejecutar `flutter run` e iniciar sesión con una cuenta administradora LOCAL vinculada a personal.
3. La app obtiene fabricante/modelo en Android (modelo genérico iPhone/iPad en iOS), genera
   un UUID v4 y un código criptográfico de 8 caracteres. Conserva ambos entre reinicios y logins.
4. Envía `uuid`, `codigo`, `nombre`, `modelo`, `numero_serie: null`, `puerto: 8080` a
   `POST dispositivos-moviles/solicitudes`, con Bearer. El nombre predeterminado es `Tablet <modelo>`.
5. En el panel: **Asistencias → Dispositivos móviles**, abrir la solicitud e introducir el código
   que muestra la tablet para aprobarla. El UUID pertenece al administrador que inició sesión;
   no corresponde a cada empleado que escanea el QR.
6. La tablet consulta `GET dispositivos-moviles/estado?uuid=...` cada 15 segundos y al volver
   a primer plano. Solo `autorizado: true` junto con `estado: aprobado` permite operar.
7. Escanear el QR desde la app del empleado y probar el registro. Apagar el acceso a XAMPP,
   manteniendo la conexión LAN entre teléfono y tablet, registrar otra asistencia y restablecer XAMPP.
   La sincronización se intenta cada minuto y conserva los registros ante errores.

La aprobación confirmada se guarda por UUID, usuario/empleado y URL del servidor. Permite
seguir guardando sin red, incluso cuando el token vence. Al reconectar se renueva la sesión
usando `users/authentication/refresh-token` antes de enviar. Un error HTTP, respuesta inválida,
estado pendiente o rechazo bloquea la operación; no se interpreta como aprobación offline.

Cerrar sesión conserva identidad y aprobación, pero apaga el receptor. Otra cuenta no hereda
esa aprobación. Borrar los datos de la aplicación genera una nueva identidad y requiere aprobación;
el UUID es por instalación y no es un identificador físico inviolable. Android desactiva el backup
para evitar restaurar la misma identidad automáticamente en otro equipo.

Una solicitud pendiente mantiene su código en los reintentos. Si vence (24 h) o se rechaza,
**Generar nuevo código y solicitar aprobación** permite renovarla sin cambiar el UUID.
El vencimiento del código no revoca una aprobación existente.

## Contrato de checada móvil

El teléfono envía únicamente `employeeNumber` y `datetime` a `/registrar`.
La tablet rechaza campos adicionales; la identidad de la estación nunca se toma del teléfono.
Para el envío inmediato y para la sincronización, añade su UUID persistente como `deviceId`
y el Bearer de su responsable. El cuerpo enviado a `POST asistencias/registrar` es:

```json
{
  "employeeNumber": "123",
  "datetime": "2026-10-20 08:00:00",
  "deviceId": "ae487aae-76d4-4d7a-818c-49be54145d33"
}
```

No se envían `serviceKey` ni un segundo campo `uuid` en la checada. El UUID sigue usándose
con su nombre `uuid` en las operaciones de vinculación/consulta de la estación.
PHP obtiene el tipo del catálogo y exige JWT, propiedad, aprobación y equipo activo para móviles.
La aprobación crea una estación de tipo MOVIL en `dispositivos`, sin servicio Java.
Los errores no deben resolverse configurando identificadores de un checador Java.

**Actualización coordinada:** usar el backend unificado y esta versión de la tablet.
PHP rechaza con HTTP 400 las checadas que incluyan el alias antiguo `uuid`, los móviles
que envíen `serviceKey` y el uso de un dispositivo Java con un Bearer móvil.
Las versiones anteriores de la tablet con cuerpos mixtos deben actualizarse.
No cambia el cuerpo de dos campos que ya utiliza `app_asistencia`.

La cola SQLite v2 guarda el UUID y el entorno/usuario de origen para evitar mezclar asistencias.
Las filas v1 existentes se conservan **sin enviarlas automáticamente**, porque no tienen esos datos.
Antes de cambiar de entorno, revisar y migrar esas filas con su origen confirmado; no se deben
atribuir al nuevo servidor local ni a otra cuenta de forma automática.

## Configuración y plataforma

```powershell
flutter run --dart-define=API_BASE_URL=http://192.168.1.16/horaexactaapp/web/api
```

No se utiliza configuración de identificadores o claves Java. `API_BASE_URL` no debe terminar en `/`. Las constantes están en
`lib/core/api_config.dart`. Android permite HTTP exclusivamente para `192.168.1.16` en
`android/app/src/main/res/xml/network_security_config.xml`; actualizar ese dominio si cambia la IP.
Para un entorno publicado utilizar HTTPS y revisar la autenticación de dispositivos con el equipo.

La extracción nativa está implementada para Android e iOS. No solicita permisos de número de serie;
se envía `null`. Los demás destinos Flutter todavía no implementan este canal. La tablet debe
mantener la app activa; no se añadió un servicio Android para recepción permanente en segundo plano.
La IP se toma de la primera interfaz IPv4 disponible: evitar VPN/interfaces adicionales en la prueba.

## Verificación

```powershell
flutter analyze
flutter test
flutter build apk --debug
```

Las pruebas cubren identidad persistente, contrato HTTP, aprobación offline, aislamiento de cuentas,
errores HTTP, UUID incorrecto, renovación de códigos, bloqueo del receptor, recuperación de cola,
rechazo del backend, aislamiento de filas antiguas y pantalla de login. La consulta HTTP real sin
credenciales se verificó contra XAMPP y devolvió JSON 401. La aprobación autenticada y el escaneo
físico requieren una cuenta local y una tablet; no se simularon registros sobre los datos reales.
