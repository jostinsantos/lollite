import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/content_service.dart';
import '../../../../data/services/library_service.dart';
import '../../../../data/services/repo_prefs.dart';
import '../../../../data/services/settings_service.dart';
import '../../widgets/focusable.dart';
import '../player/player.dart';
import '../../widgets/cached_poster.dart';
import '../../../shared/download_sheet.dart';
import '../../../../data/services/download_service.dart';
import '../../../../data/models/stream_server.dart';

// ─── Paleta / constantes de diseño ──────────────────────────────────────────
const _kBg = Color(0xFF0B0E14);
const _kSurface = Color(0xFF141A22);
const _kSurface2 = Color(0xFF1A222D);
const _kAccent = Color(0xFFE50914);
const _kAccentHi = Color(0xFFFF2D2D);
const _kAmber = Color(0xFFFFC107);
const _kHPad = 20.0;

/// Si usas google_fonts o una fuente propia, ponla aquí (ej. 'Poppins').
const String? _kFont = null;

/// Ficha de contenido móvil — mismo historial / reanudar / barras que TV.
class DetailsPage extends StatefulWidget {
  final InstalledRepo repo;
  final String itemId;
  final int? season;
  final int? episode;

  const DetailsPage({
    super.key,
    required this.repo,
    required this.itemId,
    this.season,
    this.episode,
  });

  @override
  State<DetailsPage> createState() => _DetailsPageState();
}

class _DetailsPageState extends State<DetailsPage> {
  ContentItem? _item;
  bool _loading = true;
  int _seasonIndex = 0;
  int? _selectedEpisode;
  int _episodePage = 0;

  /// Historial LibraryService para este contenido.
  List<WatchEntry> _history = [];

  /// Progreso por episodio (player SharedPreferences + library).
  final Map<String, _EpProgress> _epProgress = {};

  int? _lastSeason;
  int? _lastEpisode;
  int _lastPositionMs = 0;
  int _lastDurationMs = 0;

  /// Sinopsis expandible.
  bool _synopsisExpanded = false;
  double _synWidth = -1;
  bool _synNeedsExpand = false;

  /// Similares.
  List<ContentItem> _similar = [];
  bool _loadingSimilar = false;

  /// Datos derivados (se calculan UNA vez al cargar, no en cada build).
  String? _director;
  String? _durationText;
  List<Map<String, dynamic>> _cast = const [];

  static String _epKey(int se, int ep) => 'S${se}E$ep';

  bool get _useEpPagination =>
      widget.repo.manifest.episodesPagination &&
      widget.repo.manifest.episodesPerPage > 0;

  int get _epPerPage => widget.repo.manifest.episodesPerPage.clamp(1, 200);

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ─── Historial ────────────────────────────────────────────────────────────

  Future<void> _loadPlayerHistorial() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'continue_watch_${widget.repo.manifest.id}_${widget.itemId}';
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final map = Map<String, dynamic>.from(decoded);

      final se = (map['season'] as num?)?.toInt() ??
          (map['temporada'] as num?)?.toInt();
      final ep = (map['episode'] as num?)?.toInt() ??
          (map['episodio'] as num?)?.toInt();
      final pos = (map['positionMs'] as num?)?.toInt() ??
          (((map['segundo'] as num?)?.toInt() ?? 0) * 1000);
      final dur = (map['durationMs'] as num?)?.toInt() ??
          (((map['duration'] as num?)?.toInt() ??
                  (map['durationSec'] as num?)?.toInt() ??
                  0) *
              1000);

      if (se != null && ep != null && pos > 0) {
        _lastSeason = se;
        _lastEpisode = ep;
        _lastPositionMs = pos;
        _lastDurationMs = dur > 0 ? dur : 0;
        final p = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;
        _epProgress[_epKey(se, ep)] = _EpProgress(
          positionMs: pos,
          durationMs: dur,
          progress: p,
        );
      }

      final list = map['episodeList'];
      if (list is List) {
        for (final e in list) {
          if (e is! Map) continue;
          final m = Map<String, dynamic>.from(e);
          final s2 = (m['season'] as num?)?.toInt();
          final e2 = (m['episode'] as num?)?.toInt() ??
              (m['number'] as num?)?.toInt();
          final pMs = (m['positionMs'] as num?)?.toInt();
          final dMs = (m['durationMs'] as num?)?.toInt();
          if (s2 == null || e2 == null || pMs == null || pMs <= 0) continue;
          final d = dMs ?? 0;
          _epProgress[_epKey(s2, e2)] = _EpProgress(
            positionMs: pMs,
            durationMs: d,
            progress: d > 0 ? (pMs / d).clamp(0.0, 1.0) : 0.0,
          );
        }
      }
    } catch (e) {
      debugPrint('[DetailsMobile] loadPlayerHistorial: $e');
    }
  }

  void _mergeLibraryHistory(List<WatchEntry> hist) {
    for (final e in hist) {
      final se = _entrySeason(e);
      final ep = _entryEpisode(e);
      if (se == null || ep == null) continue;
      final pos = e.positionMs;
      if (pos <= 0) continue;
      double p = 0;
      try {
        p = (e as dynamic).progress as double? ?? 0.0;
      } catch (_) {
        p = 0;
      }
      int dur = 0;
      try {
        final d = (e as dynamic).durationMs;
        if (d is int) dur = d;
      } catch (_) {}
      if (p <= 0 && dur > 0) p = (pos / dur).clamp(0.0, 1.0);
      final key = _epKey(se, ep);
      final existing = _epProgress[key];
      if (existing == null || pos >= existing.positionMs) {
        _epProgress[key] = _EpProgress(
          positionMs: pos,
          durationMs: dur > 0 ? dur : existing?.durationMs ?? 0,
          progress: p > 0 ? p : (existing?.progress ?? 0),
        );
      }
    }

    if (hist.isNotEmpty) {
      final h = hist.first;
      final se = _entrySeason(h);
      final ep = _entryEpisode(h);
      if (se != null && ep != null) {
        if (_lastSeason == null ||
            h.positionMs >= _lastPositionMs ||
            (_lastSeason == se && _lastEpisode == ep)) {
          _lastSeason = se;
          _lastEpisode = ep;
          _lastPositionMs = h.positionMs;
          try {
            final d = (h as dynamic).durationMs;
            if (d is int && d > 0) _lastDurationMs = d;
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _refreshHistoryAndFocus() async {
    if (!mounted) return;
    final lib = context.read<LibraryService>();
    final all = lib.continueWatching(widget.repo.manifest.id);
    final hist = all.where((e) => e.contentId == widget.itemId).toList();

    await _loadPlayerHistorial();
    _mergeLibraryHistory(hist);
    if (!mounted) return;

    setState(() {
      _history = hist;
      final item = _item;
      if (item != null && item.seasons.isNotEmpty) {
        final se = _lastSeason;
        final ep = _lastEpisode;
        if (se != null) {
          final idx = item.seasons.indexWhere((s) => s.number == se);
          if (idx >= 0) _seasonIndex = idx;
        }
        if (ep != null) {
          _selectedEpisode = ep;
          if (_useEpPagination) {
            final eps = item.seasons[_seasonIndex].episodes;
            final i = eps.indexWhere((e) => e.number == ep);
            if (i >= 0) _episodePage = i ~/ _epPerPage;
          }
        }
      }
    });
  }

  Future<void> _load() async {
    final item = await ContentService.instance.getDetails(
      widget.repo,
      widget.itemId,
      season: widget.season,
      episode: widget.episode,
    );
    if (!mounted) return;

    final lib = context.read<LibraryService>();
    final all = lib.continueWatching(widget.repo.manifest.id);
    final hist = all.where((e) => e.contentId == widget.itemId).toList();

    await _loadPlayerHistorial();
    _mergeLibraryHistory(hist);
    if (!mounted) return;

    setState(() {
      _item = item;
      _loading = false;
      _history = hist;

      if (item != null) {
        _director = _directorFrom(item);
        _durationText = _durationLabel(item);
        _cast = _castFrom(item);
      }

      if (item != null && item.seasons.isNotEmpty) {
        int? se = widget.season ?? _lastSeason;
        int? ep = widget.episode ?? _lastEpisode;
        if (se == null && ep == null && hist.isNotEmpty) {
          final h = hist.first;
          se = _entrySeason(h);
          ep = _entryEpisode(h);
        }
        if (se != null) {
          final idx = item.seasons.indexWhere((s) => s.number == se);
          _seasonIndex = idx >= 0 ? idx : 0;
        }
        _selectedEpisode = ep;
        if (_useEpPagination && ep != null) {
          final eps = item.seasons[_seasonIndex].episodes;
          final i = eps.indexWhere((e) => e.number == ep);
          if (i >= 0) _episodePage = i ~/ _epPerPage;
        }
      }
    });

    if (item != null) {
      unawaited(_loadSimilar(item));
    }
  }

  // ─── Helpers de datos ─────────────────────────────────────────────────────

  int _totalEpisodes(ContentItem item) {
    var n = 0;
    for (final s in item.seasons) {
      n += s.episodes.length;
    }
    return n;
  }

  /// Si solo tiene un capítulo, se trata como película en la UI.
  bool _treatAsMovie(ContentItem item) {
    if (!item.isSeries) return true;
    return _totalEpisodes(item) <= 1;
  }

  Future<void> _loadSimilar(ContentItem item) async {
    if (!mounted) return;
    setState(() => _loadingSimilar = true);
    try {
      final list =
          await ContentService.instance.search(widget.repo, item.title);
      if (!mounted) return;
      final filtered = list.where((e) => e.id != item.id).take(6).toList();
      setState(() {
        _similar = filtered;
        _loadingSimilar = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingSimilar = false);
    }
  }

  String? _directorFrom(ContentItem item) {
    final e = item.extra;
    final candidates = [
      e['director'],
      e['directed_by'],
      e['directedBy'],
      e['Director'],
      e['creators'],
      e['creator'],
    ];
    for (final c in candidates) {
      if (c == null) continue;
      if (c is String && c.trim().isNotEmpty) return c.trim();
      if (c is List && c.isNotEmpty) {
        final s = c
            .map((x) => x is Map
                ? (x['name'] ?? x['nombre'] ?? '').toString()
                : x.toString())
            .where((s) => s.isNotEmpty)
            .take(3)
            .join(', ');
        if (s.isNotEmpty) return s;
      }
    }
    return null;
  }

  String _fmtMins(int mins) {
    if (mins >= 60) {
      final h = mins ~/ 60;
      final m = mins % 60;
      return m > 0 ? '${h}h ${m}min' : '${h}h';
    }
    return '$mins min';
  }

  String? _durationLabel(ContentItem item) {
    final e = item.extra;
    final rt =
        e['runtime'] ?? e['duration'] ?? e['runtimeMinutes'] ?? e['durationMin'];
    if (rt is num && rt > 0) return _fmtMins(rt.round());
    if (rt is String && rt.trim().isNotEmpty) return rt.trim();
    if (item.seasons.isNotEmpty &&
        item.seasons.first.episodes.isNotEmpty &&
        item.seasons.first.episodes.first.runtime != null) {
      return _fmtMins(item.seasons.first.episodes.first.runtime!);
    }
    return null;
  }

  /// true si el texto de sinopsis supera [maxLines] a ese ancho.
  bool _synopsisExceedsLines(
    String text,
    TextStyle style,
    double maxWidth, {
    int maxLines = 3,
  }) {
    if (text.trim().isEmpty || maxWidth <= 0) return false;
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: maxLines,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    final r = tp.didExceedMaxLines;
    tp.dispose();
    return r;
  }

  List<Map<String, dynamic>> _castFrom(ContentItem item) {
    final e = item.extra;
    final raw = e['cast'] ?? e['actors'] ?? e['credits'] ?? e['reparto'];
    if (raw is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final x in raw) {
      if (x is Map) {
        final name =
            (x['name'] ?? x['nombre'] ?? x['character'] ?? '').toString();
        if (name.isEmpty) continue;
        out.add({
          'name': name,
          'photo': (x['photo'] ?? x['profile'] ?? x['image'] ?? x['poster'] ?? '')
              .toString(),
        });
      } else if (x is String && x.trim().isNotEmpty) {
        out.add({'name': x.trim(), 'photo': ''});
      }
      if (out.length >= 12) break;
    }
    return out;
  }

  int? _entrySeason(WatchEntry e) {
    try {
      final v = (e as dynamic).season;
      if (v is int) return v;
    } catch (_) {}
    return null;
  }

  int? _entryEpisode(WatchEntry e) {
    try {
      final v = (e as dynamic).episode;
      if (v is int) return v;
    } catch (_) {}
    return null;
  }

  WatchEntry? get _latestEntry => _history.isEmpty ? null : _history.first;

  double _progressForEpisode(int seasonNum, int epNum) {
    final p = _epProgress[_epKey(seasonNum, epNum)];
    if (p != null && p.progress > 0) return p.progress.clamp(0.0, 1.0);
    for (final e in _history) {
      if (_entrySeason(e) == seasonNum && _entryEpisode(e) == epNum) {
        try {
          final pr = (e as dynamic).progress;
          if (pr is num && pr > 0) return pr.toDouble().clamp(0.0, 1.0);
        } catch (_) {}
        final pos = e.positionMs;
        int dur = 0;
        try {
          final d = (e as dynamic).durationMs;
          if (d is int) dur = d;
        } catch (_) {}
        if (pos > 0 && dur > 0) return (pos / dur).clamp(0.0, 1.0);
      }
    }
    return 0;
  }

  int _positionMsForEpisode(int seasonNum, int epNum) {
    final p = _epProgress[_epKey(seasonNum, epNum)];
    if (p != null && p.positionMs > 0) return p.positionMs;
    for (final e in _history) {
      if (_entrySeason(e) == seasonNum && _entryEpisode(e) == epNum) {
        return e.positionMs;
      }
    }
    return 0;
  }

  int? get _selectedSeasonNumber {
    final item = _item;
    if (item == null || item.seasons.isEmpty) return null;
    if (_seasonIndex < 0 || _seasonIndex >= item.seasons.length) return null;
    return item.seasons[_seasonIndex].number;
  }

  String? _episodeTitle() {
    final item = _item;
    if (item == null || !item.isSeries || item.seasons.isEmpty) return null;
    final season = item.seasons[_seasonIndex];
    final ep =
        season.episodes.where((e) => e.number == _selectedEpisode).toList();
    return ep.isEmpty ? null : ep.first.title;
  }

  String _formatMinutes(int positionMs) {
    final totalSec = (positionMs / 1000).round();
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    if (m >= 60) {
      final h = m ~/ 60;
      final mm = m % 60;
      return '${h}h ${mm.toString().padLeft(2, '0')}m';
    }
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }

  String? get _resumeCode {
    final se = _lastSeason;
    final ep = _lastEpisode;
    if (se == null || ep == null) return null;
    return 'S${se.toString().padLeft(2, '0')}E${ep.toString().padLeft(2, '0')}';
  }

  String _playLabel(bool asMovie) {
    if (!asMovie) {
      final code = _resumeCode;
      if (code != null && _lastPositionMs > 3000) return 'REANUDAR $code';
    } else {
      final pos = _lastPositionMs > 0
          ? _lastPositionMs
          : (_latestEntry?.positionMs ?? 0);
      if (pos > 5000) return 'REANUDAR · ${_formatMinutes(pos)}';
    }
    return 'VER AHORA';
  }

  /// Progreso (0..1) para la barrita del botón principal.
  double _resumeProgress(bool asMovie) {
    if (!asMovie) {
      final se = _lastSeason, ep = _lastEpisode;
      if (se != null && ep != null && _lastPositionMs > 3000) {
        return _progressForEpisode(se, ep);
      }
      return 0;
    }
    if (_lastDurationMs > 0 && _lastPositionMs > 5000) {
      return (_lastPositionMs / _lastDurationMs).clamp(0.0, 1.0);
    }
    return 0;
  }

  /// Lista plana de TODOS los episodios de TODAS las temporadas (igual que TV).
  List<Map<String, dynamic>> _buildFullEpisodeList(ContentItem item) {
    final out = <Map<String, dynamic>>[];
    for (final s in item.seasons) {
      for (final e in s.episodes) {
        final still = _epStill(e);
        out.add({
          'season': s.number,
          'episode': e.number,
          'number': e.number,
          'id': e.id,
          'title': e.title,
          if (still != null) 'still': still,
        });
      }
    }
    return out;
  }

  ({int? se, int? ep, String? id, String? title}) _computeNext({
    required ContentItem item,
    required int? season,
    required int? episode,
  }) {
    final list = _buildFullEpisodeList(item);
    if (season == null || episode == null || list.isEmpty) {
      return (se: null, ep: null, id: null, title: null);
    }
    final idx = list.indexWhere(
      (e) =>
          e['season'] == season &&
          (e['episode'] == episode || e['number'] == episode),
    );
    if (idx < 0 || idx + 1 >= list.length) {
      return (se: null, ep: null, id: null, title: null);
    }
    final n = list[idx + 1];
    return (
      se: (n['season'] as num?)?.toInt(),
      ep: (n['episode'] as num?)?.toInt() ?? (n['number'] as num?)?.toInt(),
      id: n['id']?.toString(),
      title: n['title']?.toString() ?? 'E${n['number']}',
    );
  }

  // ─── Acciones ─────────────────────────────────────────────────────────────

  Future<void> _openPlayer({
    int? season,
    int? episode,
    String? episodeTitle,
    int? startPositionMs,
  }) async {
    final item = _item;
    if (item == null) return;

    final prefs = context.read<RepoPrefs>();
    final prefLang = widget.repo.userConfig['preferred_language'] ??
        prefs.preferredLanguage(widget.repo.manifest.id);
    final isTv = context.read<SettingsService>().isTv;

    final se = season ?? _selectedSeasonNumber;
    final ep = episode ?? _selectedEpisode;

    int pos = startPositionMs ?? 0;
    if (pos <= 0 && se != null && ep != null) {
      pos = _positionMsForEpisode(se, ep);
    }
    if (pos <= 0 && se == null && ep == null) {
      pos = _lastPositionMs > 0
          ? _lastPositionMs
          : (_latestEntry?.positionMs ?? 0);
    }

    final fullList =
        item.isSeries ? _buildFullEpisodeList(item) : <Map<String, dynamic>>[];
    final next = item.isSeries
        ? _computeNext(item: item, season: se, episode: ep)
        : (se: null, ep: null, id: null, title: null);

    final offline = DownloadService.instance.offlineServerFor(
      repoId: widget.repo.manifest.id,
      contentId: item.id,
      season: se,
      episode: ep,
    );
    final List<StreamServer> servers =
        offline != null ? <StreamServer>[offline] : const [];
    final playUrl = offline?.url ?? '';

    await Navigator.of(context).push<Map>(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          title: item.title,
          url: playUrl,
          repoId: widget.repo.manifest.id,
          contentId: item.id,
          poster: item.poster,
          backdrop: item.backdrop,
          logo: item.logo,
          contentType: item.type,
          servers: servers,
          season: se,
          episode: ep,
          episodeTitle: episodeTitle ?? _episodeTitle(),
          nextSeason: next.se,
          nextEpisode: next.ep,
          nextEpisodeId: next.id,
          nextEpisodeTitle: next.title,
          episodeList: fullList,
          loadRepo: offline != null ? null : widget.repo,
          preferredLanguage: prefLang,
          startPositionMs: pos,
          isTv: isTv,
        ),
      ),
    );

    if (mounted) {
      await _refreshHistoryAndFocus();
    }
  }

  void _onPlayPressed(ContentItem item, bool asMovie) {
    if (!asMovie && item.seasons.isNotEmpty) {
      int se;
      int? ep;
      if (_lastSeason != null &&
          _lastEpisode != null &&
          _lastPositionMs > 3000) {
        se = _lastSeason!;
        ep = _lastEpisode;
        final idx = item.seasons.indexWhere((s) => s.number == se);
        if (idx >= 0) {
          setState(() {
            _seasonIndex = idx;
            _selectedEpisode = ep;
          });
        }
      } else {
        final s = item.seasons[_seasonIndex];
        se = s.number;
        ep = _selectedEpisode ??
            (s.episodes.isNotEmpty ? s.episodes.first.number : null);
      }
      if (ep != null) {
        final pos = _positionMsForEpisode(se, ep);
        _openPlayer(
          season: se,
          episode: ep,
          startPositionMs: pos > 0 ? pos : null,
        );
      }
    } else {
      final pos = _lastPositionMs > 0
          ? _lastPositionMs
          : (_latestEntry?.positionMs ?? 0);
      _openPlayer(startPositionMs: pos > 0 ? pos : null);
    }
  }

  void _onDownloadPressed(ContentItem item, bool asMovie) {
    int? se;
    int? ep;
    String? epTitle;
    String? epId;
    if (!asMovie && item.seasons.isNotEmpty) {
      se = item.seasons[_seasonIndex].number;
      final eps = item.seasons[_seasonIndex].episodes;
      final e = eps.isNotEmpty
          ? eps.firstWhere(
              (x) => x.number == (_selectedEpisode ?? eps.first.number),
              orElse: () => eps.first,
            )
          : null;
      ep = e?.number ?? _selectedEpisode;
      epTitle = e?.title;
      epId = e != null ? '${item.id}:$se:$ep' : null;
    }
    DownloadSheet.show(
      context: context,
      repo: widget.repo,
      item: item,
      season: se,
      episode: ep,
      episodeTitle: epTitle,
      episodeId: epId,
    );
  }

  // ─── BUILD ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // select: solo reconstruye si cambia ESTE valor (no con cada notify).
    final downloadsEnabled =
        context.select<SettingsService, bool>((s) => s.downloadsEnabled);
    final isFav = context.select<LibraryService, bool>((l) =>
        l.isFavorite(widget.repo.manifest.id, _item?.id ?? widget.itemId));

    if (_loading) return _buildSkeleton();

    final item = _item;
    if (item == null) {
      return const Scaffold(
        backgroundColor: _kBg,
        body: Center(
          child: Text('No encontrado', style: TextStyle(color: Colors.white54)),
        ),
      );
    }

    final asMovie = _treatAsMovie(item);
    final hasSynopsis =
        item.overview != null && item.overview!.trim().isNotEmpty;
    final showSeries = !asMovie && item.seasons.isNotEmpty;

    return Scaffold(
      backgroundColor: _kBg,
      body: CustomScrollView(
        cacheExtent: 400,
        slivers: [
          _buildAppBar(item, asMovie, isFav),

          // Acciones + sinopsis
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(_kHPad, 18, _kHPad, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildActions(item, asMovie, downloadsEnabled),
                  if (hasSynopsis) ...[
                    const SizedBox(height: 18),
                    _buildSynopsis(item.overview!),
                  ],
                ],
              ),
            ),
          ),

          // Reparto: si no hay, NO ocupa nada de espacio.
          if (_cast.isNotEmpty) SliverToBoxAdapter(child: _buildCast()),

          // Temporadas + episodios
          if (showSeries) ...[
            SliverToBoxAdapter(child: _buildSeasonsHeader(item)),
            _buildEpisodesSliver(item, downloadsEnabled),
          ],

          // Similares
          if (_loadingSimilar || _similar.isNotEmpty)
            SliverToBoxAdapter(child: _buildSimilar()),

          SliverToBoxAdapter(
            child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 32),
          ),
        ],
      ),
    );
  }

  Widget _buildSkeleton() {
    return const Scaffold(
      backgroundColor: _kBg,
      body: SingleChildScrollView(
        physics: NeverScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: 300, width: double.infinity, child: ColoredBox(color: _kSurface2)),
            Padding(
              padding: EdgeInsets.all(_kHPad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(height: 50, width: double.infinity, child: ColoredBox(color: _kSurface2)),
                  SizedBox(height: 18),
                  SizedBox(height: 14, width: 260, child: ColoredBox(color: _kSurface2)),
                  SizedBox(height: 8),
                  SizedBox(height: 14, width: 200, child: ColoredBox(color: _kSurface2)),
                  SizedBox(height: 24),
                  SkeletonRow(height: 70, itemWidth: 120, count: 4),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Header / Hero ────────────────────────────────────────────────────────

  SliverAppBar _buildAppBar(ContentItem item, bool asMovie, bool isFav) {
    final h = (MediaQuery.sizeOf(context).height * 0.44).clamp(300.0, 480.0);
    return SliverAppBar(
      expandedHeight: h,
      pinned: true,
      backgroundColor: _kBg,
      surfaceTintColor: Colors.transparent,
      leading: Padding(
        padding: const EdgeInsets.all(6),
        child: IconButton(
          style: IconButton.styleFrom(backgroundColor: Colors.black38),
          icon: const Icon(Icons.arrow_back, color: Colors.white, size: 22),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 6, 10, 6),
          child: IconButton(
            style: IconButton.styleFrom(backgroundColor: Colors.black38),
            icon: Icon(
              isFav ? Icons.favorite : Icons.favorite_border,
              color: isFav ? _kAccent : Colors.white,
              size: 22,
            ),
            onPressed: () => context.read<LibraryService>().toggleFavorite(
                  repoId: widget.repo.manifest.id,
                  contentId: item.id,
                  title: item.title,
                  poster: item.poster,
                  type: item.type,
                ),
          ),
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        // pin = el más barato (sin capa de parallax).
        collapseMode: CollapseMode.pin,
        background: _buildHero(item, asMovie),
      ),
    );
  }

  Widget _buildHero(ContentItem item, bool asMovie) {
    final bg = (item.backdrop != null && item.backdrop!.isNotEmpty)
        ? item.backdrop
        : item.poster;
    final hasPoster = item.poster != null && item.poster!.isNotEmpty;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (bg != null && bg.isNotEmpty)
          CachedNetworkImage(
            imageUrl: bg,
            fit: BoxFit.cover,
            memCacheWidth: 900,
            fadeInDuration: const Duration(milliseconds: 150),
            placeholder: (_, __) => const ColoredBox(color: _kSurface2),
            errorWidget: (_, __, ___) => const ColoredBox(color: _kSurface2),
          )
        else
          const ColoredBox(color: _kSurface2),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x99000000),
                Color(0x22000000),
                Color(0x00000000),
                Color(0xB30B0E14),
                _kBg,
              ],
              stops: [0.0, 0.2, 0.42, 0.78, 1.0],
            ),
          ),
        ),
        Positioned(
          left: _kHPad,
          right: _kHPad,
          bottom: 14,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (hasPoster) ...[
                Container(
                  width: 108,
                  height: 162,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white24, width: 1),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: CachedNetworkImage(
                      imageUrl: item.poster!,
                      fit: BoxFit.cover,
                      memCacheWidth: 260,
                      fadeInDuration: Duration.zero,
                      placeholder: (_, __) =>
                          const ColoredBox(color: _kSurface2),
                      errorWidget: (_, __, ___) => const ColoredBox(
                        color: _kSurface2,
                        child: Icon(Icons.movie, color: Colors.white24, size: 36),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
              ],
              Expanded(child: _buildInfoBlock(item, asMovie)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInfoBlock(ContentItem item, bool asMovie) {
    const titleStyle = TextStyle(
      fontFamily: _kFont,
      color: Colors.white,
      fontSize: 24,
      fontWeight: FontWeight.w800,
      height: 1.12,
      letterSpacing: -0.4,
    );
    final hasLogo = item.logo != null && item.logo!.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasLogo)
          Align(
            alignment: Alignment.centerLeft,
            child: CachedNetworkImage(
              imageUrl: item.logo!,
              height: 46,
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
              memCacheHeight: 140,
              fadeInDuration: Duration.zero,
              errorWidget: (_, __, ___) => Text(
                item.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
            ),
          )
        else
          Text(
            item.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
        if (_director != null && _director!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(children: [
              const TextSpan(
                text: 'Dirigido por  ',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              TextSpan(
                text: _director,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ]),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (item.year != null) _Pill(text: item.year!),
            _Pill(text: asMovie ? 'Película' : 'Serie'),
            if (item.rating != null)
              _Pill(
                text: item.rating!.toStringAsFixed(1),
                icon: Icons.star_rounded,
                accent: _kAmber,
              ),
            if (_durationText != null) _Pill(text: _durationText!),
          ],
        ),
        if (item.genres.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            item.genres.take(3).join('  •  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ],
    );
  }

  // ─── Acciones ─────────────────────────────────────────────────────────────

  Widget _buildActions(ContentItem item, bool asMovie, bool downloadsEnabled) {
    final label = _playLabel(asMovie);
    final progress = _resumeProgress(asMovie);

    return Row(
      children: [
        Expanded(
          child: Focusable(
            onTap: () => _onPlayPressed(item, asMovie),
            builder: (f) => Container(
              height: 52,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: f ? _kAccent : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.play_arrow_rounded,
                          color: Colors.black, size: 26),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: _kFont,
                            color: Colors.black,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (progress > 0.02)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3.5,
                        color: _kAccent,
                        backgroundColor: Colors.black12,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (downloadsEnabled) ...[
          const SizedBox(width: 10),
          Focusable(
            onTap: () => _onDownloadPressed(item, asMovie),
            builder: (f) => Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: _kSurface2,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: f ? Colors.white : Colors.white12,
                  width: f ? 2 : 1,
                ),
              ),
              child: const Icon(Icons.download_rounded,
                  color: Colors.white, size: 24),
            ),
          ),
        ],
      ],
    );
  }

  // ─── Sinopsis ─────────────────────────────────────────────────────────────

  Widget _buildSynopsis(String text) {
    const synStyle = TextStyle(
      fontFamily: _kFont,
      color: Colors.white70,
      height: 1.5,
      fontSize: 14,
    );
    return LayoutBuilder(
      builder: (context, c) {
        // Se mide solo cuando cambia el ancho (no en cada rebuild).
        if (_synWidth != c.maxWidth) {
          _synWidth = c.maxWidth;
          _synNeedsExpand = _synopsisExceedsLines(text, synStyle, c.maxWidth);
        }
        final needsExpand = _synNeedsExpand;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: needsExpand
              ? () => setState(() => _synopsisExpanded = !_synopsisExpanded)
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                alignment: Alignment.topLeft,
                child: Text(
                  text,
                  style: synStyle,
                  maxLines: _synopsisExpanded ? null : 3,
                  overflow: _synopsisExpanded
                      ? TextOverflow.visible
                      : TextOverflow.ellipsis,
                ),
              ),
              if (needsExpand)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _synopsisExpanded ? 'Ver menos' : 'Ver más',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // ─── Reparto ──────────────────────────────────────────────────────────────

  Widget _buildCast() {
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: _kHPad),
            child: _SectionTitle('Reparto'),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 96,
            child: RepaintBoundary(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: _kHPad),
                itemCount: _cast.length,
                addAutomaticKeepAlives: false,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, i) {
                  final c = _cast[i];
                  final name = (c['name'] ?? '').toString();
                  final photo = (c['photo'] ?? '').toString();
                  final initial =
                      name.isNotEmpty ? name[0].toUpperCase() : '?';
                  final fallback = Center(
                    child: Text(
                      initial,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                      ),
                    ),
                  );
                  return SizedBox(
                    width: 68,
                    child: Column(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: _kSurface2,
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: photo.isEmpty
                              ? fallback
                              : CachedNetworkImage(
                                  imageUrl: photo,
                                  fit: BoxFit.cover,
                                  memCacheWidth: 120,
                                  fadeInDuration: Duration.zero,
                                  errorWidget: (_, __, ___) => fallback,
                                ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            height: 1.15,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Temporadas / episodios ───────────────────────────────────────────────

  Widget _buildSeasonsHeader(ContentItem item) {
    final seasons = item.seasons;
    final epCount = seasons[_seasonIndex].episodes.length;
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _kHPad),
            child: _SectionTitle('Episodios', trailing: '$epCount cap.'),
          ),
          if (seasons.length > 1) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: _kHPad),
                itemCount: seasons.length,
                addAutomaticKeepAlives: false,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final s = seasons[i];
                  final sel = i == _seasonIndex;
                  return Focusable(
                    onTap: () => setState(() {
                      _seasonIndex = i;
                      _selectedEpisode = null;
                      _episodePage = 0;
                    }),
                    builder: (f) => Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: sel ? _kAccent : _kSurface2,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: f ? _kAccentHi : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Text(
                        s.name ?? 'T${s.number}',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: sel ? FontWeight.w800 : FontWeight.w600,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 14),
        ],
      ),
    );
  }

  Widget _buildEpisodesSliver(ContentItem item, bool downloadsEnabled) {
    final allEps = item.seasons[_seasonIndex].episodes;
    final seasonNum = item.seasons[_seasonIndex].number;
    final total = allEps.length;
    final per = _epPerPage;
    final usePag = _useEpPagination && total > per;
    final totalPages = usePag ? ((total + per - 1) ~/ per) : 1;
    final page = usePag ? _episodePage.clamp(0, totalPages - 1) : 0;
    final start = usePag ? page * per : 0;
    final end = usePag ? (start + per).clamp(0, total) : total;
    final pageEps = allEps.sublist(start, end);

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: _kHPad),
      // Lista perezosa: solo se construyen los episodios visibles.
      sliver: SliverList.builder(
        itemCount: pageEps.length + (usePag ? 1 : 0),
        addAutomaticKeepAlives: false,
        itemBuilder: (context, index) {
          var i = index;
          if (usePag) {
            if (i == 0) {
              return _buildPager(page, totalPages, start, end, total);
            }
            i -= 1;
          }
          final ep = pageEps[i];
          final progress = _progressForEpisode(seasonNum, ep.number);
          return _EpisodeTile(
            key: ValueKey('ep_${seasonNum}_${ep.number}'),
            number: ep.number,
            title: ep.title,
            overview: ep.overview,
            still: ep.still,
            runtime: ep.runtime,
            progress: progress,
            selected: _selectedEpisode == ep.number,
            isLast: _lastSeason == seasonNum && _lastEpisode == ep.number,
            showDownload: downloadsEnabled,
            onPlay: () async {
              setState(() => _selectedEpisode = ep.number);
              final pos = _positionMsForEpisode(seasonNum, ep.number);
              await _openPlayer(
                season: seasonNum,
                episode: ep.number,
                episodeTitle: ep.title,
                startPositionMs: pos > 0 ? pos : null,
              );
            },
            onDownload: () {
              DownloadSheet.show(
                context: context,
                repo: widget.repo,
                item: item,
                season: seasonNum,
                episode: ep.number,
                episodeTitle: ep.title,
                episodeId: '${item.id}/${ep.number}',
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildPager(int page, int totalPages, int start, int end, int total) {
    Widget arrow(IconData icon, bool enabled, VoidCallback go) {
      return Focusable(
        onTap: enabled ? go : null,
        builder: (f) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: enabled ? _kSurface2 : _kSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: f && enabled ? _kAccentHi : Colors.transparent,
              width: 2,
            ),
          ),
          child: Icon(icon,
              color: enabled ? Colors.white : Colors.white24, size: 22),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          arrow(Icons.chevron_left, page > 0,
              () => setState(() => _episodePage = page - 1)),
          Expanded(
            child: Text(
              'Pág. ${page + 1} / $totalPages  ·  ${start + 1}–$end de $total',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
          arrow(Icons.chevron_right, page < totalPages - 1,
              () => setState(() => _episodePage = page + 1)),
        ],
      ),
    );
  }

  // ─── Similares ────────────────────────────────────────────────────────────

  Widget _buildSimilar() {
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: _kHPad),
            child: _SectionTitle('Similares'),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 156,
            child: _loadingSimilar
                ? ListView.separated(
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: _kHPad),
                    itemCount: 4,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (_, __) => const SizedBox(
                      width: 104,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: _kSurface,
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                        ),
                      ),
                    ),
                  )
                : RepaintBoundary(
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: _kHPad),
                      itemCount: _similar.length,
                      addAutomaticKeepAlives: false,
                      separatorBuilder: (_, __) => const SizedBox(width: 10),
                      itemBuilder: (context, i) {
                        final s = _similar[i];
                        final hasPoster =
                            s.poster != null && s.poster!.isNotEmpty;
                        return Focusable(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DetailsPage(
                                repo: widget.repo,
                                itemId: s.id,
                              ),
                            ),
                          ),
                          builder: (f) => Container(
                            width: 104,
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: _kSurface2,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: f ? Colors.white : Colors.transparent,
                                width: 2,
                              ),
                            ),
                            child: hasPoster
                                ? CachedNetworkImage(
                                    imageUrl: s.poster!,
                                    fit: BoxFit.cover,
                                    memCacheWidth: 240,
                                    fadeInDuration: Duration.zero,
                                    errorWidget: (_, __, ___) =>
                                        const SizedBox.shrink(),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ─── Widgets pequeños y reutilizables ───────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  final String? trailing;
  const _SectionTitle(this.text, {this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 3.5,
          height: 16,
          decoration: BoxDecoration(
            color: _kAccent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            fontFamily: _kFont,
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.2,
          ),
        ),
        if (trailing != null) ...[
          const Spacer(),
          Text(
            trailing!,
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color? accent;
  const _Pill({required this.text, this.icon, this.accent});

  @override
  Widget build(BuildContext context) {
    final fg = accent ?? Colors.white70;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent != null
            ? accent!.withValues(alpha: 0.16)
            : const Color(0x26FFFFFF),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 3),
          ],
          Text(
            text,
            style: TextStyle(
              color: fg,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  final int number;
  final String? title;
  final String? overview;
  final String? still;
  final num? runtime;
  final double progress;
  final bool selected;
  final bool isLast;
  final bool showDownload;
  final VoidCallback onPlay;
  final VoidCallback onDownload;

  const _EpisodeTile({
    super.key,
    required this.number,
    required this.title,
    required this.overview,
    required this.still,
    required this.runtime,
    required this.progress,
    required this.selected,
    required this.isLast,
    required this.showDownload,
    required this.onPlay,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final hasStill = still != null && still!.isNotEmpty;
    final meta = <String>[
      if (runtime != null && runtime! > 0) '${runtime!.round()} min',
      if (progress > 0.02) '${(progress * 100).round()}% visto',
    ].join('  ·  ');

    return RepaintBoundary(
      child: Focusable(
        onTap: onPlay,
        builder: (f) => Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected || isLast
                ? const Color(0x14FFFFFF)
                : _kSurface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: f || selected
                  ? _kAccentHi
                  : (isLast
                      ? _kAccent.withValues(alpha: 0.5)
                      : Colors.transparent),
              width: 2,
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 112,
                  height: 63,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (hasStill)
                        CachedNetworkImage(
                          imageUrl: still!,
                          fit: BoxFit.cover,
                          memCacheWidth: 240,
                          fadeInDuration: Duration.zero,
                          errorWidget: (_, __, ___) =>
                              const ColoredBox(color: _kSurface2),
                        )
                      else
                        ColoredBox(
                          color: _kSurface2,
                          child: Center(
                            child: Text(
                              '$number',
                              style: const TextStyle(
                                color: Colors.white38,
                                fontWeight: FontWeight.w800,
                                fontSize: 18,
                              ),
                            ),
                          ),
                        ),
                      const Center(
                        child: Icon(Icons.play_circle_fill_rounded,
                            color: Colors.white70, size: 26),
                      ),
                      if (progress > 0.02)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: LinearProgressIndicator(
                            value: progress.clamp(0.0, 1.0),
                            minHeight: 3.5,
                            color: _kAccent,
                            backgroundColor: Colors.white24,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$number. ${title ?? 'Episodio $number'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: _kFont,
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: isLast ? FontWeight.w800 : FontWeight.w700,
                      ),
                    ),
                    if (overview != null && overview!.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        overview!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ],
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        meta,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (showDownload)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Descargar episodio',
                  icon: const Icon(Icons.download_rounded,
                      color: Colors.white70, size: 22),
                  onPressed: onDownload,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EpProgress {
  final int positionMs;
  final int durationMs;
  final double progress;
  const _EpProgress({
    required this.positionMs,
    required this.durationMs,
    required this.progress,
  });
}

String? _epStill(dynamic e) {
  try {
    final v = e.still;
    if (v is String && v.isNotEmpty) return v;
  } catch (_) {}
  try {
    final v = e.poster;
    if (v is String && v.isNotEmpty) return v;
  } catch (_) {}
  try {
    final v = e.image;
    if (v is String && v.isNotEmpty) return v;
  } catch (_) {}
  return null;
}