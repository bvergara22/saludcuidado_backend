import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import '../db.dart';
import '../horarios.dart';
import '../http_util.dart';
import 'json.dart';

/// Asistente de SaludCuidado.
///
/// CONTRATO: POST /api/chat
///   Requiere : sesión iniciada y {"mensaje": "..."} en el cuerpo
///   Garantiza: responde consultando la base de datos del propio usuario,
///              y devuelve sugerencias de lo siguiente que puede preguntar
///   Falla si : sin sesión -> 401; cuerpo vacío -> 400
///
/// Trazabilidad: `ChatController.java` + `ChatService.java` de la
/// plataforma web. Allí conviven dos cosas: un `ChatService` que resuelve
/// comandos por reglas sobre el repositorio (`"listar usuarios"`) y un
/// `ChatController` que delega en un modelo de lenguaje con Spring AI.
///
/// Aquí se porta **la vía de reglas**, por tres motivos que conviene
/// poder defender:
///   1. no necesita clave de API ni conexión a un tercero, así que la app
///      se puede entregar y calificar sin coste ni credenciales;
///   2. cada respuesta sale de una consulta SQL concreta, de modo que es
///      verificable y trazable igual que el resto del proyecto;
///   3. no inventa. Un modelo de lenguaje suelto sobre datos médicos
///      puede afirmar una cita que no existe; esto no puede.
///
/// Lo que sí hereda del original es la forma: un único punto de entrada
/// que recibe lenguaje natural y decide qué hacer con él.
Router construirChat(Db db) {
  final r = Router();

  r.post('/api/chat', (Request req) async {
    final uid = usuarioDe(req);
    if (uid == null) return noAutorizado();

    final cuerpo = await cuerpoJson(req);
    if (cuerpo == null) return peticionInvalida('El cuerpo debe ser JSON.');

    final mensaje = (cuerpo['mensaje'] as String?)?.trim() ?? '';
    if (mensaje.isEmpty) {
      return peticionInvalida('Escribe algo para que pueda ayudarte.');
    }

    final respuesta = _responder(db, uid, mensaje);
    return ok({
      'respuesta': respuesta.texto,
      'intencion': respuesta.intencion,
      'sugerencias': respuesta.sugerencias,
      if (respuesta.citas != null) 'citas': respuesta.citas,
      if (respuesta.doctores != null) 'doctores': respuesta.doctores,
    });
  });

  return r;
}

/// Lo que el asistente devuelve: el texto y, cuando aplica, los datos
/// crudos para que la app los pinte como tarjetas en lugar de como texto.
class _Respuesta {
  final String texto;
  final String intencion;
  final List<String> sugerencias;
  final List<Map<String, dynamic>>? citas;
  final List<Map<String, dynamic>>? doctores;

  const _Respuesta(
    this.texto, {
    required this.intencion,
    this.sugerencias = const [],
    this.citas,
    this.doctores,
  });
}

const List<String> _sugerenciasBase = [
  '¿Cuándo es mi próxima cita?',
  '¿Qué citas tengo?',
  'Muéstrame los pediatras',
  '¿Qué servicios ofrecen?',
];

/// Quita acentos y pasa a minúsculas, para que "cardiología", "Cardiologia"
/// y "CARDIOLOGÍA" se reconozcan igual.
String _normalizar(String s) {
  const con = 'áàäâãéèëêíìïîóòöôõúùüûñç';
  const sin = 'aaaaaeeeeiiiiooooouuuunc';
  var r = s.toLowerCase();
  for (var i = 0; i < con.length; i++) {
    r = r.replaceAll(con[i], sin[i]);
  }
  return r;
}

bool _contieneAlguna(String texto, List<String> claves) =>
    claves.any(texto.contains);

_Respuesta _responder(Db db, int uid, String mensajeOriginal) {
  final m = _normalizar(mensajeOriginal);

  // El orden importa: lo más específico primero, porque "cita" aparece
  // en casi todas las frases del dominio.
  if (_contieneAlguna(m, ['quien eres', 'que eres', 'como te llamas'])) {
    return const _Respuesta(
      'Soy el asistente de SaludCuidado. Consulto tus citas, los médicos y '
      'los horarios directamente en la base de datos de la clínica, así que '
      'lo que te digo es lo que hay registrado.\n\n'
      'No soy una inteligencia artificial: entiendo un conjunto concreto de '
      'preguntas. Escribe «ayuda» y te digo cuáles.',
      intencion: 'identidad',
      sugerencias: _sugerenciasBase,
    );
  }

  if (_contieneAlguna(m, ['ayuda', 'que puedes', 'que sabes', 'opciones'])) {
    return const _Respuesta(
      'Esto es lo que puedo responderte:\n\n'
      '• Cuándo es tu próxima cita\n'
      '• Qué citas tienes, y cuántas completadas o canceladas\n'
      '• Qué médicos hay, por especialidad o por nombre\n'
      '• Qué horarios tiene libres un médico un día concreto\n'
      '• Qué servicios ofrece la clínica\n'
      '• Cómo reservar, reprogramar o cancelar',
      intencion: 'ayuda',
      sugerencias: _sugerenciasBase,
    );
  }

  if (_contieneAlguna(m, ['hola', 'buenas', 'buenos dias', 'buenas tardes'])) {
    final u = db.usuarioPorId(uid);
    final nombre = (u?['nombre'] as String?)?.split(' ').first ?? '';
    return _Respuesta(
      'Hola${nombre.isEmpty ? '' : ', $nombre'}. ¿En qué te ayudo?',
      intencion: 'saludo',
      sugerencias: _sugerenciasBase,
    );
  }

  if (_contieneAlguna(m, ['proxima cita', 'siguiente cita', 'cuando es mi'])) {
    return _proximaCita(db, uid);
  }

  if (_contieneAlguna(m, ['horario', 'disponible', 'libre', 'agenda'])) {
    return _horarios(db, m);
  }

  if (_contieneAlguna(m, ['mis citas', 'que citas', 'cuantas citas',
      'tengo cita', 'mis turnos'])) {
    return _misCitas(db, uid);
  }

  if (_contieneAlguna(m, ['como reservo', 'como reservar', 'agendar',
      'pedir cita', 'sacar cita'])) {
    return const _Respuesta(
      'Para reservar: abre la pestaña **Doctores**, elige al médico y la '
      'app te lleva a los tres pasos (médico, fecha y hora, confirmación). '
      'Solo te ofrece horas realmente libres.',
      intencion: 'como_reservar',
      sugerencias: ['Muéstrame los cardiólogos', '¿Qué servicios ofrecen?'],
    );
  }

  if (_contieneAlguna(m, ['reprogram', 'cambiar la fecha', 'mover la cita',
      'cambiar mi cita'])) {
    return const _Respuesta(
      'En **Mis Citas**, cada cita próxima tiene el botón «Reprogramar». '
      'Eliges otra fecha y hora de las que estén libres y la cita se mueve '
      'conservando su historial. No hace falta cancelarla y volver a '
      'crearla.',
      intencion: 'como_reprogramar',
      sugerencias: ['¿Cuándo es mi próxima cita?'],
    );
  }

  if (_contieneAlguna(m, ['cancel', 'anular'])) {
    return const _Respuesta(
      'En **Mis Citas**, la cita próxima tiene el botón «Cancelar». Te pide '
      'confirmación y el horario queda libre para otra persona al instante.\n\n'
      'Por seguridad no cancelo citas por chat: esa acción la haces tú.',
      intencion: 'como_cancelar',
      sugerencias: ['¿Qué citas tengo?'],
    );
  }

  if (_contieneAlguna(m, ['servicio', 'especialidad', 'que ofrecen',
      'tratamiento'])) {
    return _servicios(db);
  }

  if (_contieneAlguna(m, ['doctor', 'doctora', 'medico', 'especialista',
      'quien atiende']) ||
      _especialidadEn(db, m) != null) {
    return _doctores(db, m);
  }

  return const _Respuesta(
    'No entendí esa. Soy un asistente de reglas, no adivino: entiendo un '
    'conjunto concreto de preguntas.\n\n'
    'Escribe «ayuda» y te las enumero.',
    intencion: 'desconocida',
    sugerencias: _sugerenciasBase,
  );
}

// --------------------------------------------------------------- consultas

_Respuesta _proximaCita(Db db, int uid) {
  final ahora = DateTime.now();
  final filas = db.raw.select('''
    SELECT c.*, s.nombre AS servicio_nombre
    FROM citas c LEFT JOIN servicios s ON s.id = c.servicio_id
    WHERE c.usuario_id = ? AND c.estado = 'PROGRAMADA'
    ORDER BY c.fecha, c.hora
  ''', [uid]);

  // Se descartan las que ya pasaron: siguen PROGRAMADA en la base pero
  // anunciarlas como "próxima" sería falso (misma regla que la app).
  for (final f in filas) {
    final cuando = DateTime.tryParse('${f['fecha']} ${f['hora']}:00');
    if (cuando == null || !cuando.isAfter(ahora)) continue;

    final doc = db.raw
        .select('SELECT * FROM doctores WHERE id = ?', [f['doctor_id']]);
    final nombre = doc.isEmpty
        ? 'tu médico'
        : '${doc.first['titulo']} ${doc.first['nombre']} '
            '${doc.first['apellido']}';
    final dias = DateTime(cuando.year, cuando.month, cuando.day)
        .difference(DateTime(ahora.year, ahora.month, ahora.day))
        .inDays;
    final cuandoTexto = switch (dias) {
      0 => 'hoy',
      1 => 'mañana',
      _ => 'en $dias días',
    };

    return _Respuesta(
      'Tu próxima cita es $cuandoTexto, el ${f['fecha']} a las ${f['hora']}, '
      'con $nombre.',
      intencion: 'proxima_cita',
      citas: [citaJson(db, f)],
      sugerencias: const ['¿Qué citas tengo?', 'Quiero reprogramarla'],
    );
  }

  final vencidas = filas.length;
  return _Respuesta(
    vencidas == 0
        ? 'No tienes ninguna cita programada. Puedes reservar desde la '
            'pestaña Doctores.'
        : 'No tienes citas futuras. Sí tienes $vencidas cita(s) vencida(s), '
            'de fechas que ya pasaron: están en la pestaña «Vencidas» de Mis '
            'Citas, y desde ahí puedes reprogramarlas.',
    intencion: 'proxima_cita_vacia',
    sugerencias: const ['¿Qué citas tengo?', 'Muéstrame los médicos'],
  );
}

_Respuesta _misCitas(Db db, int uid) {
  final conteo = <String, int>{
    'PROGRAMADA': 0,
    'COMPLETADA': 0,
    'CANCELADA': 0,
  };
  for (final f in db.raw.select(
      'SELECT estado, COUNT(*) AS n FROM citas WHERE usuario_id = ? '
      'GROUP BY estado',
      [uid])) {
    conteo[f['estado'] as String] = f['n'] as int;
  }

  final total = conteo.values.fold<int>(0, (a, b) => a + b);
  if (total == 0) {
    return const _Respuesta(
      'Todavía no tienes ninguna cita registrada.',
      intencion: 'mis_citas',
      sugerencias: ['Muéstrame los médicos', '¿Qué servicios ofrecen?'],
    );
  }

  final proximas = db.raw.select('''
    SELECT c.*, s.nombre AS servicio_nombre
    FROM citas c LEFT JOIN servicios s ON s.id = c.servicio_id
    WHERE c.usuario_id = ? AND c.estado = 'PROGRAMADA'
      AND datetime(c.fecha || ' ' || c.hora || ':00') > datetime('now','localtime')
    ORDER BY c.fecha, c.hora
  ''', [uid]);

  // Las programadas que ya pasaron no son "próximas" pero siguen contando
  // en el total: si no se nombran, el desglose no suma y parece un error.
  final vencidas = (conteo['PROGRAMADA'] ?? 0) - proximas.length;

  return _Respuesta(
    'Tienes $total cita(s) en total: ${proximas.length} próxima(s), '
    '${conteo['COMPLETADA']} completada(s), ${conteo['CANCELADA']} '
    'cancelada(s)'
    '${vencidas > 0 ? ' y $vencidas vencida(s)' : ''}.',
    intencion: 'mis_citas',
    citas: [for (final f in proximas) citaJson(db, f)],
    sugerencias: const ['¿Cuándo es mi próxima cita?', '¿Cómo reprogramo?'],
  );
}

/// Busca una especialidad conocida dentro del mensaje.
String? _especialidadEn(Db db, String mensajeNormalizado) {
  for (final f
      in db.raw.select('SELECT DISTINCT especialidad FROM doctores')) {
    final e = f['especialidad'] as String;
    if (mensajeNormalizado.contains(_normalizar(e))) return e;
    // "pediatras" -> "pediatria": se compara también la raíz.
    final raiz = _normalizar(e);
    if (raiz.length > 5 && mensajeNormalizado.contains(raiz.substring(0, 5))) {
      return e;
    }
  }
  return null;
}

_Respuesta _doctores(Db db, String m) {
  final especialidad = _especialidadEn(db, m);

  final filas = especialidad == null
      ? db.raw.select(
          'SELECT * FROM doctores WHERE activo = 1 ORDER BY rating DESC')
      : db.raw.select(
          'SELECT * FROM doctores WHERE activo = 1 AND especialidad = ? '
          'ORDER BY rating DESC',
          [especialidad]);

  if (filas.isEmpty) {
    return _Respuesta(
      'No encontré médicos${especialidad == null ? '' : ' de $especialidad'}.',
      intencion: 'doctores',
      sugerencias: _sugerenciasBase,
    );
  }

  final lista = [
    for (final f in filas)
      '• ${f['titulo']} ${f['nombre']} ${f['apellido']} — '
          '${f['especialidad']} (${f['rating']}★, ${f['experiencia']} años)'
  ].join('\n');

  return _Respuesta(
    especialidad == null
        ? 'Estos son los ${filas.length} médicos de la clínica:\n\n$lista'
        : 'Hay ${filas.length} en $especialidad:\n\n$lista',
    intencion: 'doctores',
    doctores: [for (final f in filas) doctorJson(db, f)],
    sugerencias: [
      '¿Qué horarios tiene ${filas.first['apellido']} mañana?',
      '¿Cómo reservo?',
    ],
  );
}

_Respuesta _servicios(Db db) {
  final filas = db.raw.select('SELECT * FROM servicios ORDER BY nombre');
  final lista = [
    for (final f in filas)
      '• ${f['nombre']} — ${f['duracion_minutos']} min'
  ].join('\n');
  return _Respuesta(
    'La clínica ofrece ${filas.length} servicios:\n\n$lista',
    intencion: 'servicios',
    sugerencias: const ['Muéstrame los médicos', '¿Cómo reservo?'],
  );
}

/// Horarios libres de un médico un día concreto.
///
/// Reconoce "hoy", "mañana", un día de la semana o una fecha YYYY-MM-DD, y
/// al médico por su apellido o su nombre de pila.
_Respuesta _horarios(Db db, String m) {
  final doctor = _doctorEn(db, m);
  if (doctor == null) {
    return const _Respuesta(
      'Dime de qué médico quieres ver los horarios. Por ejemplo: '
      '«¿qué horarios tiene García mañana?».',
      intencion: 'horarios_sin_doctor',
      sugerencias: ['Muéstrame los médicos'],
    );
  }

  final fecha = _fechaEn(m);
  final libres = Horarios.disponibles(
    db,
    doctorId: doctor['id'] as String,
    fecha: fecha,
  );
  final nombre = '${doctor['titulo']} ${doctor['nombre']} '
      '${doctor['apellido']}';

  if (libres.isEmpty) {
    return _Respuesta(
      '$nombre no tiene horarios libres el $fecha.',
      intencion: 'horarios',
      sugerencias: const ['¿Y al día siguiente?', 'Muéstrame los médicos'],
    );
  }

  return _Respuesta(
    '$nombre tiene ${libres.length} horario(s) libre(s) el $fecha:\n\n'
    '${libres.join(' · ')}',
    intencion: 'horarios',
    doctores: [doctorJson(db, doctor)],
    sugerencias: const ['¿Cómo reservo?'],
  );
}

Row? _doctorEn(Db db, String m) {
  for (final f in db.raw.select('SELECT * FROM doctores WHERE activo = 1')) {
    final apellido = _normalizar(f['apellido'] as String? ?? '');
    final nombre = _normalizar(f['nombre'] as String? ?? '');
    if (apellido.isNotEmpty && m.contains(apellido)) return f;
    if (nombre.isNotEmpty && m.contains(nombre)) return f;
  }
  return null;
}

/// Fecha mencionada en el mensaje; mañana si no se menciona ninguna.
String _fechaEn(String m) {
  final iso = RegExp(r'\d{4}-\d{2}-\d{2}').firstMatch(m);
  if (iso != null) return iso.group(0)!;

  final hoy = DateTime.now();
  if (m.contains('hoy')) return _iso(hoy);
  if (m.contains('pasado manana')) {
    return _iso(hoy.add(const Duration(days: 2)));
  }

  const dias = {
    'lunes': 1,
    'martes': 2,
    'miercoles': 3,
    'jueves': 4,
    'viernes': 5,
    'sabado': 6,
    'domingo': 7,
  };
  for (final e in dias.entries) {
    if (!m.contains(e.key)) continue;
    // El próximo día de la semana con ese nombre, nunca hoy mismo.
    var d = hoy.add(const Duration(days: 1));
    for (var i = 0; i < 7; i++) {
      if (d.weekday == e.value) return _iso(d);
      d = d.add(const Duration(days: 1));
    }
  }

  return _iso(hoy.add(const Duration(days: 1)));
}

String _iso(DateTime f) =>
    '${f.year.toString().padLeft(4, '0')}-'
    '${f.month.toString().padLeft(2, '0')}-'
    '${f.day.toString().padLeft(2, '0')}';
