import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/content_service.dart';
import '../../../../data/services/library_service.dart';
import '../../../../data/services/repo_prefs.dart';
import '../../widgets/cached_poster.dart';
import '../player/playertvoline_mobil.dart';

const _kAccent = Color(0xFFE50914);
const _kBg = Color(0xFF0B0E14);

/// Página de TV en vivo / canales online (móvil).
class RepoLivePage extends StatefulWidget {
  final InstalledRepo repo;
  const RepoLivePage({super.key, required this.repo});

  @override
  State<RepoLivePage> createState() => _RepoLivePageState();
}

class _RepoLivePageState extends State<RepoLivePage> {
  final _scroll = ScrollController();
  List<HomeRow> _rows = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await ContentService.instance.getHome(
        widget.repo,
        forceRefresh: refresh,
      );
      final channelRows = rows.where((r) {
        if (r.items.isEmpty) return false;
        final hasChannel = r.items.any((i) => i.isChannel);
        return hasChannel ||
            r.title.toLowerCase().contains('canal') ||
            r.title.toLowerCase().contains('tv') ||
            r.title.toLowerCase().contains('live') ||
            r.title.toLowerCase().contains('vivo');
      }).toList();
      final use = channelRows.isNotEmpty ? channelRows : rows;
      if (!mounted) return;
      setState(() {
        _rows = use;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<HomeRow> _rowsWithFavorites() {
    final lib = context.read<LibraryService>();
    final favs = lib.favorites(widget.repo.manifest.id);
    final favItems = <ContentItem>[];
    for (final f in favs) {
      ContentItem? found;
      for (final row in _rows) {
        for (final it in row.items) {
          if (it.id == f.contentId) {
            found = it;
            break;
          }
        }
        if (found != null) break;
      }
      favItems.add(
        found ??
            ContentItem(
              id: f.contentId,
              title: f.title,
              poster: f.poster,
              logo: f.poster,
              type: f.type.isNotEmpty ? f.type : 'channel',
            ),
      );
    }
    final out = <HomeRow>[];
    if (favItems.isNotEmpty) {
      out.add(HomeRow(id: 'favorites', title: 'Favoritos', items: favItems));
    }
    out.addAll(_rows);
    return out;
  }

  void _openChannel(ContentItem item, {required int categoryIndex, required int channelIndex}) {
    final prefs = context.read<RepoPrefs>();
    final prefLang = widget.repo.userConfig['preferred_language'] ??
        prefs.preferredLanguage(widget.repo.manifest.id);
    final guide = _rowsWithFavorites();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerMobileOnlinePage(
        title: item.currentProgram != null
            ? '${item.title} · ${item.currentProgram}'
            : item.title,
        url: '',
        repoId: widget.repo.manifest.id,
        contentId: item.id,
        poster: item.poster,
        backdrop: item.backdrop,
        logo: item.logo,
        contentType: item.type,
        servers: const [],
        preferredLanguage: prefLang,
        loadRepo: widget.repo,
        categories: guide,
        initialCategoryIndex: categoryIndex.clamp(0, guide.isEmpty ? 0 : guide.length - 1),
        initialChannelIndex: channelIndex,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.repo.manifest.backgroundColor ?? _kBg;
    final accent = widget.repo.manifest.accentColor ?? _kAccent;

    if (_loading) {
      return ColoredBox(
        color: bg,
        child: const Center(child: CircularProgressIndicator(color: _kAccent)),
      );
    }
    if (_error != null) {
      return ColoredBox(
        color: bg,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => _load(refresh: true),
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }
    if (_rows.isEmpty) {
      return ColoredBox(
        color: bg,
        child: const Center(
          child: Text(
            'No hay canales disponibles',
            style: TextStyle(color: Colors.white54, fontSize: 16),
          ),
        ),
      );
    }

    final displayRows = _rowsWithFavorites();

    return ColoredBox(
      color: bg,
      child: RefreshIndicator(
        color: accent,
        backgroundColor: const Color(0xFF1A222D),
        onRefresh: () => _load(refresh: true),
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.only(top: 12, bottom: 24),
          itemCount: displayRows.length,
          itemBuilder: (context, i) {
            final row = displayRows[i];
            return _ChannelRow(
              row: row,
              accent: accent,
              onTap: (item, chIndex) =>
                  _openChannel(item, categoryIndex: i, channelIndex: chIndex),
            );
          },
        ),
      ),
    );
  }
}

class _ChannelRow extends StatelessWidget {
  final HomeRow row;
  final Color accent;
  final void Function(ContentItem item, int index) onTap;

  const _ChannelRow({
    required this.row,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            row.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(
          height: 120,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: row.items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final item = row.items[i];
              return GestureDetector(
                onTap: () => onTap(item, i),
                child: SizedBox(
                  width: 100,
                  child: Column(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: CachedPoster(
                            url: item.logo ?? item.poster ?? item.backdrop,
                            fit: BoxFit.cover,
                            title: item.title,
                            sheenStrength: 0,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}