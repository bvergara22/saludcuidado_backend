import 'db.dart';

/// Disponibilidad de horarios.
///
/// TRAZABILIDAD: port directo de
/// `CitaService.obtenerHorariosDisponiblesString(LocalDate fecha)` del
/// backend Spring Boot original:
///   1. rejilla de atencion de 07:00 a 19:00 cada 30 minutos
///   2. si la fecha es hoy, se descartan los horarios ya pasados
///   3. se descartan los horarios ocupados por citas vigentes
/// Se agrega una cuarta regla propia del modelo movil:
///   4. se acota a la agenda del doctor (tabla doctor_horarios)
class Horarios {
  Horarios._();

  static const int _inicioMin = 7 * 60; // 07:00
  static const int _finMin = 19 * 60; // 19:00
  static const int _paso = 30;

  /// Regla 1: rejilla base completa.
  static List<String> get rejillaBase {
    final out = <String>[];
    for (var m = _inicioMin; m <= _finMin; m += _paso) {
      out.add('${(m ~/ 60).toString().padLeft(2, '0')}:'
          '${(m % 60).toString().padLeft(2, '0')}');
    }
    return out;
  }

  static int _aMinutos(String hora) {
    final p = hora.split(':');
    if (p.length != 2) return -1;
    return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
  }

  /// Horarios realmente reservables para [doctorId] en [fecha] (YYYY-MM-DD).
  static List<String> disponibles(
    Db db, {
    required String doctorId,
    required String fecha,
  }) {
    // Regla 4: agenda propia del doctor, intersecada con la rejilla base.
    final agenda = db.raw
        .select(
            'SELECT hora FROM doctor_horarios WHERE doctor_id = ? ORDER BY hora',
            [doctorId])
        .map((f) => f['hora'] as String)
        .toSet();

    var horarios =
        rejillaBase.where((h) => agenda.isEmpty || agenda.contains(h)).toList();

    // Regla 2: si es hoy, se descartan los horarios ya pasados.
    final hoy = DateTime.now();
    final hoyIso = '${hoy.year.toString().padLeft(4, '0')}-'
        '${hoy.month.toString().padLeft(2, '0')}-'
        '${hoy.day.toString().padLeft(2, '0')}';
    if (fecha == hoyIso) {
      final ahora = hoy.hour * 60 + hoy.minute;
      horarios = horarios.where((h) => _aMinutos(h) > ahora).toList();
    }

    // Regla 3: se descartan los horarios ocupados por citas vigentes.
    final ocupados = db.raw
        .select(
          "SELECT hora FROM citas "
          "WHERE doctor_id = ? AND fecha = ? AND estado <> 'CANCELADA'",
          [doctorId, fecha],
        )
        .map((f) => f['hora'] as String)
        .toSet();

    return horarios.where((h) => !ocupados.contains(h)).toList();
  }
}
