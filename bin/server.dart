import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:sqlite3/sqlite3.dart';

import 'package:saludcuidado_backend/db.dart';
import 'package:saludcuidado_backend/http_util.dart';
import 'package:saludcuidado_backend/rutas/admin.dart';
import 'package:saludcuidado_backend/rutas/api.dart';

/// Punto de entrada de la API REST de SaludCuidado.
///
///   dart run bin/server.dart [--puerto 8080] [--db datos/saludcuidado.db]
Future<void> main(List<String> args) async {
  final puerto = int.tryParse(_arg(args, '--puerto') ?? '') ??
      int.tryParse(Platform.environment['PUERTO'] ?? '') ??
      8080;
  final rutaDb = _arg(args, '--db') ?? 'datos/saludcuidado.db';

  stdout.writeln('');
  stdout.writeln('  SaludCuidado API');
  stdout.writeln('  ----------------');
  stdout.writeln('  Base de datos : $rutaDb');

  final db = Db.abrir(rutaDb);
  stdout.writeln('  Motor         : SQLite ${sqlite3.version.libVersion}');

  // Primero el router de administración (/api/admin/**) y después el
  // público: Cascade pasa al siguiente cuando el anterior responde 404/405.
  final rutas = Cascade()
      .add(construirAdmin(db).call)
      .add(construirApi(db).call)
      .handler;

  final manejador = const Pipeline()
      .addMiddleware(capturarErrores())
      .addMiddleware(trazar())
      .addMiddleware(cors())
      .addMiddleware(autenticacion(db))
      .addHandler(rutas);

  final servidor = await io.serve(manejador, InternetAddress.anyIPv4, puerto);
  servidor.autoCompress = true;

  stdout.writeln('  Escuchando    : http://localhost:$puerto');
  stdout.writeln('  Comprobación  : http://localhost:$puerto/api/salud');
  stdout.writeln('');
  stdout.writeln('  Cuentas de prueba:');
  stdout.writeln('    brandon@saludcuidado.com / demo1234');
  stdout.writeln('    admin@saludcuidado.com   / admin123');
  stdout.writeln('');

  // Cierre ordenado: se libera la base de datos antes de salir.
  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\n  Cerrando servidor...');
    await servidor.close(force: true);
    db.cerrar();
    exit(0);
  });
}

String? _arg(List<String> args, String nombre) {
  final i = args.indexOf(nombre);
  if (i == -1 || i + 1 >= args.length) return null;
  return args[i + 1];
}
