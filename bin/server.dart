import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_static/shelf_static.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:saludcuidado_backend/db.dart';
import 'package:saludcuidado_backend/http_util.dart';
import 'package:saludcuidado_backend/rutas/admin.dart';
import 'package:saludcuidado_backend/rutas/api.dart';
import 'package:saludcuidado_backend/rutas/chat.dart';

/// Punto de entrada de la API REST de SaludCuidado.
///
///   dart run bin/server.dart [--puerto 8080] [--db datos/saludcuidado.db]
///                            [--web publico]
///
/// Si la carpeta indicada en --web existe, el mismo servidor sirve ahí la
/// app Flutter Web compilada, además de la API. Se hace así a propósito:
/// un único origen significa que no hay CORS que configurar, una sola URL
/// que dar y un solo contenedor que desplegar. Si la carpeta no existe,
/// el servidor queda como estaba, solo API.
Future<void> main(List<String> args) async {
  final puerto = int.tryParse(_arg(args, '--puerto') ?? '') ??
      int.tryParse(Platform.environment['PUERTO'] ?? '') ??
      8080;
  final rutaDb = _arg(args, '--db') ?? 'datos/saludcuidado.db';
  final rutaWeb =
      _arg(args, '--web') ?? Platform.environment['WEB_DIR'] ?? 'publico';

  stdout.writeln('');
  stdout.writeln('  SaludCuidado API');
  stdout.writeln('  ----------------');
  stdout.writeln('  Base de datos : $rutaDb');

  // El directorio puede no existir en un clon nuevo (la BD está ignorada en
  // git), y sqlite3.open no lo crea: falla con "unable to open database file".
  final carpeta = File(rutaDb).parent;
  if (!carpeta.existsSync()) carpeta.createSync(recursive: true);

  final db = Db.abrir(rutaDb);
  stdout.writeln('  Motor         : SQLite ${sqlite3.version.libVersion}');

  // Primero el router de administración (/api/admin/**) y después el
  // público: Cascade pasa al siguiente cuando el anterior responde 404/405.
  var cascada = Cascade()
      .add(construirAdmin(db).call)
      .add(construirChat(db).call)
      .add(construirApi(db).call);

  // La web va al final: así una ruta /api/** nunca queda tapada por un
  // archivo que se llame igual, y lo que no sea de la API cae en el
  // index.html de Flutter.
  final carpetaWeb = Directory(rutaWeb);
  final hayWeb = carpetaWeb.existsSync();
  if (hayWeb) {
    cascada = cascada.add(
      createStaticHandler(rutaWeb, defaultDocument: 'index.html'),
    );
  }

  final rutas = cascada.handler;

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
  if (hayWeb) {
    stdout.writeln('  App web       : http://localhost:$puerto/  '
        '(desde $rutaWeb)');
  } else {
    stdout.writeln('  App web       : no se sirve (no existe $rutaWeb)');
  }
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
