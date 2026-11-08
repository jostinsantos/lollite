import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../data/models/download_item.dart';
import '../../../../data/services/download_service.dart';
import '../repo/player/player.dart';
import '../widgets/focusable.dart';

/// Página de descargas optimizada para TV (foco D-pad).
class TvDownloadsPage extends StatefulWidget {
  const TvDownloadsPage({super.key});

  @override
  State<TvDownloadsPage> createState() => _TvDownloadsPageState();
}

class _TvDownloadsPageState extends State<TvDownloadsPage> {
  Future<void> _openThreadsModal() async {
    final svc = DownloadService.instance;
    var value = svc.maxParallel;
    final result = await showGeneralDialog<int>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Cerrar',
      barrierColor: Colors.black54,
      pageBuilder: (ctx, a1, a2) {
        return Center(
          child: Material(
            color: Colors.transparent,
            child: StatefulBuilder(
              builder: (ctx, setLocal) {
                return FocusTraversalGroup(
                  child: Container(
                    width: 420,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: const Color(0xFF141A22),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Hilos de descarga',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Izquierda / derecha para cambiar · arriba / abajo para botones',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                        const SizedBox(height: 20),
                        Focus(
                          autofocus: true,
                          onKeyEvent: (node, event) {
                            if (event is! KeyDownEvent) {
                              return KeyEventResult.ignored;
                            }
                            if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                                event.logicalKey == LogicalKeyboardKey.arrowDown &&
                                    false) {
                              // left
                            }
                            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                              setLocal(() => value = (value - 1).clamp(1, 8));
                              return KeyEventResult.handled;
                            }
                            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                              setLocal(() => value = (value + 1).clamp(1, 8));
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                          child: Builder(builder: (context) {
                            final f = Focus.of(context).hasFocus;
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 100),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 16),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: f ? Colors.white : Colors.white24,
                                  width: f ? 2.5 : 1,
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.chevron_left,
                                      color: Colors.white54),
                                  const SizedBox(width: 16),
                                  Text(
                                    '$value',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 36,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  const Icon(Icons.chevron_right,
                                      color: Colors.white54),
                                ],
                              ),
                            );
                          }),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          value == 1
                              ? '1 hilo (más estable)'
                              : '$value hilos en paralelo',
                          style: const TextStyle(color: Colors.white54),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: Focusable(
                                onTap: () => Navigator.pop(ctx, null),
                                builder: (f) => Container(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: f
                                        ? Colors.white24
                                        : Colors.white.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: f
                                            ? Colors.white
                                            : Colors.transparent,
                                        width: 2),
                                  ),
                                  child: const Text('Cancelar',
                                      style: TextStyle(color: Colors.white70)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Focusable(
                                onTap: () => Navigator.pop(ctx, value),
                                builder: (f) => Container(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: f
                                        ? Colors.white
                                        : const Color(0xFFE50914),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: f
                                            ? const Color(0xFFE50914)
                                            : Colors.transparent,
                                        width: 2),
                                  ),
                                  child: Text('Aceptar',
                                      style: TextStyle(
                                          color: f
                                              ? Colors.black
                                              : Colors.white,
                                          fontWeight: FontWeight.w700)),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
    if (result != null) {
      await svc.setMaxParallel(result);
      if (mounted) setState(() {});
    }
  }

  Future<void> _openConcurrentModal() async {
    final svc = DownloadService.instance;
    var value = svc.maxConcurrent;
    final result = await showGeneralDialog<int>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Cerrar',
      barrierColor: Colors.black54,
      pageBuilder: (ctx, a1, a2) {
        return Center(
          child: Material(
            color: Colors.transparent,
            child: StatefulBuilder(
              builder: (ctx, setLocal) {
                return FocusTraversalGroup(
                  child: Container(
                    width: 420,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: const Color(0xFF141A22),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Descargas a la vez',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Cuántas películas/episodios bajar en paralelo (1–3)',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                        const SizedBox(height: 20),
                        Focus(
                          autofocus: true,
                          onKeyEvent: (node, event) {
                            if (event is! KeyDownEvent) {
                              return KeyEventResult.ignored;
                            }
                            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                              setLocal(() => value = (value - 1).clamp(1, 3));
                              return KeyEventResult.handled;
                            }
                            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                              setLocal(() => value = (value + 1).clamp(1, 3));
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                          child: Builder(builder: (context) {
                            final f = Focus.of(context).hasFocus;
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 100),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 16),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: f ? Colors.white : Colors.white24,
                                  width: f ? 2.5 : 1,
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.chevron_left,
                                      color: Colors.white54),
                                  const SizedBox(width: 16),
                                  Text(
                                    '$value',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 36,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  const Icon(Icons.chevron_right,
                                      color: Colors.white54),
                                ],
                              ),
                            );
                          }),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          value == 1
                              ? '1 descarga a la vez'
                              : '$value descargas simultáneas',
                          style: const TextStyle(color: Colors.white54),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: Focusable(
                                onTap: () => Navigator.pop(ctx, null),
                                builder: (f) => Container(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: f
                                        ? Colors.white24
                                        : Colors.white.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: f
                                            ? Colors.white
                                            : Colors.transparent,
                                        width: 2),
                                  ),
                                  child: const Text('Cancelar',
                                      style: TextStyle(color: Colors.white70)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Focusable(
                                onTap: () => Navigator.pop(ctx, value),
                                builder: (f) => Container(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: f
                                        ? Colors.white
                                        : const Color(0xFFE50914),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: f
                                            ? const Color(0xFFE50914)
                                            : Colors.transparent,
                                        width: 2),
                                  ),
                                  child: Text('Aceptar',
                                      style: TextStyle(
                                          color: f
                                              ? Colors.black
                                              : Colors.white,
                                          fontWeight: FontWeight.w700)),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
    if (result != null) {
      await svc.setMaxConcurrent(result);
      if (mounted) setState(() {});
    }
  }

  /// Episodio de serie si tiene season o episode guardados al descargar.
  bool _isEpisode(DownloadItem it) =>
      it.season != null || it.episode != null;

  /// Agrupa por contentId (datos reales al encolar). Películas sueltas.
  List<_ListEntry> _buildEntries(List<DownloadItem> items) {
    final groups = <String, List<DownloadItem>>{};
    final order = <String>[];
    final singles = <DownloadItem>[];

    for (final it in items) {
      if (_isEpisode(it)) {
        final key = it.contentId;
        if (!groups.containsKey(key)) {
          groups[key] = [];
          order.add('g:$key');
        }
        groups[key]!.add(it);
      } else {
        order.add('s:${it.id}');
        singles.add(it);
      }
    }

    for (final list in groups.values) {
      list.sort((a, b) {
        final sa = a.season ?? 0;
        final sb = b.season ?? 0;
        if (sa != sb) return sa.compareTo(sb);
        return (a.episode ?? 0).compareTo(b.episode ?? 0);
      });
    }

    final entries = <_ListEntry>[];
    final used = <String>{};
    for (final k in order) {
      if (k.startsWith('g:')) {
        final list = groups[k.substring(2)]!;
        if (list.isNotEmpty) entries.add(_ListEntry.group(list));
      } else {
        final id = k.substring(2);
        final it = singles.cast<DownloadItem?>().firstWhere(
              (e) => e?.id == id,
              orElse: () => null,
            );
        if (it != null && used.add(it.id)) {
          entries.add(_ListEntry.single(it));
        }
      }
    }
    return entries;
  }

  void _openSeriesView(List<DownloadItem> episodes) {
    final first = episodes.first;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _TvSeriesDownloadsPage(
          contentId: first.contentId,
          seriesTitle: first.title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<DownloadService>();
    final entries = _buildEntries(svc.items);

    return Scaffold(
      backgroundColor: const Color(0xFF0B0E14),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 16, 28, 8),
              child: Row(
                children: [
                  const Text(
                    'Descargas',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Hilos: ${svc.maxParallel}  ·  A la vez: ${svc.maxConcurrent}',
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  const SizedBox(width: 12),
                  Focusable(
                    autofocus: true,
                    onTap: _openThreadsModal,
                    builder: (f) => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: f ? Colors.white24 : Colors.white10,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: f ? Colors.white : Colors.transparent,
                            width: 2),
                      ),
                      child: const Text('Hilos',
                          style:
                              TextStyle(color: Colors.white70, fontSize: 12)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Focusable(
                    onTap: _openConcurrentModal,
                    builder: (f) => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: f ? Colors.white24 : Colors.white10,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: f ? Colors.white : Colors.transparent,
                            width: 2),
                      ),
                      child: const Text('A la vez',
                          style:
                              TextStyle(color: Colors.white70, fontSize: 12)),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: entries.isEmpty
                  ? const Center(
                      child: Text('No hay descargas',
                          style:
                              TextStyle(color: Colors.white54, fontSize: 16)),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(28, 8, 28, 32),
                      itemCount: entries.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (ctx, i) {
                        final e = entries[i];
                        if (e.isGroup) {
                          return _TvSeriesGroupTile(
                            episodes: e.episodes,
                            onOpen: () => _openSeriesView(e.episodes),
                          );
                        }
                        return _TvTile(item: e.item!);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ListEntry {
  final DownloadItem? item;
  final List<DownloadItem> episodes;
  final bool isGroup;

  _ListEntry.single(DownloadItem this.item)
      : episodes = const [],
        isGroup = false;

  _ListEntry.group(List<DownloadItem> this.episodes)
      : item = null,
        isGroup = true;
}

/// Fila de serie en la lista principal (agrupa todos los capítulos del contentId).
class _TvSeriesGroupTile extends StatelessWidget {
  final List<DownloadItem> episodes;
  final VoidCallback onOpen;

  const _TvSeriesGroupTile({required this.episodes, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final first = episodes.first;
    final total = episodes.length;
    final done =
        episodes.where((e) => e.status == DownloadStatus.completed).length;
    final active = episodes
        .where((e) =>
            e.status == DownloadStatus.downloading ||
            e.status == DownloadStatus.queued ||
            e.status == DownloadStatus.converting)
        .length;

    String summary;
    if (active > 0) {
      summary = '$done/$total completados · $active en curso';
    } else if (done == total) {
      summary = '$total capítulos · Completada';
    } else {
      summary = '$done/$total completados';
    }

    double? avgProgress;
    final downloading =
        episodes.where((e) => e.status == DownloadStatus.downloading).toList();
    if (downloading.isNotEmpty) {
      avgProgress = downloading.map((e) => e.progress).reduce((a, b) => a + b) /
          downloading.length;
    }

    return Focusable(
      onTap: onOpen,
      builder: (f) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF141A22),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: f ? Colors.white : Colors.white10,
            width: f ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 64,
                height: 90,
                child: first.poster != null
                    ? CachedNetworkImage(
                        imageUrl: first.poster!,
                        fit: BoxFit.cover,
                        memCacheWidth: 128)
                    : const ColoredBox(color: Colors.black26),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color:
                              const Color(0xFFE50914).withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'SERIE',
                          style: TextStyle(
                            color: Color(0xFFE50914),
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          first.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Repo: ${first.repoName} · $total capítulo${total == 1 ? '' : 's'}',
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    summary,
                    style: TextStyle(
                      color: done == total
                          ? const Color(0xFF4CAF50)
                          : (active > 0
                              ? const Color(0xFF7DD3FC)
                              : Colors.white54),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (avgProgress != null) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: avgProgress.clamp(0.0, 1.0),
                      minHeight: 4,
                      color: const Color(0xFF7DD3FC),
                      backgroundColor: Colors.white12,
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: f ? Colors.white : Colors.white38, size: 28),
          ],
        ),
      ),
    );
  }
}

/// Vista de capítulos de una serie (mismo estilo de tiles que la lista).
class _TvSeriesDownloadsPage extends StatelessWidget {
  final String contentId;
  final String seriesTitle;

  const _TvSeriesDownloadsPage({
    required this.contentId,
    required this.seriesTitle,
  });

  Future<void> _deleteAll(BuildContext context, List<DownloadItem> episodes) async {
    final svc = DownloadService.instance;
    final ok = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Cerrar',
      barrierColor: Colors.black54,
      pageBuilder: (ctx, a1, a2) {
        return Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 420,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF141A22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Borrar serie',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '¿Borrar los ${episodes.length} capítulos de "$seriesTitle"?',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: Focusable(
                          autofocus: true,
                          onTap: () => Navigator.pop(ctx, false),
                          builder: (f) => Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: f
                                  ? Colors.white24
                                  : Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: f ? Colors.white : Colors.transparent,
                                  width: 2),
                            ),
                            child: const Text('Cancelar',
                                style: TextStyle(color: Colors.white70)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Focusable(
                          onTap: () => Navigator.pop(ctx, true),
                          builder: (f) => Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: f ? Colors.white : const Color(0xFFE50914),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: f
                                      ? const Color(0xFFE50914)
                                      : Colors.transparent,
                                  width: 2),
                            ),
                            child: Text('Borrar todos',
                                style: TextStyle(
                                    color: f ? Colors.black : Colors.white,
                                    fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (ok == true) {
      for (final ep in List<DownloadItem>.from(episodes)) {
        await svc.remove(ep.id);
      }
      if (context.mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<DownloadService>();
    final episodes = svc.items
        .where((e) => e.contentId == contentId && (e.season != null || e.episode != null))
        .toList()
      ..sort((a, b) {
        final sa = a.season ?? 0;
        final sb = b.season ?? 0;
        if (sa != sb) return sa.compareTo(sb);
        return (a.episode ?? 0).compareTo(b.episode ?? 0);
      });

    return Scaffold(
      backgroundColor: const Color(0xFF0B0E14),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 16, 28, 8),
              child: Row(
                children: [
                  Focusable(
                    autofocus: true,
                    onTap: () => Navigator.pop(context),
                    builder: (f) => Icon(
                      Icons.arrow_back_rounded,
                      color: f ? Colors.white : Colors.white70,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          seriesTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '${episodes.length} capítulo${episodes.length == 1 ? '' : 's'}',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  if (episodes.isNotEmpty)
                    Focusable(
                      onTap: () => _deleteAll(context, episodes),
                      builder: (f) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: f
                              ? Colors.redAccent.withValues(alpha: 0.35)
                              : Colors.white10,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: f ? Colors.redAccent : Colors.transparent,
                              width: 2),
                        ),
                        child: const Text('Borrar todos',
                            style:
                                TextStyle(color: Colors.white70, fontSize: 12)),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: episodes.isEmpty
                  ? const Center(
                      child: Text('No hay capítulos',
                          style:
                              TextStyle(color: Colors.white54, fontSize: 16)),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(28, 8, 28, 32),
                      itemCount: episodes.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (ctx, i) =>
                          _TvTile(item: episodes[i], asEpisode: true),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvTile extends StatelessWidget {
  final DownloadItem item;
  final bool asEpisode;
  const _TvTile({required this.item, this.asEpisode = false});

  @override
  Widget build(BuildContext context) {
    final svc = DownloadService.instance;

    // Título: en vista de serie → T1 E2 · nombre capítulo; si no displayTitle completo
    String mainTitle;
    if (asEpisode) {
      final parts = <String>[];
      if (item.season != null && item.episode != null) {
        parts.add('T${item.season} E${item.episode}');
      } else if (item.episode != null) {
        parts.add('E${item.episode}');
      }
      if (item.episodeTitle != null && item.episodeTitle!.trim().isNotEmpty) {
        parts.add(item.episodeTitle!.trim());
      }
      mainTitle = parts.isNotEmpty ? parts.join(' · ') : item.displayTitle;
    } else {
      mainTitle = item.displayTitle;
    }

    return Focusable(
      onTap: () {},
      builder: (f) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF141A22),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: f ? Colors.white : Colors.white10,
            width: f ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 64,
                height: 90,
                child: item.poster != null
                    ? CachedNetworkImage(
                        imageUrl: item.poster!,
                        fit: BoxFit.cover,
                        memCacheWidth: 128)
                    : const ColoredBox(color: Colors.black26),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mainTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
                  Text(
                      'Repo: ${item.repoName} · ${item.serverName} · ${item.kind.name.toUpperCase()}',
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 12)),
                  const SizedBox(height: 6),
                  Text(
                    _status(item),
                    style: TextStyle(
                        color: _color(item),
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                  if (item.status == DownloadStatus.downloading) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: item.progress.clamp(0.0, 1.0),
                      minHeight: 4,
                      color: const Color(0xFF7DD3FC),
                      backgroundColor: Colors.white12,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (item.status == DownloadStatus.completed)
              Focusable(
                onTap: () {
                  final server = svc.offlineServerFor(
                    repoId: item.repoId,
                    contentId: item.contentId,
                    season: item.season,
                    episode: item.episode,
                  );
                  if (server == null) return;
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PlayerPage(
                        title: item.displayTitle,
                        url: server.url,
                        poster: item.poster,
                        contentType: item.type,
                        servers: [server],
                        season: item.season,
                        episode: item.episode,
                        isTv: true,
                      ),
                    ),
                  );
                },
                builder: (pf) => Icon(Icons.play_circle_fill,
                    color: pf ? Colors.white : const Color(0xFF4CAF50),
                    size: 36),
              ),
            if (item.status == DownloadStatus.downloading ||
                item.status == DownloadStatus.queued)
              Focusable(
                onTap: () => svc.cancel(item.id),
                builder: (cf) =>
                    Icon(Icons.close, color: cf ? Colors.white : Colors.white54),
              ),
            Focusable(
              onTap: () => svc.remove(item.id),
              builder: (rf) => Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(Icons.delete_outline,
                    color: rf ? Colors.redAccent : Colors.white38),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _status(DownloadItem item) {
    switch (item.status) {
      case DownloadStatus.queued:
        return 'En cola';
      case DownloadStatus.downloading:
        return 'Descargando ${(item.progress * 100).toStringAsFixed(0)}% · ${item.sizeLabel}';
      case DownloadStatus.completed:
        return 'Completada · ${item.sizeLabel}';
      case DownloadStatus.failed:
        return 'Error';
      case DownloadStatus.converting:
        return 'Convirtiendo…';
      case DownloadStatus.cancelled:
        return 'Cancelada';
      case DownloadStatus.paused:
        return 'Pausada';
    }
  }

  static Color _color(DownloadItem item) {
    switch (item.status) {
      case DownloadStatus.completed:
        return const Color(0xFF4CAF50);
      case DownloadStatus.downloading:
      case DownloadStatus.converting:
        return const Color(0xFF7DD3FC);
      case DownloadStatus.failed:
      case DownloadStatus.cancelled:
        return Colors.redAccent;
      default:
        return Colors.white54;
    }
  }
}