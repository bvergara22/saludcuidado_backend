import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import '../db.dart';
import '../http_util.dart';
import 'json.dart';

/// API de administración.
///
/// TRAZABILIDAD: equivale a `AdminController.java` + `UsuarioController.java`
/// del proyecto web, incluida la regla de acceso de `SecurityConfig.java`:
///
///   .requestMatchers("/admin/**").hasAuthority("ROLE_ADMIN")
///
/// Aquí ese control lo hace [_exigirAdmin]: toda ruta de este router
/// comprueba que la sesión pertenezca a un usuario con `ROLE_ADMIN`, y
/// responde 403 si no. No alcanza con estar autenticado.
Router construirAdmin(Db db) {
  final r = Router();

  /// Devuelve null si el usuario de la sesión es administrador; si no,
  /// devuelve la respuesta de error que corresponde.
  Response? _exigirAdmin(Request req) {
    final uid = usuarioDe(req);
    if (uid == null) return noAutorizado();
    if (!db.rolesDe(uid).contains('ROLE_ADMIN')) {
      return error(403, 'prohibido',
          'Esta sección es solo para administradores.');
    }
    return null;
  }

  // ------------------------------------------------------------- resumen

  /// Datos del tablero. Equivale a `AdminController.getDatosDashboard()`.
  r.get('/api/admin/resumen', (Request req) {
    final vetado = _exigirAdmin(req);
    if (vetado != null) return vetado;

    // Totales por estado (de TODAS las citas, no solo las del usuario).
    final conteo = {'PROGRAMADA': 0, 'COMPLETADA': 0, 'CANCELADA': 0};
    for (final f
        in db.raw.select('SELECT estado, COUNT(*) AS n FROM citas GROUP BY estado')) {
      conteo[f['estado'] as String] = f['n'] as int;
    }

    // Citas por mes de los últimos 6 meses, para la gráfica de barras.
    final hoy = DateTime.now();
    final meses = <Map<String, dynamic>>[];
    for (var i = 5; i >= 0; i--) {
      final m = DateTime(hoy.year, hoy.month - i, 1);
      final clave = '${m.year.toString().padLeft(4, '0')}-'
          '${m.month.toString().padLeft(2, '0')}';
      final n = db.raw.select(
        "SELECT COUNT(*) AS n FROM citas WHERE substr(fecha, 1, 7) = ?",
        [clave],
      ).first['n'] as int;
      meses.add({'mes': clave, 'total': n});
    }

    // Doctores con más citas, para la gráfica de dona.
    final populares = db.raw.select('''
      SELECT d.id AS id, d.titulo AS titulo, d.nombre AS nombre,
             d.apellido AS apellido, d.especialidad AS especialidad,
             d.color AS color, COUNT(c.id) AS total
      FROM doctores d LEFT JOIN citas c ON c.doctor_id = d.id
      GROUP BY d.id
      ORDER BY total DESC, d.nombre
    ''').map((f) => {
          'id': f['id'],
          'nombre': '${f['titulo']} ${f['nombre']} ${f['apellido']}',
          'especialidad': f['especialidad'],
          'color': f['color'],
          'total': f['total'],
        }).toList();

    int cuenta(String sql) => db.raw.select(sql).first['n'] as int;

    return ok({
      'citas': {
        'total': conteo.values.fold<int>(0, (a, b) => a + b),
        'programadas': conteo['PROGRAMADA'],
        'completadas': conteo['COMPLETADA'],
        'canceladas': conteo['CANCELADA'],
      },
      'totales': {
        'usuarios': cuenta('SELECT COUNT(*) AS n FROM usuarios'),
        'usuariosActivos':
            cuenta('SELECT COUNT(*) AS n FROM usuarios WHERE activo = 1'),
        'doctores': cuenta('SELECT COUNT(*) AS n FROM doctores'),
        'servicios': cuenta('SELECT COUNT(*) AS n FROM servicios'),
      },
      'citasPorMes': meses,
      'doctoresPopulares': populares,
    });
  });

  // --------------------------------------------------------------- citas

  /// Todas las citas, con filtros. Equivale a `/admin/citas/filtrar` y
  /// `/admin/citas/buscar` del controlador web, en un solo endpoint.
  ///
  /// `rango`  = hoy | semana | mes (opcional)
  /// `estado` = PROGRAMADA | COMPLETADA | CANCELADA (opcional)
  /// `q`      = texto libre: paciente, correo, doctor o especialidad
  r.get('/api/admin/citas', (Request req) {
    final vetado = _exigirAdmin(req);
    if (vetado != null) return vetado;

    final p = req.url.queryParameters;
    final condiciones = <String>[];
    final valores = <Object?>[];

    final estado = p['estado']?.trim().toUpperCase();
    if (estado != null && estado.isNotEmpty && estado != 'TODAS') {
      condiciones.add('c.estado = ?');
      valores.add(estado);
    }

    final rango = p['rango']?.trim().toLowerCase();
    if (rango != null && rango.isNotEmpty && rango != 'todas') {
      final hoy = DateTime.now();
      String iso(DateTime d) =>
          '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      switch (rango) {
        case 'hoy':
          condiciones.add('c.fecha = ?');
          valores.add(iso(hoy));
        case 'semana':
          condiciones.add('c.fecha BETWEEN ? AND ?');
          valores..add(iso(hoy))..add(iso(hoy.add(const Duration(days: 7))));
        case 'mes':
          condiciones.add("substr(c.fecha, 1, 7) = ?");
          valores.add('${hoy.year.toString().padLeft(4, '0')}-'
              '${hoy.month.toString().padLeft(2, '0')}');
      }
    }

    final q = p['q']?.trim();
    if (q != null && q.isNotEmpty) {
      condiciones.add('''(
        u.nombre LIKE ? OR u.apellido LIKE ? OR u.email LIKE ?
        OR d.nombre LIKE ? OR d.apellido LIKE ? OR d.especialidad LIKE ?
      )''');
      final like = '%$q%';
      for (var i = 0; i < 6; i++) {
        valores.add(like);
      }
    }

    final donde =
        condiciones.isEmpty ? '' : 'WHERE ${condiciones.join(' AND ')}';
    final filas = db.raw.select('''
      SELECT c.* FROM citas c
      JOIN usuarios u ON u.id = c.usuario_id
      JOIN doctores d ON d.id = c.doctor_id
      $donde
      ORDER BY c.fecha DESC, c.hora DESC
    ''', valores);

    return ok({
      'total': filas.length,
      'citas': filas.map((c) => citaAdminJson(db, c)).toList(),
    });
  });

  /// Cambia el estado de cualquier cita.
  /// Equivale a `AdminController.cambiarEstadoCita()`.
  r.patch('/api/admin/citas/<id>', (Request req, String id) async {
    final vetado = _exigirAdmin(req);
    if (vetado != null) return vetado;

    final cuerpo = await cuerpoJson(req);
    if (cuerpo == null) return peticionInvalida('El cuerpo debe ser JSON.');

    final estado = (cuerpo['estado'] as String?)?.trim().toUpperCase() ?? '';
    const validos = {'PROGRAMADA', 'COMPLETADA', 'CANCELADA'};
    if (!validos.contains(estado)) {
      return peticionInvalida(
          'Estado inválido. Usa PROGRAMADA, COMPLETADA o CANCELADA.');
    }

    final existe = db.raw.select('SELECT id FROM citas WHERE id = ?', [id]);
    if (existe.isEmpty) return noEncontrado('La cita no existe.');

    try {
      db.raw.execute(
        'UPDATE citas SET estado = ?, actualizada_en = ? WHERE id = ?',
        [estado, DateTime.now().toIso8601String(), id],
      );
    } on SqliteException catch (e) {
      // Reactivar una cita cuyo horario ya fue tomado choca con ix_citas_slot.
      if (e.extendedResultCode == 2067 || e.resultCode == 19) {
        return conflicto(
            'No se puede reactivar: ese horario ya está ocupado por otra cita.');
      }
      rethrow;
    }

    final fila = db.raw.select('SELECT * FROM citas WHERE id = ?', [id]).first;
    return ok({'cita': citaAdminJson(db, fila)});
  });

  /// Elimina definitivamente una cita.
  /// Equivale a `AdminController.deleteCita()`.
  r.delete('/api/admin/citas/<id>', (Request req, String id) {
    final vetado = _exigirAdmin(req);
    if (vetado != null) return vetado;

    final existe = db.raw.select('SELECT id FROM citas WHERE id = ?', [id]);
    if (existe.isEmpty) return noEncontrado('La cita no existe.');

    db.raw.execute('DELETE FROM citas WHERE id = ?', [id]);
    return ok({'mensaje': 'Cita eliminada.', 'id': id});
  });

  // ------------------------------------------------------------ doctores

  r.get('/api/admin/doctores', (Request req) {
    final vetado = _exigirAdmin(req);
    if (vetado != null) return vetado;

    final filas = db.raw
        .select('SELECT * FROM doctores ORDER BY especialidad, nombre');
    return ok({
      'doctores': filas.map((d) => doctorJson(db, d)).toList(),
    });
  });

  /// Crea un doctor. Equivale a `AdminController.createDoctor()`.
  r.post('/api/admin/doctores', (Request req) async {
    final vetado = _exigirAdmin(req);
    if (vetado != null) return vetado;

    final cuerpo = await cuerpoJson(req);
    if (cuerpo == null) return peticionInvalida('El cuerpo debe ser JSON.');

    final nombre = (cuerpo['nombre'] as String?)?.trim() ?? '';
    final apellido = (cuerpo['apellido'] as String?)?.trim() ?? '';
    final especialidad = (cuerpo['especialidad'] as String?)?.trim() ?? '';
    if (nombre.isEmpty || apellido.isEmpty || especialidad.isEmpty) {
      return peticionInvalida(
          'Nombre, apellido y especialidad son obligatorios.');
    }

    // Id legible y estable: doc-007, doc-008, ...
    final maximo = db.raw
        .select("SELECT id FROM doctores WHERE id LIKE 'doc-%' ORDER BY id DESC LIMIT 1");
    var siguiente = 1;
    if (maximo.isNotEmpty) {
      final n = int.tryParse((maximo.first['id'] as String).substring(4));
      if (n != null) siguiente = n + 1;
    }
    final id = 'doc-${siguiente.toString().padLeft(3, '0')}';

    final horarios = (cuerpo['horarios'] as List?)?.cast<String>() ??
        const ['08:00', '08:30', '09:00', '10:00', '14:00', '15:00', '16:00'];

    try {
      db.raw.execute('''
        INSERT INTO doctores (id, nombre, apellido, titulo, especialidad,
                              correo, telefono, descripcion, clinica, rating,
                              experiencia, color, avatar_semilla, foto_url, activo)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,1)
      ''', [
        id,
        nombre,
        apellido,
        (cuerpo['titulo'] as String?)?.trim().isNotEmpty == true
            ? (cuerpo['titulo'] as String).trim()
            : 'Dr.',
        especialidad,
        (cuerpo['correo'] as String?)?.trim(),
        (cuerpo['telefono'] as String?)?.trim(),
        (cuerpo['descripcion'] as String?)?.trim() ?? '',
        (cuerpo['clinica'] as String?)?.trim() ?? '',
        (cuerpo['rating'] as num?)?.toDouble() ?? 4.5,
        (cuerpo['experiencia'] as num?)?.toInt() ?? 1,
        (cuerpo['color'] as num?)?.toInt() ?? _colorDe(especialidad),
        (cuerpo['avatarSemilla'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch % 100000,
        (cuerpo['fotoUrl'] as String?)?.trim(),
      ]);
    } on SqliteException catch (e) {
      if (e.resultCode == 19) {
        return conflicto('Ya existe un doctor con ese correo.');
      }
      rethrow;
    }

    _guardarHorarios(db, id, horarios);

    final fila =
        db.raw.select('SELECT * FROM doctores WHERE id = ?', [id]).first;
    return creado({'doctor': doctorJson(db, fila)});
  });

  /// Actualiza un doctor. Equivale a `AdminController.updateDoctor()`.
  r.put('/api/admin/doctores/<id>', (Request req, String id) async {
    final vetado = _exigirAdmin(req);
    if (vetado != null) return vetado;

    final cuerpo = await cuerpoJson(req);
    if (cuerpo == null) return peticionInvalida('El cuerpo debe ser JSON.');

    final actual = db.raw.select('SELECT * FROM doctores WHERE id = ?', [id]);
    if (actual.isEmpty) return noEncontrado('El doctor no existe.');
    final a = actual.first;

    // Solo se cambia lo que venga en el cuerpo; el resto se conserva.
    Object? dato(String clave, String columna) =>
        cuerpo.containsKey(clave) ? cuerpo[clave] : a[columna];

    try {
      db.raw.execute('''
        UPDATE doctores SET nombre = ?, apellido = ?, titulo = ?,
               especialidad = ?, correo = ?, telefono = ?, descripcion = ?,
               clinica = ?, rating = ?, experiencia = ?, color = ?,
               foto_url = ?, activo = ?
        WHERE id = ?
      ''', [
        dato('nombre', 'nombre'),
        dato('apellido', 'apellido'),
        dato('titulo', 'titulo'),
        dato('especialidad', 'especialidad'),
        dato('correo', 'correo'),
        dato('telefono', 'telefono'),
        dato('descripcion', 'descripcion'),
        dato('clinica', 'clinica'),
        dato('rating', 'rating'),
        dato('experiencia', 'experiencia'),
        dato('color', 'color'),
        dato('fotoUrl', 'foto_url'),
        cuerpo.containsKey('activo')
            ? ((cuerpo['activo'] == true) ? 1 : 0)
            : a['activo'],
        id,
      ]);
    } on SqliteException catch (e) {
      if (e.resultCode == 19) {
        return conflicto('Ese correo ya pertenece a otro doctor.');
      }
      rethrow;
    }

    if (cuerpo['horarios'] is List) {
      _guardarHorarios(db, id, (cuerpo['horarios'] as List).cast<String>());
    }

    final fila =
        db.raw.select('SELECT * FROM doctores WHERE id = ?', [id]).first;
    return ok({'doctor': doctorJson(db, fila)});
  });

  /// Elimina un doctor. Si tiene citas, no se borra: se desactiva, para no
  /// dejar citas huérfanas (la FK de citas apunta a doctores).
  r.delete('/api/admin/doctores/<id>', (Request req, String id) {
    final vetado = _exigirAdmin(req);
    if (vetado != null) return vetado;

    final existe = db.raw.select('SELECT id FROM doctores WHERE id = ?', [id]);
    if (existe.isEmpty) return noEncontrado('El doctor no existe.');

    final citas = db.raw.select(
        'SELECT COUNT(*) AS n FROM citas WHERE doctor_id = ?',
        [id]).first['n'] as int;

    if (citas > 0) {
      db.raw.execute('UPDATE doctores SET activo = 0 WHERE id = ?', [id]);
      return ok({
        'mensaje': 'El doctor tiene $citas cita(s) registradas, '
            'así que se desactivó en lugar de eliminarse.',
        'desactivado': true,
        'id': id,
      });
    }

    db.raw.execute('DELETE FROM doctor_horarios WHERE doctor_id = ?', [id]);
    db.raw.execute('DELETE FROM doctores WHERE id = ?', [id]);
    return ok({'mensaje': 'Doctor eliminado.', 'desactivado': false, 'id': id});
  });

  // ----------------------------------------------------------- servicios

  r.get('/api/admin/servicios', (Request req) {
    final vetado = _exigirAdmin(req);
    if (vetado != null) return vetado;

    final filas = db.raw.select('SELECT * FROM servicios ORDER BY nombre');
    return ok({'servicios': filas.map(servicioJson).toList()});
  });

  r.post('/api/admin/servicios', (Request req) async {
    final vetado = _exigirAdmin(req);
    if (vetado != null) return vetado;

    final cuerpo = await cuerpoJson(req);
    if (cuerpo == null) return peticionInvalida('El cuerpo debe ser JSON.');

    final nombre = (cuerpo['nombre'] as String?)?.trim() ?? '';
    final duracion = (cuerpo['duracionMinutos'] as num?)?.toInt() ?? 0;
    if (nombre.isEmpty) return peticionInvalida('El nombre es obligatorio.');
    if (duracion <= 0) {
      return peticionInvalida('La duración debe ser mayor que cero.');
    }

    final maximo = db.raw.select(
        "SELECT id FROM servicios WHERE id LIKE 'srv-%' ORDER BY id DESC LIMIT 1");
    var siguiente = 1;
    if (maximo.isNotEmpty) {
      final n = int.tryParse((maximo.first['id'] as String).substring(4));
      if (n != null) siguiente = n + 1;
    }
    final id = 'srv-${siguiente.toString().padLeft(3, '0')}';

    try {
      db.raw.execute('''
        INSERT INTO servicios (id, nombre, descripcion, categoria,
                               duracion_minutos, icono, color, activo)
        VALUES (?,?,?,?,?,?,?,1)
      ''', [
        id,
        nombre,
        (cuerpo['descripcion'] as String?)?.trim() ?? '',
        (cuerpo['categoria'] as String?)?.trim(),
        duracion,
        (cuerpo['icono'] as String?)?.trim().isNotEmpty == true
            ? (cuerpo['icono'] as String).trim()
            : 'medical',
        (cuerpo['color'] as num?)?.toInt() ?? _colorDe(nombre),
      ]);
    } on SqliteException catch (e) {
      if (e.resultCode == 19) {
        return conflicto('Ya existe un servicio con ese nombre.');
      }
      rethrow;
    }

    final fila =
        db.raw.select('SELECT * FROM servicios WHERE id = ?', [id]).first;
    return creado({'servicio': servicioJson(fila)});
  });

  r.put('/api/admin/servicios/<id>', (Request req, String id) async {
    final vetado = _exigirAdmin(req);
    if (vetado != null) return vetado;

    final cuerpo = await cuerpoJson(req);
    if (cuerpo == null) return peticionInvalida('El cuerpo debe ser JSON.');

    final actual = db.raw.select('SELECT * FROM servicios WHERE id = ?', [id]);
    if (actual.isEmpty) return noEncontrado('El servicio no existe.');
    final a = actual.first;

    Object? dato(String clave, String columna) =>
        cuerpo.containsKey(clave) ? cuerpo[clave] : a[columna];

    try {
      db.raw.execute('''
        UPDATE servicios SET nombre = ?, descripcion = ?, categoria = ?,
               duracion_minutos = ?, icono = ?, color = ?, activo = ?
        WHERE id = ?
      ''', [
        dato('nombre', 'nombre'),
        dato('descripcion', 'descripcion'),
        dato('categoria', 'categoria'),
        dato('duracionMinutos', 'duracion_minutos'),
        dato('icono', 'icono'),
        dato('color', 'color'),
        cuerpo.containsKey('activo')
            ? ((cuerpo['activo'] == true) ? 1 : 0)
            : a['activo'],
        id,
      ]);
    } on SqliteException catch (e) {
      if (e.resultCode == 19) {
        return conflicto('Ese nombre ya pertenece a otro servicio.');
      }
      rethrow;
    }

    final fila =
        db.raw.select('SELECT * FROM servicios WHERE id = ?', [id]).first;
    return ok({'servicio': servicioJson(fila)});
  });

  r.delete('/api/admin/servicios/<id>', (Request req, String id) {
    final vetado = _exigirAdmin(req);
    if (vetado != null) return vetado;

    final existe = db.raw.select('SELECT id FROM servicios WHERE id = ?', [id]);
    if (existe.isEmpty) return noEncontrado('El servicio no existe.');

    final citas = db.raw.select(
        'SELECT COUNT(*) AS n FROM citas WHERE servicio_id = ?',
        [id]).first['n'] as int;

    if (citas > 0) {
      db.raw.execute('UPDATE servicios SET activo = 0 WHERE id = ?', [id]);
      return ok({
        'mensaje': 'El servicio tiene $citas cita(s) asociadas, '
            'así que se desactivó en lugar de eliminarse.',
        'desactivado': true,
        'id': id,
      });
    }

    db.raw.execute('DELETE FROM servicios WHERE id = ?', [id]);
    return ok(
        {'mensaje': 'Servicio eliminado.', 'desactivado': false, 'id': id});
  });

  // ------------------------------------------------------------ usuarios

  r.get('/api/admin/usuarios', (Request req) {
    final vetado = _exigirAdmin(req);
    if (vetado != null) return vetado;

    final filas = db.raw.select('SELECT * FROM usuarios ORDER BY creado_en');
    return ok({
      'usuarios': filas.map((u) {
        final j = usuarioJson(db, u);
        j['citas'] = db.raw.select(
            'SELECT COUNT(*) AS n FROM citas WHERE usuario_id = ?',
            [u['id']]).first['n'];
        return j;
      }).toList(),
    });
  });

  /// Activa/desactiva un usuario o cambia sus roles.
  /// Equivale a `UsuarioController.cambiarEstadoUsuario()`.
  r.patch('/api/admin/usuarios/<id|[0-9]+>', (Request req, String id) async {
    final vetado = _exigirAdmin(req);
    if (vetado != null) return vetado;

    final cuerpo = await cuerpoJson(req);
    if (cuerpo == null) return peticionInvalida('El cuerpo debe ser JSON.');

    final uid = int.parse(id);
    final u = db.usuarioPorId(uid);
    if (u == null) return noEncontrado('El usuario no existe.');

    // Un administrador no puede quitarse a sí mismo el acceso: así no se
    // puede dejar el sistema sin ningún administrador por accidente.
    final yo = usuarioDe(req);
    if (uid == yo && (cuerpo.containsKey('activo') || cuerpo.containsKey('esAdmin'))) {
      return conflicto('No puedes cambiar tu propia cuenta de administrador.');
    }

    if (cuerpo.containsKey('activo')) {
      db.raw.execute('UPDATE usuarios SET activo = ? WHERE id = ?',
          [cuerpo['activo'] == true ? 1 : 0, uid]);
      // Al desactivar, se cierran sus sesiones abiertas.
      if (cuerpo['activo'] != true) {
        db.raw.execute('DELETE FROM sesiones WHERE usuario_id = ?', [uid]);
      }
    }

    if (cuerpo.containsKey('esAdmin')) {
      if (cuerpo['esAdmin'] == true) {
        db.raw.execute(
            'INSERT OR IGNORE INTO usuario_roles (usuario_id, rol) VALUES (?, ?)',
            [uid, 'ROLE_ADMIN']);
      } else {
        db.raw.execute(
            "DELETE FROM usuario_roles WHERE usuario_id = ? AND rol = 'ROLE_ADMIN'",
            [uid]);
      }
    }

    final fila = db.usuarioPorId(uid)!;
    return ok({'usuario': usuarioJson(db, fila)});
  });

  return r;
}

/// Guarda la agenda del doctor, reemplazando la anterior.
void _guardarHorarios(Db db, String doctorId, List<String> horas) {
  db.raw.execute('DELETE FROM doctor_horarios WHERE doctor_id = ?', [doctorId]);
  final ins = db.raw
      .prepare('INSERT OR IGNORE INTO doctor_horarios (doctor_id, hora) VALUES (?,?)');
  for (final h in horas) {
    final limpia = h.trim();
    if (RegExp(r'^\d{2}:\d{2}$').hasMatch(limpia)) ins.execute([doctorId, limpia]);
  }
  ins.dispose();
}

/// Color por especialidad, igual que la paleta de la app.
int _colorDe(String especialidad) {
  const paleta = <String, int>{
    'Cardiología': 0xFFE11D48,
    'Pediatría': 0xFF7C3AED,
    'Dermatología': 0xFF10B981,
    'Neurología': 0xFFEA580C,
    'Traumatología': 0xFF0369A1,
    'Ginecología': 0xFFDB2777,
    'Medicina General': 0xFF1A5FBF,
    'Odontología': 0xFF4F46E5,
    'Laboratorio': 0xFFEA580C,
  };
  return paleta[especialidad] ?? 0xFF1A5FBF;
}
