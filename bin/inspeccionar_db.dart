import 'package:sqlite3/sqlite3.dart';
void main() {
  final db = sqlite3.open('datos/saludcuidado.db', mode: OpenMode.readOnly);
  for (final t in ['usuarios','doctores','servicios','citas','sesiones','doctor_horarios']) {
    final n = db.select('SELECT COUNT(*) AS n FROM $t').first['n'];
    print('  ${t.padRight(16)} $n filas');
  }
  db.dispose();
}
