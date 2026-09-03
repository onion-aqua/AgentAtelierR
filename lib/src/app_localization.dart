enum AppThemePreference { system, light, dark }

enum AppLanguage { chinese, english, japanese }

enum TranslationLanguage { none, chinese, english, japanese }

extension AppLanguageData on AppLanguage {
  String text(String chinese, String english, String japanese) =>
      switch (this) {
        AppLanguage.chinese => chinese,
        AppLanguage.english => english,
        AppLanguage.japanese => japanese,
      };

  String get nativeLabel => switch (this) {
    AppLanguage.chinese => '中文',
    AppLanguage.english => 'English',
    AppLanguage.japanese => '日本語',
  };

  String get promptLabel => switch (this) {
    AppLanguage.chinese =>
      'Chinese (Simplified Chinese unless quoting a source)',
    AppLanguage.english => 'English',
    AppLanguage.japanese => 'Japanese',
  };

  String get audioLocaleCode => switch (this) {
    AppLanguage.chinese => 'zh-tw',
    AppLanguage.english => 'en',
    AppLanguage.japanese => 'jp',
  };
}

extension TranslationLanguageData on TranslationLanguage {
  String label(AppLanguage uiLanguage) => switch (this) {
    TranslationLanguage.none => uiLanguage.text(
      '不翻译',
      'Do not translate',
      '翻訳しない',
    ),
    TranslationLanguage.chinese => '中文',
    TranslationLanguage.english => 'English',
    TranslationLanguage.japanese => '日本語',
  };

  String? get promptLabel => switch (this) {
    TranslationLanguage.none => null,
    TranslationLanguage.chinese => 'Chinese (Simplified Chinese)',
    TranslationLanguage.english => 'English',
    TranslationLanguage.japanese => 'Japanese',
  };
}

extension AppThemePreferenceData on AppThemePreference {
  String label(AppLanguage uiLanguage) => switch (this) {
    AppThemePreference.system => uiLanguage.text(
      '跟随系统',
      'System default',
      'システムに従う',
    ),
    AppThemePreference.light => uiLanguage.text('浅色模式', 'Light', 'ライト'),
    AppThemePreference.dark => uiLanguage.text('暗色模式', 'Dark', 'ダーク'),
  };
}
