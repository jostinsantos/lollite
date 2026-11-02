import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:apk_sideload/install_apk.dart';

/// Verifica actualizaciones leyendo el JSON público en GitHub.
///
/// Fuente:
/// https://raw.githubusercontent.com/LOLapptv/lollite/main/lollite.json
class VersionService {
  VersionService._();
  static final VersionService instance = VersionService._();

  // ============================================
  // CONFIGURA AQUÍ LA VERSIÓN ACTUAL DE TU APP
  // ============================================
  static const String currentVersionName = '0.0.2'; // version (debe coincidir con pubspec / build)
  static const String currentParche = '013'; // parche local (comparar con remoto lollite.json)
  static const String appId = 'lollite';

  static const String manifestUrl =
      'https://raw.githubusercontent.com/LOLapptv/lollite/main/lollite.json';

  /// Obtiene la entrada de esta app desde GitHub.
  Future<AppVersionInfo?> fetchRemote() async {
    try {
      final res = await http
          .get(
            Uri.parse(manifestUrl),
            headers: const {
              'Accept': 'application/json',
              'User-Agent': 'LolliteApp/1.0',
              'Cache-Control': 'no-cache',
            },
          )
          .timeout(const Duration(seconds: 12));

      if (res.statusCode != 200) {
        debugPrint('[Version] HTTP ${res.statusCode}');
        return null;
      }

      final jsonData = json.decode(res.body);
      if (jsonData is! Map) return null;
      final apps = jsonData['apps'];
      if (apps is! List || apps.isEmpty) return null;

      Map<String, dynamic>? match;
      for (final e in apps) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final id = (m['app'] ?? '').toString().toLowerCase();
        if (id == appId.toLowerCase()) {
          match = m;
          break;
        }
      }
      match ??= Map<String, dynamic>.from(apps.first as Map);
      return AppVersionInfo.fromJson(match);
    } catch (e) {
      debugPrint('[Version] fetch error: $e');
      return null;
    }
  }

  /// Compara nombres tipo "1.0.3" vs "1.0.2".
  /// >0 si a es más nueva, <0 si b es más nueva, 0 si iguales.
  static int compareVersionNames(String a, String b) {
    List<int> parts(String v) {
      final cleaned = v.trim();
      final only = RegExp(r'[0-9]+(?:\.[0-9]+)*').firstMatch(cleaned);
      final s = only?.group(0) ?? cleaned;
      return s.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    }

    final pa = parts(a);
    final pb = parts(b);
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  /// Compara parches tipo "2024.11.20" (orden lexicográfico tras normalizar).
  static int compareParche(String a, String b) {
    String norm(String v) {
      final digits = v.trim().replaceAll(RegExp(r'[^0-9.]'), '');
      return digits;
    }

    final na = norm(a);
    final nb = norm(b);
    // Primero por semver numérico de segmentos
    final cmp = compareVersionNames(na, nb);
    if (cmp != 0) return cmp;
    return na.compareTo(nb);
  }

  /// [notifyPatches]: si false, solo avisa por cambio de VERSIÓN (no por parche).
  Future<UpdateStatus> checkForUpdate({bool notifyPatches = true}) async {
    final latest = await fetchRemote();
    if (latest == null) {
      return UpdateStatus(
        requiresUpdate: false,
        hasVersionUpdate: false,
        hasPatchUpdate: false,
        latestVersion: null,
        message: 'No se pudo obtener información de actualización',
      );
    }

    final remoteName = latest.version.trim();
    final remoteParche = latest.parche.trim();

    // Versión siempre se notifica si el remoto es más nuevo
    final hasVersionUpdate =
        remoteName.isNotEmpty && compareVersionNames(remoteName, currentVersionName) > 0;

    final hasPatchUpdate = remoteParche.isNotEmpty &&
        compareParche(remoteParche, currentParche) > 0;

    // Solo VERSION siempre; PARCHES solo si el usuario tiene notificaciones activas
    final needsUpdate =
        hasVersionUpdate || (notifyPatches && hasPatchUpdate);

    String message;
    if (needsUpdate) {
      final parts = <String>[];
      if (hasVersionUpdate) {
        parts.add('versión ${latest.version}');
      }
      if (notifyPatches && hasPatchUpdate) {
        parts.add('parche ${latest.parche}');
      }
      message = 'Actualización disponible: ${parts.join(' · ')}';
    } else {
      message = 'Tu aplicación está actualizada';
    }

    return UpdateStatus(
      requiresUpdate: needsUpdate,
      hasVersionUpdate: hasVersionUpdate,
      hasPatchUpdate: hasPatchUpdate,
      latestVersion: latest,
      message: message,
    );
  }

  // ── Caché de última descarga (ABI + versión + URL) ──
  static const _kLastAbi = 'update_last_abi';
  static const _kLastVersion = 'update_last_version';
  static const _kLastParche = 'update_last_parche';
  static const _kLastUrl = 'update_last_url';
  static const _kLastAt = 'update_last_at';

  Future<void> saveLastDownload({
    required String abi,
    required String version,
    required String parche,
    required String url,
  }) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kLastAbi, abi);
      await p.setString(_kLastVersion, version);
      await p.setString(_kLastParche, parche);
      await p.setString(_kLastUrl, url);
      await p.setString(_kLastAt, DateTime.now().toIso8601String());
    } catch (e) {
      debugPrint('[Version] saveLastDownload: $e');
    }
  }

  Future<Map<String, String>?> loadLastDownload() async {
    try {
      final p = await SharedPreferences.getInstance();
      final abi = p.getString(_kLastAbi);
      final ver = p.getString(_kLastVersion);
      if (abi == null || ver == null) return null;
      return {
        'abi': abi,
        'version': ver,
        'parche': p.getString(_kLastParche) ?? '',
        'url': p.getString(_kLastUrl) ?? '',
        'at': p.getString(_kLastAt) ?? '',
      };
    } catch (_) {
      return null;
    }
  }

  /// ABI forzada para TV / Android TV (cache): solo armeabi.
  static const String tvForcedAbi = 'armeabi';

  /// Lista de ABIs disponibles en el remoto (con URL no vacía).
  List<({String id, String label, String url})> availableAbis(AppVersionInfo info) {
    final out = <({String id, String label, String url})>[];
    void add(String id, String label, String? url) {
      if (url != null && url.isNotEmpty) {
        out.add((id: id, label: label, url: url));
      }
    }
    add('arm64', 'ARM64 (recomendado móviles)', info.urlApkArm64);
    add('armeabi', 'ARMeabi (TV / dispositivos antiguos)', info.urlApkArmeabi);
    add('x86', 'x86 (emuladores)', info.urlApkX86);
    add('universal', 'Universal (todas las arquitecturas)', info.urlApkUniversal);
    return out;
  }

  /// Elige la mejor URL de APK según ABI preferida.
  String? resolveApkUrl(AppVersionInfo info, {String? preferredAbi}) {
    final order = <String>[
      if (preferredAbi != null) preferredAbi,
      'arm64',
      'universal',
      'armeabi',
      'x86',
    ];
    final seen = <String>{};
    for (final abi in order) {
      if (!seen.add(abi)) continue;
      final u = info.urlForAbi(abi);
      if (u != null && u.isNotEmpty) return u;
    }
    return null;
  }

  /// Descarga el APK a caché temporal. [onProgress] 0.0–1.0.
  /// Valida que el archivo sea un ZIP/APK real (cabecera PK) y no un HTML de error.
  Future<File?> downloadApk(
    String url, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/lollite_update.apk');
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }

      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(url));
        req.headers['User-Agent'] = 'LolliteApp/1.0';
        req.headers['Accept'] = '*/*';
        final streamed =
            await client.send(req).timeout(const Duration(minutes: 8));
        if (streamed.statusCode != 200) {
          debugPrint('[Version] download HTTP ${streamed.statusCode} url=$url');
          return null;
        }
        final total = streamed.contentLength ?? 0;
        final sink = file.openWrite();
        var received = 0;
        await for (final chunk in streamed.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0 && onProgress != null) {
            onProgress((received / total).clamp(0.0, 1.0));
          }
        }
        await sink.flush();
        await sink.close();
        if (onProgress != null) onProgress(1.0);

        // Sanity: APK es un ZIP → empieza por "PK"
        final len = await file.length();
        if (len < 1024 * 50) {
          debugPrint('[Version] download too small: $len bytes');
          try {
            await file.delete();
          } catch (_) {}
          return null;
        }
        final raf = await file.open();
        final header = await raf.read(4);
        await raf.close();
        final isZip = header.length >= 2 && header[0] == 0x50 && header[1] == 0x4B;
        if (!isZip) {
          debugPrint('[Version] download is not an APK/ZIP (bad header)');
          try {
            await file.delete();
          } catch (_) {}
          return null;
        }
        debugPrint('[Version] download OK ${len ~/ (1024 * 1024)} MB → ${file.path}');
        return file;
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('[Version] download error: $e');
      return null;
    }
  }

  /// Último error de instalación (para mostrar al usuario).
  String? lastInstallError;

  /// Instala un APK local con apk_sideload (solo Android).
  /// Requiere FileProvider con authority: ${applicationId}.install_apk.fileprovider
  Future<bool> installApkFile(String path) async {
    lastInstallError = null;
    if (!Platform.isAndroid) {
      lastInstallError = 'Solo disponible en Android';
      return false;
    }
    try {
      final f = File(path);
      if (!await f.exists()) {
        lastInstallError = 'El APK no existe en $path';
        return false;
      }
      final len = await f.length();
      if (len < 1024 * 50) {
        lastInstallError = 'APK incompleto ($len bytes)';
        return false;
      }
      await InstallApk().installApk(path);
      return true;
    } catch (e) {
      lastInstallError = e.toString();
      debugPrint('[Version] install error: $e');
      return false;
    }
  }
}

class AppVersionInfo {
  final String app;
  final String version;
  final String parche;
  final String? urlApkArm64;
  final String? urlApkArmeabi;
  final String? urlApkX86;
  final String? urlApkUniversal;
  final List<String> novedades;

  AppVersionInfo({
    required this.app,
    required this.version,
    required this.parche,
    this.urlApkArm64,
    this.urlApkArmeabi,
    this.urlApkX86,
    this.urlApkUniversal,
    this.novedades = const [],
  });

  factory AppVersionInfo.fromJson(Map<String, dynamic> j) {
    String? opt(dynamic v) {
      final s = v?.toString().trim();
      return (s != null && s.isNotEmpty) ? s : null;
    }

    final urls = j['paquete_url'];
    Map<String, dynamic> u = {};
    if (urls is Map) {
      u = Map<String, dynamic>.from(urls);
    }

    final nov = <String>[];
    final rawNov = j['novedades'];
    if (rawNov is List) {
      for (final e in rawNov) {
        final s = e?.toString().trim();
        if (s != null && s.isNotEmpty) nov.add(s);
      }
    } else if (rawNov is String && rawNov.trim().isNotEmpty) {
      nov.addAll(rawNov.split(RegExp(r'[\n;|]')).map((e) => e.trim()).where((e) => e.isNotEmpty));
    }

    return AppVersionInfo(
      app: j['app']?.toString() ?? '',
      version: j['version']?.toString() ?? '',
      parche: j['parche']?.toString() ?? '',
      urlApkArm64: opt(u['url_apk_arm64']),
      urlApkArmeabi: opt(u['url_apk_armeabi']),
      urlApkX86: opt(u['url_apk_x86']),
      urlApkUniversal: opt(u['url_apk_universal']),
      novedades: nov,
    );
  }

  String? urlForAbi(String abi) {
    switch (abi) {
      case 'arm64':
        return urlApkArm64;
      case 'armeabi':
        return urlApkArmeabi;
      case 'x86':
        return urlApkX86;
      case 'universal':
        return urlApkUniversal;
      default:
        return null;
    }
  }
}

class UpdateStatus {
  final bool requiresUpdate;
  final bool hasVersionUpdate;
  final bool hasPatchUpdate;
  final AppVersionInfo? latestVersion;
  final String message;

  UpdateStatus({
    required this.requiresUpdate,
    required this.hasVersionUpdate,
    required this.hasPatchUpdate,
    required this.latestVersion,
    required this.message,
  });
}
