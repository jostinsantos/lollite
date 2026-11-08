import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'app/app.dart';
import 'data/services/repo_manager.dart';
import 'data/services/settings_service.dart';
import 'data/services/library_service.dart';
import 'data/services/repo_prefs.dart';
import 'core/storage/local_storage.dart';
import 'data/services/content_cache.dart';
import 'data/services/download_service.dart';
import 'package:media_kit/media_kit.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // Necesario para DateFormat con locale (ej. 'es')
  await initializeDateFormatting('es');
  await initializeDateFormatting('es_ES');
  await initializeDateFormatting('en');

  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  final storage = LocalStorage();
  await storage.init();

  ContentCache.instance.bind(storage);
  // Limpia entradas de caché caducadas en background
  ContentCache.instance.purgeExpired();

  DownloadService.instance.bind(storage);
  await DownloadService.instance.init();

  final settings = SettingsService(storage);
  await settings.load();

  final repoManager = RepoManager(storage);
  await repoManager.init();

  final library = LibraryService(storage);
  await library.init();

  final repoPrefs = RepoPrefs(storage);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: repoManager),
        ChangeNotifierProvider.value(value: library),
        ChangeNotifierProvider.value(value: repoPrefs),
        ChangeNotifierProvider.value(value: DownloadService.instance),
      ],
      child: const NuvioApp(),
    ),
  );
}
