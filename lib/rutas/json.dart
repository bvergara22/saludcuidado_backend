import 'package:sqlite3/sqlite3.dart';

import '../db.dart';

/// Serializadores compartidos entre la API pública (`api.dart`) y la API de
/// administración (`admin.dart`).
///
/// Convención: las claves salen en camelCase, que es lo que consumen los
/// modelos de Flutter (`Doctor.desdeJson`, `Cita.desdeJson`, ...).

Map<String, dynamic> usuarioJson(Db db, Row u) {
  final nombre = u['nombre'] as String;
  final apellido = u['apellido'] as String?;
  final completo =
      apellido == null || apellido.isEmpty ? nombre : '$nombre $apellido';
  return {
    'id': u['id'],
    'nombre': completo,
    'email': u['email'],
    'username': u['username'],
    'iniciales': iniciales(completo),
    'avatarSemilla': u['avatar_semilla'],
    'activo': (u['activo'] as int) == 1,
    'creadoEn': u['creado_en'],
    'roles': db.rolesDe(u['id'] as int),
  };
}

Map<String, dynamic> doctorJson(Db db, Row d) {
  final id = d['id'] as String;
  final horarios = db.raw
      .select(
          'SELECT hora FROM doctor_horarios WHERE doctor_id = ? ORDER BY hora',
          [id])
      .map((f) => f['hora'] as String)
      .toList();
  final nombreCompleto = '${d['titulo']} ${d['nombre']} ${d['apellido']}';
  return {
    'id': id,
    'nombre': nombreCompleto,
    'nombrePila': d['nombre'],
    'apellido': d['apellido'],
    'titulo': d['titulo'],
    'especialidad': d['especialidad'],
    'iniciales': iniciales('${d['nombre']} ${d['apellido']}'),
    'correo': d['correo'],
    'telefono': d['telefono'],
    'rating': d['rating'],
    'experiencia': d['experiencia'],
    'clinica': d['clinica'],
    'descripcion': d['descripcion'],
    'color': d['color'],
    'avatarSemilla': d['avatar_semilla'],
    'fotoUrl': d['foto_url'],
    'activo': (d['activo'] as int) == 1,
    'horariosDisponibles': horarios,
  };
}

Map<String, dynamic> servicioJson(Row s) => {
      'id': s['id'],
      'nombre': s['nombre'],
      'descripcion': s['descripcion'],
      'categoria': s['categoria'],
      'duracionMinutos': s['duracion_minutos'],
      'icono': s['icono'],
      'color': s['color'],
      'activo': (s['activo'] as int) == 1,
    };

Map<String, dynamic> citaJson(Db db, Row c) {
  final doctorId = c['doctor_id'] as String;
  final d = db.raw.select('SELECT * FROM doctores WHERE id = ?', [doctorId]);
  return {
    'id': c['id'],
    'fecha': c['fecha'],
    'hora': c['hora'],
    'estado': c['estado'],
    'servicio': c['servicio_nombre'],
    'notas': c['notas'],
    'creadaEn': c['creada_en'],
    'doctor': d.isEmpty ? null : doctorJson(db, d.first),
  };
}

/// Cita con los datos del paciente: la vista de administración necesita
/// saber de quién es cada cita, cosa que la vista del paciente no.
Map<String, dynamic> citaAdminJson(Db db, Row c) {
  final base = citaJson(db, c);
  final u = db.usuarioPorId(c['usuario_id'] as int);
  base['paciente'] = u == null
      ? null
      : {
          'id': u['id'],
          'nombre': [u['nombre'], u['apellido']]
              .where((p) => p != null && (p as String).isNotEmpty)
              .join(' '),
          'email': u['email'],
          'avatarSemilla': u['avatar_semilla'],
        };
  return base;
}

String iniciales(String nombre) {
  final partes = nombre
      .trim()
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (partes.isEmpty) return '?';
  if (partes.length == 1) return partes.first.substring(0, 1).toUpperCase();
  return (partes[0].substring(0, 1) + partes[1].substring(0, 1)).toUpperCase();
}
