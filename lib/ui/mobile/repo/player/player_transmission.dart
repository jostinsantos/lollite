import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dart_cast/dart_cast.dart';
import '../../../../data/services/stream_proxy.dart';
import 'cast_sheets.dart' show prepareCastMedia;
import '../../../../data/models/stream_server.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/content_service.dart';
import '../../../../data/services/cast_controller.dart';

const _bg = Color(0xFF0B0F14);
const _card = Color(0xFF1A222D);
const _accent = Color(0xFFE50914);

class PlayerTransmissionPage extends StatefulWidget {
  final CastService castService;
  final CastSession session;
  final CastDevice device;
  final String title;
  final String? poster;
  final String? backdrop;
  final String? logo;
  final List<StreamServer> servers;
  final int initialServerIndex;
  final Map<String, String>? headers;
  final int? season;
  final int? episode;
  final String? episodeTitle;
  final int? nextSeason;
  final int? nextEpisode;
  final String? nextEpisodeId;
  final String? nextEpisodeTitle;
  final List<Map<String, dynamic>> episodeList;
  final InstalledRepo? loadRepo;
  final String? repoId;
  final String? contentId;
  final String contentType;
  final String preferredLanguage;
  final double introStartSec;
  final double introEndSec;
  final double outroStartSec;
  final double outroEndSec;

  const PlayerTransmissionPage({
    super.key,
    required this.castService,
    required this.session,
    required this.device,
    required this.title,
    this.poster,
    this.backdrop,
    this.logo,
    this.servers = const [],
    this.initialServerIndex = 0,
    this.headers,
    this.season,
    this.episode,
    this.episodeTitle,
    this.nextSeason,
    this.nextEpisode,
    this.nextEpisodeId,
    this.nextEpisodeTitle,
    this.episodeList = const [],
    this.loadRepo,
    this.repoId,
    this.contentId,
    this.contentType = 'movie',
    this.preferredLanguage = '',
    this.introStartSec = -1,
    this.introEndSec = -1,
    this.outroStartSec = -1,
    this.outroEndSec = -1,
  });

  @override
  State<PlayerTransmissionPage> createState() => _PlayerTransmissionPageState();
}

class _PlayerTransmissionPageState extends State<PlayerTransmissionPage> {
  late CastSession _session;
  late List<StreamServer> _servers;
  late int _serverIndex;
  bool _busy = false;
  bool _showServers = false;
  bool _isPlaying = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  StreamSubscription? _posSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _durSub;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    _session = widget.session;
    _servers = List<StreamServer>.from(widget.servers);
    _serverIndex = widget.initialServerIndex.clamp(
      0,
      _servers.isEmpty ? 0 : _servers.length - 1,
    );
    _wireSession();
    // Registrar sesión global + notificación
    unawaited(CastController.instance.bind(
      castService: widget.castService,
      castSession: widget.session,
      castDevice: widget.device,
      title: widget.title,
      poster: widget.poster,
      backdrop: widget.backdrop,
      logo: widget.logo,
      servers: widget.servers,
      serverIndex: widget.initialServerIndex,
      headers: widget.headers,
      season: widget.season,
      episode: widget.episode,
      episodeTitle: widget.episodeTitle,
      nextSeason: widget.nextSeason,
      nextEpisode: widget.nextEpisode,
      nextEpisodeId: widget.nextEpisodeId,
      nextEpisodeTitle: widget.nextEpisodeTitle,
      episodeList: widget.episodeList,
      loadRepo: widget.loadRepo,
      repoId: widget.repoId,
      contentId: widget.contentId,
      contentType: widget.contentType,
      preferredLanguage: widget.preferredLanguage,
      introStartSec: widget.introStartSec,
      introEndSec: widget.introEndSec,
      outroStartSec: widget.outroStartSec,
      outroEndSec: widget.outroEndSec,
    ));
    CastController.instance.onOpenCastScreen = _onNotifOpen;
  }

  void _onNotifOpen() {
    // Si esta página ya está visible, no hacer nada.
    // Si se cerró (keep), el launcher/app debe reabrir; aquí solo traemos foco.
    if (!mounted) return;
  }

  void _wireSession() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _durSub?.cancel();
    try {
      _posSub = _session.positionStream.listen((p) {
        if (mounted) setState(() => _position = p);
        CastController.instance.updateProgress(p, _duration, isPlaying: _isPlaying);
      });
    } catch (_) {}
    try {
      _durSub = _session.durationStream.listen((d) {
        if (mounted) setState(() => _duration = d);
        CastController.instance.updateProgress(_position, d, isPlaying: _isPlaying);
      });
    } catch (_) {}
    try {
      _stateSub = _session.stateStream.listen((s) {
        if (!mounted) return;
        final playing = s == SessionState.playing;
        setState(() => _isPlaying = playing);
        CastController.instance.updateProgress(_position, _duration, isPlaying: playing);
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _durSub?.cancel();
    // No limpiar la sesión si se eligió "continuar cast" (se limpia en stop).
    // Solo desregistrar el callback de esta página.
    if (CastController.instance.onOpenCastScreen == _onNotifOpen) {
      CastController.instance.onOpenCastScreen = null;
    }
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
    ]);
    super.dispose();
  }

  bool get _hasNext =>
      widget.nextSeason != null && widget.nextEpisode != null;

  bool get _canSkipIntro {
    final a = widget.introStartSec;
    final b = widget.introEndSec;
    if (a < 0 || b <= a) return false;
    final sec = _position.inSeconds.toDouble();
    return sec >= a && sec < b;
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }

  Future<void> _togglePlay() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_isPlaying) {
        await _session.pause();
        await CastController.instance.pause();
      } else {
        await _session.play();
        await CastController.instance.play();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _seekRelative(int seconds) async {
    final to = _position + Duration(seconds: seconds);
    final max = _duration > Duration.zero ? _duration : to + const Duration(hours: 1);
    final clamped = to < Duration.zero ? Duration.zero : (to > max ? max : to);
    try {
      await _session.seek(clamped);
    } catch (_) {}
  }

  Future<void> _onSeek(double value) async {
    if (_duration.inMilliseconds <= 0) return;
    final to = Duration(
        milliseconds: (value * _duration.inMilliseconds).round());
    try {
      await _session.seek(to);
    } catch (_) {}
  }

  Future<void> _skipIntro() async {
    final end = widget.introEndSec;
    if (end <= 0) return;
    try {
      await _session.seek(Duration(seconds: end.ceil() + 1));
    } catch (_) {}
  }

  Future<void> _switchServer(int index) async {
    if (index < 0 || index >= _servers.length || _busy) return;
    setState(() {
      _busy = true;
      _serverIndex = index;
      _showServers = false;
    });
    final s = _servers[index];
    try {
      final headers = <String, String>{...?widget.headers, ...s.headers};
      final prepared = await prepareCastMedia(
        videoUrl: s.url,
        headers: headers,
        protocol: widget.device.protocol,
      );
      await _session.loadMedia(CastMedia(
        url: prepared.url,
        type: prepared.type,
        title: widget.title,
        imageUrl: widget.poster,
        httpHeaders: prepared.url.contains('/media') ? const {} : headers,
        startPosition: _position,
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo cambiar de servidor: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _goNextEpisode() async {
    if (!_hasNext || widget.loadRepo == null) return;
    setState(() => _busy = true);
    try {
      final streams = await ContentService.instance.getStreams(
        widget.loadRepo!,
        widget.nextEpisodeId ?? widget.contentId ?? '',
        type: widget.contentType,
        season: widget.nextSeason,
        episode: widget.nextEpisode,
      );
      if (streams.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sin servidores para el siguiente')),
          );
        }
        return;
      }
      _servers = List<StreamServer>.from(streams);
      _serverIndex = 0;
      final s = _servers.first;
      final title = widget.nextEpisodeTitle ??
          '${widget.title} · T${widget.nextSeason} E${widget.nextEpisode}';
      final lower = s.url.toLowerCase();
      final type = lower.contains('.m3u8') || lower.contains('hls')
          ? CastMediaType.hls
          : (lower.contains('.ts') ? CastMediaType.mpegTs : CastMediaType.mp4);
      await _session.loadMedia(CastMedia(
        url: s.url,
        type: type,
        title: title,
        imageUrl: widget.poster,
        httpHeaders: {...?widget.headers, ...s.headers},
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopAndClose() async {
    await CastController.instance.stopAndClear();
    if (mounted) Navigator.of(context).pop('stop');
  }

  Future<void> _confirmLeave() async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Salir de Cast',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: const Text(
          '¿Qué deseas hacer con la transmisión?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'stay'),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'keep'),
            child: const Text('Salir y continuar Cast',
                style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _accent),
            onPressed: () => Navigator.pop(ctx, 'stop'),
            child: const Text('Salir'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'stop') {
      await _stopAndClose();
    } else if (action == 'keep') {
      // Deja notificación + sesión vivas en segundo plano.
      // El player recibirá 'keep' y hará pop → ficha de contenido.
      Navigator.of(context).pop('keep');
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final art = widget.backdrop ?? widget.poster;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _confirmLeave();
      },
      child: Scaffold(
        backgroundColor: _bg,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (art != null && art.isNotEmpty)
              Opacity(
                opacity: 0.25,
                child: CachedNetworkImage(
                  imageUrl: art,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xCC0B0F14),
                    Color(0xF00B0F14),
                    Color(0xFF0B0F14),
                  ],
                ),
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Salir',
                          onPressed: _confirmLeave,
                          icon: const Icon(Icons.close_rounded,
                              color: Colors.white),
                        ),
                        const Expanded(
                          child: Text(
                            'Transmitiendo',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.greenAccent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color:
                                    Colors.greenAccent.withValues(alpha: 0.4)),
                          ),
                          child: Text(
                            _isPlaying ? 'En TV' : 'Pausa',
                            style: const TextStyle(
                              color: Colors.greenAccent,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Column(
                        children: [
                          const SizedBox(height: 12),
                          if (widget.poster != null &&
                              widget.poster!.isNotEmpty)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: CachedNetworkImage(
                                imageUrl: widget.poster!,
                                width: 100,
                                height: 150,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) =>
                                    const SizedBox(height: 150),
                              ),
                            ),
                          const SizedBox(height: 12),
                          Text(
                            widget.title,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            widget.device.name,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 12,
                            ),
                          ),
                          if (_canSkipIntro) ...[
                            const SizedBox(height: 12),
                            TextButton.icon(
                              onPressed: _skipIntro,
                              style: TextButton.styleFrom(
                                backgroundColor:
                                    Colors.white.withValues(alpha: 0.12),
                                foregroundColor: Colors.white,
                              ),
                              icon: const Icon(Icons.skip_next_rounded,
                                  size: 18),
                              label: const Text('Saltar intro'),
                            ),
                          ],
                          const SizedBox(height: 8),
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 7),
                              activeTrackColor: _accent,
                              inactiveTrackColor: Colors.white24,
                              thumbColor: Colors.white,
                            ),
                            child: Slider(
                              value: progress,
                              onChanged: (v) => _onSeek(v),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              children: [
                                Text(_fmt(_position),
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 12)),
                                const Spacer(),
                                Text(_fmt(_duration),
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 12)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              IconButton(
                                onPressed: () => _seekRelative(-10),
                                icon: const Icon(Icons.replay_10_rounded,
                                    color: Colors.white, size: 32),
                              ),
                              Material(
                                color: _accent,
                                shape: const CircleBorder(),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: _busy ? null : _togglePlay,
                                  child: SizedBox(
                                    width: 64,
                                    height: 64,
                                    child: _busy
                                        ? const Padding(
                                            padding: EdgeInsets.all(18),
                                            child: CircularProgressIndicator(
                                              color: Colors.white,
                                              strokeWidth: 2.5,
                                            ),
                                          )
                                        : Icon(
                                            _isPlaying
                                                ? Icons.pause_rounded
                                                : Icons.play_arrow_rounded,
                                            color: Colors.white,
                                            size: 36,
                                          ),
                                  ),
                                ),
                              ),
                              IconButton(
                                onPressed: () => _seekRelative(10),
                                icon: const Icon(Icons.forward_10_rounded,
                                    color: Colors.white, size: 32),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _chip(Icons.dns_rounded, 'Servidor', () {
                                setState(() => _showServers = true);
                              }),
                              if (_hasNext)
                                _chip(Icons.skip_next_rounded, 'Siguiente',
                                    _goNextEpisode),
                              _chip(Icons.stop_rounded, 'Detener',
                                  _stopAndClose),
                            ],
                          ),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_showServers) _serversPanel(),
          ],
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(height: 4),
            Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _serversPanel() {
    return Positioned.fill(
      child: Material(
        color: Colors.black54,
        child: SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.5,
              ),
              decoration: const BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text('Servidores',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16)),
                        ),
                        IconButton(
                          onPressed: () =>
                              setState(() => _showServers = false),
                          icon:
                              const Icon(Icons.close, color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _servers.length,
                      itemBuilder: (context, i) {
                        final s = _servers[i];
                        final selected = i == _serverIndex;
                        return ListTile(
                          selected: selected,
                          selectedTileColor:
                              _accent.withValues(alpha: 0.12),
                          leading: Icon(
                            selected
                                ? Icons.check_circle
                                : Icons.dns_outlined,
                            color: selected ? _accent : Colors.white38,
                          ),
                          title: Text(
                            s.name.isNotEmpty
                                ? s.name
                                : 'Servidor ${i + 1}',
                            style: const TextStyle(color: Colors.white),
                          ),
                          onTap: () => _switchServer(i),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
