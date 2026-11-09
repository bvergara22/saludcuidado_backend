# SaludCuidado — API y base de datos

Backend de la app móvil **SaludCuidado** (`../SaludCuidado-flutter`).
Guarda usuarios, doctores, servicios, horarios y citas en una base de datos
**SQLite** y los expone como API REST en JSON.

> Fundación Tecnológico Comfenalco — Computación Móvil
> Brandon Llamas · Carlos Gomez · Camilo Mackensie · Aurelio Guzman

---

## 1. Puesta en marcha

```bash
cd SaludCuidado-backend
dart pub get
dart run bin/server.dart                      # puerto 8080
dart run bin/server.dart --puerto 9090 --db datos/otra.db
```

Comprobación rápida:

```bash
curl http://localhost:8080/api/salud
# {"estado":"activo","servicio":"SaludCuidado API","version":"1.0.0",
#  "motor":"SQLite 3.48.0","doctores":6,"hora":"..."}
```

La primera ejecución crea el esquema y **siembra** los datos de los mocks de
Penpot: 6 doctores con su agenda, 6 servicios, 2 usuarios y 5 citas de ejemplo.
Las ejecuciones siguientes reutilizan lo que ya hay en el archivo.

Para ver el contenido de la base de datos sin el servidor:

```bash
dart run bin/inspeccionar_db.dart
#   usuarios         2 filas
#   doctores         6 filas
#   servicios        6 filas
#   citas            6 filas
#   sesiones         1 filas
#   doctor_horarios  51 filas
```

Abre el archivo en **modo solo lectura y en un proceso aparte**, así que sirve
de prueba independiente de que los datos están realmente guardados y no en la
memoria del servidor.

### Cuentas sembradas

| Correo | Contraseña | Rol |
|---|---|---|
| `brandon@saludcuidado.com` | `demo1234` | `ROLE_USER` |
| `admin@saludcuidado.com` | `admin123` | `ROLE_USER`, `ROLE_ADMIN` |

### Por qué Dart + SQLite

El backend original (`ejemplo_99`) es Spring Boot con MySQL **y** MongoDB. En el
equipo no hay Java, Maven, Docker ni esos motores instalados: extenderlo pedía
~3 GB de descargas y cuatro servicios encendidos a la vez el día de la
sustentación. Dart + SQLite da lo que hacía falta —tablas, claves foráneas,
transacciones y un archivo `.db` inspeccionable— con un solo comando, y deja
todo el sistema en un mismo lenguaje que la app.

---

## 2. Esquema

```
usuarios ──┬── usuario_roles        (ROLE_USER / ROLE_ADMIN)
           ├── sesiones             (token de portador)
           └── citas ──┬── doctores ── doctor_horarios
                       └── servicios
```

| Tabla | Origen en el proyecto Java |
|---|---|
| `usuarios`, `usuario_roles` | `models/mysql/Usuario.java` |
| `sesiones` | sesión de Spring Security |
| `doctores`, `doctor_horarios` | `models/mongo/Doctor.java` |
| `servicios` | `models/mongo/Servicio.java` |
| `citas` | `models/mongo/Cita.java` |

### La regla de negocio vive en la base de datos

```sql
CREATE UNIQUE INDEX ix_citas_slot
  ON citas (doctor_id, fecha, hora)
  WHERE estado <> 'CANCELADA';
```

Es un índice **parcial**, y por eso resuelve dos cosas de una vez:

1. Dos personas que confirmen la misma hora con el mismo doctor en el mismo
   instante no pueden: la segunda inserción falla con `SQLITE_CONSTRAINT` (19) y
   la API responde `409 horario_ocupado`. No depende de que la app compruebe nada.
2. Al cancelar una cita, su fila deja de contar para el índice, así que **el
   horario vuelve a quedar libre** automáticamente.

Esto es exactamente lo que `CitaService.java` conseguía filtrando listas en
memoria, pero impuesto por el motor.

---

## 3. Endpoints

Todas las respuestas son JSON. Las rutas marcadas con 🔒 exigen la cabecera
`Authorization: Bearer <token>`, y las marcadas con 👑 exigen además
`ROLE_ADMIN` (sin él la respuesta es `403 prohibido`).

| Método | Ruta | Qué hace |
|---|---|---|
| `GET` | `/api/salud` | comprobación de vida: motor, versión y nº de doctores |
| `POST` | `/api/auth/registro` | crea el usuario y devuelve `{token, usuario}` |
| `POST` | `/api/auth/login` | valida credenciales y devuelve `{token, usuario}` |
| `POST` | `/api/auth/logout` | 🔒 invalida la sesión |
| `GET` | `/api/auth/yo` | 🔒 usuario de la sesión actual |
| `GET` | `/api/doctores?especialidad=&q=` | catálogo filtrable por especialidad y texto |
| `GET` | `/api/doctores/<id>` | un doctor con su agenda |
| `GET` | `/api/doctores/<id>/horarios?fecha=YYYY-MM-DD` | horas libres de ese día |
| `GET` | `/api/servicios` | catálogo de servicios |
| `GET` | `/api/citas` | 🔒 citas del usuario autenticado |
| `POST` | `/api/citas` | 🔒 reserva una cita |
| `PATCH` | `/api/citas/<id>` | 🔒 cambia el estado (`CANCELADA` / `COMPLETADA`) |
| `DELETE` | `/api/citas/<id>` | 🔒 elimina la cita |
| `GET` | `/api/estadisticas` | 🔒 totales por estado |

### API de administración

Traza `AdminController.java` y `UsuarioController.java` del proyecto Java, cuyo
acceso `SecurityConfig` restringe con
`.requestMatchers("/admin/**").hasAuthority("ROLE_ADMIN")`. El guardia está en
`_exigirAdmin()` (`lib/rutas/admin.dart`): sin sesión responde `401`, con sesión
pero sin el rol responde `403`, **antes** de tocar la base de datos.

| Método | Ruta | Qué hace |
|---|---|---|
| `GET` | `/api/admin/resumen` | 👑 cifras por estado, serie de 6 meses, doctores más solicitados y totales del sistema |
| `GET` | `/api/admin/citas?estado=&rango=&q=` | 👑 todas las citas, con el paciente de cada una |
| `PATCH` | `/api/admin/citas/<id>` | 👑 cambia el estado de cualquier cita |
| `DELETE` | `/api/admin/citas/<id>` | 👑 elimina cualquier cita |
| `GET` | `/api/admin/doctores` | 👑 doctores con sus campos sueltos y su estado `activo` |
| `POST` | `/api/admin/doctores` | 👑 crea un doctor (id `doc-00N`) con su rejilla de horarios |
| `PUT` | `/api/admin/doctores/<id>` | 👑 actualiza el doctor y reescribe sus horarios |
| `DELETE` | `/api/admin/doctores/<id>` | 👑 lo elimina, o lo **desactiva** si tiene citas |
| `GET` | `/api/admin/servicios` | 👑 servicios con su estado `activo` |
| `POST` | `/api/admin/servicios` | 👑 crea un servicio |
| `PUT` | `/api/admin/servicios/<id>` | 👑 actualiza el servicio |
| `DELETE` | `/api/admin/servicios/<id>` | 👑 lo elimina, o lo **desactiva** si tiene citas |
| `GET` | `/api/admin/usuarios` | 👑 usuarios con roles, estado y nº de citas |
| `PATCH` | `/api/admin/usuarios/<id>` | 👑 `activo` (desactivar borra sus sesiones) y `esAdmin` (da o quita el rol) |

Dos protecciones que conviene conocer:

- **Nunca se deja una cita huérfana.** Borrar un doctor o un servicio que tiene
  citas no borra la fila: la desactiva (`activo = 0`), deja de aparecer en el
  catálogo público y el historial se conserva. La respuesta lo dice.
- **Un administrador no puede desactivarse a sí mismo** (`409 conflicto`), para
  que no sea posible quedarse sin ningún acceso de administración.
- Desactivar un usuario **borra sus filas de `sesiones`**, así que su token deja
  de valer en la petición siguiente, no al cabo de un rato.

### Ejemplos

```bash
# Iniciar sesión
curl -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"brandon@saludcuidado.com","password":"demo1234"}'

# Reservar (TOKEN es el valor devuelto arriba)
curl -X POST http://localhost:8080/api/citas \
  -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
  -d '{"doctorId":"doc-001","fecha":"2026-11-20","hora":"09:30"}'

# Cancelar
curl -X PATCH http://localhost:8080/api/citas/cita-001 \
  -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
  -d '{"estado":"CANCELADA"}'
```

### Formato de error

Siempre el mismo, para que el cliente pueda traducirlo sin adivinar:

```json
{ "error": { "codigo": "horario_ocupado", "mensaje": "El horario ya está ocupado" } }
```

| Código HTTP | Cuándo |
|---|---|
| `400` | falta un campo o la fecha no es válida |
| `401` | credenciales incorrectas o token ausente/vencido |
| `403` | hay sesión, pero el usuario no tiene `ROLE_ADMIN` |
| `404` | el doctor o la cita no existe |
| `409` | el correo ya está registrado, o el horario ya está ocupado |
| `500` | error no previsto (queda en la traza del servidor) |

---

## 4. Reglas de horarios

Portadas tal cual desde `CitaService.obtenerHorariosDisponiblesString()`
(`lib/horarios.dart`):

1. Rejilla de **07:00 a 19:00 cada 30 minutos**.
2. Si la fecha es hoy, se descartan las horas ya pasadas.
3. Se descartan las horas ocupadas por citas no canceladas de ese doctor.
4. Se intersecta con la agenda propia del doctor (`doctor_horarios`), que es un
   añadido del contrato móvil.

---

## 5. Seguridad

- Las contraseñas no se guardan: se almacena **PBKDF2-HMAC-SHA256**, 12 000
  iteraciones, clave de 32 bytes y **sal distinta por usuario**
  (`lib/seguridad.dart`).
- La comparación de hashes es de **tiempo constante**, para no filtrar
  información por el tiempo de respuesta.
- La sesión es un **token opaco** guardado en la tabla `sesiones`; cerrar sesión
  lo borra. No es un JWT a propósito: así se puede revocar del lado del servidor.
- CORS abierto en desarrollo, para que Flutter Web pueda llamar desde
  `localhost:5000`.

> Para un despliegue real faltarían HTTPS, caducidad de sesión y límite de
> intentos de inicio de sesión.

---

## 6. Estructura

```
bin/
├── server.dart              arranque, argumentos --puerto y --db
└── inspeccionar_db.dart     cuenta las filas de cada tabla
lib/
├── db.dart                  esquema, siembra, usuarios y sesiones
├── seguridad.dart           PBKDF2 + comparación en tiempo constante
├── http_util.dart           respuestas JSON, CORS, traza, autenticación
├── horarios.dart            reglas portadas de CitaService.java
└── rutas/
    ├── json.dart            serializadores compartidos (camelCase)
    ├── api.dart             endpoints públicos y del paciente
    └── admin.dart           endpoints /api/admin/** (exigen ROLE_ADMIN)
datos/
└── saludcuidado.db          la base de datos (se crea al arrancar)
sqlite3.dll                  motor SQLite 3.48.0 para Windows
```

El servidor es una tubería de middleware de `shelf`:

```
capturarErrores → trazar → cors → autenticacion → Cascade(admin, api)
```

`Cascade` prueba primero el enrutador de administración y, si éste responde
`404`/`405` (la ruta no es suya), cae al público. Así los dos conjuntos de
rutas viven en archivos separados sin pisarse.

Cada petición queda trazada con método, ruta, código y duración, igual que en la
app, de modo que una misma acción se puede seguir en los dos lados.

## 7. Qué se versiona y qué no

`.gitignore` deja fuera todo lo que una máquina nueva puede regenerar, y una
cosa que además no debe salir del equipo:

| Ruta | Por qué se ignora |
|---|---|
| `.dart_tool/` | Lo regenera `dart pub get`. Guarda rutas absolutas de la máquina que lo creó (`C:/Users/...`), así que en otro equipo apunta a carpetas que no existen. |
| `datos/*.db`, `-shm`, `-wal` | Es un artefacto de ejecución. Versionarla publicaría las citas de prueba y los hashes PBKDF2 de las contraseñas. |
| `.env`, `*.key`, `*.pem` | Credenciales. Hoy no hay ninguna, pero si se añade un host o una clave, que no se suba por descuido. |
| `*.log` | Salida del servidor. |

Dos que sí se versionan a propósito:

- **`pubspec.lock`** — esto es una aplicación, no una biblioteca. Fijar las
  versiones exactas hace que el equipo y el servidor instalen lo mismo.
- **`sqlite3.dll`** — el paquete `sqlite3` no trae el motor; lo busca en el
  sistema. Dejarlo en el repositorio hace que en Windows baste `dart pub get`
  y `dart run bin/server.dart` tras clonar, sin instalar nada. En Linux o
  macOS este archivo se ignora y el motor lo da el sistema
  (`apt install libsqlite3-0`, o ya viene incluido en macOS).

Al clonar, la base de datos no está, y eso es lo normal: `bin/server.dart` crea
la carpeta `datos/` si falta y `Db.abrir` aplica el esquema y siembra los 6
doctores, 6 servicios y 2 usuarios cuando las tablas están vacías. Comprobado
sobre una carpeta vacía:

```
Base de datos : .../clon-limpio/datos/prueba.db
Sembrando datos iniciales...
Semilla lista: 6 doctores, 6 servicios, 2 usuarios.
```

> Las dos cuentas sembradas (§1) son de demostración y sus contraseñas están
> aquí escritas a propósito. No sirven en ningún otro sitio; si esta API se
> publica en Internet, cámbialas en `lib/db.dart` antes.
