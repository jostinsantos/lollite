import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:dart_cast/dart_cast.dart';
import '../../../../data/services/stream_proxy.dart';

const _bg = Color(0xFF12161E);
const _card = Color(0xFF1A222D);
const _accent = Color(0xFFE50914);

/// Prepara URL + tipo de media para Cast/DLNA.
/// - DLNA: siempre proxy (la TV no manda headers).
/// - .ts / mpegts: proxy + wrapper HLS (muchas TV no leen TS crudo).
/// - Headers (Referer/Auth/Cookie): proxy.
Future<({String url, CastMediaType type})> prepareCastMedia({
  required String videoUrl,
  Map<String, String> headers = const {},
  required CastProtocol protocol,
}) async {
  final lower = videoUrl.toLowerCase();
  final isHls = StreamProxy.isHls(videoUrl);
  // isMpegTs ya excluye URLs HLS (no tocar m3u8 aunque el path tenga .ts)
  final isTs = !isHls && StreamProxy.isMpegTs(videoUrl);

  // Headers que la TV no puede enviar sola
  final hasAuthHeaders = headers.keys.any((k) {
    final l = k.toLowerCase();
    return l == 'referer' ||
        l == 'origin' ||
        l == 'authorization' ||
        l == 'cookie';
  });

  // HLS: mismo comportamiento de siempre (proxy solo DLNA o headers de auth).
  // TS: siempre proxy + wrapper HLS (solo para .ts, no para m3u8).
  final needsProxy = isTs ||
      protocol == CastProtocol.dlna ||
      hasAuthHeaders;

  var playUrl = videoUrl;
  if (needsProxy) {
    try {
      playUrl = await StreamProxy.instance.start(
        upstreamUrl: videoUrl,
        headers: headers,
      );
      debugPrint(
          '[Cast] proxy → $playUrl (ts=$isTs hls=$isHls dlna=${protocol == CastProtocol.dlna})');
    } catch (e) {
      debugPrint('[Cast] proxy falló, URL directa: $e');
      playUrl = videoUrl;
    }
  }

  final CastMediaType type;
  if (isHls) {
    // HLS real: no convertir, tipo HLS
    type = CastMediaType.hls;
  } else if (isTs) {
    // TS envuelto como HLS solo en el proxy local
    type = CastMediaType.hls;
  } else if (lower.contains('.mkv')) {
    type = CastMediaType.mkv;
  } else if (lower.contains('.mp4') || lower.contains('.m4v')) {
    type = CastMediaType.mp4;
  } else {
    type = CastMediaType.mp4;
  }
  return (url: playUrl, type: type);
}

/// Resultado al conectar: servicio + sesión activos.
class CastConnection {
  final CastService service;
  final CastSession session;
  final CastDevice device;
  CastConnection({
    required this.service,
    required this.session,
    required this.device,
  });
}

/// Modal: busca dispositivos (Chromecast + DLNA) y conecta con dart_cast.
Future<CastConnection?> showCastDevicePicker(
  BuildContext context, {
  required String videoUrl,
  Map<String, String> headers = const {},
  String title = '',
  String? imageUrl,
  Duration? startPosition,
  Duration? duration,
}) {
  return showModalBottomSheet<CastConnection>(
    context: context,
    backgroundColor: _bg,
    isScrollControlled: true,
    isDismissible: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (ctx) => _DeviceSheet(
      videoUrl: videoUrl,
      headers: headers,
      title: title,
      imageUrl: imageUrl,
      startPosition: startPosition,
      duration: duration,
    ),
  );
}

class _DeviceSheet extends StatefulWidget {
  final String videoUrl;
  final Map<String, String> headers;
  final String title;
  final String? imageUrl;
  final Duration? startPosition;
  final Duration? duration;

  const _DeviceSheet({
    required this.videoUrl,
    required this.headers,
    required this.title,
    this.imageUrl,
    this.startPosition,
    this.duration,
  });

  @override
  State<_DeviceSheet> createState() => _DeviceSheetState();
}

class _DeviceSheetState extends State<_DeviceSheet> {
  late final CastService _service;
  List<CastDevice> _devices = [];
  bool _discovering = true;
  String? _connectingId;
  String? _error;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    // Igual que LOL app: Chromecast + DLNA via dart_cast
    _service = CastService(
      discoveryProviders: [
        ChromecastDiscoveryProvider(),
        DlnaDiscoveryProvider(),
      ],
      sessionFactory: (device) {
        switch (device.protocol) {
          case CastProtocol.chromecast:
            return ChromecastSession(device: device);
          case CastProtocol.dlna:
            // Extrae control URLs del metadata del discovery
            return DlnaSession.fromDevice(device);
          case CastProtocol.airplay:
            throw UnsupportedError('AirPlay no soportado en esta build');
        }
      },
    );
    _startDiscovery();
  }

  void _startDiscovery() {
    setState(() {
      _discovering = true;
      _devices = [];
      _error = null;
      _connectingId = null;
    });
    _sub?.cancel();
    _sub = _service
        .startDiscovery(
          protocols: {CastProtocol.chromecast, CastProtocol.dlna},
          timeout: const Duration(seconds: 12),
        )
        .listen(
      (devices) {
        if (!mounted) return;
        setState(() {
          _devices = devices;
          _discovering = false;
        });
      },
      onError: (e) {
        if (!mounted) return;
        setState(() {
          _discovering = false;
          _error = e.toString();
        });
      },
      onDone: () {
        if (mounted && _discovering) {
          setState(() => _discovering = false);
        }
      },
    );
  }

  Future<void> _connect(CastDevice device) async {
    if (_connectingId != null) return;
    setState(() => _connectingId = device.id);

    try {
      final session = await _service.connect(device);

      final prepared = await prepareCastMedia(
        videoUrl: widget.videoUrl,
        headers: widget.headers,
        protocol: device.protocol,
      );

      await session.loadMedia(CastMedia(
        url: prepared.url,
        type: prepared.type,
        title: widget.title.isNotEmpty ? widget.title : 'Video',
        imageUrl: widget.imageUrl,
        // Si ya va por proxy, headers no hacen falta en la TV
        httpHeaders: prepared.url.contains('/media') ? const {} : widget.headers,
        startPosition: widget.startPosition,
        duration: widget.duration,
      ));

      if (!mounted) return;
      Navigator.of(context).pop(CastConnection(
        service: _service,
        session: session,
        device: device,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _connectingId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No se pudo conectar: $e'),
          backgroundColor: Colors.red[900],
        ),
      );
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    // No dispose del CastService si hay sesión activa (la gestiona CastScreen)
    if (_connectingId == null) {
      try {
        _service.stopDiscovery();
      } catch (_) {}
    }
    super.dispose();
  }

  IconData _iconFor(CastProtocol p) {
    switch (p) {
      case CastProtocol.chromecast:
        return Icons.cast_rounded;
      case CastProtocol.dlna:
        return Icons.tv_rounded;
      case CastProtocol.airplay:
        return Icons.airplay_rounded;
    }
  }

  String _labelFor(CastProtocol p) {
    switch (p) {
      case CastProtocol.chromecast:
        return 'Chromecast';
      case CastProtocol.dlna:
        return 'DLNA';
      case CastProtocol.airplay:
        return 'AirPlay';
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height * 0.58;
    return SafeArea(
      child: SizedBox(
        height: h,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Transmitir a',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Buscar de nuevo',
                    onPressed: _discovering ? null : _startDiscovery,
                    icon: Icon(
                      Icons.refresh_rounded,
                      color: _discovering ? Colors.white24 : Colors.white70,
                    ),
                  ),
                ],
              ),
              Text(
                'Chromecast y DLNA · misma Wi‑Fi',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45), fontSize: 12),
              ),
              const SizedBox(height: 12),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                ),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_discovering && _devices.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(color: _accent, strokeWidth: 3),
            ),
            SizedBox(height: 16),
            Text('Buscando dispositivos…',
                style: TextStyle(color: Colors.white54)),
          ],
        ),
      );
    }
    if (!_discovering && _devices.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.devices_other_rounded,
                color: Colors.white.withValues(alpha: 0.3), size: 44),
            const SizedBox(height: 12),
            const Text('No se encontraron dispositivos',
                style:
                    TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              'Misma Wi‑Fi · TV/Chromecast encendido\nWeb Video Caster en modo receptor',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45), fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _startDiscovery,
              child: const Text('Buscar de nuevo',
                  style: TextStyle(color: _accent)),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      itemCount: _devices.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final d = _devices[i];
        final busy = _connectingId == d.id;
        return Material(
          color: _card,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: busy ? null : () => _connect(d),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(_iconFor(d.protocol),
                        color: Colors.white70, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          d.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          _labelFor(d.protocol) +
                              (''),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.45),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (busy)
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: _accent),
                    )
                  else
                    const Icon(Icons.chevron_right_rounded,
                        color: Colors.white38),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}