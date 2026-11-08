import 'package:flutter/foundation.dart';
import '../../core/storage/local_storage.dart';

enum TvMenuMode { superior, lateral }
enum PosterSize { small, medium, large }
enum RowImageType { poster, backdrop }

/// Preferencias por repo (tamaño póster, menú TV, idioma preferido, etc.)
class RepoPrefs extends ChangeNotifier {
  RepoPrefs(this._storage);
  final LocalStorage _storage;

  static String _k(String repoId, String key) => 'repo_pref_${repoId}_$key';

  TvMenuMode menuMode(String repoId) {
    final v = _storage.getString(_k(repoId, 'tv_menu'));
    return v == 'lateral' ? TvMenuMode.lateral : TvMenuMode.superior;
  }

  Future<void> setMenuMode(String repoId, TvMenuMode mode) async {
    await _storage.setString(
      _k(repoId, 'tv_menu'),
      mode == TvMenuMode.lateral ? 'lateral' : 'superior',
    );
    notifyListeners();
  }

  PosterSize posterSize(String repoId) {
    final v = _storage.getString(_k(repoId, 'poster_size'));
    switch (v) {
      case 'small':
        return PosterSize.small;
      case 'large':
        return PosterSize.large;
      default:
        return PosterSize.medium;
    }
  }

  Future<void> setPosterSize(String repoId, PosterSize size) async {
    await _storage.setString(_k(repoId, 'poster_size'), size.name);
    notifyListeners();
  }

  double posterWidth(String repoId) {
    switch (posterSize(repoId)) {
      case PosterSize.small:
        return 100;
      case PosterSize.medium:
        return 130;
      case PosterSize.large:
        return 160;
    }
  }

  /// Idioma preferido del repo (Latino, Castellano, Inglés, Subtitulado, o vacío = cualquiera)
  String preferredLanguage(String repoId) {
    return _storage.getString(_k(repoId, 'pref_lang')) ?? '';
  }

  Future<void> setPreferredLanguage(String repoId, String lang) async {
    await _storage.setString(_k(repoId, 'pref_lang'), lang);
    notifyListeners();
  }

  static const languageOptions = [
    '',
    'Latino',
    'Castellano',
    'Inglés',
    'Subtitulado',
    'Japonés',
  ];

  /// ¿Ya se mostró el aviso/anuncio del repo al entrar?
  bool adsShown(String repoId) {
    return _storage.getString(_k(repoId, 'ads_shown')) == '1';
  }

  Future<void> setAdsShown(String repoId, {bool shown = true}) async {
    await _storage.setString(_k(repoId, 'ads_shown'), shown ? '1' : '0');
    notifyListeners();
  }

  /// Último aviso cacheado para mostrarlo también en Configuración.
  Map<String, String>? lastAd(String repoId) {
    final title = _storage.getString(_k(repoId, 'ad_title'));
    final message = _storage.getString(_k(repoId, 'ad_message'));
    if ((title == null || title.isEmpty) &&
        (message == null || message.isEmpty)) {
      return null;
    }
    return {
      'title': title ?? '',
      'message': message ?? '',
      'image': _storage.getString(_k(repoId, 'ad_image')) ?? '',
      'url': _storage.getString(_k(repoId, 'ad_url')) ?? '',
    };
  }

  Future<void> saveLastAd(
    String repoId, {
    required String title,
    required String message,
    String image = '',
    String url = '',
  }) async {
    await _storage.setString(_k(repoId, 'ad_title'), title);
    await _storage.setString(_k(repoId, 'ad_message'), message);
    await _storage.setString(_k(repoId, 'ad_image'), image);
    await _storage.setString(_k(repoId, 'ad_url'), url);
    notifyListeners();
  }

  /// Historial de búsquedas por repo (persiste al cerrar repo/app).
  static const int maxSearchHistory = 15;

  List<String> searchHistory(String repoId) {
    final raw = _storage.getJson(_k(repoId, 'search_history'));
    if (raw is List) {
      return raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    }
    return const [];
  }

  Future<void> setSearchHistory(String repoId, List<String> history) async {
    final trimmed = history
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(maxSearchHistory)
        .toList();
    await _storage.setJson(_k(repoId, 'search_history'), trimmed);
    notifyListeners();
  }

  Future<void> addSearchQuery(String repoId, String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    final list = List<String>.from(searchHistory(repoId));
    list.remove(q);
    list.insert(0, q);
    if (list.length > maxSearchHistory) {
      list.removeRange(maxSearchHistory, list.length);
    }
    await setSearchHistory(repoId, list);
  }

  Future<void> removeSearchQuery(String repoId, String query) async {
    final list = List<String>.from(searchHistory(repoId));
    list.remove(query);
    await setSearchHistory(repoId, list);
  }

  Future<void> clearSearchHistory(String repoId) async {
    await setSearchHistory(repoId, const []);
  }
}

