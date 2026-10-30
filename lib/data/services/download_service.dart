import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/storage/local_storage.dart';
import '../models/download_item.dart';
import '../models/stream_server.dart';

/// Servicio global de descargas (películas / episodios).
/// - Progresivo (mp4/mkv/ts)
/// - HLS (m3u8 + segmentos)
/// - Subtítulos externos
/// - Notificación nativa (Android)
/// - Segundo plano en móvil vía foreground service nativo
class DownloadService extends ChangeNotifier {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  static const _storageKey = 'downloads_v1';
  static const _channel = MethodChannel('com.lol.lite/downloads');

  LocalStorage? _storage;
  final List<DownloadItem> _items = [];
  final Map<String, http.Client> _clients = {};
  final Map<String, bool> _cancelFlags = {};
  bool _running = false;
  int maxParallel = 3;
  /// TV: toasts cortos en vez de notificación del sistema.
  bool softToast = false;
  static const _parallelKey = 'download_max_parallel';

  List<DownloadItem> get items => List.unmodifiable(_items);
  List<DownloadItem> get active =>
      _items.where((e) => e.status == DownloadStatus.downloading || e.status == DownloadStatus.queued).toList();
  List<DownloadItem> get completed =>
      _items.where((e) => e.status == DownloadStatus.completed).toList();
  int get activeCount => active.length;

  /// Busca una descarga completada para reproducir offline.
  DownloadItem? findCompleted({
    required String repoId,
    required String contentId,
    int? season,
    int? episode,
  }) {
    for (final e in _items) {
      if (e.status != DownloadStatus.completed) continue;
      if (e.repoId != repoId) continue;
      if (e.contentId != contentId && !e.contentId.startsWith('$contentId:')) continue;
      if (season != null && episode != null) {
        if (e.season == season && e.episode == episode) return e;
        continue;
      }
      if (season == null && episode == null) return e;
    }
    // fallback: cualquier completed del contentId
    for (final e in _items) {
      if (e.status == DownloadStatus.completed &&
          e.repoId == repoId &&
          (e.contentId == contentId || e.contentId.startsWith('$contentId:'))) {
        if (season == null || e.season == season) {
          if (episode == null || e.episode == episode) return e;
        }
      }
    }
    return null;
  }

  bool isDownloaded({
    required String repoId,
    required String contentId,
    int? season,
    int? episode,
  }) =>
      findCompleted(repoId: repoId, contentId: contentId, season: season, episode: episode) != null;

  /// StreamServer local para el player (file:// o path absoluto).
  StreamServer? offlineServerFor({
    required String repoId,
    required String contentId,
    int? season,
    int? episode,
  }) {
    final d = findCompleted(
      repoId: repoId,
      contentId: contentId,
      season: season,
      episode: episode,
    );
    if (d == null || d.localPath == null || d.localPath!.isEmpty) return null;
    final path = d.localPath!;
    final file = File(path);
    if (!file.existsSync()) return null;
    final uri = path.startsWith('file:') ? path : Uri.file(path).toString();
    final subs = d.subtitles
        .where((s) => s.localPath != null && s.localPath!.isNotEmpty)
        .map((s) => ExternalSubtitle(
              lang: s.lang,
              label: s.label,
              url: s.localPath!.startsWith('file:')
                  ? s.localPath!
                  : Uri.file(s.localPath!).toString(),
            ))
        .toList();
    return StreamServer(
      url: uri,
      name: 'Descarga local',
      quality: d.quality ?? 'Offline',
      language: 'local',
      provider: d.repoName,
      isHls: path.endsWith('.m3u8'),
      subtitles: subs,
    );
  }

  void bind(LocalStorage storage) {
    _storage = storage;
  }

  Future<void> init() async {
    final s = _storage;
    if (s == null) return;
    final raw = s.getJson(_storageKey);
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          try {
            final item = DownloadItem.fromJson(Map<String, dynamic>.from(e));
            // Reanudar como queued si estaba downloading al cerrar
            // Reanudar sin perder progreso (Range / segmentos ya bajados)
            if (item.status == DownloadStatus.downloading) {
              item.status = DownloadStatus.queued;
            }
            _items.add(item);
          } catch (err) {
            debugPrint('[Download] skip: $err');
          }
        }
      }
    }
    final parRaw = s.getJson(_parallelKey);
    final par = parRaw is int ? parRaw : int.tryParse('${parRaw ?? ''}');
    if (par != null && par >= 1 && par <= 8) maxParallel = par;
    notifyListeners();
    unawaited(_pumpQueue());
  }

  Future<void> setMaxParallel(int n) async {
    maxParallel = n.clamp(1, 8);
    final s = _storage;
    if (s != null) await s.setJson(_parallelKey, maxParallel);
    notifyListeners();
  }

  Future<void> convertItem(String id) async {
    final i = _items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final item = _items[i];
    if (item.localPath == null) return;
    _items[i] = item.copyWith(status: DownloadStatus.converting);
    notifyListeners();
    try {
      final local = item.localPath!;
      final folder = File(local).parent.path;
      final out = await _channel.invokeMethod<String>('convert', {
        'input': local,
        'kind': item.kind.name,
        'outputDir': folder,
        'title': item.displayTitle,
      });
      if (out != null && out.isNotEmpty) {
        _items[i] = _items[i].copyWith(
          status: DownloadStatus.completed,
          localPath: out,
          progress: 1,
        );
      } else {
        _items[i] = item.copyWith(
          status: DownloadStatus.failed,
          error: 'No se pudo guardar en Descargas/lollite',
        );
      }
    } catch (e) {
      _items[i] = item.copyWith(status: DownloadStatus.failed, error: 'Convert: $e');
    }
    await _persist();
    notifyListeners();
    await _notifyNative(hide: active.isEmpty);
  }

  Future<void> _persist() async {
    final s = _storage;
    if (s == null) return;
    await s.setJson(_storageKey, _items.map((e) => e.toJson()).toList());
  }

  DownloadKind _kindFor(String url, bool isHls) {
    final u = url.toLowerCase();
    if (isHls || u.contains('.m3u8')) return DownloadKind.hls;
    if (u.contains('.ts') && !u.contains('.m3u8')) return DownloadKind.ts;
    return DownloadKind.progressive;
  }

  /// Encola una descarga y arranca la cola.
  Future<DownloadItem> enqueue({
    required String repoId,
    required String repoName,
    required String contentId,
    required String title,
    String? poster,
    String type = 'movie',
    int? season,
    int? episode,
    String? episodeTitle,
    required StreamServer server,
    bool convertOnMobile = false,
  }) async {
    final id = '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}';
    final kind = _kindFor(server.url, server.isHls);
    final subs = server.subtitles
        .where((s) => s.url.isNotEmpty)
        .map((s) => SubtitleDownload(lang: s.lang, label: s.label, url: s.url))
        .toList();

    final item = DownloadItem(
      id: id,
      repoId: repoId,
      repoName: repoName,
      contentId: contentId,
      title: title,
      poster: poster,
      type: type,
      season: season,
      episode: episode,
      episodeTitle: episodeTitle,
      serverName: server.name,
      quality: server.quality,
      url: server.url,
      headers: Map<String, String>.from(server.headers),
      isHls: server.isHls || kind == DownloadKind.hls,
      subtitles: subs,
      kind: kind,
      convertOnMobile: convertOnMobile,
      status: DownloadStatus.queued,
    );
    _items.insert(0, item);
    await _persist();
    notifyListeners();
    unawaited(_pumpQueue());
    return item;
  }

  Future<void> cancel(String id) async {
    _cancelFlags[id] = true;
    _clients[id]?.close();
    final i = _items.indexWhere((e) => e.id == id);
    if (i >= 0) {
      _items[i] = _items[i].copyWith(status: DownloadStatus.cancelled, error: 'Cancelado');
      await _persist();
      notifyListeners();
      await _notifyNative();
    }
  }

  Future<void> remove(String id) async {
    await cancel(id);
    final i = _items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final item = _items[i];
    final path = item.localPath;

    // Solo borra caché interna de la app (lol_downloads/...).
    // NO toca Descargas/lollite (archivo convertido del usuario).
    if (path != null && path.isNotEmpty) {
      try {
        // Si el path ya es público (lollite / content://), no borrar
        final lower = path.toLowerCase();
        final isPublic = lower.contains('${Platform.pathSeparator}download') ||
            lower.contains('/download') ||
            lower.contains('lollite') ||
            path.startsWith('content:');
        if (!isPublic) {
          final f = File(path);
          Directory? root;
          if (await f.exists() || await Directory(path).exists()) {
            var parent = f.existsSync() ? f.parent : Directory(path);
            if (parent.path.endsWith('${Platform.pathSeparator}hls') ||
                parent.path.endsWith('/hls')) {
              parent = parent.parent;
            }
            if (parent.path.contains('lol_downloads')) {
              root = parent;
            }
          }
          if (root != null && await root.exists()) {
            await root.delete(recursive: true);
          } else if (await File(path).exists()) {
            await File(path).delete();
          }
        }
      } catch (e) {
        debugPrint('[Download] remove cache: $e');
      }
    }

    _items.removeAt(i);
    await _persist();
    notifyListeners();
    await _notifyNative(hide: active.isEmpty);
  }

  Future<void> retry(String id) async {
    final i = _items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    _cancelFlags[id] = false;
    _items[i] = _items[i].copyWith(
      status: DownloadStatus.queued,
      progress: 0,
      receivedBytes: 0,
      error: null,
    );
    await _persist();
    notifyListeners();
    unawaited(_pumpQueue());
  }

  Future<void> _pumpQueue() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final next = _items.cast<DownloadItem?>().firstWhere(
              (e) => e!.status == DownloadStatus.queued,
              orElse: () => null,
            );
        if (next == null) break;
        await _runOne(next);
      }
    } finally {
      _running = false;
      await _notifyNative(hide: active.isEmpty);
    }
  }

  Future<Directory> _baseDir() async {
    Directory dir;
    try {
      dir = await getApplicationDocumentsDirectory();
    } catch (_) {
      dir = Directory.systemTemp;
    }
    final d = Directory('${dir.path}/lol_downloads');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<void> _runOne(DownloadItem item) async {
    final idx = _items.indexWhere((e) => e.id == item.id);
    if (idx < 0) return;
    _cancelFlags[item.id] = false;
    _items[idx] = item.copyWith(status: DownloadStatus.downloading);
    await _persist();
    notifyListeners();
    await _notifyNative();

    try {
      final base = await _baseDir();
      final safe = item.title.replaceAll(RegExp(r'[^\w\s\-\.]'), '_').trim();
      final folder = Directory('${base.path}/${item.id}_$safe');
      if (!await folder.exists()) await folder.create(recursive: true);

      // Metadatos JSON
      final metaFile = File('${folder.path}/meta.json');
      await metaFile.writeAsString(jsonEncode({
        'title': item.title,
        'poster': item.poster,
        'repoId': item.repoId,
        'repoName': item.repoName,
        'contentId': item.contentId,
        'type': item.type,
        'season': item.season,
        'episode': item.episode,
        'episodeTitle': item.episodeTitle,
        'serverName': item.serverName,
        'quality': item.quality,
      }));

      // Poster
      if (item.poster != null && item.poster!.startsWith('http')) {
        try {
          final r = await http.get(Uri.parse(item.poster!)).timeout(const Duration(seconds: 15));
          if (r.statusCode == 200) {
            await File('${folder.path}/poster.jpg').writeAsBytes(r.bodyBytes);
          }
        } catch (_) {}
      }

      String? videoPath;
      if (item.kind == DownloadKind.hls) {
        videoPath = await _downloadHls(item, folder);
      } else {
        videoPath = await _downloadProgressive(item, folder);
      }

      if (_cancelFlags[item.id] == true) {
        final i2 = _items.indexWhere((e) => e.id == item.id);
        if (i2 >= 0) {
          _items[i2] = _items[i2].copyWith(status: DownloadStatus.cancelled);
          await _persist();
          notifyListeners();
        }
        return;
      }

      // Subtítulos
      final subsOut = <SubtitleDownload>[];
      for (var s = 0; s < item.subtitles.length; s++) {
        final sub = item.subtitles[s];
        try {
          final r = await http.get(Uri.parse(sub.url), headers: item.headers)
              .timeout(const Duration(seconds: 20));
          if (r.statusCode == 200) {
            final ext = sub.url.contains('.vtt')
                ? 'vtt'
                : (sub.url.contains('.srt') ? 'srt' : 'txt');
            final path = '${folder.path}/sub_$s.${sub.lang}.$ext';
            await File(path).writeAsBytes(r.bodyBytes);
            subsOut.add(SubtitleDownload(
              lang: sub.lang,
              label: sub.label,
              url: sub.url,
              localPath: path,
            ));
          }
        } catch (_) {}
      }

      // Conversión móvil (marcador: el nativo puede encolar ffmpeg si está disponible)
      var finalPath = videoPath;
      if (item.convertOnMobile && !kIsWeb && Platform.isAndroid && videoPath != null) {
        final i3 = _items.indexWhere((e) => e.id == item.id);
        if (i3 >= 0) {
          _items[i3] = _items[i3].copyWith(status: DownloadStatus.converting);
          notifyListeners();
          await _notifyNative();
        }
        try {
          final out = await _channel.invokeMethod<String>('convert', {
            'input': videoPath,
            'kind': item.kind.name,
            'outputDir': folder.path,
            'title': item.displayTitle,
          });
          if (out != null && out.isNotEmpty) finalPath = out;
        } catch (e) {
          debugPrint('[Download] convert skip: $e');
        }
      }

      final i4 = _items.indexWhere((e) => e.id == item.id);
      if (i4 >= 0) {
        final done = _items[i4].copyWith(
          status: DownloadStatus.completed,
          progress: 1,
          localPath: finalPath,
        );
        // actualizar paths de subs en el objeto original no es trivial; se dejan en disco
        _items[i4] = done;
        await _persist();
        notifyListeners();
        await _notifyNative();
      }
    } catch (e) {
      debugPrint('[Download] error ${item.id}: $e');
      final i5 = _items.indexWhere((e) => e.id == item.id);
      if (i5 >= 0 && _cancelFlags[item.id] != true) {
        _items[i5] = _items[i5].copyWith(
          status: DownloadStatus.failed,
          error: e.toString(),
        );
        await _persist();
        notifyListeners();
        await _notifyNative();
      }
    }
  }

  Future<String> _downloadProgressive(DownloadItem item, Directory folder) async {
    final client = http.Client();
    _clients[item.id] = client;
    try {
      final ext = _extFromUrl(item.url, item.kind);
      final out = File('${folder.path}/video.$ext');
      var existing = 0;
      if (await out.exists()) {
        existing = await out.length();
      }
      final req = http.Request('GET', Uri.parse(item.url));
      item.headers.forEach((k, v) => req.headers[k] = v);
      if (existing > 0) {
        req.headers['Range'] = 'bytes=$existing-';
      }
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode == 416) {
        // ya completo
        return out.path;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final total = (res.contentLength != null && res.statusCode == 206)
          ? existing + res.contentLength!
          : (res.contentLength ?? (item.totalBytes));
      final sink = out.openWrite(mode: existing > 0 ? FileMode.append : FileMode.write);
      var received = existing;
      await for (final chunk in res.stream) {
        if (_cancelFlags[item.id] == true) break;
        sink.add(chunk);
        received += chunk.length;
        final i = _items.indexWhere((e) => e.id == item.id);
        if (i >= 0) {
          final p = total != null && total > 0 ? received / total : 0.0;
          _items[i] = _items[i].copyWith(
            progress: p.clamp(0.0, 0.99),
            receivedBytes: received,
            totalBytes: total,
          );
          // Throttle notify
          if (received % (256 * 1024) < chunk.length) {
            notifyListeners();
            unawaited(_notifyNative());
          }
        }
      }
      await sink.flush();
      await sink.close();
      if (_cancelFlags[item.id] == true) {
        throw Exception('Cancelado');
      }
      return out.path;
    } finally {
      client.close();
      _clients.remove(item.id);
    }
  }

  Future<String> _downloadHls(DownloadItem item, Directory folder) async {
    // 1) Descargar playlist
    final playlistRes = await http
        .get(Uri.parse(item.url), headers: item.headers)
        .timeout(const Duration(seconds: 20));
    if (playlistRes.statusCode != 200) {
      throw Exception('No se pudo leer el m3u8 (${playlistRes.statusCode})');
    }
    var body = playlistRes.body;
    final baseUri = Uri.parse(item.url);

    // Master playlist → elegir la variante de mayor BANDWIDTH
    if (body.contains('#EXT-X-STREAM-INF')) {
      final lines = body.split('\n');
      String? bestUrl;
      var bestBw = -1;
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.startsWith('#EXT-X-STREAM-INF')) {
          final bwMatch = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
          final bw = int.tryParse(bwMatch?.group(1) ?? '') ?? 0;
          final next = (i + 1 < lines.length) ? lines[i + 1].trim() : '';
          if (next.isNotEmpty && !next.startsWith('#') && bw >= bestBw) {
            bestBw = bw;
            bestUrl = next;
          }
        }
      }
      if (bestUrl != null) {
        final variantUri = bestUrl.startsWith('http')
            ? Uri.parse(bestUrl)
            : baseUri.resolve(bestUrl);
        final vRes = await http
            .get(variantUri, headers: item.headers)
            .timeout(const Duration(seconds: 20));
        if (vRes.statusCode == 200) {
          body = vRes.body;
          // actualizar base
          final segFolder = Directory('${folder.path}/hls');
          if (!await segFolder.exists()) await segFolder.create(recursive: true);
          return _downloadHlsSegments(item, body, variantUri, segFolder);
        }
      }
    }

    final segFolder = Directory('${folder.path}/hls');
    if (!await segFolder.exists()) await segFolder.create(recursive: true);
    return _downloadHlsSegments(item, body, baseUri, segFolder);
  }

  Future<String> _downloadHlsSegments(
    DownloadItem item,
    String playlistBody,
    Uri baseUri,
    Directory segFolder,
  ) async {
    final lines = playlistBody.split('\n');
    final segmentUrls = <String>[];
    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      segmentUrls.add(t.startsWith('http') ? t : baseUri.resolve(t).toString());
    }
    if (segmentUrls.isEmpty) throw Exception('Playlist HLS sin segmentos');

    final total = segmentUrls.length;
    final names = List<String>.generate(
        total, (i) => 'seg_${i.toString().padLeft(5, '0')}.ts');
    var done = 0;
    var received = 0;
    final threads = maxParallel.clamp(1, 8);

    Future<void> downloadOne(int i) async {
      if (_cancelFlags[item.id] == true) return;
      final file = File('${segFolder.path}/${names[i]}');
      if (await file.exists() && await file.length() > 0) {
        received += await file.length();
        done++;
        return;
      }
      final r = await http
          .get(Uri.parse(segmentUrls[i]), headers: item.headers)
          .timeout(const Duration(seconds: 30));
      if (r.statusCode == 200) {
        await file.writeAsBytes(r.bodyBytes);
        received += r.bodyBytes.length;
      }
      done++;
      final idx = _items.indexWhere((e) => e.id == item.id);
      if (idx >= 0) {
        _items[idx] = _items[idx].copyWith(
          progress: (done / total).clamp(0.0, 0.99),
          receivedBytes: received,
        );
        if (done % threads == 0 || done == total) {
          notifyListeners();
          unawaited(_notifyNative());
        }
      }
    }

    // Pool de hilos (default 3, configurable)
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (_cancelFlags[item.id] == true) return;
        final i = next;
        next++;
        if (i >= total) return;
        try {
          await downloadOne(i);
        } catch (_) {}
      }
    }

    await Future.wait(List.generate(threads, (_) => worker()));
    if (_cancelFlags[item.id] == true) throw Exception('Cancelado');

    final localPlaylist = StringBuffer();
    localPlaylist.writeln('#EXTM3U');
    localPlaylist.writeln('#EXT-X-VERSION:3');
    for (var i = 0; i < total; i++) {
      final f = File('${segFolder.path}/${names[i]}');
      if (await f.exists()) {
        localPlaylist.writeln('#EXTINF:6.0,');
        localPlaylist.writeln(names[i]);
      }
    }
    localPlaylist.writeln('#EXT-X-ENDLIST');
    final pl = File('${segFolder.path}/index.m3u8');
    await pl.writeAsString(localPlaylist.toString());
    return pl.path;
  }

  String _extFromUrl(String url, DownloadKind kind) {
    final u = url.toLowerCase().split('?').first;
    if (u.endsWith('.mp4')) return 'mp4';
    if (u.endsWith('.mkv')) return 'mkv';
    if (u.endsWith('.webm')) return 'webm';
    if (u.endsWith('.ts') || kind == DownloadKind.ts) return 'ts';
    if (kind == DownloadKind.hls) return 'm3u8';
    return 'mp4';
  }

  /// Estima tamaño: HEAD Content-Length, o para HLS suma de segmentos / bandwidth.
  static Future<int?> estimateSize(String url, Map<String, String> headers) async {
    try {
      final res = await http.head(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode >= 200 && res.statusCode < 400) {
        final cl = res.headers['content-length'];
        if (cl != null) {
          final n = int.tryParse(cl);
          if (n != null && n > 0) return n;
        }
      }
    } catch (_) {}

    // HLS: leer playlist
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8')) {
      try {
        final res = await http
            .get(Uri.parse(url), headers: headers)
            .timeout(const Duration(seconds: 12));
        if (res.statusCode != 200) return null;
        final body = res.body;
        final base = Uri.parse(url);

        // Master: estimar por BANDWIDTH * duración aprox
        if (body.contains('#EXT-X-STREAM-INF')) {
          var bestBw = 0;
          final lines = body.split('\n');
          for (final line in lines) {
            if (line.contains('BANDWIDTH=')) {
              final m = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
              final bw = int.tryParse(m?.group(1) ?? '') ?? 0;
              if (bw > bestBw) bestBw = bw;
            }
          }
          // ~45 min típico si no hay duración; 45*60*bw/8
          if (bestBw > 0) return (bestBw / 8 * 45 * 60).round();
        }

        // Media playlist: sumar EXTINF y HEAD del primer segmento * n
        final segUrls = <String>[];
        double duration = 0;
        final lines = body.split('\n');
        for (var i = 0; i < lines.length; i++) {
          final t = lines[i].trim();
          if (t.startsWith('#EXTINF:')) {
            final m = RegExp(r'#EXTINF:([\d.]+)').firstMatch(t);
            duration += double.tryParse(m?.group(1) ?? '') ?? 0;
          } else if (t.isNotEmpty && !t.startsWith('#')) {
            segUrls.add(t.startsWith('http') ? t : base.resolve(t).toString());
          }
        }
        if (segUrls.isEmpty) return null;
        // HEAD del primer segmento
        int? one;
        try {
          final h = await http
              .head(Uri.parse(segUrls.first), headers: headers)
              .timeout(const Duration(seconds: 6));
          final cl = h.headers['content-length'];
          if (cl != null) one = int.tryParse(cl);
        } catch (_) {}
        if (one != null && one > 0) return one * segUrls.length;
        // fallback bandwidth-ish: 2.5 Mbps * duration
        if (duration > 0) return (2.5 * 1000 * 1000 / 8 * duration).round();
      } catch (_) {}
    }
    return null;
  }

  Future<void> _notifyNative({bool hide = false}) async {
    try {
      if (hide) {
        await _channel.invokeMethod('hide');
        return;
      }
      final activeItems = active;
      if (activeItems.isEmpty) {
        await _channel.invokeMethod('hide');
        return;
      }
      final cur = activeItems.first;
      await _channel.invokeMethod('update', {
        'title': cur.displayTitle,
        'progress': (cur.progress * 100).round(),
        'status': cur.status.name,
        'count': activeItems.length,
        'repo': cur.repoName,
        'soft': softToast,
      });
    } catch (e) {
      debugPrint('[Download] notif: $e');
    }
  }
}
