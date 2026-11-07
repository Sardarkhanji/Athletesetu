import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../domain/sai_test.dart';
import 'strings.dart';

enum AppLang {
  en('EN'),
  hi('हिं');

  const AppLang(this.short);
  final String short;
}

/// Immutable translator for one language.
@immutable
class L10n {
  const L10n(this.lang);

  final AppLang lang;

  String t(String key, [Map<String, Object?> params = const {}]) =>
      _fill(_lookup(key, lang), params);

  /// English and Hindi side by side ("Height / लंबाई"). Used for PDF headers.
  String bi(String key, [Map<String, Object?> params = const {}]) {
    final en = _fill(_lookup(key, AppLang.en), params);
    final hi = _fill(_lookup(key, AppLang.hi), params);
    return en == hi ? en : '$en / $hi';
  }

  String en(String key, [Map<String, Object?> params = const {}]) =>
      _fill(_lookup(key, AppLang.en), params);

  String hi(String key, [Map<String, Object?> params = const {}]) =>
      _fill(_lookup(key, AppLang.hi), params);

  String testName(SaiTest test) => t(test.nameKey);

  String unit(SaiTest test) => t('units_${test.unit}');

  static String _lookup(String key, AppLang lang) {
    final entry = kStrings[key];
    if (entry == null) {
      assert(() {
        debugPrint('[L10n] missing key: $key');
        return true;
      }());
      return key;
    }
    return entry[lang.index];
  }

  static String _fill(String s, Map<String, Object?> params) {
    if (params.isEmpty) return s;
    var out = s;
    params.forEach((k, v) => out = out.replaceAll('{$k}', '${v ?? ''}'));
    return out;
  }
}

/// Persists the selected language in the encrypted settings table.
class LangNotifier extends Notifier<AppLang> {
  static const _key = 'lang';

  @override
  AppLang build() {
    final db = ref.read(appDatabaseProvider);
    final stored = db.cachedSetting(_key);
    return AppLang.values.firstWhere((l) => l.name == stored, orElse: () => AppLang.en);
  }

  Future<void> set(AppLang lang) async {
    state = lang;
    await ref.read(appDatabaseProvider).setSetting(_key, lang.name);
  }

  Future<void> toggle() => set(state == AppLang.en ? AppLang.hi : AppLang.en);
}

final langProvider = NotifierProvider<LangNotifier, AppLang>(LangNotifier.new);

final l10nProvider = Provider<L10n>((ref) => L10n(ref.watch(langProvider)));
