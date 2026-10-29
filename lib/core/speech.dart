import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'settings.dart';

/// Voice dictation using the device's own speech engine
/// (Android SpeechRecognizer, Windows speech recognition).
///
/// Inkwell never sends audio anywhere itself and bundles no cloud speech
/// service. With "prefer on-device" on, the engine is asked to work offline;
/// whether it really can depends on the offline language pack installed on the
/// device, which is why the UI words this as a preference, not a guarantee.
class VoiceInput extends ChangeNotifier {
  VoiceInput(this.settings);

  final AppSettings settings;
  final SpeechToText _stt = SpeechToText();

  bool _initialised = false;
  bool available = false;
  bool listening = false;

  /// The running transcript of the current utterance.
  String partial = '';

  /// A user-readable problem from the last attempt, or null.
  String? error;

  List<LocaleName> locales = const [];
  VoidCallback? _onDone;

  Future<bool> ensureReady() async {
    if (_initialised) return available;
    _initialised = true;
    try {
      available = await _stt.initialize(
        onStatus: _onStatus,
        onError: _onError,
      );
      if (available) locales = await _stt.locales();
    } catch (_) {
      available = false;
    }
    if (!available) error = _unavailableMessage;
    notifyListeners();
    return available;
  }

  String get _unavailableMessage => Platform.isWindows
      ? 'Voice input is not available. Check that a microphone is connected '
          'and speech recognition is enabled in Windows settings. '
          'You can also dictate anywhere with Win+H.'
      : 'Voice input is not available. Allow microphone access for Inkwell and '
          'make sure a speech service is installed.';

  /// Starts listening. [onText] receives the transcript so far; [isFinal] is
  /// true for the last callback of an utterance. [onDone] runs when listening
  /// stops for any reason.
  Future<void> start({
    required void Function(String text, bool isFinal) onText,
    VoidCallback? onDone,
  }) async {
    error = null;
    if (!await ensureReady()) {
      notifyListeners();
      onDone?.call();
      return;
    }
    partial = '';
    listening = true;
    _onDone = onDone;
    notifyListeners();
    try {
      await _stt.listen(
        onResult: (SpeechRecognitionResult r) {
          partial = r.recognizedWords;
          onText(r.recognizedWords, r.finalResult);
          if (r.finalResult) _finish();
          notifyListeners();
        },
        listenOptions: SpeechListenOptions(
          localeId: settings.speechLocale.isEmpty ? null : settings.speechLocale,
          listenFor: const Duration(minutes: 2),
          pauseFor: const Duration(seconds: 4),
          onDevice: settings.onDeviceSpeech,
          partialResults: true,
          listenMode: ListenMode.dictation,
          cancelOnError: true,
        ),
      );
    } catch (e) {
      error = 'Could not start listening: $e';
      _finish();
    }
  }

  Future<void> stop() async {
    try {
      await _stt.stop();
    } catch (_) {}
    _finish();
  }

  void _finish() {
    if (!listening) return;
    listening = false;
    final done = _onDone;
    _onDone = null;
    notifyListeners();
    done?.call();
  }

  void _onStatus(String status) {
    if (status == 'done' || status == 'notListening') _finish();
  }

  void _onError(SpeechRecognitionError e) {
    error = _friendly(e.errorMsg);
    _finish();
  }

  String? _friendly(String code) {
    switch (code) {
      case 'error_no_match':
      case 'error_speech_timeout':
        return "Didn't catch that. Tap the mic and try again.";
      case 'error_language_not_supported':
      case 'error_language_unavailable':
        return 'That language is not available offline on this device. Install '
            'its offline speech pack in your device settings, choose another '
            'language, or switch off on-device recognition in Inkwell settings.';
      case 'error_permission':
        return 'Microphone permission is needed for voice input.';
      case 'error_network':
      case 'error_network_timeout':
        return 'The speech service needs a connection for this language. '
            'Install its offline pack to use it without internet.';
      default:
        return 'Voice input stopped ($code).';
    }
  }

  @override
  void dispose() {
    _stt.cancel();
    super.dispose();
  }
}
