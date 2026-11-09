import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Derivacion de contrasenas y generacion de tokens.
///
/// Las contrasenas NUNCA se guardan en claro: se almacena el resultado de
/// PBKDF2-HMAC-SHA256 junto con una sal aleatoria por usuario.
class Seguridad {
  Seguridad._();

  static final Random _rnd = Random.secure();

  /// Iteraciones de PBKDF2. Valor moderado para que el login siga siendo
  /// instantaneo en el equipo de demostracion.
  static const int _iteraciones = 12000;
  static const int _largoLlave = 32; // bytes

  static String _aleatorioHex(int bytes) {
    final b = List<int>.generate(bytes, (_) => _rnd.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  static String generarSal() => _aleatorioHex(16);

  static String generarToken() => _aleatorioHex(32);

  /// PBKDF2-HMAC-SHA256 implementado sobre el paquete `crypto`.
  static String derivar(String password, String sal) {
    final hmac = Hmac(sha256, utf8.encode(password));
    final salBytes = utf8.encode(sal);

    final bloques = (_largoLlave / 32).ceil();
    final salida = <int>[];

    for (var bloque = 1; bloque <= bloques; bloque++) {
      // U1 = HMAC(password, sal || INT_32_BE(bloque))
      var u = hmac.convert([...salBytes, ..._enteroBE(bloque)]).bytes;
      final acumulado = List<int>.from(u);

      for (var i = 1; i < _iteraciones; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < acumulado.length; j++) {
          acumulado[j] ^= u[j];
        }
      }
      salida.addAll(acumulado);
    }

    return salida
        .take(_largoLlave)
        .map((x) => x.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static List<int> _enteroBE(int v) =>
      [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

  /// Comparacion en tiempo constante, para no filtrar informacion por el
  /// tiempo de respuesta.
  static bool iguales(String a, String b) {
    if (a.length != b.length) return false;
    var dif = 0;
    for (var i = 0; i < a.length; i++) {
      dif |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return dif == 0;
  }

  static bool verificar(String password, String sal, String hashEsperado) =>
      iguales(derivar(password, sal), hashEsperado);
}
