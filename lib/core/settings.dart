import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'image_compress.dart';

class SyncConfig {
  const SyncConfig({
    this.token = '',
    this.repo = '',
    this.branch = 'main',
    this.passphrase = '',
  });

  final String token;

  /// "owner/name"
  final String repo;
  final String branch;
  final String passphrase;

  bool get isComplete =>
      token.isNotEmpty &&
      RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(repo) &&
      branch.isNotEmpty &&
      passphrase.isNotEmpty;

  SyncConfig copyWith({
    String? token,
    String? repo,
    String? branch,
    String? passphrase,
  }) =>
      SyncConfig(
        token: token ?? this.token,
        repo: repo ?? this.repo,
        branch: branch ?? this.branch,
        passphrase: passphrase ?? this.passphrase,
      );
}

/// App preferences. The GitHub token and the backup passphrase live in the
/// platform's secure storage (Android Keystore / Windows credential store);
/// everything else is ordinary preferences.
///
/// This class is also loaded inside the Android background-sync worker, so it
/// must not depend on any UI.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs, this._secure, this.config);

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;
  SyncConfig config;

  static const _kToken = 'sync.token';
  static const _kPass = 'sync.passphrase';

  // ---- preferences, with defaults -------------------------------------------

  ThemeMode get themeMode => ThemeMode.values.firstWhere(
        (m) => m.name == _prefs.getString('theme'),
        orElse: () => ThemeMode.system,
      );

  bool get autoSync => _prefs.getBool('sync.auto') ?? true;

  /// Android only: periodic sync while the app is closed.
  bool get backgroundSync => _prefs.getBool('sync.background') ?? true;

  ImageCompression get imageCompression => ImageCompression.values.firstWhere(
        (c) => c.name == _prefs.getString('image.compression'),
        orElse: () => ImageCompression.balanced,
      );

  /// Ask the speech engine to work offline. Whether audio really stays on the
  /// device depends on the engine and its installed offline language pack.
  bool get onDeviceSpeech => _prefs.getBool('speech.ondevice') ?? true;

  /// Empty means "use the device language".
  String get speechLocale => _prefs.getString('speech.locale') ?? '';

  /// How "12/11" is read: 12 November (true) or December 11 (false).
  bool get dayFirstDates => _prefs.getBool('dates.dayfirst') ?? true;

  /// Notify when a task is due.
  bool get remindersEnabled => _prefs.getBool('reminders.enabled') ?? true;

  /// Hour (0-23) for the reminder of a task that has a date but no time.
  int get reminderHour => (_prefs.getInt('reminders.hour') ?? 9).clamp(0, 23);

  /// Windows: closing the window keeps Inkwell running in the system tray, so
  /// it keeps syncing and reminding.
  bool get keepInTray => _prefs.getBool('win.tray') ?? true;

  /// Windows: start with Windows (minimised to the tray).
  bool get startWithWindows => _prefs.getBool('win.startup') ?? false;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final secure = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
    Future<String> read(String key) async {
      try {
        return (await secure.read(key: key)) ?? '';
      } catch (_) {
        return '';
      }
    }

    final config = SyncConfig(
      token: await read(_kToken),
      passphrase: await read(_kPass),
      repo: prefs.getString('sync.repo') ?? '',
      branch: prefs.getString('sync.branch') ?? 'main',
    );
    return AppSettings._(prefs, secure, config);
  }

  Future<void> saveSync(SyncConfig c) async {
    config = c;
    await _prefs.setString('sync.repo', c.repo.trim());
    await _prefs.setString('sync.branch', c.branch.trim());
    await _secure.write(key: _kToken, value: c.token.trim());
    await _secure.write(key: _kPass, value: c.passphrase);
    notifyListeners();
  }

  Future<void> clearSync() async {
    config = const SyncConfig();
    await _prefs.remove('sync.repo');
    await _prefs.remove('sync.branch');
    await _secure.delete(key: _kToken);
    await _secure.delete(key: _kPass);
    notifyListeners();
  }

  Future<void> _set(Future<bool> write) async {
    await write;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode m) => _set(_prefs.setString('theme', m.name));
  Future<void> setAutoSync(bool v) => _set(_prefs.setBool('sync.auto', v));
  Future<void> setBackgroundSync(bool v) => _set(_prefs.setBool('sync.background', v));
  Future<void> setImageCompression(ImageCompression c) =>
      _set(_prefs.setString('image.compression', c.name));
  Future<void> setOnDeviceSpeech(bool v) => _set(_prefs.setBool('speech.ondevice', v));
  Future<void> setSpeechLocale(String id) => _set(_prefs.setString('speech.locale', id));
  Future<void> setDayFirstDates(bool v) => _set(_prefs.setBool('dates.dayfirst', v));
  Future<void> setRemindersEnabled(bool v) => _set(_prefs.setBool('reminders.enabled', v));
  Future<void> setReminderHour(int h) => _set(_prefs.setInt('reminders.hour', h));
  Future<void> setKeepInTray(bool v) => _set(_prefs.setBool('win.tray', v));
  Future<void> setStartWithWindows(bool v) => _set(_prefs.setBool('win.startup', v));

  /// Small string/JSON helpers for services that keep their own state.
  String? getString(String key) => _prefs.getString(key);
  Future<void> putString(String key, String value) async {
    await _prefs.setString(key, value);
  }
}
