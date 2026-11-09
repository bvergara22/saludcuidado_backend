import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'seguridad.dart';

/// Acceso a la base de datos SQLite.
///
/// El esquema replica el dominio del backend Spring Boot original
/// (`ejemplo_99`) para que la trazabilidad se mantenga:
///   Usuario.java        -> usuarios + usuario_roles
///   Doctor.java         -> doctores + doctor_horarios
///   Servicio.java       -> servicios
///   Cita.java           -> citas
///
/// Reglas de negocio que se hacen cumplir en la propia base de datos:
///   - un doctor no puede tener dos citas no canceladas en el mismo
///     dia y hora (indice unico parcial `ix_citas_slot`)
///   - las citas referencian usuarios y doctores existentes (claves foraneas)
class Db {
  final Database _db;

  Db._(this._db);

  Database get raw => _db;

  /// Abre (o crea) la base de datos en [ruta] y aplica el esquema.
  factory Db.abrir(String ruta) {
    final archivo = File(ruta);
    archivo.parent.createSync(recursive: true);
    final db = sqlite3.open(ruta);

    // Integridad referencial y mejor concurrencia de lectura.
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA journal_mode = WAL');

    final instancia = Db._(db);
    instancia._crearEsquema();
    instancia._sembrar();
    instancia._sincronizarPaleta();
    return instancia;
  }

  /// Alinea los colores de doctores y servicios con la identidad visual
  /// vigente de la app (AppColors de Flutter).
  ///
  /// La siembra solo corre con las tablas vacías, así que una base de datos
  /// creada antes del rediseño conservaría los colores viejos y la app se
  /// vería incoherente. Esto se ejecuta en cada arranque y es idempotente:
  /// actualiza el color por id sin tocar el resto de los datos ni las citas.
  void _sincronizarPaleta() {
    const porEspecialidad = <String, int>{
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

    final upDoc = _db.prepare(
        'UPDATE doctores SET color = ? WHERE especialidad = ? AND color <> ?');
    final upSrv = _db.prepare(
        'UPDATE servicios SET color = ? WHERE nombre = ? AND color <> ?');
    porEspecialidad.forEach((nombre, color) {
      upDoc.execute([color, nombre, color]);
      upSrv.execute([color, nombre, color]);
    });
    upDoc.dispose();
    upSrv.dispose();
  }

  void cerrar() => _db.dispose();

  // ------------------------------------------------------------- esquema

  void _crearEsquema() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS usuarios (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        username      TEXT    NOT NULL UNIQUE,
        email         TEXT    NOT NULL UNIQUE,
        password_hash TEXT    NOT NULL,
        salt          TEXT    NOT NULL,
        nombre        TEXT    NOT NULL,
        apellido      TEXT,
        avatar_semilla INTEGER NOT NULL DEFAULT 0,
        activo        INTEGER NOT NULL DEFAULT 1,
        creado_en     TEXT    NOT NULL
      );
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS usuario_roles (
        usuario_id INTEGER NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
        rol        TEXT    NOT NULL,
        PRIMARY KEY (usuario_id, rol)
      );
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS doctores (
        id             TEXT    PRIMARY KEY,
        nombre         TEXT    NOT NULL,
        apellido       TEXT    NOT NULL,
        titulo         TEXT    NOT NULL DEFAULT 'Dr.',
        especialidad   TEXT    NOT NULL,
        correo         TEXT    UNIQUE,
        telefono       TEXT,
        descripcion    TEXT    NOT NULL DEFAULT '',
        clinica        TEXT    NOT NULL DEFAULT '',
        rating         REAL    NOT NULL DEFAULT 0,
        experiencia    INTEGER NOT NULL DEFAULT 0,
        color          INTEGER NOT NULL,
        avatar_semilla INTEGER NOT NULL,
        foto_url       TEXT,
        activo         INTEGER NOT NULL DEFAULT 1
      );
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS doctor_horarios (
        doctor_id TEXT NOT NULL REFERENCES doctores(id) ON DELETE CASCADE,
        hora      TEXT NOT NULL,
        PRIMARY KEY (doctor_id, hora)
      );
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS servicios (
        id               TEXT    PRIMARY KEY,
        nombre           TEXT    NOT NULL UNIQUE,
        descripcion      TEXT    NOT NULL DEFAULT '',
        categoria        TEXT,
        duracion_minutos INTEGER NOT NULL,
        icono            TEXT    NOT NULL DEFAULT 'medical',
        color            INTEGER NOT NULL,
        activo           INTEGER NOT NULL DEFAULT 1
      );
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS citas (
        id             TEXT    PRIMARY KEY,
        usuario_id     INTEGER NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
        doctor_id      TEXT    NOT NULL REFERENCES doctores(id),
        servicio_id    TEXT    REFERENCES servicios(id),
        fecha          TEXT    NOT NULL,
        hora           TEXT    NOT NULL,
        estado         TEXT    NOT NULL DEFAULT 'PROGRAMADA'
                               CHECK (estado IN ('PROGRAMADA','COMPLETADA','CANCELADA')),
        nombre_paciente TEXT,
        telefono       TEXT,
        notas          TEXT,
        creada_en      TEXT    NOT NULL,
        actualizada_en TEXT
      );
    ''');

    // REGLA DE NEGOCIO EN LA BASE DE DATOS:
    // un mismo doctor no puede tener dos citas vigentes en el mismo instante.
    // Las canceladas quedan fuera del indice, asi que liberan el horario.
    _db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS ix_citas_slot
        ON citas (doctor_id, fecha, hora)
        WHERE estado <> 'CANCELADA';
    ''');

    _db.execute(
        'CREATE INDEX IF NOT EXISTS ix_citas_usuario ON citas (usuario_id);');
    _db.execute(
        'CREATE INDEX IF NOT EXISTS ix_citas_fecha ON citas (fecha);');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS sesiones (
        token      TEXT    PRIMARY KEY,
        usuario_id INTEGER NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
        creada_en  TEXT    NOT NULL,
        expira_en  TEXT    NOT NULL
      );
    ''');
  }

  // -------------------------------------------------------------- semilla

  bool get _vacia =>
      (_db.select('SELECT COUNT(*) AS n FROM doctores').first['n'] as int) == 0;

  void _sembrar() {
    if (!_vacia) return;
    stdout.writeln('  Sembrando datos iniciales...');

    // --- usuarios de ejemplo (equivalentes a DataInitializer.java)
    crearUsuario(
      nombre: 'Administrador',
      email: 'admin@saludcuidado.com',
      password: 'admin123',
      roles: ['ROLE_ADMIN', 'ROLE_USER'],
    );
    crearUsuario(
      nombre: 'Brandon Llamas',
      email: 'brandon@saludcuidado.com',
      password: 'demo1234',
      roles: ['ROLE_USER'],
    );

    // --- doctores
    const doctores = [
      {
        'id': 'doc-001', 'nombre': 'Carlos', 'apellido': 'Mendoza',
        'titulo': 'Dr.', 'especialidad': 'Cardiología',
        'correo': 'carlos.mendoza@saludcuidado.com', 'telefono': '555-123-4567',
        'descripcion': 'Especialista en cardiología clínica e intervencionista. '
            'Enfocado en prevención cardiovascular, hipertensión y control de arritmias.',
        'clinica': 'Clínica SaludCuidado - Sede Norte',
        'rating': 4.9, 'experiencia': 12, 'color': 0xFFE11D48, 'semilla': 17,
        'horarios': ['08:00','08:30','09:00','10:00','10:30','14:00','14:30','15:00','16:00'],
      },
      {
        'id': 'doc-002', 'nombre': 'Ana', 'apellido': 'García',
        'titulo': 'Dra.', 'especialidad': 'Pediatría',
        'correo': 'ana.garcia@saludcuidado.com', 'telefono': '555-234-5678',
        'descripcion': 'Pediatra con enfoque en crecimiento y desarrollo infantil, '
            'control de niño sano y atención de enfermedades respiratorias.',
        'clinica': 'Clínica SaludCuidado - Sede Centro',
        'rating': 4.8, 'experiencia': 8, 'color': 0xFF7C3AED, 'semilla': 42,
        'horarios': ['07:00','07:30','08:00','09:00','09:30','11:00','15:00','15:30','16:30'],
      },
      {
        'id': 'doc-003', 'nombre': 'Luis', 'apellido': 'López',
        'titulo': 'Dr.', 'especialidad': 'Dermatología',
        'correo': 'luis.lopez@saludcuidado.com', 'telefono': '555-345-6789',
        'descripcion': 'Dermatólogo clínico y estético. Tratamiento de acné, '
            'dermatitis, psoriasis y revisión preventiva de lunares.',
        'clinica': 'Clínica SaludCuidado - Sede Norte',
        'rating': 4.7, 'experiencia': 10, 'color': 0xFF10B981, 'semilla': 8,
        'horarios': ['09:00','09:30','10:00','11:00','11:30','13:00','17:00','17:30','18:00'],
      },
      {
        'id': 'doc-004', 'nombre': 'María', 'apellido': 'Torres',
        'titulo': 'Dra.', 'especialidad': 'Neurología',
        'correo': 'maria.torres@saludcuidado.com', 'telefono': '555-456-7890',
        'descripcion': 'Neuróloga especializada en cefaleas, epilepsia y '
            'trastornos del sueño. Amplia experiencia en electroencefalografía.',
        'clinica': 'Clínica SaludCuidado - Sede Sur',
        'rating': 4.9, 'experiencia': 15, 'color': 0xFFEA580C, 'semilla': 91,
        'horarios': ['08:30','10:00','10:30','12:00','14:00','14:30','16:00','16:30'],
      },
      {
        'id': 'doc-005', 'nombre': 'Roberto', 'apellido': 'Sánchez',
        'titulo': 'Dr.', 'especialidad': 'Traumatología',
        'correo': 'roberto.sanchez@saludcuidado.com', 'telefono': '555-567-8901',
        'descripcion': 'Traumatólogo y ortopedista. Manejo de lesiones '
            'deportivas, fracturas y rehabilitación osteomuscular.',
        'clinica': 'Clínica SaludCuidado - Sede Centro',
        'rating': 4.6, 'experiencia': 9, 'color': 0xFF0369A1, 'semilla': 55,
        'horarios': ['07:30','08:00','09:30','11:00','13:30','15:00','17:00','18:30'],
      },
      {
        'id': 'doc-006', 'nombre': 'Elena', 'apellido': 'Morales',
        'titulo': 'Dra.', 'especialidad': 'Ginecología',
        'correo': 'elena.morales@saludcuidado.com', 'telefono': '555-678-9012',
        'descripcion': 'Ginecóloga y obstetra. Control prenatal, planificación '
            'familiar y detección temprana de cáncer de cuello uterino.',
        'clinica': 'Clínica SaludCuidado - Sede Sur',
        'rating': 4.8, 'experiencia': 11, 'color': 0xFFDB2777, 'semilla': 73,
        'horarios': ['08:00','08:30','10:00','10:30','12:00','14:30','15:30','16:00'],
      },
    ];

    final insDoc = _db.prepare('''
      INSERT INTO doctores (id, nombre, apellido, titulo, especialidad, correo,
                            telefono, descripcion, clinica, rating, experiencia,
                            color, avatar_semilla, activo)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,1)
    ''');
    final insHora = _db.prepare(
        'INSERT INTO doctor_horarios (doctor_id, hora) VALUES (?,?)');

    for (final d in doctores) {
      insDoc.execute([
        d['id'], d['nombre'], d['apellido'], d['titulo'], d['especialidad'],
        d['correo'], d['telefono'], d['descripcion'], d['clinica'],
        d['rating'], d['experiencia'], d['color'], d['semilla'],
      ]);
      for (final h in d['horarios'] as List) {
        insHora.execute([d['id'], h]);
      }
    }
    insDoc.dispose();
    insHora.dispose();

    // --- servicios (duraciones tomadas de DataInitializer.java)
    const servicios = [
      ['srv-001','Medicina General','Evaluación y seguimiento en medicina general.','general',30,'stethoscope',0xFF1A5FBF],
      ['srv-002','Odontología','Servicios dentales: limpieza, extracciones y tratamientos de conducto.','dental',60,'tooth',0xFF4F46E5],
      ['srv-003','Pediatría','Atención médica especializada para niños y adolescentes.','infantil',45,'child',0xFF7C3AED],
      ['srv-004','Cardiología','Control cardiovascular, hipertensión y arritmias.','especialidad',40,'heart',0xFFE11D48],
      ['srv-005','Dermatología','Diagnóstico y tratamiento de afecciones de la piel.','especialidad',30,'skin',0xFF10B981],
      ['srv-006','Laboratorio','Toma de muestras y exámenes de laboratorio clínico.','apoyo',20,'lab',0xFFEA580C],
    ];
    final insSrv = _db.prepare('''
      INSERT INTO servicios (id, nombre, descripcion, categoria,
                             duracion_minutos, icono, color, activo)
      VALUES (?,?,?,?,?,?,?,1)
    ''');
    for (final s in servicios) {
      insSrv.execute(s);
    }
    insSrv.dispose();

    _sembrarCitas();
    stdout.writeln('  Semilla lista: ${doctores.length} doctores, '
        '${servicios.length} servicios, 2 usuarios.');
  }

  /// Citas de ejemplo para el usuario de demostracion.
  void _sembrarCitas() {
    final usuario = _db.select(
        "SELECT id FROM usuarios WHERE email = 'brandon@saludcuidado.com'");
    if (usuario.isEmpty) return;
    final uid = usuario.first['id'] as int;

    final hoy = DateTime.now();
    String f(int dias) {
      final d = DateTime(hoy.year, hoy.month, hoy.day + dias);
      return '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
    }

    final ejemplos = [
      ['doc-001', 'srv-004', f(2), '10:00', 'PROGRAMADA'],
      ['doc-002', 'srv-003', f(5), '09:00', 'PROGRAMADA'],
      ['doc-003', 'srv-005', f(-7), '11:00', 'COMPLETADA'],
      ['doc-004', null, f(-14), '14:30', 'COMPLETADA'],
      ['doc-005', null, f(-3), '15:00', 'CANCELADA'],
    ];

    final ins = _db.prepare('''
      INSERT INTO citas (id, usuario_id, doctor_id, servicio_id, fecha, hora,
                         estado, creada_en)
      VALUES (?,?,?,?,?,?,?,?)
    ''');
    final ahora = DateTime.now().toIso8601String();
    for (var i = 0; i < ejemplos.length; i++) {
      final e = ejemplos[i];
      ins.execute([
        'cita-semilla-${i + 1}', uid, e[0], e[1], e[2], e[3], e[4], ahora,
      ]);
    }
    ins.dispose();
  }

  // -------------------------------------------------------------- usuarios

  /// Crea un usuario con la contrasena derivada (PBKDF2-HMAC-SHA256).
  /// Devuelve el id, o null si el correo ya existe.
  int? crearUsuario({
    required String nombre,
    required String email,
    required String password,
    List<String> roles = const ['ROLE_USER'],
  }) {
    final existe = _db.select(
        'SELECT id FROM usuarios WHERE email = ? COLLATE NOCASE', [email]);
    if (existe.isNotEmpty) return null;

    final sal = Seguridad.generarSal();
    final hash = Seguridad.derivar(password, sal);
    final partes = nombre.trim().split(RegExp(r'\s+'));
    final username = email.split('@').first.toLowerCase();

    _db.execute('''
      INSERT INTO usuarios (username, email, password_hash, salt, nombre,
                            apellido, avatar_semilla, activo, creado_en)
      VALUES (?,?,?,?,?,?,?,1,?)
    ''', [
      username,
      email,
      hash,
      sal,
      partes.first,
      partes.length > 1 ? partes.sublist(1).join(' ') : null,
      email.hashCode.abs() % 1000,
      DateTime.now().toIso8601String(),
    ]);

    final id = _db.lastInsertRowId;
    final insRol =
        _db.prepare('INSERT INTO usuario_roles (usuario_id, rol) VALUES (?,?)');
    for (final r in roles) {
      insRol.execute([id, r]);
    }
    insRol.dispose();
    return id;
  }

  Row? usuarioPorEmail(String email) {
    final r = _db.select(
        'SELECT * FROM usuarios WHERE email = ? COLLATE NOCASE', [email]);
    return r.isEmpty ? null : r.first;
  }

  Row? usuarioPorId(int id) {
    final r = _db.select('SELECT * FROM usuarios WHERE id = ?', [id]);
    return r.isEmpty ? null : r.first;
  }

  List<String> rolesDe(int usuarioId) => _db
      .select('SELECT rol FROM usuario_roles WHERE usuario_id = ?', [usuarioId])
      .map((r) => r['rol'] as String)
      .toList();

  // -------------------------------------------------------------- sesiones

  String crearSesion(int usuarioId, {Duration duracion = const Duration(days: 30)}) {
    final token = Seguridad.generarToken();
    final ahora = DateTime.now();
    _db.execute(
      'INSERT INTO sesiones (token, usuario_id, creada_en, expira_en) VALUES (?,?,?,?)',
      [
        token,
        usuarioId,
        ahora.toIso8601String(),
        ahora.add(duracion).toIso8601String(),
      ],
    );
    return token;
  }

  /// Devuelve el id de usuario de una sesion vigente, o null.
  int? usuarioDeSesion(String token) {
    final r = _db.select('SELECT * FROM sesiones WHERE token = ?', [token]);
    if (r.isEmpty) return null;
    final expira = DateTime.tryParse(r.first['expira_en'] as String);
    if (expira == null || expira.isBefore(DateTime.now())) {
      _db.execute('DELETE FROM sesiones WHERE token = ?', [token]);
      return null;
    }
    return r.first['usuario_id'] as int;
  }

  void cerrarSesion(String token) =>
      _db.execute('DELETE FROM sesiones WHERE token = ?', [token]);
}
