# Despliegue en AWS (EKS)

Un solo contenedor sirve la API y la app web en el puerto 8080. Eso
significa una sola URL, sin CORS que configurar y sin coordinar dos
servicios detras de un ingress.

## Antes de empezar

La imagen incluye la app web compilada, asi que hay que generarla
primero:

```bash
cd ../SaludCuidado-flutter
flutter build web --release
cp -r build/web ../SaludCuidado-backend/publico
```

## Construir y publicar la imagen

Los nodos de EKS son linux/amd64; si se construye en otra arquitectura
el pod se queda en `CrashLoopBackOff` sin un mensaje obvio.

```bash
docker build --platform linux/amd64 -t <USUARIO>/saludcuidado:1.0 .
docker push <USUARIO>/saludcuidado:1.0
```

Probar la imagen en local **antes** de crear el cluster, en las mismas
condiciones que tendra en Kubernetes (sin root y con el disco de solo
lectura):

```bash
docker run --rm -p 8099:8080 --read-only \
  --tmpfs /app/datos:uid=1001,gid=1001 --user 1001:1001 \
  <USUARIO>/saludcuidado:1.0
```

## Desplegar

Sustituir `<USUARIO>` en `deployment.yaml` por la cuenta de Docker Hub.

```bash
kubectl apply -f namespace.yaml
kubectl apply -f pvc.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

kubectl get pods -n saludcuidado -w
kubectl get svc  -n saludcuidado
```

La columna `EXTERNAL-IP` del servicio da el nombre DNS del balanceador:
esa es la URL publica. Tarda un par de minutos en aparecer.

## Decisiones que conviene saber

**Una sola replica.** Los datos viven en SQLite dentro del pod. Con
varias replicas cada una tendria su propia base de datos: un paciente
podria registrarse, que el balanceador lo mandara a otro pod en la
siguiente peticion y que su cuenta "no existiera". Por eso tampoco hay
HorizontalPodAutoscaler. Escalar de verdad exigiria sacar la base a un
servicio aparte, que esta fuera del alcance de la entrega.

**Volumen para la base.** Sin el, cada reinicio del pod empezaria con
una base vacia. El contenedor es desechable; los datos no.

**Zona horaria.** `TZ=America/Bogota`. Sin esto el contenedor corre en
UTC y, entre las 19:00 y medianoche hora local, marcaria como vencidas
citas que todavia no han llegado.

**Sonda de vida.** `/api/salud` consulta la base de datos, asi que un
200 significa que el servidor y la base estan sanos, no solo que el
proceso sigue vivo.

## Apagar

EKS se cobra por hora desde que el cluster existe. Al terminar la
evaluacion:

```bash
kubectl delete namespace saludcuidado
eksctl delete cluster --name <NOMBRE-DEL-CLUSTER>
```

Borrar el namespace antes que el cluster no es un detalle: se asegura de
que el balanceador y el disco EBS se eliminen. Si se borra el cluster
directamente, esos recursos pueden quedar huerfanos y siguen cobrandose.
