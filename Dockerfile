# syntax=docker/dockerfile:1

# Imagen de SaludCuidado: un solo contenedor que sirve la API y la app web.
#
# Se construye en dos etapas para que la imagen final no arrastre el SDK de
# Dart (unos 800 MB) cuando lo unico que hace falta en produccion es el
# ejecutable ya compilado.
#
#   docker build -t saludcuidado:1.0 .
#   docker run --rm -p 8080:8080 saludcuidado:1.0
#
# La carpeta publico/ con la app Flutter Web compilada tiene que existir
# antes de construir:  flutter build web --release  y copiarla aqui.

# --------------------------------------------------------------- compilacion
FROM dart:3.13 AS compilacion

WORKDIR /app

# Las dependencias van en su propia capa y antes que el codigo: cambian
# mucho menos, asi que Docker reaprovecha esta capa en cada reconstruccion
# y solo vuelve a compilar lo que de verdad cambio.
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

COPY bin/ bin/
COPY lib/ lib/
RUN dart pub get --offline

# Un unico ejecutable nativo, sin SDK ni fuentes detras.
RUN dart compile exe bin/server.dart -o /app/servidor

# ----------------------------------------------------------------- ejecucion
FROM debian:bookworm-slim AS ejecucion

# El paquete sqlite3 de Dart abre la libreria por su nombre generico
# (libsqlite3.so), pero Debian solo instala libsqlite3.so.0: el enlace
# .so lo trae el paquete -dev, que no queremos en produccion. De ahi el
# symlink, en vez de arrastrar las cabeceras de desarrollo enteras.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates tzdata \
    && ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 \
              /usr/lib/x86_64-linux-gnu/libsqlite3.so \
    && rm -rf /var/lib/apt/lists/*

# Usuario sin privilegios. El despliegue exige runAsNonRoot, y ademas un
# servidor que atiende peticiones no tiene ninguna razon para ser root.
RUN groupadd --gid 1001 salud \
    && useradd --uid 1001 --gid 1001 --no-create-home --shell /usr/sbin/nologin salud

WORKDIR /app

COPY --from=compilacion /app/servidor /app/servidor
COPY publico/ /app/publico/

# La base de datos se escribe aqui. En Kubernetes este directorio se monta
# como volumen: el sistema de archivos del contenedor es de solo lectura.
RUN mkdir -p /app/datos && chown -R 1001:1001 /app/datos

USER 1001:1001

# Sin esto el contenedor corre en UTC, y la clinica esta en Colombia
# (UTC-5). Importa de verdad: entre las 19:00 y medianoche hora local el
# servidor ya creeria que es el dia siguiente, y marcaria como vencidas
# citas que todavia no han llegado.
ENV TZ=America/Bogota

ENV PUERTO=8080
ENV WEB_DIR=/app/publico
EXPOSE 8080

ENTRYPOINT ["/app/servidor"]
CMD ["--db", "/app/datos/saludcuidado.db"]
