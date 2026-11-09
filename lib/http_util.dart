import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'db.dart';

/// Respuestas JSON uniformes y middleware compartido.

const _cabeceras = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
};

Response ok(Object? datos, {int estado = 200}) => Response(
      estado,
      body: jsonEncode(datos),
      headers: _cabeceras,
    );

Response creado(Object? datos) => ok(datos, estado: 201);

/// Error en formato uniforme: { "error": { "codigo", "mensaje" } }
Response error(int estado, String codigo, String mensaje) => Response(
      estado,
      body: jsonEncode({
        'error': {'codigo': codigo, 'mensaje': mensaje}
      }),
      headers: _cabeceras,
    );

Response noEncontrado(String mensaje) =>
    error(404, 'no_encontrado', mensaje);

Response peticionInvalida(String mensaje) =>
    error(400, 'peticion_invalida', mensaje);

Response noAutorizado([String mensaje = 'Credenciales requeridas o inválidas']) =>
    error(401, 'no_autorizado', mensaje);

Response conflicto(String mensaje) => error(409, 'conflicto', mensaje);

/// Lee y decodifica el cuerpo JSON. Devuelve null si no es un objeto valido.
Future<Map<String, dynamic>?> cuerpoJson(Request req) async {
  try {
    final texto = await req.readAsString();
    if (texto.trim().isEmpty) return <String, dynamic>{};
    final v = jsonDecode(texto);
    return v is Map<String, dynamic> ? v : null;
  } catch (_) {
    return null;
  }
}

// ------------------------------------------------------------------ CORS

const _corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET, POST, PATCH, PUT, DELETE, OPTIONS',
  'access-control-allow-headers': 'Origin, Content-Type, Authorization, Accept',
  'access-control-max-age': '86400',
};

/// Permite que la app Flutter Web consuma la API desde otro puerto.
Middleware cors() => (innerHandler) {
      return (Request req) async {
        if (req.method == 'OPTIONS') {
          return Response.ok('', headers: _corsHeaders);
        }
        final res = await innerHandler(req);
        return res.change(headers: {...res.headers, ..._corsHeaders});
      };
    };

// -------------------------------------------------------------- registro

/// Traza cada peticion con su metodo, ruta, estado y duracion.
Middleware trazar() => (innerHandler) {
      return (Request req) async {
        final inicio = DateTime.now();
        final res = await innerHandler(req);
        final ms = DateTime.now().difference(inicio).inMilliseconds;
        final marca = inicio.toIso8601String().substring(11, 19);
        // ignore: avoid_print
        print('[$marca] ${req.method.padRight(6)} /${req.url.path} '
            '-> ${res.statusCode} (${ms}ms)');
        return res;
      };
    };

// ---------------------------------------------------------------- errores

/// Convierte cualquier excepcion no controlada en un 500 con formato JSON,
/// en vez de dejar caer la conexion.
Middleware capturarErrores() => (innerHandler) {
      return (Request req) async {
        try {
          return await innerHandler(req);
        } catch (e, s) {
          // ignore: avoid_print
          print('ERROR no controlado en /${req.url.path}: $e\n$s');
          return error(500, 'error_interno',
              'Ocurrió un error inesperado procesando la solicitud.');
        }
      };
    };

// ------------------------------------------------------------ autenticacion

/// Clave con la que se guarda el id de usuario en el contexto de la peticion.
const claveUsuario = 'usuarioId';

/// Extrae el token "Authorization: Bearer <token>" y resuelve el usuario.
/// No rechaza la peticion: solo anota el usuario si el token es valido.
Middleware autenticacion(Db db) => (innerHandler) {
      return (Request req) async {
        final cabecera = req.headers['authorization'];
        if (cabecera != null && cabecera.toLowerCase().startsWith('bearer ')) {
          final token = cabecera.substring(7).trim();
          final uid = db.usuarioDeSesion(token);
          if (uid != null) {
            return innerHandler(req.change(context: {claveUsuario: uid}));
          }
        }
        return innerHandler(req);
      };
    };

/// Devuelve el usuario autenticado de la peticion, o null.
int? usuarioDe(Request req) => req.context[claveUsuario] as int?;
