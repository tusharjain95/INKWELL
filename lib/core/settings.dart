import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'digest.dart';
import 'image_compress.dart';

/// Where notes are synced to.
enum SyncProvider { github, drive }

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
  AppSettings._(this._prefs, this._secure, this.config,
      this._driveToken, this._drivePass, this._botKey, this._tgToken);

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;
  SyncConfig config;
  String _driveToken;
  String _drivePass;
  String _botKey;
  String _tgToken;

  static const _kToken = 'sync.token';
  static const _kPass = 'sync.passphrase';
  static const _kDriveToken = 'drive.refresh';
  static const _kDrivePass = 'drive.passphrase';
  static const _kBotKey = 'hub.key';
  static const _kTgToken = 'hub.token';

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

  SyncProvider get syncProvider => SyncProvider.values.firstWhere(
        (p) => p.name == _prefs.getString('sync.provider'),
        orElse: () => SyncProvider.github,
      );

  /// Google sign-in (refresh token) and the passphrase used with Drive.
  String get driveRefreshToken => _driveToken;
  String get drivePassphrase => _drivePass;
  String get driveEmail => _prefs.getString('drive.email') ?? '';
  bool get driveSignedIn => _driveToken.isNotEmpty;

  /// Whether the selected provider has everything it needs to sync.
  bool get syncReady => syncProvider == SyncProvider.drive
      ? (_driveToken.isNotEmpty && _drivePass.isNotEmpty)
      : config.isComplete;

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
    return AppSettings._(prefs, secure, config, await read(_kDriveToken),
        await read(_kDrivePass), await read(_kBotKey), await read(_kTgToken));
  }

  Future<void> saveSync(SyncConfig c) async {
    config = c;
    await _prefs.setString('sync.repo', c.repo.trim());
    await _prefs.setString('sync.branch', c.branch.trim());
    await _secure.write(key: _kToken, value: c.token.trim());
    await _secure.write(key: _kPass, value: c.passphrase);
    notifyListeners();
  }

  Future<void> setSyncProvider(SyncProvider p) =>
      _set(_prefs.setString('sync.provider', p.name));

  Future<void> saveDrive({
    required String refreshToken,
    required String email,
    required String passphrase,
  }) async {
    _driveToken = refreshToken;
    _drivePass = passphrase;
    await _secure.write(key: _kDriveToken, value: refreshToken);
    await _secure.write(key: _kDrivePass, value: passphrase);
    await _prefs.setString('drive.email', email);
    notifyListeners();
  }

  Future<void> clearDrive() async {
    _driveToken = '';
    _drivePass = '';
    await _secure.delete(key: _kDriveToken);
    await _secure.delete(key: _kDrivePass);
    await _prefs.remove('drive.email');
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

  // ---- Telegram and email hub -------------------------------------------------

  /// Address of the bot on Vercel, e.g. https://inkwell-bot.vercel.app
  String get botUrl => _prefs.getString('hub.url') ?? '';

  /// Shared secret between the app, the bot and the Gmail script.
  String get botKey => _botKey;

  /// Telegram bot token and the owner's chat id, for sending messages.
  String get telegramToken => _tgToken;
  String get telegramChat => _prefs.getString('hub.chat') ?? '';

  /// This device collects the bot's inbox and sends the digests.
  bool get hubEnabled => _prefs.getBool('hub.enabled') ?? false;

  /// Telegram works straight from the app: a bot token and chat id are enough.
  bool get hubConfigured => _tgToken.isNotEmpty && telegramChat.isNotEmpty;

  /// The optional email relay (a small Vercel bot). Telegram does not need it.
  bool get botConfigured => botUrl.isNotEmpty && _botKey.isNotEmpty;

  bool get hubReady => hubEnabled && hubConfigured;

  bool get digestEnabled => _prefs.getBool('hub.digest') ?? true;
  int get digestHour => (_prefs.getInt('hub.digest.hour') ?? 8).clamp(0, 23);
  bool get nudgeEnabled => _prefs.getBool('hub.nudge') ?? true;
  int get nudgeHour => (_prefs.getInt('hub.nudge.hour') ?? 17).clamp(0, 23);
  bool get weeklyEnabled => _prefs.getBool('hub.weekly') ?? true;
  int get weeklyDay => (_prefs.getInt('hub.weekly.day') ?? DateTime.sunday).clamp(1, 7);
  int get weeklyHour => (_prefs.getInt('hub.weekly.hour') ?? 18).clamp(0, 23);
  bool get escalateEnabled => _prefs.getBool('hub.escalate') ?? true;

  bool get quietEnabled => _prefs.getBool('quiet.enabled') ?? false;
  int get quietStart => (_prefs.getInt('quiet.start') ?? 22).clamp(0, 23);
  int get quietEnd => (_prefs.getInt('quiet.end') ?? 7).clamp(0, 23);

  /// Quiet hours apply to task reminders and to Telegram messages.
  QuietHours get quietHours =>
      QuietHours(enabled: quietEnabled, startHour: quietStart, endHour: quietEnd);

  DigestConfig get digestConfig => DigestConfig(
        digest: digestEnabled,
        digestHour: digestHour,
        nudge: nudgeEnabled,
        nudgeHour: nudgeHour,
        weekly: weeklyEnabled,
        weeklyDay: weeklyDay,
        weeklyHour: weeklyHour,
        escalate: escalateEnabled,
        quiet: quietHours,
        dayStartHour: reminderHour,
      );

  Future<void> saveHub({
    required String url,
    required String key,
    required String token,
    required String chat,
  }) async {
    _botKey = key.trim();
    _tgToken = token.trim();
    await _secure.write(key: _kBotKey, value: _botKey);
    await _secure.write(key: _kTgToken, value: _tgToken);
    await _prefs.setString('hub.url', url.trim().replaceAll(RegExp(r'/+$'), ''));
    await _prefs.setString('hub.chat', chat.trim());
    notifyListeners();
  }

  Future<void> setHubEnabled(bool v) => _set(_prefs.setBool('hub.enabled', v));
  Future<void> setDigestEnabled(bool v) => _set(_prefs.setBool('hub.digest', v));
  Future<void> setDigestHour(int h) => _set(_prefs.setInt('hub.digest.hour', h));
  Future<void> setNudgeEnabled(bool v) => _set(_prefs.setBool('hub.nudge', v));
  Future<void> setNudgeHour(int h) => _set(_prefs.setInt('hub.nudge.hour', h));
  Future<void> setWeeklyEnabled(bool v) => _set(_prefs.setBool('hub.weekly', v));
  Future<void> setWeeklyDay(int d) => _set(_prefs.setInt('hub.weekly.day', d));
  Future<void> setWeeklyHour(int h) => _set(_prefs.setInt('hub.weekly.hour', h));
  Future<void> setEscalateEnabled(bool v) => _set(_prefs.setBool('hub.escalate', v));
  Future<void> setQuietEnabled(bool v) => _set(_prefs.setBool('quiet.enabled', v));
  Future<void> setQuietStart(int h) => _set(_prefs.setInt('quiet.start', h));
  Future<void> setQuietEnd(int h) => _set(_prefs.setInt('quiet.end', h));

  /// Re-reads preferences from disk. The Android background worker runs in
  /// another isolate and may have changed them since this one cached them.
  Future<void> refresh() => _prefs.reload();

  /// Small string/JSON helpers for services that keep their own state.
  String? getString(String key) => _prefs.getString(key);
  Future<void> putString(String key, String value) async {
    await _prefs.setString(key, value);
  }
}
