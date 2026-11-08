import 'package:flutter/foundation.dart';
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
const _kCard = Color(0xFF141A22);
const _kPageSize = 20;

/// Live móvil:
/// - Selector de categorías (chips)
/// - Lista vertical de canales de la categoría seleccionada
/// - Peticiones reales a la API por categoría y página (20)
/// - Compatible con repos legados (getHome completo → pagina en memoria)
class RepoLivePage extends StatefulWidget {
  final InstalledRepo repo;
  const RepoLivePage({super.key, required this.repo});

  @override
  State<RepoLivePage> createState() => _RepoLivePageState();
}

class _RepoLivePageState extends State<RepoLivePage> {
  final _scroll = ScrollController();

  List<HomeRow> _categories = [];
  bool _legacy = true;
  bool _loading = true;
  String? _error;

  int _selectedCat = 0;

  List<ContentItem> _visibleChannels = [];
  int _page = 0;
  bool _loadingMore = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore) return;
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final pos = _scroll.position.pixels;
    if (pos >= max - 240) {
      _loadMoreChannels();
    }
  }

  Future<void> _load({bool refresh = false}) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      _visibleChannels = [];
      _page = 0;
      _hasMore = true;
    });
    try {
      final result = await ContentService.instance.getLiveCategories(
        widget.repo,
        forceRefresh: refresh,
      );
      if (!mounted) return;
      setState(() {
        _categories = result.rows;
        _legacy = result.legacy;
        _selectedCat = 0;
        _loading = false;
      });
      await _resetAndLoadPage();
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
      for (final row in _categories) {
        for (final it in row.items) {
          if (it.id == f.contentId) {
            found = it;
            break;
          }
        }
        if (found != null) break;
      }
      found ??= _visibleChannels.cast<ContentItem?>().firstWhere(
            (it) => it?.id == f.contentId,
            orElse: () => null,
          );
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
    out.addAll(_categories);
    return out;
  }

  List<HomeRow> get _displayCategories => _rowsWithFavorites();

  HomeRow? get _currentCategory {
    final cats = _displayCategories;
    if (cats.isEmpty) return null;
    final i = _selectedCat.clamp(0, cats.length - 1);
    return cats[i];
  }

  Future<void> _resetAndLoadPage() async {
    _page = 0;
    _visibleChannels = [];
    _hasMore = true;
    await _loadMoreChannels();
  }

  Future<void> _loadMoreChannels() async {
    if (_loadingMore || !_hasMore) return;
    final cat = _currentCategory;
    if (cat == null) {
      setState(() {
        _hasMore = false;
        _loadingMore = false;
      });
      return;
    }

    if (cat.id == 'favorites') {
      setState(() {
        _visibleChannels = List.from(cat.items);
        _hasMore = false;
        _loadingMore = false;
        _page = 1;
      });
      return;
    }

    setState(() => _loadingMore = true);
    final nextPage = _page + 1;

    try {
      final page = await ContentService.instance.loadLiveCategory(
        widget.repo,
        categoryId: cat.id,
        catalogId: cat.catalogId,
        page: nextPage,
        fallbackItems: cat.items,
      );

      if (!mounted) return;
      setState(() {
        final existing = _visibleChannels.map((e) => e.id).toSet();
        final fresh =
            page.items.where((e) => !existing.contains(e.id)).toList();
        _visibleChannels = [..._visibleChannels, ...fresh];
        _page = nextPage;
        _hasMore = page.hasMore && (page.items.isNotEmpty || nextPage == 1);
        if (page.items.isEmpty && nextPage > 1) _hasMore = false;
        _loadingMore = false;
      });
    } catch (e) {
      debugPrint('[Live] load category ${cat.id} page $nextPage: $e');
      if (!mounted) return;
      final all = cat.items;
      final start = _page * _kPageSize;
      if (start >= all.length) {
        setState(() {
          _hasMore = false;
          _loadingMore = false;
        });
        return;
      }
      final end = (start + _kPageSize).clamp(0, all.length);
      setState(() {
        _visibleChannels = [..._visibleChannels, ...all.sublist(start, end)];
        _page = nextPage;
        _hasMore = end < all.length;
        _loadingMore = false;
      });
    }
  }

  void _selectCategory(int index) {
    if (index == _selectedCat) return;
    setState(() {
      _selectedCat = index;
      _visibleChannels = [];
      _page = 0;
      _hasMore = true;
      _loadingMore = false;
    });
    _loadMoreChannels();
  }

  void _openChannel(ContentItem item, {required int channelIndex}) {
    final prefs = context.read<RepoPrefs>();
    final prefLang = widget.repo.userConfig['preferred_language'] ??
        prefs.preferredLanguage(widget.repo.manifest.id);
    final guide = _displayCategories;
    final catIndex =
        _selectedCat.clamp(0, guide.isEmpty ? 0 : guide.length - 1);

    final catsForPlayer = List<HomeRow>.from(guide);
    final cat = catsForPlayer[catIndex];
    if (_visibleChannels.isNotEmpty) {
      catsForPlayer[catIndex] = HomeRow(
        id: cat.id,
        title: cat.title,
        type: cat.type,
        items: _visibleChannels.length >= cat.items.length
            ? _visibleChannels
            : (cat.items.isNotEmpty ? cat.items : _visibleChannels),
        catalogId: cat.catalogId,
        imageStyle: cat.imageStyle,
      );
    }

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
        categories: catsForPlayer,
        initialCategoryIndex: catIndex,
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

    final cats = _displayCategories;
    if (cats.isEmpty) {
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

    return ColoredBox(
      color: bg,
      child: RefreshIndicator(
        color: accent,
        backgroundColor: const Color(0xFF1A222D),
        onRefresh: () => _load(refresh: true),
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: SizedBox(
                height: 52,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                  itemCount: cats.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    final selected = i == _selectedCat;
                    return ChoiceChip(
                      label: Text(
                        cats[i].title.isEmpty
                            ? 'Categoría ${i + 1}'
                            : cats[i].title,
                      ),
                      selected: selected,
                      onSelected: (_) => _selectCategory(i),
                      selectedColor: accent,
                      backgroundColor: _kCard,
                      labelStyle: TextStyle(
                        color: selected ? Colors.white : Colors.white70,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        fontSize: 13,
                      ),
                      side: BorderSide(
                        color: selected ? accent : Colors.white12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      visualDensity: VisualDensity.compact,
                    );
                  },
                ),
              ),
            ),
            if (_visibleChannels.isEmpty && !_loadingMore)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    'Sin canales en esta categoría',
                    style: TextStyle(color: Colors.white38),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      if (i >= _visibleChannels.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: _loadingMore
                                ? const SizedBox(
                                    width: 28,
                                    height: 28,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: _kAccent,
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        );
                      }
                      final item = _visibleChannels[i];
                      return _ChannelTile(
                        item: item,
                        accent: accent,
                        onTap: () => _openChannel(item, channelIndex: i),
                      );
                    },
                    childCount: _visibleChannels.length +
                        (_hasMore || _loadingMore ? 1 : 0),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final ContentItem item;
  final Color accent;
  final VoidCallback onTap;

  const _ChannelTile({
    required this.item,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final logo = item.logo ?? item.poster ?? item.backdrop;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: _kCard,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: CachedPoster(
                      url: logo,
                      fit: BoxFit.cover,
                      title: item.title,
                      sheenStrength: 0,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (item.currentProgram != null &&
                          item.currentProgram!.trim().isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          item.currentProgram!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.play_circle_fill_rounded, color: accent, size: 28),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
