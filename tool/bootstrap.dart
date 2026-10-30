// Generates the android/ and windows/ platform folders with `flutter create`
// and applies Inkwell's patches (permissions, release signing, minSdk).
//
// Safe to run repeatedly: finished work is detected and skipped.
//
//   dart run tool/bootstrap.dart              # android + windows
//   dart run tool/bootstrap.dart android      # just one platform
import 'dart:io';

Future<void> main(List<String> args) async {
  final wanted = args.isEmpty ? <String>['android', 'windows'] : args;

  final missing = [
    for (final p in wanted)
      if (!Directory(p).existsSync()) p,
  ];
  if (missing.isNotEmpty) {
    stdout.writeln('Generating platform folders: ${missing.join(', ')}');
    final r = await Process.run(
      'flutter',
      [
        'create',
        '--platforms=${missing.join(',')}',
        '--org',
        'dev.inkwell',
        '--project-name',
        'inkwell',
        '.',
      ],
      runInShell: true,
    );
    stdout.write(r.stdout);
    stderr.write(r.stderr);
    if (r.exitCode != 0) exit(r.exitCode);
  }

  // `flutter create` can add a sample widget test that does not fit this app.
  final sample = File('test/widget_test.dart');
  if (sample.existsSync() && sample.readAsStringSync().contains('MyApp')) {
    sample.deleteSync();
  }

  if (wanted.contains('android')) _patchAndroid();
  if (wanted.contains('windows')) _patchWindows();
  stdout.writeln('Platform setup complete.');
}

void _patchAndroid() {
  // --- manifest: network + installing updates ---------------------------------
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  if (!manifest.existsSync()) {
    stderr.writeln('error: ${manifest.path} not found');
    exit(1);
  }
  var m = manifest.readAsStringSync();
  if (!m.contains('inkwell-patched')) {
    const perms = '''
    <!-- inkwell-patched -->
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>
''';
    m = m.replaceFirstMapped(
      RegExp(r'<manifest[^>]*>'),
      (match) => '${match[0]}\n$perms',
    );
    m = m.replaceAll('android:label="inkwell"', 'android:label="Inkwell"');
    manifest.writeAsStringSync(m);
    stdout.writeln('Patched AndroidManifest.xml');
  }

  // --- manifest: voice input (microphone + speech recognition service) -------
  m = manifest.readAsStringSync();
  if (!m.contains('inkwell-patched-voice')) {
    const mic = '''
    <!-- inkwell-patched-voice -->
    <uses-permission android:name="android.permission.RECORD_AUDIO"/>
''';
    const query = '''
        <intent>
            <action android:name="android.speech.RecognitionService"/>
        </intent>
''';
    m = m.replaceFirstMapped(
      RegExp(r'<manifest[^>]*>'),
      (match) => '${match[0]}\n$mic',
    );
    if (m.contains('</queries>')) {
      m = m.replaceFirst('</queries>', '$query    </queries>');
    } else {
      m = m.replaceFirst(
          '</manifest>', '    <queries>\n$query    </queries>\n</manifest>');
    }
    manifest.writeAsStringSync(m);
    stdout.writeln('Patched AndroidManifest.xml for voice input');
  }

  // --- manifest: reminders (notifications, exact alarms, reboot) -------------
  m = manifest.readAsStringSync();
  if (!m.contains('inkwell-patched-notify')) {
    const perms = '''
    <!-- inkwell-patched-notify -->
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
    <uses-permission android:name="android.permission.VIBRATE"/>
''';
    const receivers = '''
        <receiver android:exported="false"
            android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver"/>
        <receiver android:exported="false"
            android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
                <action android:name="android.intent.action.QUICKBOOT_POWERON"/>
                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
            </intent-filter>
        </receiver>
''';
    m = m.replaceFirstMapped(
      RegExp(r'<manifest[^>]*>'),
      (match) => '${match[0]}\n$perms',
    );
    m = m.replaceFirst('</application>', '$receivers    </application>');
    manifest.writeAsStringSync(m);
    stdout.writeln('Patched AndroidManifest.xml for reminders');
  }

  // --- manifest: receive shared text / images / files -----------------------
  m = manifest.readAsStringSync();
  if (!m.contains('inkwell-patched-share')) {
    const filters = '''
            <!-- inkwell-patched-share -->
            <intent-filter>
                <action android:name="android.intent.action.SEND"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:mimeType="text/*"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:mimeType="image/*"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:mimeType="application/pdf"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND_MULTIPLE"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:mimeType="image/*"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND_MULTIPLE"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:mimeType="*/*"/>
            </intent-filter>
''';
    final act = RegExp(r'</activity>');
    if (act.hasMatch(m)) {
      m = m.replaceFirst('</activity>', '$filters        </activity>');
      manifest.writeAsStringSync(m);
      stdout.writeln('Patched AndroidManifest.xml for sharing');
    } else {
      stderr.writeln('warning: no </activity> in manifest; share-to-Inkwell not added');
    }
  }

  // --- gradle: compile every plugin against a recent Android API ---------------
  _patchPluginCompileSdk();

  // --- gradle: release signing + minSdk ---------------------------------------
  final kts = File('android/app/build.gradle.kts');
  if (kts.existsSync()) {
    _patchGradleKts(kts);
  } else if (File('android/app/build.gradle').existsSync()) {
    stderr.writeln('warning: Groovy build.gradle found. Add release signing '
        'from android/key.properties manually (see README).');
  } else {
    stderr.writeln('error: no android/app/build.gradle(.kts) found');
    exit(1);
  }
}

/// Some plugins (file_picker, open_filex, ...) still compile against an old
/// API level, but androidx.lifecycle now requires 36+. Raise it for every
/// Android library from a Gradle init script in the user's Gradle home. An
/// init script is plain Groovy, so it does not depend on which Android Gradle
/// Plugin classes the project build scripts can see.
void _patchPluginCompileSdk() {
  final home = Platform.environment['GRADLE_USER_HOME'] ??
      '${Platform.environment['HOME'] ?? Platform.environment['USERPROFILE']}'
          '${Platform.pathSeparator}.gradle';
  final dir = Directory('$home${Platform.pathSeparator}init.d')
    ..createSync(recursive: true);
  final f = File('${dir.path}${Platform.pathSeparator}inkwell-compilesdk.gradle');
  f.writeAsStringSync(r'''
// inkwell-compilesdk: plugins compiled against old APIs fail the AAR metadata check
gradle.beforeProject { p ->
    p.afterEvaluate {
        if (p.plugins.hasPlugin('com.android.library')) {
            def ext = p.extensions.findByName('android')
            def cur = ext.hasProperty('compileSdk') ? ext.compileSdk : null
            if (cur == null || cur < 36) {
                ext.compileSdk = 36
                println "inkwell: compileSdk 36 for ${p.name} (was ${cur})"
            }
        }
    }
}
''');
  stdout.writeln('Wrote ${f.path} (compileSdk 36 for plugins)');
}

void _patchGradleKts(File f) {
  var s = f.readAsStringSync();
  if (s.contains('inkwell-signing')) return;

  const loader = '''
// inkwell-signing: release signing comes from android/key.properties (written by CI)
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

''';
  const signing = '''
    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

''';

  final androidBlock = RegExp(r'^android\s*\{', multiLine: true);
  final first = androidBlock.firstMatch(s);
  if (first == null) {
    stderr.writeln('error: no android { block found in ${f.path}');
    exit(1);
  }
  s = s.replaceRange(first.start, first.start, loader);
  // `java.util...` does not resolve in Gradle Kotlin scripts (`java` is the
  // Java plugin extension there), so use imports, which must come first.
  s = 'import java.io.FileInputStream\nimport java.util.Properties\n\n$s';

  final second = androidBlock.firstMatch(s)!;
  final lineEnd = s.indexOf('\n', second.end) + 1;
  s = s.replaceRange(lineEnd, lineEnd, '\n$signing');

  s = s.replaceAll(
    'signingConfig = signingConfigs.getByName("debug")',
    'signingConfig = if (keystorePropertiesFile.exists()) '
        'signingConfigs.getByName("release") else signingConfigs.getByName("debug")',
  );
  // flutter_local_notifications needs core library desugaring.
  if (!s.contains('isCoreLibraryDesugaringEnabled')) {
    final co = RegExp(r'compileOptions\s*\{');
    if (co.hasMatch(s)) {
      s = s.replaceFirstMapped(
          co, (m) => '${m[0]}\n        isCoreLibraryDesugaringEnabled = true');
      s += '''

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
''';
    } else {
      stderr.writeln('warning: no compileOptions block found in ${f.path}; '
          'enable core library desugaring manually (see flutter_local_notifications).');
    }
  }
  // Secure storage and file pickers need API 23+; 24 keeps things simple.
  s = s.replaceAll(
    RegExp(r'minSdk\s*=\s*flutter\.minSdkVersion'),
    'minSdk = 24',
  );

  if (!s.contains('signingConfigs.getByName("release")')) {
    stderr.writeln('warning: could not find the release signingConfig line in '
        '${f.path}. Releases would be debug-signed; wire signing manually.');
  }
  f.writeAsStringSync(s);
  stdout.writeln('Patched ${f.path}');
}

void _patchWindows() {
  final main = File('windows/runner/main.cpp');
  if (main.existsSync()) {
    main.writeAsStringSync(
        main.readAsStringSync().replaceAll('L"inkwell"', 'L"Inkwell"'));
  }
}
