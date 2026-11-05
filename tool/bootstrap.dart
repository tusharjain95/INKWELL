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
        <intent>
            <action android:name="android.intent.action.VIEW"/>
            <data android:scheme="https"/>
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

  // --- native: hand shared text / files to Flutter -----------------------------
  _patchMainActivity();
  _patchWidgets();

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

/// Replaces the generated MainActivity with one that receives Android share
/// intents (text, links, images, files), copies shared files into the app cache
/// and passes them to Dart over the "inkwell/share" channel.
void _patchMainActivity() {
  final root = Directory('android/app/src/main');
  File? target;
  if (root.existsSync()) {
    for (final e in root.listSync(recursive: true)) {
      if (e is File && e.path.endsWith('MainActivity.kt')) target = e;
    }
  }
  if (target == null) {
    stderr.writeln('warning: MainActivity.kt not found; share-to-Inkwell not added');
    return;
  }
  var src = target.readAsStringSync();
  if (src.contains('inkwell-share')) return;
  final pkg = RegExp(r'^\s*package\s+([\w.]+)', multiLine: true).firstMatch(src)?.group(1);
  if (pkg == null) {
    stderr.writeln('warning: no package line in ${target.path}; share not added');
    return;
  }
  target.writeAsStringSync('''
// inkwell-share: receives Android share intents and passes them to Dart
package $pkg

import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "inkwell/share")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            if (call.method == "getInitial") {
                val i = intent
                if (i == null || !isShare(i)) {
                    result.success(null)
                } else {
                    extract(i) { data -> result.success(data) }
                }
            } else if (call.method == "getAction") {
                result.success(action(intent))
            } else if (call.method == "refreshWidgets") {
                InkwellWidgetData.refreshAll(this)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (isShare(intent)) {
            extract(intent) { data -> channel?.invokeMethod("shared", data) }
        }
        action(intent)?.let { channel?.invokeMethod("action", it) }
    }

    /** A tap on a home-screen widget: open a note or start a new one. Read once. */
    private fun action(i: Intent?): Map<String, Any?>? {
        if (i == null) return null
        val open = i.getStringExtra("inkwell_open")
        val fresh = i.getStringExtra("inkwell_new")
        if (open == null && fresh == null) return null
        i.removeExtra("inkwell_open")
        i.removeExtra("inkwell_new")
        return if (open != null) mapOf("open" to open) else mapOf("new" to fresh)
    }

    private fun isShare(i: Intent) =
        i.action == Intent.ACTION_SEND || i.action == Intent.ACTION_SEND_MULTIPLE

    /** Copies shared streams to the cache off the main thread, then calls back on it. */
    @Suppress("DEPRECATION")
    private fun extract(i: Intent, done: (Map<String, Any?>?) -> Unit) {
        val text = listOfNotNull(
            i.getStringExtra(Intent.EXTRA_SUBJECT),
            i.getStringExtra(Intent.EXTRA_TEXT)
        ).filter { it.isNotBlank() }.joinToString("\\n")
        val uris = ArrayList<Uri>()
        if (i.action == Intent.ACTION_SEND) {
            (i.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris.add(it) }
        } else {
            i.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        }
        i.action = null // consume, so a rotation does not re-import it
        thread {
            val files = ArrayList<String>()
            val dir = File(cacheDir, "shared").apply { mkdirs() }
            for (u in uris) {
                try {
                    val name = displayName(u) ?: "shared-" + System.currentTimeMillis()
                    val out = File(dir, System.currentTimeMillis().toString() + "-" + name)
                    contentResolver.openInputStream(u)?.use { input ->
                        out.outputStream().use { input.copyTo(it) }
                    }
                    if (out.exists()) files.add(out.absolutePath)
                } catch (e: Exception) {
                    // skip unreadable items
                }
            }
            main.post { done(mapOf("text" to text, "files" to files)) }
        }
    }

    private fun displayName(u: Uri): String? {
        try {
            contentResolver.query(u, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) return it.getString(0)
            }
        } catch (e: Exception) {
        }
        return u.lastPathSegment
    }
}
''');
  stdout.writeln('Patched MainActivity.kt for sharing');
}

/// Adds the Tasks and Notes home-screen widgets: Kotlin providers, a list
/// service, layouts, colours (light and dark), provider info and manifest
/// entries. The data comes from shared preferences, written by the Dart side.
void _patchWidgets() {
  final main = Directory('android/app/src/main');
  File? activity;
  if (main.existsSync()) {
    for (final e in main.listSync(recursive: true)) {
      if (e is File && e.path.endsWith('MainActivity.kt')) activity = e;
    }
  }
  if (activity == null) {
    stderr.writeln('warning: MainActivity.kt not found; widgets not added');
    return;
  }
  final pkg = RegExp(r'^\s*package\s+([\w.]+)', multiLine: true)
      .firstMatch(activity.readAsStringSync())
      ?.group(1);
  if (pkg == null) {
    stderr.writeln('warning: no package in MainActivity.kt; widgets not added');
    return;
  }
  final sep = Platform.pathSeparator;
  final kotlinDir = activity.parent.path;

  File('$kotlinDir${sep}InkwellWidgets.kt')
      .writeAsStringSync(_widgetKotlin.replaceAll('__PKG__', pkg));

  void res(String rel, String body) {
    final f = File('android/app/src/main/res/$rel'.replaceAll('/', sep));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(body);
  }

  res('layout/inkwell_widget.xml', _widgetLayout);
  res('layout/inkwell_widget_item.xml', _widgetItemLayout);
  res('drawable/inkwell_widget_bg.xml', _widgetBackground);
  res('values/inkwell_widget_colors.xml', _widgetColors(night: false));
  res('values-night/inkwell_widget_colors.xml', _widgetColors(night: true));
  res('xml/inkwell_tasks_widget_info.xml', _widgetInfo);
  res('xml/inkwell_notes_widget_info.xml', _widgetInfo);

  final manifest = File('android/app/src/main/AndroidManifest.xml');
  var m = manifest.readAsStringSync();
  if (!m.contains('inkwell-patched-widgets')) {
    final decl = '''
        <!-- inkwell-patched-widgets -->
        <receiver android:name="$pkg.TasksWidget" android:exported="true"
            android:label="Inkwell tasks">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE"/>
            </intent-filter>
            <meta-data android:name="android.appwidget.provider"
                android:resource="@xml/inkwell_tasks_widget_info"/>
        </receiver>
        <receiver android:name="$pkg.NotesWidget" android:exported="true"
            android:label="Inkwell notes">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE"/>
            </intent-filter>
            <meta-data android:name="android.appwidget.provider"
                android:resource="@xml/inkwell_notes_widget_info"/>
        </receiver>
        <service android:name="$pkg.InkwellWidgetService" android:exported="false"
            android:permission="android.permission.BIND_REMOTEVIEWS"/>
''';
    if (m.contains('</application>')) {
      m = m.replaceFirst('</application>', '$decl    </application>');
      manifest.writeAsStringSync(m);
      stdout.writeln('Patched AndroidManifest.xml for widgets');
    } else {
      stderr.writeln('warning: no </application> in manifest; widgets not added');
    }
  }
  stdout.writeln('Added home-screen widgets');
}

const String _widgetInfo = '''<?xml version="1.0" encoding="utf-8"?>
<appwidget-provider xmlns:android="http://schemas.android.com/apk/res/android"
    android:minWidth="250dp"
    android:minHeight="180dp"
    android:updatePeriodMillis="1800000"
    android:initialLayout="@layout/inkwell_widget"
    android:resizeMode="horizontal|vertical"
    android:widgetCategory="home_screen"/>
''';

const String _widgetBackground = '''<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <solid android:color="@color/inkwell_widget_bg"/>
    <corners android:radius="20dp"/>
</shape>
''';

String _widgetColors({required bool night}) => night
    ? '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="inkwell_widget_bg">#FF1E1B24</color>
    <color name="inkwell_widget_text">#FFE8E1EC</color>
    <color name="inkwell_widget_sub">#FFB0A9B5</color>
    <color name="inkwell_widget_accent">#FFCFBCFF</color>
</resources>
'''
    : '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="inkwell_widget_bg">#FFFEF7FF</color>
    <color name="inkwell_widget_text">#FF1D1B20</color>
    <color name="inkwell_widget_sub">#FF625B71</color>
    <color name="inkwell_widget_accent">#FF6750A4</color>
</resources>
''';

const String _widgetLayout = '''<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:orientation="vertical"
    android:padding="8dp"
    android:background="@drawable/inkwell_widget_bg">

    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="horizontal"
        android:gravity="center_vertical">

        <TextView
            android:id="@+id/widget_title"
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:paddingStart="8dp"
            android:paddingEnd="8dp"
            android:paddingTop="6dp"
            android:paddingBottom="6dp"
            android:textColor="@color/inkwell_widget_accent"
            android:textSize="15sp"
            android:textStyle="bold"
            android:maxLines="1"
            android:ellipsize="end"/>

        <TextView
            android:id="@+id/widget_add"
            android:layout_width="40dp"
            android:layout_height="40dp"
            android:gravity="center"
            android:text="+"
            android:textColor="@color/inkwell_widget_accent"
            android:textSize="26sp"/>
    </LinearLayout>

    <FrameLayout
        android:layout_width="match_parent"
        android:layout_height="0dp"
        android:layout_weight="1">

        <ListView
            android:id="@+id/widget_list"
            android:layout_width="match_parent"
            android:layout_height="match_parent"
            android:divider="@null"
            android:dividerHeight="0dp"/>

        <TextView
            android:id="@+id/widget_empty"
            android:layout_width="match_parent"
            android:layout_height="match_parent"
            android:gravity="center"
            android:textColor="@color/inkwell_widget_sub"
            android:textSize="14sp"/>
    </FrameLayout>
</LinearLayout>
''';

const String _widgetItemLayout = '''<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:id="@+id/item_root"
    android:layout_width="match_parent"
    android:layout_height="wrap_content"
    android:orientation="horizontal"
    android:gravity="center_vertical"
    android:paddingStart="8dp"
    android:paddingEnd="8dp"
    android:paddingTop="7dp"
    android:paddingBottom="7dp">

    <TextView
        android:id="@+id/item_dot"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:text="●"
        android:textSize="12sp"
        android:paddingEnd="10dp"/>

    <LinearLayout
        android:layout_width="0dp"
        android:layout_height="wrap_content"
        android:layout_weight="1"
        android:orientation="vertical">

        <TextView
            android:id="@+id/item_title"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:textColor="@color/inkwell_widget_text"
            android:textSize="15sp"
            android:maxLines="1"
            android:ellipsize="end"/>

        <TextView
            android:id="@+id/item_sub"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:textColor="@color/inkwell_widget_sub"
            android:textSize="12sp"
            android:maxLines="1"
            android:ellipsize="end"/>
    </LinearLayout>
</LinearLayout>
''';

const String _widgetKotlin = r'''
// inkwell-widgets: home-screen widgets for tasks and notes
package __PKG__

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import org.json.JSONObject

object InkwellWidgetData {
    private fun raw(ctx: Context, kind: String): JSONObject? {
        val prefs = ctx.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val text = prefs.getString("flutter.inkwell.widget." + kind, null) ?: return null
        return try {
            JSONObject(text)
        } catch (e: Exception) {
            null
        }
    }

    fun rows(ctx: Context, kind: String): List<JSONObject> {
        val arr = raw(ctx, kind)?.optJSONArray("items") ?: return emptyList()
        val out = ArrayList<JSONObject>()
        for (i in 0 until arr.length()) {
            arr.optJSONObject(i)?.let { out.add(it) }
        }
        return out
    }

    fun count(ctx: Context, kind: String): Int = raw(ctx, kind)?.optInt("count", 0) ?: 0

    fun refreshAll(ctx: Context) {
        val mgr = AppWidgetManager.getInstance(ctx)
        for (cls in listOf(TasksWidget::class.java, NotesWidget::class.java)) {
            val ids = mgr.getAppWidgetIds(ComponentName(ctx, cls))
            if (ids.isEmpty()) continue
            val i = Intent(ctx, cls)
            i.action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
            i.putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
            ctx.sendBroadcast(i)
        }
    }
}

abstract class InkwellListWidget : AppWidgetProvider() {
    abstract val kind: String
    abstract val heading: String
    abstract val newKind: String
    abstract val emptyText: String

    override fun onUpdate(ctx: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) {
            mgr.updateAppWidget(id, build(ctx, id))
        }
        mgr.notifyAppWidgetViewDataChanged(ids, R.id.widget_list)
    }

    private fun build(ctx: Context, id: Int): RemoteViews {
        val views = RemoteViews(ctx.packageName, R.layout.inkwell_widget)
        val n = InkwellWidgetData.count(ctx, kind)
        views.setTextViewText(R.id.widget_title, if (n > 0) heading + " (" + n + ")" else heading)
        views.setTextViewText(R.id.widget_empty, emptyText)

        val svc = Intent(ctx, InkwellWidgetService::class.java)
        svc.putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
        svc.putExtra("kind", kind)
        svc.setData(android.net.Uri.parse(svc.toUri(Intent.URI_INTENT_SCHEME)))
        views.setRemoteAdapter(R.id.widget_list, svc)
        views.setEmptyView(R.id.widget_list, R.id.widget_empty)

        val flags = PendingIntent.FLAG_UPDATE_CURRENT
        val openApp = Intent(ctx, MainActivity::class.java)
        openApp.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        views.setOnClickPendingIntent(
            R.id.widget_title,
            PendingIntent.getActivity(ctx, 2000 + id, openApp, flags or PendingIntent.FLAG_IMMUTABLE)
        )

        val add = Intent(ctx, MainActivity::class.java)
        add.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        add.putExtra("inkwell_new", newKind)
        views.setOnClickPendingIntent(
            R.id.widget_add,
            PendingIntent.getActivity(ctx, 1000 + id, add, flags or PendingIntent.FLAG_IMMUTABLE)
        )

        // Rows share one template; each row fills in the note id.
        val template = Intent(ctx, MainActivity::class.java)
        template.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        views.setPendingIntentTemplate(
            R.id.widget_list,
            PendingIntent.getActivity(ctx, 3000 + id, template, flags or PendingIntent.FLAG_MUTABLE)
        )
        return views
    }
}

class TasksWidget : InkwellListWidget() {
    override val kind = "tasks"
    override val heading = "Tasks"
    override val newKind = "task"
    override val emptyText = "No open tasks"
}

class NotesWidget : InkwellListWidget() {
    override val kind = "notes"
    override val heading = "Notes"
    override val newKind = "note"
    override val emptyText = "No notes yet"
}

class InkwellWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        InkwellRowFactory(applicationContext, intent.getStringExtra("kind") ?: "tasks")
}

class InkwellRowFactory(private val ctx: Context, private val kind: String) :
    RemoteViewsService.RemoteViewsFactory {
    private var items: List<JSONObject> = emptyList()

    override fun onCreate() {}

    override fun onDataSetChanged() {
        items = InkwellWidgetData.rows(ctx, kind)
    }

    override fun onDestroy() {}

    override fun getCount(): Int = items.size

    override fun getViewAt(position: Int): RemoteViews {
        val rv = RemoteViews(ctx.packageName, R.layout.inkwell_widget_item)
        if (position < 0 || position >= items.size) return rv
        val row = items[position]
        rv.setTextViewText(R.id.item_title, row.optString("title"))

        val sub = row.optString("sub")
        if (sub.isEmpty()) {
            rv.setViewVisibility(R.id.item_sub, View.GONE)
        } else {
            rv.setViewVisibility(R.id.item_sub, View.VISIBLE)
            rv.setTextViewText(R.id.item_sub, sub)
            val color = if (row.optBoolean("overdue", false)) 0xFFD32F2F.toInt()
            else ctx.getColor(R.color.inkwell_widget_sub)
            rv.setTextColor(R.id.item_sub, color)
        }

        if (kind == "tasks") {
            val dot = when (row.optInt("prio", 0)) {
                1 -> 0xFFD32F2F.toInt()
                2 -> 0xFFF57C00.toInt()
                3 -> 0xFF1976D2.toInt()
                else -> 0xFF9E9E9E.toInt()
            }
            rv.setViewVisibility(R.id.item_dot, View.VISIBLE)
            rv.setTextColor(R.id.item_dot, dot)
        } else if (row.optBoolean("pinned", false)) {
            rv.setViewVisibility(R.id.item_dot, View.VISIBLE)
            rv.setTextColor(R.id.item_dot, ctx.getColor(R.color.inkwell_widget_accent))
        } else {
            rv.setViewVisibility(R.id.item_dot, View.GONE)
        }

        val fill = Intent()
        fill.putExtra("inkwell_open", row.optString("id"))
        rv.setOnClickFillInIntent(R.id.item_root, fill)
        return rv
    }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = 1

    override fun getItemId(position: Int): Long = position.toLong()

    override fun hasStableIds(): Boolean = false
}
''';

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
