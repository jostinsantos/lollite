import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/content_service.dart';
import '../../../../data/services/library_service.dart';
import '../../../../data/services/repo_prefs.dart';
import '../../../mobile/widgets/cached_poster.dart';
import '../../../mobile/widgets/focusable.dart';
import '../player/playertvoline_tv.dart';

const _kAccent = Color(0xFFE50914);

/// Vista de TV en vivo: categorías | canales | player embebido + favoritos.
///
/// El preview SOLO se cambia con OK/click en un canal (no al mover el foco),
/// para evitar crear muchos Player y congelar la UI.
///
/// Navegación:
///   Categorías  → / OK  →  primer canal de esa categoría
///   Canales     ←       →  categoría activa
///   Canales     →       →  player
///   Canales     OK      →  cambia preview
///   Player      OK      →  pantalla completa
///   Player/Fav/Full ←   →  canal actual
class RepoLivePage extends StatefulWidget {
  final InstalledRepo repo;
  const RepoLivePage({super.key, required this.repo});

  @override
  State<RepoLivePage> createState() => _RepoLivePageState();
}

class _RepoLivePageState extends State<RepoLivePage> {
  List<HomeRow> _categories = [];
  bool _loading = true;
  String? _error;

  int _catIndex = 0;
  int _channelIndex = 0;
  ContentItem? _activeChannel;

  /// Paginación de canales de la categoría seleccionada (no cargar todos de golpe).
  static const int _kPageSize = 20;
  int _visibleChannelLimit = _kPageSize;

  final List<FocusNode> _catNodes = [];
  final List<FocusNode> _channelNodes = [];
  final FocusNode _rootFocus = FocusNode(debugLabel: 'live_root');
  final FocusNode _playerFocus = FocusNode(debugLabel: 'player');
  final FocusNode _favFocus = FocusNode(debugLabel: 'fav');
  final FocusNode _fullFocus = FocusNode(debugLabel: 'full');

  final ScrollController _catScroll = ScrollController();
  final ScrollController _channelScroll = ScrollController();

  Player? _preview;
  VideoController? _previewVideo;
  final List<StreamSubscription> _previewSubs = [];
  bool _previewLoading = false;
  String? _previewError;
  String? _previewingId;

  bool _syncingFocus = false;

  // Evita solapar cargas de preview si el usuario pulsa rápido.
  int _previewGen = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _rootFocus.dispose();
    for (final n in _catNodes) {
      n.dispose();
    }
    for (final n in _channelNodes) {
      n.dispose();
    }
    _playerFocus.dispose();
    _favFocus.dispose();
    _fullFocus.dispose();
    _catScroll.dispose();
    _channelScroll.dispose();
    unawaited(_disposePreview());
    super.dispose();
  }

  Future<void> _disposePreview() async {
    for (final s in _previewSubs) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    _previewSubs.clear();
    final p = _preview;
    _preview = null;
    _previewVideo = null;
    try {
      await p?.dispose();
    } catch (_) {}
  }

  bool _legacyLive = true;

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ContentService.instance.getLiveCategories(
        widget.repo,
        forceRefresh: refresh,
      );
      final use = result.rows;
      _legacyLive = result.legacy;

      if (!mounted) return;

      List<HomeRow> categories = use;
      if (!_legacyLive && use.isNotEmpty) {
        final first = use.first;
        final page = await ContentService.instance.loadLiveCategory(
          widget.repo,
          categoryId: first.id,
          catalogId: first.catalogId,
          page: 1,
          fallbackItems: first.items,
        );
        categories = [
          HomeRow(
            id: first.id,
            title: first.title,
            type: first.type,
            items: page.items.isNotEmpty ? page.items : first.items,
            catalogId: first.catalogId,
            imageStyle: first.imageStyle,
          ),
          ...use.skip(1).map((r) => HomeRow(
                id: r.id,
                title: r.title,
                type: r.type,
                items: const [],
                catalogId: r.catalogId,
                imageStyle: r.imageStyle,
              )),
        ];
      }

      if (!mounted) return;
      setState(() {
        _categories = categories;
        _loading = false;
        _catIndex = 0;
        _channelIndex = 0;
        _visibleChannelLimit = _kPageSize;
        if (categories.isNotEmpty && categories[0].items.isNotEmpty) {
          _activeChannel = categories[0].items[0];
        } else {
          _activeChannel = null;
        }
        _syncCatNodes();
        _rebuildChannelNodes();
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_catNodes.isNotEmpty) _catNodes[0].requestFocus();
      });
      if (_activeChannel != null) {
        unawaited(_playPreview(_activeChannel!));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Al cambiar de categoría: pedir sus canales a la API (no todo de golpe).
  Future<void> _fetchCategoryChannels(int catIndex) async {
    final cats = _displayCategories;
    if (catIndex < 0 || catIndex >= cats.length) return;
    final cat = cats[catIndex];
    if (cat.id == 'favorites') return;
    if (_legacyLive && cat.items.isNotEmpty) return;
    if (cat.items.length >= _kPageSize) return;

    try {
      final page = await ContentService.instance.loadLiveCategory(
        widget.repo,
        categoryId: cat.id,
        catalogId: cat.catalogId,
        page: 1,
        fallbackItems: cat.items,
      );
      if (!mounted || page.items.isEmpty) return;

      final realIndex = _categories.indexWhere((r) => r.id == cat.id);
      if (realIndex < 0) return;
      setState(() {
        _categories[realIndex] = HomeRow(
          id: cat.id,
          title: cat.title,
          type: cat.type,
          items: page.items,
          catalogId: cat.catalogId,
          imageStyle: cat.imageStyle,
        );
        _visibleChannelLimit = _kPageSize;
        _rebuildChannelNodes();
      });
    } catch (e) {
      // ignore
    }
  }

  void _syncCatNodes() {
    final need = _displayCategories.length;
    while (_catNodes.length > need) {
      _catNodes.removeLast().dispose();
    }
    while (_catNodes.length < need) {
      final i = _catNodes.length;
      _catNodes.add(FocusNode(debugLabel: 'cat_$i'));
    }
  }

  void _rebuildChannelNodes() {
    for (final n in _channelNodes) {
      n.dispose();
    }
    _channelNodes.clear();
    final items = _currentChannels;
    for (var i = 0; i < items.length; i++) {
      _channelNodes.add(FocusNode(debugLabel: 'ch_$i'));
    }
  }

  List<HomeRow> get _displayCategories => _categoriesWithFavoritesSafe();

  List<HomeRow> _categoriesWithFavoritesSafe() {
    try {
      return _categoriesWithFavorites();
    } catch (_) {
      return _categories;
    }
  }

  /// Todos los canales de la categoría actual (fuente completa).
  List<ContentItem> get _allCurrentChannels {
    final cats = _displayCategories;
    if (cats.isEmpty || _catIndex < 0 || _catIndex >= cats.length) {
      return const [];
    }
    return cats[_catIndex].items;
  }

  /// Solo los canales visibles (paginados) de la categoría seleccionada.
  List<ContentItem> get _currentChannels {
    final all = _allCurrentChannels;
    if (all.isEmpty) return const [];
    final limit = _visibleChannelLimit.clamp(0, all.length);
    return all.sublist(0, limit);
  }

  void _ensureMoreChannelsIfNeeded(int focusedIndex) {
    final all = _allCurrentChannels;
    // UI: ampliar ventana visible si aún hay items en memoria
    if (_visibleChannelLimit < all.length &&
        focusedIndex >= _visibleChannelLimit - 5) {
      setState(() {
        _visibleChannelLimit =
            (_visibleChannelLimit + _kPageSize).clamp(0, all.length);
        _rebuildChannelNodes();
      });
      return;
    }
    // API: si no es legado y estamos al final de lo cargado, pedir siguiente página
    if (!_legacyLive &&
        focusedIndex >= all.length - 3 &&
        all.isNotEmpty) {
      unawaited(_fetchMoreCategoryPage());
    }
  }

  Future<void> _fetchMoreCategoryPage() async {
    final cats = _displayCategories;
    if (_catIndex < 0 || _catIndex >= cats.length) return;
    final cat = cats[_catIndex];
    if (cat.id == 'favorites') return;
    final nextPage = (cat.items.length / _kPageSize).floor() + 1;
    try {
      final page = await ContentService.instance.loadLiveCategory(
        widget.repo,
        categoryId: cat.id,
        catalogId: cat.catalogId,
        page: nextPage,
        fallbackItems: const [],
      );
      if (!mounted || page.items.isEmpty) return;
      final realIndex = _categories.indexWhere((r) => r.id == cat.id);
      if (realIndex < 0) return;
      final existing = _categories[realIndex].items.map((e) => e.id).toSet();
      final fresh = page.items.where((e) => !existing.contains(e.id)).toList();
      if (fresh.isEmpty) return;
      setState(() {
        _categories[realIndex] = HomeRow(
          id: cat.id,
          title: cat.title,
          type: cat.type,
          items: [..._categories[realIndex].items, ...fresh],
          catalogId: cat.catalogId,
          imageStyle: cat.imageStyle,
        );
        _visibleChannelLimit =
            (_visibleChannelLimit + fresh.length).clamp(0, 100000);
        _rebuildChannelNodes();
      });
    } catch (_) {}
  }

  void _ensureVisible(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = node.context;
      if (ctx == null || !ctx.mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.35,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  /// Solo actualiza índice de categoría al mover el foco (NO toca el preview).
  /// Al cambiar de categoría se resetea la paginación (solo carga los primeros 20).
  void _onCategoryFocused(int i) {
    if (_syncingFocus || _catIndex == i) return;
    final cats = _displayCategories;
    if (i < 0 || i >= cats.length) return;
    setState(() {
      _catIndex = i;
      _channelIndex = 0;
      _visibleChannelLimit = _kPageSize;
      _rebuildChannelNodes();
    });
    if (i < _catNodes.length) _ensureVisible(_catNodes[i]);
    // Pide a la API solo la categoría enfocada (si no es legado).
    unawaited(_fetchCategoryChannels(i));
  }

  /// OK / → desde categoría: foco al primer canal (NO cambia preview).
  void _enterChannelsFromCategory([int? cat]) {
    final cats = _displayCategories;
    if (cats.isEmpty) return;
    final i = (cat ?? _catIndex).clamp(0, cats.length - 1);

    setState(() {
      _catIndex = i;
      _channelIndex = 0;
      _visibleChannelLimit = _kPageSize;
      _rebuildChannelNodes();
    });
    unawaited(_fetchCategoryChannels(i));

    void focusFirstChannel() {
      if (!mounted || _channelNodes.isEmpty) return;
      _syncingFocus = true;
      final first = _channelNodes[0];
      first.requestFocus();
      _ensureVisible(first);
      _syncingFocus = false;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      focusFirstChannel();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        focusFirstChannel();
      });
    });
  }

  /// Solo resalta el canal al mover el foco (NO crea player).
  void _highlightChannel(int i) {
    final items = _currentChannels;
    if (i < 0 || i >= items.length) return;
    if (_channelIndex == i) {
      if (i < _channelNodes.length) _ensureVisible(_channelNodes[i]);
      _ensureMoreChannelsIfNeeded(i);
      return;
    }
    setState(() => _channelIndex = i);
    if (i < _channelNodes.length) _ensureVisible(_channelNodes[i]);
    _ensureMoreChannelsIfNeeded(i);
  }

  /// OK / click: selecciona canal y cambia el preview.
  void _selectChannelAndPlay(int i) {
    final items = _currentChannels;
    if (i < 0 || i >= items.length) return;
    final item = items[i];
    setState(() {
      _channelIndex = i;
      _activeChannel = item;
    });
    if (i < _channelNodes.length) _ensureVisible(_channelNodes[i]);
    unawaited(_playPreview(item));
  }

  void _focusCurrentCategory() {
    if (_catIndex >= 0 && _catIndex < _catNodes.length) {
      _catNodes[_catIndex].requestFocus();
      _ensureVisible(_catNodes[_catIndex]);
    } else if (_catNodes.isNotEmpty) {
      _catNodes[0].requestFocus();
    }
  }

  void _focusCurrentChannel() {
    if (_channelIndex >= 0 && _channelIndex < _channelNodes.length) {
      _channelNodes[_channelIndex].requestFocus();
      _ensureVisible(_channelNodes[_channelIndex]);
    } else if (_channelNodes.isNotEmpty) {
      _channelNodes[0].requestFocus();
      _ensureVisible(_channelNodes[0]);
    }
  }

  Future<void> _playPreview(ContentItem item) async {
    // Ya se está mostrando este canal.
    if (_previewingId == item.id && _preview != null && !_previewLoading) {
      return;
    }

    final gen = ++_previewGen;
    _previewingId = item.id;

    setState(() {
      _previewLoading = true;
      _previewError = null;
    });

    try {
      final list = await ContentService.instance.getStreams(
        widget.repo,
        item.id,
        type: item.type,
      );

      // Otra petición más reciente: descartar esta.
      if (!mounted || gen != _previewGen || _previewingId != item.id) return;

      if (list.isEmpty) {
        setState(() {
          _previewLoading = false;
          _previewError = 'Sin fuente';
        });
        return;
      }

      final s = list.first;
      await _disposePreview();

      if (!mounted || gen != _previewGen) return;

      final player = Player(
        configuration: PlayerConfiguration(
          title: item.title,
          bufferSize: 16 * 1024 * 1024,
        ),
      );
      final video = VideoController(player);
      _preview = player;
      _previewVideo = video;

      final hdrs = Map<String, String>.from(s.headers);
      hdrs.putIfAbsent(
        'User-Agent',
        () =>
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36',
      );

      await player.open(Media(s.url, httpHeaders: hdrs), play: true);

      if (!mounted || gen != _previewGen || _previewingId != item.id) {
        try {
          await player.dispose();
        } catch (_) {}
        return;
      }

      setState(() => _previewLoading = false);
    } catch (e) {
      if (!mounted || gen != _previewGen) return;
      setState(() {
        _previewLoading = false;
        _previewError = e.toString();
      });
    }
  }

  Future<void> _openFullPlayer() async {
    final items = _currentChannels;
    // Preferir el canal resaltado si hay lista; si no, el activo.
    ContentItem? item;
    if (items.isNotEmpty &&
        _channelIndex >= 0 &&
        _channelIndex < items.length) {
      item = items[_channelIndex];
    } else {
      item = _activeChannel;
    }
    if (item == null) return;

    // Si aún no es el preview actual, arrancarlo no hace falta: full player
    // carga sus propios streams. Solo liberamos el preview del home.
    await _disposePreview();
    _previewingId = null;
    _previewGen++;
    if (mounted) {
      setState(() {
        _activeChannel = item;
      });
    }

    final prefs = context.read<RepoPrefs>();
    final prefLang = widget.repo.userConfig['preferred_language'] ??
        prefs.preferredLanguage(widget.repo.manifest.id);

    final guideCats = _categoriesWithFavorites();

    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerTvOnlinePage(
        title: item!.currentProgram != null
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
        categories: guideCats,
        initialCategoryIndex: _catIndex < guideCats.length ? _catIndex : 0,
        initialChannelIndex: _channelIndex,
      ),
    ));

    // Al volver, reanudar solo el canal activo (uno).
    if (mounted && _activeChannel != null) {
      unawaited(_playPreview(_activeChannel!));
    }
  }

  List<HomeRow> _categoriesWithFavorites() {
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
      out.add(HomeRow(
        id: 'favorites',
        title: 'Favoritos',
        items: favItems,
      ));
    }
    out.addAll(_categories);
    return out;
  }

  Future<void> _toggleFav() async {
    final item = _activeChannel;
    if (item == null) return;
    final lib = context.read<LibraryService>();
    await lib.toggleFavorite(
      repoId: widget.repo.manifest.id,
      contentId: item.id,
      title: item.title,
      poster: item.logo ?? item.poster,
      type: item.type.isNotEmpty ? item.type : 'channel',
    );
    if (!mounted) return;
    setState(() {
      _syncCatNodes();
      final cats = _displayCategories;
      if (_catIndex >= cats.length) {
        _catIndex = 0;
        _channelIndex = 0;
        _rebuildChannelNodes();
      }
    });
  }

  /// CH+ / CH- del control: sí cambian de canal y preview (acción explícita).
  void _channelUp() {
    final items = _currentChannels;
    if (items.isEmpty) return;
    final next = (_channelIndex - 1 + items.length) % items.length;
    _selectChannelAndPlay(next);
    if (next < _channelNodes.length) {
      _channelNodes[next].requestFocus();
    }
  }

  void _channelDown() {
    final items = _currentChannels;
    if (items.isEmpty) return;
    final next = (_channelIndex + 1) % items.length;
    _selectChannelAndPlay(next);
    if (next < _channelNodes.length) {
      _channelNodes[next].requestFocus();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.channelUp ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      _channelUp();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.channelDown ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      _channelDown();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.repo.manifest.backgroundColor;
    final accent = widget.repo.manifest.accentColor;

    final displayLen = _displayCategories.length;
    if (!_loading && _error == null && _catNodes.length != displayLen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(_syncCatNodes);
      });
    }

    if (_loading) {
      return ColoredBox(
        color: bg,
        child: const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(color: _kAccent, strokeWidth: 2.5),
          ),
        ),
      );
    }
    if (_error != null) {
      return ColoredBox(
        color: bg,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 12),
              Focusable(
                onTap: () => _load(refresh: true),
                builder: (_) => const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Text('Reintentar',
                      style: TextStyle(color: Colors.white, fontSize: 14)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Focus(
      focusNode: _rootFocus,
      onKeyEvent: _onKey,
      child: ColoredBox(
        color: bg,
        child: Row(
          children: [
            SizedBox(width: 168, child: _buildCategories(accent)),
            SizedBox(width: 240, child: _buildChannels(accent)),
            Expanded(child: _buildPlayerPane(accent)),
          ],
        ),
      ),
    );
  }

  Widget _tile({
    required bool selected,
    required bool focused,
    required Color accent,
    required Widget child,
    EdgeInsets margin = const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    EdgeInsets padding =
        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
  }) {
    final on = selected || focused;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 100),
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: on ? accent : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: focused ? Colors.white : Colors.transparent,
          width: focused ? 2 : 0,
        ),
      ),
      child: DefaultTextStyle(
        style: TextStyle(
          color: on ? Colors.white : Colors.white70,
          fontWeight: on ? FontWeight.w700 : FontWeight.w500,
          fontSize: 13,
        ),
        child: IconTheme(
          data: IconThemeData(
            color: on ? Colors.white : Colors.white70,
            size: 18,
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _buildCategories(Color accent) {
    final cats = _displayCategories;
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        border: Border(
            right: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Text(
              'Categorías',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _catScroll,
              cacheExtent: 800,
              padding: const EdgeInsets.only(bottom: 16),
              itemCount: cats.length,
              itemBuilder: (context, i) {
                final selected = i == _catIndex;
                if (i >= _catNodes.length) return const SizedBox.shrink();
                final node = _catNodes[i];

                return Focus(
                  focusNode: node,
                  onKeyEvent: (n, event) {
                    if (event is! KeyDownEvent) {
                      return KeyEventResult.ignored;
                    }
                    final key = event.logicalKey;
                    if (key == LogicalKeyboardKey.arrowRight ||
                        key == LogicalKeyboardKey.select ||
                        key == LogicalKeyboardKey.enter ||
                        key == LogicalKeyboardKey.space) {
                      _enterChannelsFromCategory(i);
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: AnimatedBuilder(
                    animation: node,
                    builder: (context, _) {
                      final focused = node.hasFocus;
                      if (focused && _catIndex != i && !_syncingFocus) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && !_syncingFocus) {
                            _onCategoryFocused(i);
                          }
                        });
                      }
                      if (focused) _ensureVisible(node);

                      return GestureDetector(
                        onTap: () => _enterChannelsFromCategory(i),
                        child: _tile(
                          selected: selected,
                          focused: focused,
                          accent: accent,
                          child: Text(
                            cats[i].title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: (selected || focused)
                                  ? Colors.white
                                  : Colors.white70,
                              fontSize: 12.5,
                              fontWeight: (selected || focused)
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChannels(Color accent) {
    final items = _currentChannels;
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.2),
        border: Border(
            right: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Text(
              items.isEmpty
                  ? 'Canales'
                  : (_allCurrentChannels.length > items.length
                      ? '${items.length}/${_allCurrentChannels.length} canales'
                      : '${items.length} canales'),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text('Sin canales',
                        style:
                            TextStyle(color: Colors.white38, fontSize: 12)),
                  )
                : ListView.builder(
                    controller: _channelScroll,
                    cacheExtent: 800,
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final item = items[i];
                      final selected = i == _channelIndex;
                      if (i >= _channelNodes.length) {
                        return const SizedBox.shrink();
                      }
                      final node = _channelNodes[i];

                      return Focus(
                        focusNode: node,
                        onKeyEvent: (n, event) {
                          if (event is! KeyDownEvent) {
                            return KeyEventResult.ignored;
                          }
                          final key = event.logicalKey;
                          if (key == LogicalKeyboardKey.arrowLeft) {
                            _focusCurrentCategory();
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.arrowRight) {
                            _playerFocus.requestFocus();
                            return KeyEventResult.handled;
                          }
                          // OK / Enter: AQUÍ sí cambia el preview
                          if (key == LogicalKeyboardKey.select ||
                              key == LogicalKeyboardKey.enter ||
                              key == LogicalKeyboardKey.space) {
                            _selectChannelAndPlay(i);
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: AnimatedBuilder(
                          animation: node,
                          builder: (context, _) {
                            final focused = node.hasFocus;
                            // Solo resaltar: NO llamar _playPreview
                            if (focused &&
                                _channelIndex != i &&
                                !_syncingFocus) {
                              WidgetsBinding.instance
                                  .addPostFrameCallback((_) {
                                if (mounted && !_syncingFocus) {
                                  _highlightChannel(i);
                                }
                              });
                            }
                            if (focused) _ensureVisible(node);

                            return GestureDetector(
                              onTap: () => _selectChannelAndPlay(i),
                              child: _tile(
                                selected: selected,
                                focused: focused,
                                accent: accent,
                                margin: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                padding: const EdgeInsets.all(6),
                                child: Row(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(5),
                                      child: SizedBox(
                                        width: 44,
                                        height: 28,
                                        child: CachedPoster(
                                          url: item.logo ?? item.poster,
                                          fit: BoxFit.cover,
                                          title: item.title,
                                          sheenStrength: 0,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: (selected || focused)
                                                  ? Colors.white
                                                  : Colors.white70,
                                              fontSize: 12,
                                              fontWeight:
                                                  (selected || focused)
                                                      ? FontWeight.w700
                                                      : FontWeight.w500,
                                            ),
                                          ),
                                          if (item.currentProgram != null)
                                            Text(
                                              item.currentProgram!,
                                              maxLines: 1,
                                              overflow:
                                                  TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: Colors.white
                                                    .withValues(alpha: 0.5),
                                                fontSize: 10,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerPane(Color accent) {
    final item = _activeChannel;
    final lib = context.watch<LibraryService>();
    final isFav =
        item != null && lib.isFavorite(widget.repo.manifest.id, item.id);

    return Focus(
      canRequestFocus: false,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _focusCurrentChannel();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 3,
              child: Focus(
                focusNode: _playerFocus,
                onKeyEvent: (n, event) {
                  if (event is! KeyDownEvent) {
                    return KeyEventResult.ignored;
                  }
                  final key = event.logicalKey;
                  if (key == LogicalKeyboardKey.arrowLeft) {
                    _focusCurrentChannel();
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.select ||
                      key == LogicalKeyboardKey.enter ||
                      key == LogicalKeyboardKey.space) {
                    unawaited(_openFullPlayer());
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: AnimatedBuilder(
                  animation: _playerFocus,
                  builder: (context, _) {
                    final focused = _playerFocus.hasFocus;
                    return GestureDetector(
                      onTap: _openFullPlayer,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 100),
                        decoration: BoxDecoration(
                          color: const Color(0xFF12161E),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: focused
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.1),
                            width: focused ? 2 : 1,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: item == null
                            ? const Center(
                                child: Text(
                                  'Selecciona un canal',
                                  style: TextStyle(
                                      color: Colors.white38, fontSize: 13),
                                ),
                              )
                            : Stack(
                                fit: StackFit.expand,
                                children: [
                                  if (_previewVideo != null)
                                    Video(
                                      controller: _previewVideo!,
                                      controls: NoVideoControls,
                                      fit: BoxFit.contain,
                                    )
                                  else
                                    CachedPoster(
                                      url: item.backdrop ??
                                          item.poster ??
                                          item.logo,
                                      fit: BoxFit.cover,
                                      title: item.title,
                                      sheenStrength: 0.08,
                                    ),
                                  if (_previewLoading)
                                    const Center(
                                      child: SizedBox(
                                        width: 26,
                                        height: 26,
                                        child: CircularProgressIndicator(
                                            color: _kAccent,
                                            strokeWidth: 2.2),
                                      ),
                                    ),
                                  if (_previewError != null &&
                                      !_previewLoading)
                                    Center(
                                      child: Text(
                                        _previewError!,
                                        style: const TextStyle(
                                            color: Colors.white54,
                                            fontSize: 12),
                                      ),
                                    ),
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      padding: const EdgeInsets.fromLTRB(
                                          14, 28, 14, 12),
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Colors.transparent,
                                            Colors.black
                                                .withValues(alpha: 0.85),
                                          ],
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.title,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                          if (item.currentProgram !=
                                              null) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                              item.currentProgram!,
                                              style: TextStyle(
                                                color: Colors.white
                                                    .withValues(alpha: 0.75),
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                          const SizedBox(height: 8),
                                          Row(
                                            children: [
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 8,
                                                        vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: accent,
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          4),
                                                ),
                                                child: const Text(
                                                  'EN VIVO',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontWeight:
                                                        FontWeight.w800,
                                                    fontSize: 10,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                'CH ${_channelIndex + 1}/${_currentChannels.length}',
                                                style: TextStyle(
                                                  color: Colors.white
                                                      .withValues(
                                                          alpha: 0.55),
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  Expanded(
                    child: Focus(
                      focusNode: _favFocus,
                      onKeyEvent: (n, event) {
                        if (event is! KeyDownEvent) {
                          return KeyEventResult.ignored;
                        }
                        final key = event.logicalKey;
                        if (key == LogicalKeyboardKey.arrowLeft) {
                          _focusCurrentChannel();
                          return KeyEventResult.handled;
                        }
                        if (key == LogicalKeyboardKey.select ||
                            key == LogicalKeyboardKey.enter ||
                            key == LogicalKeyboardKey.space) {
                          unawaited(_toggleFav());
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: AnimatedBuilder(
                        animation: _favFocus,
                        builder: (context, _) {
                          final focused = _favFocus.hasFocus;
                          return GestureDetector(
                            onTap: () => unawaited(_toggleFav()),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 100),
                              decoration: BoxDecoration(
                                color: focused
                                    ? accent
                                    : (isFav
                                        ? accent.withValues(alpha: 0.35)
                                        : Colors.white
                                            .withValues(alpha: 0.08)),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: focused
                                      ? Colors.white
                                      : Colors.transparent,
                                  width: focused ? 2 : 0,
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    isFav
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    isFav ? 'En favoritos' : 'Favorito',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Focus(
                      focusNode: _fullFocus,
                      onKeyEvent: (n, event) {
                        if (event is! KeyDownEvent) {
                          return KeyEventResult.ignored;
                        }
                        final key = event.logicalKey;
                        if (key == LogicalKeyboardKey.arrowLeft) {
                          _focusCurrentChannel();
                          return KeyEventResult.handled;
                        }
                        if (key == LogicalKeyboardKey.select ||
                            key == LogicalKeyboardKey.enter ||
                            key == LogicalKeyboardKey.space) {
                          unawaited(_openFullPlayer());
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: AnimatedBuilder(
                        animation: _fullFocus,
                        builder: (context, _) {
                          final focused = _fullFocus.hasFocus;
                          return GestureDetector(
                            onTap: _openFullPlayer,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 100),
                              decoration: BoxDecoration(
                                color: focused
                                    ? accent
                                    : accent.withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: focused
                                      ? Colors.white
                                      : Colors.transparent,
                                  width: focused ? 2 : 0,
                                ),
                              ),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.fullscreen_rounded,
                                      color: Colors.white, size: 18),
                                  SizedBox(width: 6),
                                  Text(
                                    'Pantalla completa',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'OK en canal = preview · navegar con flechas no recarga el player',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.3),
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}