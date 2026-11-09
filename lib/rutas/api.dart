import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import '../db.dart';
import '../horarios.dart';
import '../http_util.dart';
import '../seguridad.dart';
import 'json.dart';

/// Define todos los endpoints de la API REST.
///
/// Convenciones:
///   - respuestas JSON con claves en camelCase (lo que consume Flutter)
///   - errores con { "error": { "codigo", "mensaje" } }
///   - rutas protegidas exigen "Authorization: Bearer <token>"
Router construirApi(Db db) {
  final r = Router();

  // ------------------------------------------------------------- salud

  r.get('/api/salud', (Request req) {
    final n = db.raw.select('SELECT COUNT(*) AS n FROM doctores').first['n'];
    return ok({
      'estado': 'activo',
      'servicio': 'SaludCuidado API',
      'version': '1.0.0',
      'motor': 'SQLite ${sqlite3.version.libVersion}',
      'doctores': n,
      'hora': DateTime.now().toIso8601String(),
    });
  });

  // --------------------------------------------------------- autenticacion

  r.post('/api/auth/registro', (Request req) async {
    final cuerpo = await cuerpoJson(req);
    if (cuerpo == null) return peticionInvalida('El cuerpo debe ser JSON.');

    final nombre = (cuerpo['nombre'] as String?)?.trim() ?? '';
    final email = (cuerpo['email'] as String?)?.trim() ?? '';
    final password = (cuerpo['password'] as String?) ?? '';

    // Las mismas validaciones que aplica RegistroScreen en el cliente.
    if (nombre.length < 3) {
      return peticionInvalida('El nombre debe tener al menos 3 caracteres.');
    }
    if (!email.contains('@') || !email.contains('.')) {
      return peticionInvalida('El correo no es válido.');
    }
    if (password.length < 8) {
      return peticionInvalida(
          'La contraseña debe tener al menos 8 caracteres.');
    }

    final id = db.crearUsuario(
        nombre: nombre, email: email, password: password);
    if (id == null) {
      return conflicto('Ya existe una cuenta con ese correo.');
    }

    final token = db.crearSesion(id);
    return creado({
      'token': token,
      'usuario': usuarioJson(db, db.usuarioPorId(id)!),
    });
  });

  r.post('/api/auth/login', (Request req) async {
    final cuerpo = await cuerpoJson(req);
    if (cuerpo == null) return peticionInvalida('El cuerpo debe ser JSON.');

    final email = (cuerpo['email'] as String?)?.trim() ?? '';
    final password = (cuerpo['password'] as String?) ?? '';
    if (email.isEmpty || password.isEmpty) {
      return peticionInvalida('Correo y contraseña son obligatorios.');
    }

    final u = db.usuarioPorEmail(email);
    // Mismo mensaje exista o no el usuario: no se revela qué correos existen.
    if (u == null ||
        !Seguridad.verificar(
            password, u['salt'] as String, u['password_hash'] as String)) {
      return noAutorizado('Correo o contraseña incorrectos.');
    }
    if ((u['activo'] as int) == 0) {
      return noAutorizado('La cuenta está desactivada.');
    }

    final token = db.crearSesion(u['id'] as int);
    return ok({'token': token, 'usuario': usuarioJson(db, u)});
  });

  r.post('/api/auth/logout', (Request req) {
    final cabecera = req.headers['authorization'];
    if (cabecera != null && cabecera.toLowerCase().startsWith('bearer ')) {
      db.cerrarSesion(cabecera.substring(7).trim());
    }
    return ok({'mensaje': 'Sesión cerrada.'});
  });

  r.get('/api/auth/yo', (Request req) {
    final uid = usuarioDe(req);
    if (uid == null) return noAutorizado();
    final u = db.usuarioPorId(uid);
    if (u == null) return noAutorizado();
    return ok({'usuario': usuarioJson(db, u)});
  });

  // -------------------------------------------------------------- doctores

  r.get('/api/doctores', (Request req) {
    final especialidad = req.url.queryParameters['especialidad'];
    final q = req.url.queryParameters['q'];

    final condiciones = <String>['activo = 1'];
    final params = <Object?>[];

    if (especialidad != null &&
        especialidad.isNotEmpty &&
        especialidad.toLowerCase() != 'todas') {
      condiciones.add('especialidad = ?');
      params.add(especialidad);
    }
    if (q != null && q.trim().isNotEmpty) {
      condiciones.add(
          '(nombre LIKE ? OR apellido LIKE ? OR especialidad LIKE ?)');
      final patron = '%${q.trim()}%';
      params.addAll([patron, patron, patron]);
    }

    final filas = db.raw.select(
      'SELECT * FROM doctores WHERE ${condiciones.join(' AND ')} '
      'ORDER BY rating DESC, nombre ASC',
      params,
    );
    return ok({'doctores': filas.map((f) => doctorJson(db, f)).toList()});
  });

  r.get('/api/doctores/<id>', (Request req, String id) {
    final f = db.raw.select('SELECT * FROM doctores WHERE id = ?', [id]);
    if (f.isEmpty) return noEncontrado('No existe el doctor $id.');
    return ok({'doctor': doctorJson(db, f.first)});
  });

  /// Horarios disponibles de un doctor en una fecha.
  /// Trazabilidad: CitaService.obtenerHorariosDisponiblesString(LocalDate).
  r.get('/api/doctores/<id>/horarios', (Request req, String id) {
    final fecha = req.url.queryParameters['fecha'];
    if (fecha == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(fecha)) {
      return peticionInvalida(
          'Indica la fecha en formato YYYY-MM-DD (?fecha=2026-11-10).');
    }
    final existe = db.raw.select('SELECT id FROM doctores WHERE id = ?', [id]);
    if (existe.isEmpty) return noEncontrado('No existe el doctor $id.');

    final disponibles = Horarios.disponibles(db, doctorId: id, fecha: fecha);
    return ok({
      'doctorId': id,
      'fecha': fecha,
      'horarios': disponibles,
      'total': disponibles.length,
    });
  });

  // ------------------------------------------------------------- servicios

  r.get('/api/servicios', (Request req) {
    final filas = db.raw
        .select('SELECT * FROM servicios WHERE activo = 1 ORDER BY nombre');
    return ok({'servicios': filas.map(servicioJson).toList()});
  });

  // ---------------------------------------------------------------- citas

  r.get('/api/citas', (Request req) {
    final uid = usuarioDe(req);
    if (uid == null) return noAutorizado();

    final estado = req.url.queryParameters['estado'];
    final condiciones = <String>['c.usuario_id = ?'];
    final params = <Object?>[uid];
    if (estado != null && estado.isNotEmpty) {
      condiciones.add('c.estado = ?');
      params.add(estado.toUpperCase());
    }

    final filas = db.raw.select('''
      SELECT c.*, s.nombre AS servicio_nombre
      FROM citas c
      LEFT JOIN servicios s ON s.id = c.servicio_id
      WHERE ${condiciones.join(' AND ')}
      ORDER BY c.fecha ASC, c.hora ASC
    ''', params);

    return ok({'citas': filas.map((f) => citaJson(db, f)).toList()});
  });

  r.post('/api/citas', (Request req) async {
    final uid = usuarioDe(req);
    if (uid == null) return noAutorizado();

    final cuerpo = await cuerpoJson(req);
    if (cuerpo == null) return peticionInvalida('El cuerpo debe ser JSON.');

    final doctorId = (cuerpo['doctorId'] as String?)?.trim() ?? '';
    final fecha = (cuerpo['fecha'] as String?)?.trim() ?? '';
    final hora = (cuerpo['hora'] as String?)?.trim() ?? '';
    final servicioId = (cuerpo['servicioId'] as String?)?.trim();
    final notas = (cuerpo['notas'] as String?)?.trim();

    if (doctorId.isEmpty) return peticionInvalida('Falta doctorId.');
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(fecha)) {
      return peticionInvalida('La fecha debe tener formato YYYY-MM-DD.');
    }
    if (!RegExp(r'^\d{2}:\d{2}$').hasMatch(hora)) {
      return peticionInvalida('La hora debe tener formato HH:MM.');
    }

    final doc = db.raw.select('SELECT * FROM doctores WHERE id = ?', [doctorId]);
    if (doc.isEmpty) return noEncontrado('No existe el doctor $doctorId.');

    // Regla portada de CitaService.crearCita(): la hora debe estar disponible.
    if (!Horarios.disponibles(db, doctorId: doctorId, fecha: fecha)
        .contains(hora)) {
      return conflicto(
          'El horario $hora del $fecha ya no está disponible.');
    }

    final id = 'cita-${DateTime.now().millisecondsSinceEpoch}';
    final ahora = DateTime.now().toIso8601String();
    try {
      db.raw.execute('''
        INSERT INTO citas (id, usuario_id, doctor_id, servicio_id, fecha, hora,
                           estado, notas, creada_en)
        VALUES (?,?,?,?,?,?, 'PROGRAMADA', ?, ?)
      ''', [id, uid, doctorId, servicioId, fecha, hora, notas, ahora]);
    } on SqliteException catch (e) {
      // El indice unico parcial protege de reservas simultaneas que pasen
      // la verificacion anterior por una condicion de carrera.
      if (e.resultCode == 19) {
        return conflicto('Ese horario acaba de ser reservado por otra persona.');
      }
      rethrow;
    }

    final creada = db.raw.select('''
      SELECT c.*, s.nombre AS servicio_nombre
      FROM citas c LEFT JOIN servicios s ON s.id = c.servicio_id
      WHERE c.id = ?
    ''', [id]);
    return creado({'cita': citaJson(db, creada.first)});
  });

  /// Cambia el estado de una cita (cancelar / completar).
  /// Trazabilidad: CitaService.cambiarEstadoCita(id, estado).
  r.patch('/api/citas/<id>', (Request req, String id) async {
    final uid = usuarioDe(req);
    if (uid == null) return noAutorizado();

    final cuerpo = await cuerpoJson(req);
    if (cuerpo == null) return peticionInvalida('El cuerpo debe ser JSON.');

    final estado = (cuerpo['estado'] as String?)?.toUpperCase();
    const validos = {'PROGRAMADA', 'COMPLETADA', 'CANCELADA'};
    if (estado == null || !validos.contains(estado)) {
      return peticionInvalida(
          'estado debe ser uno de: ${validos.join(', ')}.');
    }

    final actual =
        db.raw.select('SELECT * FROM citas WHERE id = ? AND usuario_id = ?',
            [id, uid]);
    if (actual.isEmpty) return noEncontrado('No existe la cita $id.');

    db.raw.execute(
      'UPDATE citas SET estado = ?, actualizada_en = ? WHERE id = ?',
      [estado, DateTime.now().toIso8601String(), id],
    );

    final f = db.raw.select('''
      SELECT c.*, s.nombre AS servicio_nombre
      FROM citas c LEFT JOIN servicios s ON s.id = c.servicio_id
      WHERE c.id = ?
    ''', [id]);
    return ok({'cita': citaJson(db, f.first)});
  });

  r.delete('/api/citas/<id>', (Request req, String id) {
    final uid = usuarioDe(req);
    if (uid == null) return noAutorizado();
    final f = db.raw.select(
        'SELECT id FROM citas WHERE id = ? AND usuario_id = ?', [id, uid]);
    if (f.isEmpty) return noEncontrado('No existe la cita $id.');
    db.raw.execute('DELETE FROM citas WHERE id = ?', [id]);
    return ok({'mensaje': 'Cita eliminada.'});
  });

  // --------------------------------------------------------- estadisticas

  r.get('/api/estadisticas', (Request req) {
    final uid = usuarioDe(req);
    if (uid == null) return noAutorizado();

    Map<String, int> conteo() {
      final filas = db.raw.select(
        'SELECT estado, COUNT(*) AS n FROM citas WHERE usuario_id = ? GROUP BY estado',
        [uid],
      );
      final m = {'PROGRAMADA': 0, 'COMPLETADA': 0, 'CANCELADA': 0};
      for (final f in filas) {
        m[f['estado'] as String] = f['n'] as int;
      }
      return m;
    }

    final c = conteo();
    final porEspecialidad = db.raw.select('''
      SELECT d.especialidad AS especialidad, COUNT(*) AS n
      FROM citas c JOIN doctores d ON d.id = c.doctor_id
      WHERE c.usuario_id = ?
      GROUP BY d.especialidad
      ORDER BY n DESC
    ''', [uid]);

    return ok({
      'total': c.values.fold<int>(0, (a, b) => a + b),
      'proximas': c['PROGRAMADA'],
      'completadas': c['COMPLETADA'],
      'canceladas': c['CANCELADA'],
      'porEspecialidad': porEspecialidad
          .map((f) => {
                'especialidad': f['especialidad'],
                'cantidad': f['n'],
              })
          .toList(),
    });
  });

  return r;
}

