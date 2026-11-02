import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../../data/models/repo_manifest.dart';
import '../../../../data/models/stream_server.dart';
import '../../../../data/services/content_service.dart';
import '../../../../data/services/party_service.dart';
import '../../widgets/focusable.dart';
import '../../widgets/tv_keyboard.dart';

const _accent = Color(0xFFE50914);
const _panel = Color(0xFF0E1117);
const _card = Color(0xFF161A22);
const _border = Color(0xFF1E2430);
const _muted = Color(0x99FFFFFF);

/// Party player dedicado TV: foco/D-pad, sidebar Meet, dual HLS/media_kit.
class PartyTvPlayer extends StatefulWidget {
  final PartyRoom room;
  final InstalledRepo repo;

  const PartyTvPlayer({super.key, required this.room, required this.repo});

  @override
  State<PartyTvPlayer> createState() => _PartyTvPlayerState();
}

class _PartyTvPlayerState extends State<PartyTvPlayer> {
  final PartyService _party = PartyService.instance;

  List<StreamServer> _servers = [];
  StreamServer? _selected;
  bool _loading = true;
  String? _error;

  VideoPlayerController? _vp;
  Player? _mk;
  VideoController? _mkVideo;
  bool _useMediaKit = false;
  final List<StreamSubscription> _subs = [];

  bool _playing = false;
  bool _buffering = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _dragging = false;

  bool _sidebarOpen = false;
  int _sidebarTab = 0; // 0 chat 1 miembros 2 servidores

  final _chatScroll = ScrollController();
  final _membersScroll = ScrollController();
  final _serversScroll = ScrollController();

  bool _applyingRemote = false;
  bool _syncStarted = false;
  Timer? _hostPushTimer;
  Timer? _pollTimer;
  Timer? _clockTimer;
  DateTime _now = DateTime.now();
  String? _lastAppliedKey;
  bool _depsReady = false;

  final FocusNode _rootFocus = FocusNode(debugLabel: 'party_tv_root');
  final FocusNode _playFocus = FocusNode(debugLabel: 'party_tv_play');

  bool get _isHost => _party.isHost;

  /// Tiempo restante = duración − posición (se actualiza con cada seek / tick).
  Duration get _remaining {
    if (_duration <= Duration.zero) return Duration.zero;
    final r = _duration - _position;
    return r.isNegative ? Duration.zero : r;
  }

  static bool _isHls(String url, {bool flag = false}) {
    if (flag) return true;
    final u = url.toLowerCase();
    return u.contains('.m3u8') || u.contains('m3u8') || u.contains('type=hls');
  }

  static bool _isTs(String url) {
    final u = url.toLowerCase();
    return u.contains('.ts') || u.contains('mpegts') || u.contains('mpeg-ts');
  }

  @override
  void initState() {
    super.initState();
    try {
      WakelockPlus.enable();
    } catch (_) {}
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _party.addListener(_onParty);
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _depsReady = true;
      _bootstrap();
    });
  }

  @override
  void dispose() {
    _hostPushTimer?.cancel();
    _pollTimer?.cancel();
    _clockTimer?.cancel();
    _party.removeListener(_onParty);
    for (final s in _subs) {
      s.cancel();
    }
    _vp?.dispose();
    _mk?.dispose();
    _chatScroll.dispose();
    _membersScroll.dispose();
    _serversScroll.dispose();
    _rootFocus.dispose();
    _playFocus.dispose();
    if (!_isHost) {
      unawaited(_party.leaveCurrentRoom(silent: true));
    }
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      await _party.init();
      if (!mounted) return;
      if (_party.currentRoom?.id != widget.room.id) {
        try {
          await _party.joinRoom(widget.room.code);
        } catch (e) {
          debugPrint('[PartyTV] join: $e');
        }
      }
      if (!mounted) return;
      if (_party.isPendingMember && !_party.isHost) {
        setState(() {
          _loading = false;
          _error = null;
        });
        return;
      }
      await _loadStreams();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  void _onParty() {
    if (!mounted || !_depsReady) return;
    if (_party.kickedFromRoom) {
      _party.kickedFromRoom = false;
      _hostPushTimer?.cancel();
      _pollTimer?.cancel();
      _syncStarted = false;
      try {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('El host te ha quitado de la sala')),
        );
      } catch (_) {}
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      return;
    }
    if (_party.currentRoom == null) {
      _hostPushTimer?.cancel();
      _pollTimer?.cancel();
      _syncStarted = false;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      return;
    }
    if (!_loading &&
        _selected == null &&
        _party.isAcceptedMember &&
        !_party.isPendingMember) {
      unawaited(_loadStreams());
    }
    if (_party.isRoomExpired) {
      unawaited(_party.leaveCurrentRoom());
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      return;
    }
    setState(() {});
    _tryStartSync();
    if (!_isHost) _applyRemote(force: false);
  }

  int _pickPreferred(List<StreamServer> list) {
    final pref = (widget.room.language ?? '').trim().toLowerCase();
    if (pref.isEmpty || list.isEmpty) return 0;
    for (var i = 0; i < list.length; i++) {
      final lang = (list[i].language ?? '').toLowerCase();
      final name = list[i].name.toLowerCase();
      if (lang.contains(pref) || pref.contains(lang) || name.contains(pref)) {
        return i;
      }
    }
    for (var i = 0; i < list.length; i++) {
      final lang = (list[i].language ?? '').toLowerCase();
      if (pref.startsWith('lat') && lang.contains('lat')) return i;
      if (pref.startsWith('cast') && lang.contains('cast')) return i;
      if (pref.startsWith('ing') &&
          (lang.contains('ing') || lang.contains('en'))) {
        return i;
      }
      if (pref.startsWith('sub') && lang.contains('sub')) return i;
    }
    return 0;
  }

  Future<void> _loadStreams() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ContentService.instance.getStreams(
        widget.repo,
        widget.room.contentId,
        type: widget.room.contentType,
        season: widget.room.season,
        episode: widget.room.episode,
      );
      if (!mounted) return;
      if (list.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'No hay servidores';
        });
        return;
      }
      final idx = _pickPreferred(list);
      _servers = list;
      _selected = list[idx];
      setState(() => _loading = false);
      await _openServer(_selected!);
      await _party.setServerReady(true);
      if (_isHost) await _push(forcePlay: false);
      _tryStartSync();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _disposeEngines() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _vp?.dispose();
    _vp = null;
    await _mk?.dispose();
    _mk = null;
    _mkVideo = null;
  }

  Future<void> _openServer(StreamServer server) async {
    await _disposeEngines();
    final url = server.url.trim();
    if (url.isEmpty) {
      setState(() => _error = 'URL vacía');
      return;
    }
    _selected = server;
    final hls = _isHls(url, flag: server.isHls);
    final bool engineMk = !hls;
    _useMediaKit = engineMk;
    debugPrint(
        '[PartyTV] engine=${engineMk ? "media_kit" : "video_player"} hls=$hls url=$url');

    final headers = <String, String>{...server.headers};
    headers.putIfAbsent(
      'User-Agent',
      () =>
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    );

    try {
      if (engineMk) {
        try {
          MediaKit.ensureInitialized();
        } catch (_) {}
        final player = Player(
          configuration: const PlayerConfiguration(
            title: 'LOL Party TV',
            bufferSize: 32 * 1024 * 1024,
          ),
        );
        try {
          final platform = player.platform;
          if (platform != null) {
            await (platform as dynamic)
                .setProperty('demuxer-lavf-analyzeduration', '15');
            await (platform as dynamic)
                .setProperty('demuxer-lavf-probesize', '50000000');
            await (platform as dynamic).setProperty('network-timeout', '60');
            await (platform as dynamic).setProperty('cache', 'yes');
            await (platform as dynamic).setProperty('cache-secs', '30');
            await (platform as dynamic).setProperty('tls-verify', 'no');
            await (platform as dynamic).setProperty('sub-visibility', 'yes');
          }
        } catch (_) {}
        final video = VideoController(
          player,
          configuration: const VideoControllerConfiguration(
            enableHardwareAcceleration: true,
          ),
        );
        _mk = player;
        _mkVideo = video;
        _subs.add(player.stream.playing.listen((v) {
          if (!mounted || _applyingRemote) return;
          setState(() => _playing = v);
          if (_isHost && _syncStarted) unawaited(_push(forcePlay: v));
        }));
        _subs.add(player.stream.buffering.listen((v) {
          if (mounted) setState(() => _buffering = v);
        }));
        _subs.add(player.stream.position.listen((v) {
          if (mounted && !_dragging) setState(() => _position = v);
        }));
        _subs.add(player.stream.duration.listen((v) {
          if (mounted) setState(() => _duration = v);
        }));
        await player.open(Media(url, httpHeaders: headers), play: false);
      } else {
        final ctrl = VideoPlayerController.networkUrl(
          Uri.parse(url),
          httpHeaders: headers,
          formatHint: VideoFormat.hls,
        );
        await ctrl.initialize();
        await ctrl.pause();
        _vp = ctrl;
        _subs.add(
            Stream.periodic(const Duration(milliseconds: 400)).listen((_) {
          if (!mounted || _vp == null || _dragging) return;
          final v = _vp!.value;
          setState(() {
            _playing = v.isPlaying;
            _buffering = v.isBuffering;
            _position = v.position;
            _duration = v.duration;
          });
        }));
      }
      if (engineMk && server.subtitles.isNotEmpty && _mk != null) {
        final sub = server.subtitles.first;
        try {
          await _mk!.setSubtitleTrack(
            SubtitleTrack.uri(sub.url, title: sub.label, language: sub.lang),
          );
        } catch (_) {}
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[PartyTV] open error: $e');
      if (!engineMk) {
        debugPrint('[PartyTV] fallback media_kit');
        try {
          await _openWithMkOnly(url, headers);
        } catch (e2) {
          if (mounted) setState(() => _error = 'Error stream: $e2');
        }
      } else {
        if (mounted) setState(() => _error = 'Error stream: $e');
      }
    }
  }

  Future<void> _openWithMkOnly(
      String url, Map<String, String> headers) async {
    await _disposeEngines();
    _useMediaKit = true;
    MediaKit.ensureInitialized();
    final player = Player(
      configuration: const PlayerConfiguration(
        title: 'LOL Party TV',
        bufferSize: 32 * 1024 * 1024,
      ),
    );
    final video = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );
    _mk = player;
    _mkVideo = video;
    _subs.add(player.stream.playing.listen((v) {
      if (!mounted || _applyingRemote) return;
      setState(() => _playing = v);
      if (_isHost && _syncStarted) unawaited(_push(forcePlay: v));
    }));
    _subs.add(player.stream.buffering.listen((v) {
      if (mounted) setState(() => _buffering = v);
    }));
    _subs.add(player.stream.position.listen((v) {
      if (mounted && !_dragging) setState(() => _position = v);
    }));
    _subs.add(player.stream.duration.listen((v) {
      if (mounted) setState(() => _duration = v);
    }));
    await player.open(Media(url, httpHeaders: headers), play: false);
    if (mounted) setState(() {});
  }

  void _tryStartSync() {
    if (_syncStarted) return;
    if (!_party.allMembersHaveServer) return;
    if (_selected == null) return;
    _syncStarted = true;
    if (_isHost) {
      unawaited(_push(forcePlay: false));
      _hostPushTimer?.cancel();
      _hostPushTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (_isHost && _syncStarted && !_applyingRemote) unawaited(_push());
      });
    } else {
      _applyRemote(force: true);
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) async {
        if (!mounted || _isHost) return;
        await _party.refreshRoom();
        _applyRemote(force: false);
      });
    }
    if (mounted) setState(() {});
  }

  Future<void> _push({bool? forcePlay}) async {
    if (!_isHost || _selected == null) return;
    final hls = _isHls(_selected!.url, flag: _selected!.isHls);
    await _party.updatePlayback(PlaybackState(
      isPlaying: forcePlay ?? _playing,
      positionMs: _position.inMilliseconds,
      serverIndex: _servers.indexOf(_selected!),
      serverName: _selected!.name,
      streamUrl: _selected!.url,
      headers: Map<String, String>.from(_selected!.headers),
      isHls: hls,
      engine: hls ? 'video_player' : 'media_kit',
      streamKind: hls ? 'hls' : (_isTs(_selected!.url) ? 'ts' : 'other'),
    ));
  }

  void _applyRemote({bool force = false}) {
    if (_isHost) return;
    if (!_syncStarted && !force) return;
    final room = _party.currentRoom;
    if (room == null) return;
    final pb = room.playbackState;
    if (pb.streamUrl == null || pb.streamUrl!.isEmpty) return;
    final key =
        '${pb.isPlaying}|${pb.positionMs ~/ 2000}|${pb.streamUrl}|${pb.updatedAt?.millisecondsSinceEpoch}';
    if (!force && key == _lastAppliedKey) return;
    _lastAppliedKey = key;
    final need = _selected?.url != pb.streamUrl;
    if (need) {
      StreamServer? match;
      for (final s in _servers) {
        if (s.url == pb.streamUrl) {
          match = s;
          break;
        }
      }
      match ??= StreamServer(
        name: pb.serverName ?? 'Party',
        url: pb.streamUrl!,
        headers: pb.headers,
        isHls: pb.isHls,
      );
      unawaited(_openServer(match).then((_) => _applyPosAndPlay(pb)));
    } else {
      unawaited(_applyPosAndPlay(pb));
    }
  }

  Future<void> _applyPosAndPlay(PlaybackState pb) async {
    if (_applyingRemote) return;
    _applyingRemote = true;
    try {
      final target = Duration(milliseconds: pb.positionMs);
      const seekThreshold = Duration(milliseconds: 2000);
      if (_useMediaKit && _mk != null) {
        final buffering = _mk!.state.buffering;
        final diff = (_mk!.state.position - target).abs();
        if (!buffering && diff > seekThreshold) {
          await _mk!.seek(target);
        }
        if (pb.isPlaying && !_mk!.state.playing) {
          await _mk!.play();
        } else if (!pb.isPlaying && _mk!.state.playing) {
          await _mk!.pause();
        }
      } else if (_vp != null) {
        final buffering = _vp!.value.isBuffering;
        final diff = (_vp!.value.position - target).abs();
        if (!buffering && diff > seekThreshold) {
          await _vp!.seekTo(target);
        }
        if (pb.isPlaying && !_vp!.value.isPlaying) {
          await _vp!.play();
        } else if (!pb.isPlaying && _vp!.value.isPlaying) {
          await _vp!.pause();
        }
      }
    } finally {
      _applyingRemote = false;
    }
  }

  Future<void> _togglePlay() async {
    if (!_isHost || !_syncStarted) return;
    if (_useMediaKit && _mk != null) {
      if (_mk!.state.playing) {
        await _mk!.pause();
      } else {
        await _mk!.play();
      }
    } else if (_vp != null) {
      if (_vp!.value.isPlaying) {
        await _vp!.pause();
      } else {
        await _vp!.play();
      }
    }
    await _push();
  }

  Future<void> _seek(Duration d) async {
    if (!_isHost || !_syncStarted) return;
    if (_useMediaKit) {
      await _mk?.seek(d);
    } else {
      await _vp?.seekTo(d);
    }
    setState(() => _position = d);
    await _push();
  }

  Future<void> _selectServer(StreamServer s) async {
    if (!_isHost) return;
    await _openServer(s);
    await _party.setServerReady(true);
    await _push(forcePlay: false);
  }

  Future<void> _copyCode() async {
    final code = (_party.currentRoom ?? widget.room).code;
    await Clipboard.setData(ClipboardData(text: code));
  }

  Future<void> _writeChat() async {
    final text = await TvKeyboard.show(
      context,
      hint: 'Mensaje al chat',
      title: 'Chat de la sala',
    );
    if (text != null && text.trim().isNotEmpty) {
      await _party.sendMessage(text.trim());
    }
  }

  Future<void> _onLeave() async {
    if (_isHost) {
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _card,
          title: const Text('Salir de la sala',
              style: TextStyle(color: Colors.white)),
          content: const Text(
            'Eres el host. ¿Qué quieres hacer?',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            Focusable(
              autofocus: true,
              onTap: () => Navigator.pop(ctx),
              builder: (f) => _dlgBtn('Cancelar', f),
            ),
            Focusable(
              onTap: () => Navigator.pop(ctx, 'transfer'),
              builder: (f) => _dlgBtn('Ceder host', f),
            ),
            Focusable(
              onTap: () => Navigator.pop(ctx, 'close'),
              builder: (f) => _dlgBtn('Cerrar sala', f, danger: true),
            ),
          ],
        ),
      );
      if (action == 'close') {
        await _party.endAndDeleteRoom();
        if (mounted) Navigator.of(context).maybePop();
      } else if (action == 'transfer') {
        final members = _party.members
            .where(
                (m) => m.status == 'accepted' && m.userId != _party.userId)
            .toList();
        if (members.isEmpty) return;
        final chosen = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: _card,
            title: const Text('Ceder host a…',
                style: TextStyle(color: Colors.white)),
            content: SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: members
                    .map((m) => Focusable(
                          onTap: () => Navigator.pop(ctx, m.userId),
                          builder: (f) => Container(
                            padding: const EdgeInsets.all(12),
                            margin: const EdgeInsets.only(bottom: 6),
                            decoration: BoxDecoration(
                              border: Border.all(
                                  color: f ? _accent : Colors.white24),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(m.username,
                                style:
                                    const TextStyle(color: Colors.white)),
                          ),
                        ))
                    .toList(),
              ),
            ),
          ),
        );
        if (chosen != null) {
          await _party.transferHost(chosen);
          await _party.leaveAsMember();
          if (mounted) Navigator.of(context).maybePop();
        }
      }
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _card,
          title: const Text('Abandonar sala',
              style: TextStyle(color: Colors.white)),
          content: const Text(
            '¿Seguro que quieres salir?',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            Focusable(
              autofocus: true,
              onTap: () => Navigator.pop(ctx, false),
              builder: (f) => _dlgBtn('Cancelar', f),
            ),
            Focusable(
              onTap: () => Navigator.pop(ctx, true),
              builder: (f) => _dlgBtn('Salir', f, danger: true),
            ),
          ],
        ),
      );
      if (ok == true) {
        await _party.leaveAsMember();
        if (mounted) Navigator.of(context).maybePop();
      }
    }
  }

  Widget _dlgBtn(String label, bool focused, {bool danger = false}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: focused
            ? (danger ? Colors.redAccent : _accent)
            : Colors.white10,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: focused ? Colors.white : Colors.white24, width: 2),
        boxShadow: focused
            ? [
                BoxShadow(
                  color: (danger ? Colors.redAccent : _accent)
                      .withValues(alpha: 0.45),
                  blurRadius: 12,
                ),
              ]
            : null,
      ),
      child: Text(label,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w600)),
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String _fmtClock(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// Autoscroll al ítem con foco (TV D-pad).
  void _ensureFocusVisible(BuildContext itemContext) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!itemContext.mounted) return;
      Scrollable.ensureVisible(
        itemContext,
        alignment: 0.35,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Widget _buildWaitingRoomPage() {
    final room = _party.currentRoom ?? widget.room;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.hourglass_top_rounded, color: _accent, size: 56),
            const SizedBox(height: 20),
            const Text('En espera de ser aceptado',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Text(
                'El host debe aceptar tu entrada · Código ${room.code}',
                style: const TextStyle(color: Colors.white54)),
            const SizedBox(height: 24),
            const CircularProgressIndicator(color: _accent),
            const SizedBox(height: 24),
            Focusable(
              autofocus: true,
              onTap: () async {
                await _party.leaveAsMember();
                if (mounted) Navigator.of(context).maybePop();
              },
              builder: (f) => _dlgBtn('Cancelar', f, danger: true),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_party.isPendingMember && !_isHost) {
      return _buildWaitingRoomPage();
    }
    final room = _party.currentRoom ?? widget.room;
    final members =
        _party.members.where((m) => m.status == 'accepted').toList();
    final pending =
        _party.members.where((m) => m.status == 'pending').toList();
    final ready = members.where((m) => m.hasServerReady).length;
    const sideW = 380.0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _rootFocus,
        autofocus: !_sidebarOpen,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final k = event.logicalKey;
          if (k == LogicalKeyboardKey.goBack ||
              k == LogicalKeyboardKey.escape ||
              k == LogicalKeyboardKey.browserBack) {
            if (_sidebarOpen) {
              setState(() => _sidebarOpen = false);
              return KeyEventResult.handled;
            }
            unawaited(_onLeave());
            return KeyEventResult.handled;
          }
          if (!_sidebarOpen) {
            if (k == LogicalKeyboardKey.select ||
                k == LogicalKeyboardKey.enter ||
                k == LogicalKeyboardKey.space) {
              if (_isHost) unawaited(_togglePlay());
              return KeyEventResult.handled;
            }
            if (k == LogicalKeyboardKey.arrowLeft && _isHost) {
              unawaited(_seek(_position - const Duration(seconds: 10)));
              return KeyEventResult.handled;
            }
            if (k == LogicalKeyboardKey.arrowRight && _isHost) {
              unawaited(_seek(_position + const Duration(seconds: 10)));
              return KeyEventResult.handled;
            }
            if (k == LogicalKeyboardKey.arrowUp) {
              setState(() => _sidebarOpen = true);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Row(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_useMediaKit && _mkVideo != null)
                    Center(
                      child: Video(
                        controller: _mkVideo!,
                        controls: NoVideoControls,
                      ),
                    )
                  else if (!_useMediaKit &&
                      _vp != null &&
                      _vp!.value.isInitialized)
                    Center(
                      child: AspectRatio(
                        aspectRatio: _vp!.value.aspectRatio == 0
                            ? 16 / 9
                            : _vp!.value.aspectRatio,
                        child: VideoPlayer(_vp!),
                      ),
                    )
                  else
                    const ColoredBox(color: Colors.black),

                  if (_party.isPendingMember && !_isHost)
                    Container(
                      color: Colors.black87,
                      child: const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.hourglass_top_rounded,
                                  color: _accent, size: 48),
                              SizedBox(height: 16),
                              Text('Sala privada',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700)),
                              SizedBox(height: 8),
                              Text(
                                'Espera la confirmación del host.\nNo hay vídeo ni audio hasta que te acepte.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else if (_loading || _error != null || !_syncStarted)
                    Container(
                      color: Colors.black87,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_error != null) ...[
                              Text(_error!,
                                  style: const TextStyle(
                                      color: Colors.white70)),
                              const SizedBox(height: 12),
                              Focusable(
                                autofocus: true,
                                onTap: _loadStreams,
                                builder: (f) => _dlgBtn('Reintentar', f),
                              ),
                            ] else ...[
                              const CircularProgressIndicator(
                                  color: _accent),
                              const SizedBox(height: 12),
                              Text(
                                _loading
                                    ? 'Cargando…'
                                    : 'Esperando servidores ($ready/${members.length})',
                                style: const TextStyle(
                                    color: Colors.white70),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                  // Top bar: título + código + reloj + restante + acciones
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(28, 18, 28, 28),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.black87, Colors.transparent],
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(room.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 18)),
                                const SizedBox(height: 2),
                                Text(
                                  '${_isHost ? "HOST" : "INVITADO"} · ${members.length} en sala',
                                  style: const TextStyle(
                                      color: Colors.white54, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          // Hora actual + tiempo restante (arriba derecha)
                          Container(
                            margin: const EdgeInsets.only(right: 12),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.black45,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  _fmtClock(_now),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                    letterSpacing: 1,
                                  ),
                                ),
                                Text(
                                  _duration.inMilliseconds > 0
                                      ? '−${_fmt(_remaining)}'
                                      : '−−:−−',
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Focusable(
                            onTap: _copyCode,
                            builder: (f) => AnimatedContainer(
                              duration: const Duration(milliseconds: 120),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: f ? _accent : Colors.white12,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                    color: f ? Colors.white : Colors.transparent,
                                    width: 2),
                              ),
                              child: Text(room.code,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 2)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Focusable(
                            onTap: () =>
                                setState(() => _sidebarOpen = !_sidebarOpen),
                            builder: (f) => _roundAction(
                              f,
                              Icons.chat_rounded,
                              f ? _accent : Colors.white12,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Focusable(
                            onTap: _onLeave,
                            builder: (f) => _roundAction(
                              f,
                              Icons.call_end_rounded,
                              f ? Colors.redAccent : Colors.white12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Bottom: barra de progreso ARRIBA, botones DEBAJO
                  if (_syncStarted)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(28, 32, 28, 22),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [Colors.black87, Colors.transparent],
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Progreso
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: _duration.inMilliseconds <= 0
                                    ? 0
                                    : (_position.inMilliseconds /
                                            _duration.inMilliseconds)
                                        .clamp(0.0, 1.0),
                                backgroundColor: Colors.white24,
                                color: _accent,
                                minHeight: 5,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Text(_fmt(_position),
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 12)),
                                const Spacer(),
                                Text(
                                  _duration.inMilliseconds > 0
                                      ? 'Quedan ${_fmt(_remaining)}'
                                      : '',
                                  style: const TextStyle(
                                      color: Colors.white38, fontSize: 11),
                                ),
                                const Spacer(),
                                Text(_fmt(_duration),
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 12)),
                              ],
                            ),
                            const SizedBox(height: 10),
                            // Botones DEBAJO de la barra
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (_isHost) ...[
                                  Focusable(
                                    onTap: () => unawaited(
                                        _seek(_position -
                                            const Duration(seconds: 10))),
                                    builder: (f) => _controlBtn(
                                      f,
                                      Icons.replay_10_rounded,
                                      size: 36,
                                    ),
                                  ),
                                  const SizedBox(width: 20),
                                ],
                                Focusable(
                                  focusNode: _playFocus,
                                  onTap: _isHost ? _togglePlay : null,
                                  builder: (f) => AnimatedScale(
                                    scale: f ? 1.12 : 1.0,
                                    duration:
                                        const Duration(milliseconds: 120),
                                    child: Icon(
                                      _playing
                                          ? Icons.pause_circle_filled
                                          : Icons.play_circle_filled,
                                      size: 56,
                                      color: f
                                          ? _accent
                                          : (_isHost
                                              ? Colors.white
                                              : Colors.white38),
                                    ),
                                  ),
                                ),
                                if (_isHost) ...[
                                  const SizedBox(width: 20),
                                  Focusable(
                                    onTap: () => unawaited(
                                        _seek(_position +
                                            const Duration(seconds: 10))),
                                    builder: (f) => _controlBtn(
                                      f,
                                      Icons.forward_10_rounded,
                                      size: 36,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (!_isHost)
                              const Padding(
                                padding: EdgeInsets.only(top: 6),
                                child: Text(
                                  'El host controla · ↑ panel chat',
                                  style: TextStyle(
                                      color: Colors.white38, fontSize: 11),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // SIDEBAR
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: _sidebarOpen ? sideW : 0,
              child: _sidebarOpen
                  ? Material(
                      color: _panel,
                      child: Column(
                        children: [
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              _tab(0, 'Chat', Icons.chat_bubble_outline),
                              _tab(1, 'Gente', Icons.group_outlined),
                              _tab(2, 'Idioma', Icons.tune_rounded),
                            ],
                          ),
                          const Divider(height: 1, color: _border),
                          Expanded(
                            child: _sidebarTab == 0
                                ? _chatPanel()
                                : _sidebarTab == 1
                                    ? _membersPanel(members, pending)
                                    : _serversPanel(),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roundAction(bool focused, IconData icon, Color bg) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: Border.all(
            color: focused ? Colors.white : Colors.transparent, width: 2),
        boxShadow: focused
            ? [
                BoxShadow(
                    color: bg.withValues(alpha: 0.5), blurRadius: 10)
              ]
            : null,
      ),
      child: Icon(icon, color: Colors.white, size: 22),
    );
  }

  Widget _controlBtn(bool focused, IconData icon, {double size = 32}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: focused ? _accent.withValues(alpha: 0.25) : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(
            color: focused ? _accent : Colors.transparent, width: 2),
      ),
      child: Icon(icon,
          size: size, color: focused ? _accent : Colors.white70),
    );
  }

  Widget _tab(int i, String label, IconData icon) {
    final sel = _sidebarTab == i;
    return Expanded(
      child: Focusable(
        onTap: () => setState(() => _sidebarTab = i),
        builder: (f) {
          final active = sel || f;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: f ? Colors.white.withValues(alpha: 0.06) : null,
              border: Border(
                bottom: BorderSide(
                    color: active ? _accent : Colors.transparent, width: 2),
              ),
            ),
            child: Column(
              children: [
                Icon(icon,
                    size: 18, color: active ? _accent : Colors.white54),
                const SizedBox(height: 2),
                Text(label,
                    style: TextStyle(
                        color: active ? _accent : Colors.white54,
                        fontWeight: FontWeight.w600,
                        fontSize: 12)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _chatPanel() {
    final msgs = _party.messages
        .where((m) => !m.message.startsWith('__reaction__:'))
        .toList();
    return Column(
      children: [
        Expanded(
          child: msgs.isEmpty
              ? const Center(
                  child:
                      Text('Sin mensajes', style: TextStyle(color: _muted)))
              : ListView.builder(
                  controller: _chatScroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) {
                    final m = msgs[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: RichText(
                        text: TextSpan(children: [
                          TextSpan(
                            text: '${m.username}: ',
                            style: const TextStyle(
                                color: _accent, fontWeight: FontWeight.w700),
                          ),
                          TextSpan(
                            text: m.message,
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ]),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Focusable(
            onTap: _writeChat,
            builder: (f) => AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: f ? _accent : _card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: f ? Colors.white : Colors.white12, width: 2),
              ),
              alignment: Alignment.center,
              child: const Text('Escribir mensaje (teclado)',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _membersPanel(
      List<PartyMember> members, List<PartyMember> pending) {
    final hostId = (_party.currentRoom ?? widget.room).hostUserId;
    final sorted = List<PartyMember>.from(members)
      ..sort((a, b) {
        final aH = a.isHost || a.userId == hostId;
        final bH = b.isHost || b.userId == hostId;
        if (aH && !bH) return -1;
        if (!aH && bH) return 1;
        return a.username.compareTo(b.username);
      });

    return ListView(
      controller: _membersScroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('En la sala',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
            ),
            Focusable(
              onTap: () async {
                await _party.refreshRoom();
                if (mounted) setState(() {});
              },
              builder: (f) => AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: f ? _accent : Colors.white10,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: f ? Colors.white : Colors.transparent, width: 2),
                ),
                child: const Icon(Icons.refresh_rounded,
                    color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...sorted.asMap().entries.map((entry) {
          final i = entry.key;
          final m = entry.value;
          final isRoomHost = m.isHost || m.userId == hostId;
          return Focusable(
            autofocus: i == 0 && pending.isEmpty,
            onTap: () {},
            builder: (f) {
              return _FocusScrollItem(
                focused: f,
                onFocused: _ensureFocusVisible,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  margin: const EdgeInsets.only(bottom: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    color: f
                        ? _accent.withValues(alpha: 0.18)
                        : _card,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: f ? _accent : Colors.white12,
                      width: f ? 2 : 1,
                    ),
                    boxShadow: f
                        ? [
                            BoxShadow(
                              color: _accent.withValues(alpha: 0.25),
                              blurRadius: 10,
                            )
                          ]
                        : null,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isRoomHost
                            ? Icons.workspace_premium_rounded
                            : Icons.person_rounded,
                        color: isRoomHost
                            ? const Color(0xFFFFD54F)
                            : Colors.white54,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(m.username,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600)),
                            Text(
                              m.hasServerReady ? 'Listo' : 'Cargando…',
                              style: TextStyle(
                                color: m.hasServerReady
                                    ? Colors.greenAccent
                                    : Colors.white38,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_isHost && m.userId != _party.userId)
                        Focusable(
                          onTap: () => _party.kickMember(m.userId),
                          builder: (fk) => AnimatedContainer(
                            duration: const Duration(milliseconds: 100),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: fk ? Colors.redAccent : Colors.white10,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: fk ? Colors.white : Colors.transparent,
                                  width: 2),
                            ),
                            child: const Icon(Icons.person_remove_rounded,
                                color: Colors.white, size: 18),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          );
        }),
        if (_isHost && pending.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('Solicitudes',
              style: TextStyle(
                  color: Colors.white70, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          ...pending.asMap().entries.map((entry) {
            final i = entry.key;
            final m = entry.value;
            return Focusable(
              autofocus: i == 0,
              onTap: () {},
              builder: (f) {
                return _FocusScrollItem(
                  focused: f,
                  onFocused: _ensureFocusVisible,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: f ? Colors.white.withValues(alpha: 0.08) : _card,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: f ? _accent : Colors.white12,
                          width: f ? 2 : 1),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(m.username,
                              style: const TextStyle(color: Colors.white)),
                        ),
                        Focusable(
                          onTap: () =>
                              _party.respondJoinRequest(m.userId, true),
                          builder: (fk) => _miniIconBtn(
                              fk, Icons.check, Colors.greenAccent),
                        ),
                        const SizedBox(width: 8),
                        Focusable(
                          onTap: () =>
                              _party.respondJoinRequest(m.userId, false),
                          builder: (fk) =>
                              _miniIconBtn(fk, Icons.close, Colors.redAccent),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          }),
        ],
      ],
    );
  }

  Widget _miniIconBtn(bool focused, IconData icon, Color color) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 100),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: focused ? color.withValues(alpha: 0.35) : Colors.white10,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: focused ? color : Colors.transparent, width: 2),
      ),
      child: Icon(icon, color: focused ? color : Colors.white54, size: 20),
    );
  }

  Widget _serversPanel() {
    if (!_isHost) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Solo el host puede cambiar idioma / servidor.\nSe respeta el idioma del repo al entrar.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _muted),
          ),
        ),
      );
    }
    return ListView(
      controller: _serversScroll,
      padding: const EdgeInsets.all(10),
      children: _servers.asMap().entries.map((entry) {
        final i = entry.key;
        final s = entry.value;
        final sel = _selected?.url == s.url;
        final lang = s.language ?? '';
        return Focusable(
          autofocus: i == 0,
          onTap: () => _selectServer(s),
          builder: (f) {
            return _FocusScrollItem(
              focused: f,
              onFocused: _ensureFocusVisible,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: sel || f
                      ? _accent.withValues(alpha: 0.18)
                      : _card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: f || sel ? _accent : Colors.white12,
                    width: f || sel ? 2 : 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600)),
                    if (lang.isNotEmpty)
                      Text(lang,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12)),
                    Text(
                      _isHls(s.url, flag: s.isHls) ? 'HLS' : 'TS / otro',
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      }).toList(),
    );
  }
}

/// Al ganar foco, hace scroll para que el ítem quede visible en TV.
class _FocusScrollItem extends StatefulWidget {
  final bool focused;
  final Widget child;
  final void Function(BuildContext context) onFocused;

  const _FocusScrollItem({
    required this.focused,
    required this.child,
    required this.onFocused,
  });

  @override
  State<_FocusScrollItem> createState() => _FocusScrollItemState();
}

class _FocusScrollItemState extends State<_FocusScrollItem> {
  @override
  void didUpdateWidget(covariant _FocusScrollItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focused && !oldWidget.focused) {
      widget.onFocused(context);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}