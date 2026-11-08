import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../../data/models/repo_manifest.dart';
import '../../../../data/models/stream_server.dart';
import '../../../../data/services/content_service.dart';
import '../../../../data/services/library_service.dart';
import '../../widgets/cached_poster.dart';
import '../../widgets/focusable.dart';

/// Player móvil en vivo con guía de canales (categorías | canales) superpuesta.
class PlayerMobileOnlinePage extends StatefulWidget {
  final String title;
  final String? repoId;
  final String? contentId;
  final String? poster;
  final String? backdrop;
  final String? logo;
  final String contentType;
  final List<StreamServer> servers;
  final int initialServerIndex;
  final InstalledRepo? loadRepo;
  final String preferredLanguage;
  final Map<String, String>? headers;
  final String url;
  final List<HomeRow> categories;
  final int initialCategoryIndex;
  final int initialChannelIndex;

  const PlayerMobileOnlinePage({
    super.key,
    required this.title,
    this.repoId,
    this.contentId,
    this.poster,
    this.backdrop,
    this.logo,
    this.contentType = 'channel',
    this.servers = const [],
    this.initialServerIndex = 0,
    this.loadRepo,
    this.preferredLanguage = '',
    this.headers,
    this.url = '',
    this.categories = const [],
    this.initialCategoryIndex = 0,
    this.initialChannelIndex = 0,
  });

  @override
  State<PlayerMobileOnlinePage> createState() => _PlayerMobileOnlinePageState();
}

class _PlayerMobileOnlinePageState extends State<PlayerMobileOnlinePage> {
  static const accent = Color(0xFFE50914);

  Player? _player;
  VideoController? _video;
  final List<StreamSubscription> _subs = [];

  bool _loading = true;
  bool _buffering = false;
  bool _playing = false;
  String? _error;
  bool _showControls = true;
  bool _showGuide = false;

  late List<StreamServer> _servers;
  late int _serverIndex;

  late String _title;
  late String? _contentId;
  late String? _poster;
  late String? _backdrop;
  late String? _logo;
  late String _contentType;

  late int _catIndex;
  late int _channelIndex;
  late List<HomeRow> _categories;

  final FocusNode _rootFocus = FocusNode();
  final FocusNode _playFocus = FocusNode();
  final FocusNode _guideFocus = FocusNode();
  final FocusNode _favFocus = FocusNode();
  Timer? _hideTimer;
  Timer? _wakelockTimer;

  StreamServer? get _current =>
      _servers.isEmpty ? null : _servers[_serverIndex.clamp(0, _servers.length - 1)];

  List<ContentItem> get _channels {
    if (_categories.isEmpty ||
        _catIndex < 0 ||
        _catIndex >= _categories.length) {
      return const [];
    }
    return _categories[_catIndex].items;
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _keepAwake();
    _title = widget.title;
    _contentId = widget.contentId;
    _poster = widget.poster;
    _backdrop = widget.backdrop;
    _logo = widget.logo;
    _contentType = widget.contentType;
    _categories = List.of(widget.categories);
    _catIndex = widget.initialCategoryIndex.clamp(
        0, (_categories.isEmpty ? 0 : _categories.length - 1));
    _channelIndex = widget.initialChannelIndex;
    _servers = List.of(widget.servers);
    if (_servers.isEmpty && widget.url.isNotEmpty) {
      _servers = [
        StreamServer(
          url: widget.url,
          name: 'Principal',
          headers: widget.headers ?? {},
          isHls: widget.url.toLowerCase().contains('.m3u8'),
        ),
      ];
    }
    _serverIndex =
        widget.initialServerIndex.clamp(0, (_servers.length - 1).clamp(0, 9999));

    if (widget.loadRepo != null &&
        _contentId != null &&
        _contentId!.isNotEmpty) {
      _loadStreamsThenPlay();
    } else {
      _startCurrent();
    }
  }

  void _keepAwake() {
    WakelockPlus.enable();
    _wakelockTimer?.cancel();
    _wakelockTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!mounted) return;
      try {
        if (_playing) await WakelockPlus.enable();
      } catch (_) {}
    });
  }

  Future<void> _loadStreamsThenPlay() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ContentService.instance.getStreams(
        widget.loadRepo!,
        _contentId!,
        type: _contentType,
      );
      if (!mounted) return;
      if (list.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'No hay fuentes de transmisión';
        });
        return;
      }
      _servers = list;
      _serverIndex = 0;
      await _startCurrent();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Error cargando transmisión: $e';
        });
      }
    }
  }

  Future<void> _startCurrent() async {
    final s = _current;
    if (s == null) {
      setState(() {
        _loading = false;
        _error = 'Sin URL de transmisión';
      });
      return;
    }
    await _openUrl(s.url, s.headers);
  }

  Future<void> _openUrl(String url, Map<String, String> headers) async {
    setState(() {
      _loading = true;
      _error = null;
      _buffering = true;
    });
    try {
      await _disposePlayer();
      final player = Player(
        configuration: PlayerConfiguration(
          title: _title,
          bufferSize: 32 * 1024 * 1024,
        ),
      );
      final video = VideoController(player);
      _player = player;
      _video = video;
      _subs.add(player.stream.playing.listen((v) {
        if (!mounted) return;
        setState(() => _playing = v);
      }));
      _subs.add(player.stream.buffering.listen((v) {
        if (!mounted) return;
        setState(() => _buffering = v);
      }));
      _subs.add(player.stream.error.listen((e) {
        if (!mounted || e.toString().isEmpty) return;
        debugPrint('[LiveTV] error: $e');
      }));

      final hdrs = <String, String>{};
      if (headers.isNotEmpty) hdrs.addAll(headers);
      if (widget.headers != null) {
        for (final e in widget.headers!.entries) {
          hdrs.putIfAbsent(e.key, () => e.value);
        }
      }
      hdrs.putIfAbsent(
        'User-Agent',
        () =>
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36',
      );

      await player.open(Media(url, httpHeaders: hdrs), play: true);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _buffering = false;
        _playing = true;
      });
      _scheduleHide();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No se pudo reproducir: $e';
      });
    }
  }

  Future<void> _switchChannel(ContentItem item, int cat, int ch) async {
    setState(() {
      _catIndex = cat;
      _channelIndex = ch;
      _contentId = item.id;
      _title = item.currentProgram != null
          ? '${item.title} · ${item.currentProgram}'
          : item.title;
      _poster = item.poster;
      _backdrop = item.backdrop;
      _logo = item.logo;
      _contentType = item.type;
      _showGuide = false;
      _loading = true;
    });
    if (widget.loadRepo != null) {
      await _loadStreamsThenPlay();
    }
  }

  Future<void> _toggleFav() async {
    final id = _contentId;
    final repoId = widget.repoId;
    if (id == null || repoId == null) return;
    final lib = context.read<LibraryService>();
    await lib.toggleFavorite(
      repoId: repoId,
      contentId: id,
      title: _title,
      poster: _logo ?? _poster,
      type: _contentType.isNotEmpty ? _contentType : 'channel',
    );
    if (mounted) setState(() {});
  }

  Future<void> _togglePlay() async {
    final p = _player;
    if (p == null) return;
    if (_playing) {
      await p.pause();
    } else {
      await p.play();
    }
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      if (_showGuide) return;
      setState(() => _showControls = false);
    });
  }

  void _showUi() {
    setState(() => _showControls = true);
    _scheduleHide();
  }

  Future<void> _disposePlayer() async {
    for (final s in _subs) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    _subs.clear();
    final p = _player;
    _player = null;
    _video = null;
    try {
      await p?.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _wakelockTimer?.cancel();
    _rootFocus.dispose();
    _playFocus.dispose();
    _guideFocus.dispose();
    _favFocus.dispose();
    unawaited(_disposePlayer());
    WakelockPlus.disable();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  KeyEventResult _onRootKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.browserBack) {
      if (_showGuide) {
        setState(() => _showGuide = false);
        return KeyEventResult.handled;
      }
      if (_showControls) {
        setState(() => _showControls = false);
        return KeyEventResult.handled;
      }
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.channelUp ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      _zap(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.channelDown ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      _zap(1);
      return KeyEventResult.handled;
    }
    if (!_showControls &&
        !_showGuide &&
        (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      _showUi();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      unawaited(_togglePlay());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _zap(int dir) {
    final items = _channels;
    if (items.isEmpty) return;
    final next = (_channelIndex + dir + items.length) % items.length;
    unawaited(_switchChannel(items[next], _catIndex, next));
  }

  @override
  Widget build(BuildContext context) {
    final repoId = widget.repoId ?? '';
    final isFav = _contentId != null &&
        repoId.isNotEmpty &&
        context.watch<LibraryService>().isFavorite(repoId, _contentId!);

    return PopScope(
      canPop: !(_showGuide || _showControls),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_showGuide) {
          setState(() => _showGuide = false);
          return;
        }
        if (_showControls) {
          setState(() => _showControls = false);
          return;
        }
        Navigator.of(context).maybePop();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _rootFocus,
          autofocus: true,
          onKeyEvent: _onRootKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_showGuide) return;
              if (_showControls) {
                setState(() => _showControls = false);
              } else {
                _showUi();
              }
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_video != null)
                  Video(
                    controller: _video!,
                    controls: NoVideoControls,
                    fit: BoxFit.contain,
                  )
                else if (_backdrop != null || _poster != null)
                  CachedNetworkImage(
                    imageUrl: (_backdrop ?? _poster)!,
                    fit: BoxFit.cover,
                    color: Colors.black54,
                    colorBlendMode: BlendMode.darken,
                  ),
                if (_loading || _buffering)
                  const Center(
                    child: CircularProgressIndicator(
                        color: accent, strokeWidth: 3),
                  ),
                if (_error != null)
                  Center(
                    child: Text(_error!,
                        style: const TextStyle(color: Colors.white70)),
                  ),
                if (_showControls && _error == null && !_showGuide)
                  _controls(isFav),
                if (_showGuide) _guidePanel(),
                Positioned(
                  top: 16,
                  left: 20,
                  child: SafeArea(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'EN VIVO',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _controls(bool isFav) {
    return Positioned.fill(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0x99000000),
              Colors.transparent,
              Color(0xCC000000),
            ],
            stops: [0, 0.35, 1],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    const SizedBox(width: 72),
                    Expanded(
                      child: Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
                child: Row(
                  children: [
                    _btn(
                      focusNode: _playFocus,
                      icon: _playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      onTap: () => unawaited(_togglePlay()),
                    ),
                    const SizedBox(width: 14),
                    if (_categories.isNotEmpty)
                      _btn(
                        focusNode: _guideFocus,
                        icon: Icons.list_alt_rounded,
                        label: 'Canales',
                        onTap: () => setState(() {
                          _showGuide = true;
                          _showControls = false;
                        }),
                      ),
                    if (_categories.isNotEmpty) const SizedBox(width: 14),
                    _btn(
                      focusNode: _favFocus,
                      icon: isFav ? Icons.favorite : Icons.favorite_border,
                      label: isFav ? 'Favorito' : 'Fav',
                      onTap: () => unawaited(_toggleFav()),
                    ),
                    const Spacer(),
                    Text(
                      _playing ? 'EN EMISIÓN' : 'PAUSA',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _btn({
    FocusNode? focusNode,
    required IconData icon,
    String? label,
    required VoidCallback onTap,
  }) {
    return Focusable(
      focusNode: focusNode,
      onTap: onTap,
      builder: (focused) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: EdgeInsets.symmetric(
          horizontal: label != null ? 16 : 12,
          vertical: 12,
        ),
        decoration: BoxDecoration(
          color: focused ? accent : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 26),
            if (label != null) ...[
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Guía: columna categorías + columna canales, encima del video.
  Widget _guidePanel() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.72),
        child: SafeArea(
          child: Row(
            children: [
              // Categorías
              SizedBox(
                width: 220,
                child: Container(
                  color: const Color(0xFF0E1218),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 16, 16, 10),
                        child: Text(
                          'Categorías',
                          style: TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _categories.length,
                          itemBuilder: (context, i) {
                            final sel = i == _catIndex;
                            return Focusable(
                              autofocus: i == _catIndex,
                              onTap: () => setState(() {
                                _catIndex = i;
                                _channelIndex = 0;
                              }),
                              builder: (focused) {
                                final on = sel || focused;
                                return Container(
                                  margin: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: on ? accent : Colors.transparent,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    _categories[i].title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: on
                                          ? Colors.white
                                          : Colors.white70,
                                      fontWeight: on
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Canales
              SizedBox(
                width: 320,
                child: Container(
                  color: const Color(0xFF12161E),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                        child: Text(
                          '${_channels.length} canales',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _channels.length,
                          itemBuilder: (context, i) {
                            final item = _channels[i];
                            final sel = i == _channelIndex;
                            return Focusable(
                              onTap: () => unawaited(
                                  _switchChannel(item, _catIndex, i)),
                              builder: (focused) {
                                final on = sel || focused;
                                return Container(
                                  margin: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: on ? accent : Colors.transparent,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Row(
                                    children: [
                                      ClipRRect(
                                        borderRadius:
                                            BorderRadius.circular(6),
                                        child: SizedBox(
                                          width: 52,
                                          height: 34,
                                          child: CachedPoster(
                                            url: item.logo ?? item.poster,
                                            fit: BoxFit.cover,
                                            title: item.title,
                                            sheenStrength: 0,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          item.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: on
                                                ? Colors.white
                                                : Colors.white70,
                                            fontWeight: on
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // resto: toque para cerrar
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _showGuide = false),
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}