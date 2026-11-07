import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/database/app_database.dart';
import 'core/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));

  try {
    final db = await AppDatabase.open();
    runApp(ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
      child: const AthleteSetuApp(),
    ));
  } catch (e, st) {
    debugPrint('Database open failed: $e\n$st');
    runApp(_FatalErrorApp(error: '$e'));
  }
}

/// Shown only if the encrypted database cannot be opened (e.g. keystore failure).
class _FatalErrorApp extends StatelessWidget {
  const _FatalErrorApp({required this.error});
  final String error;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.lock_outline_rounded, size: 56, color: AppColors.foul),
                  const SizedBox(height: AppSpace.md),
                  const Text(
                    'Encrypted storage could not be opened\nएन्क्रिप्टेड स्टोरेज नहीं खुल सका',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text(error, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textMuted)),
                ],
              ),
            ),
          ),
        ),
      );
}
