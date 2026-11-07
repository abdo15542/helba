import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'config.dart';

// ---------------------------------------------------------------------------
// In-app update (self-update): when a new build is published as a GitHub
// Release tagged `build-<run_number>` (see the workflow), the app checks
// the public GitHub API, prompts the user in Arabic, downloads the APK
// into its cache dir with visible progress, and hands it to the system
// installer — so the user never has to delete the app and reinstall it
// from GitHub by hand.
//
// Design notes:
// - Best-effort only: every failure (no network, API error, rate limit,
//   malformed payload) is swallowed silently. The check never throws,
//   never blocks startup, and never shows an error to the user.
// - The check runs at most once per launch and at most once per hour
//   (last-check time persisted in secure storage). A release push
//   (GitHub webhook → github-release-notify Edge Function → FCM
//   `app_update` message) bypasses the throttle: tapping it records
//   the build as pending (see [AppUpdateStore.pendingBuild]) and the
//   inbox shows the update dialog for it without waiting for the
//   next hourly check.
// - GitHub is reached DIRECTLY: the app installs a global HttpOverrides
//   (network.dart) that routes traffic through the DoH fallback + system
//   proxy for Supabase. That layer must not touch the update check, so
//   the HTTP work below runs inside runWithHttpOverrides with a stock
//   overrides instance ([_DirectHttpOverrides]), which shadows the global
//   and yields a plain HttpClient.
// - Persistence reuses the app's existing secure storage (config.dart
//   secureStore); no new storage dependency was needed.
// ---------------------------------------------------------------------------

/// Stock HTTP overrides: a concrete [io.HttpOverrides] instance whose
/// inherited [createHttpClient] is the SDK default (plain [io.HttpClient],
/// no DoH fallback, no system-proxy routing). Used with
/// [io.HttpOverrides.runWithHttpOverrides] so the GitHub update check
/// and APK download bypass the app's global [HelbaHttpOverrides]
/// (network.dart) and reach GitHub directly. The class body is
/// intentionally empty: the base implementation IS the stock client —
/// the instance only exists so the zone shadows the global overrides.
///
/// (Dart 3.13: [io.HttpOverrides] is abstract and `runZoned` no longer
/// takes an `overrides` instance — and a bare `runZoned` would fall back
/// to the global overrides, so the bypass must be an explicit instance
/// passed to `runWithHttpOverrides`.)
class _DirectHttpOverrides extends io.HttpOverrides {}

/// Runs [body] with the stock HTTP client (see [_DirectHttpOverrides]).
Future<T> _runDirect<T>(Future<T> Function() body) =>
    io.HttpOverrides.runWithHttpOverrides(body, _DirectHttpOverrides());

/// The public GitHub API endpoint for the latest Helba release.
const latestReleaseUrl =
    'https://api.github.com/repos/abdo15542/helba/releases/latest';

/// How often the app may check for an update (at most once per hour).
/// One hour — not one day — so a build published the same day an
/// earlier check already ran (e.g. build 136, hours after 135) is still
/// picked up promptly when the inbox opens. The GitHub API is public
/// and unauthenticated here, and one small call per hour per device is
/// far inside its rate limit.
const updateCheckInterval = Duration(hours: 1);

/// Secure-storage keys (see config.dart secureStore).
const _lastCheckKey = 'helba_update_last_check_ms';
const _dismissedBuildKey = 'helba_update_dismissed_build';

/// Build number recorded when the user taps an update push
/// notification (FCM data type `app_update`, see push.dart). The inbox
/// reads it first in `_checkForUpdate` and shows the update dialog for
/// it without waiting for the hourly check.
const _pendingBuildKey = 'helba_update_pending_build';

/// A published build the app can update to.
class UpdateInfo {
  final int buildNumber;
  final String tag;
  final String downloadUrl;
  final String? name;

  const UpdateInfo({
    required this.buildNumber,
    required this.tag,
    required this.downloadUrl,
    this.name,
  });
}

/// Parses a release tag of the form `build-<N>` (e.g. `build-98`) to its
/// build number. Returns null for anything else (null, `v1.0`, `build-`,
/// `build-abc`, ...). Whitespace around the tag is tolerated.
int? parseBuildTag(String? tag) {
  if (tag == null) return null;
  final match = RegExp(r'^build-(\d+)$').firstMatch(tag.trim());
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/// True when the latest published build is newer than the installed one.
bool isUpdateAvailable({
  required int installedBuild,
  required int? latestBuild,
}) =>
    latestBuild != null && latestBuild > installedBuild;

/// True when the update prompt should be shown for [update]: never when
/// the user already dismissed this build (or a newer one) with [لاحقاً].
bool shouldPromptForUpdate({
  required UpdateInfo update,
  required int? dismissedBuild,
}) =>
    dismissedBuild == null || dismissedBuild < update.buildNumber;

/// The direct download URL for a build's APK on its GitHub release.
/// This is the URL the workflow publishes: tag `build-<N>` with the
/// single asset `helba-build-<N>.apk` (see .github/workflows/android.yml).
/// Used for a pending update from a notification tap, where there is no
/// release payload to pick the asset URL from (see [pendingUpdateInfo]).
String releaseDownloadUrl(int build) =>
    'https://github.com/abdo15542/helba/releases/download/build-$build/helba-build-$build.apk';

/// The [UpdateInfo] for a pending build recorded from an update push
/// notification tap: the tag and download URL follow the release
/// naming, so the existing download/install flow works unchanged.
UpdateInfo pendingUpdateInfo(int build) => UpdateInfo(
      buildNumber: build,
      tag: 'build-$build',
      downloadUrl: releaseDownloadUrl(build),
    );

/// What the inbox should do with a pending update build recorded from
/// a notification tap.
enum PendingUpdateAction {
  /// The pending build is newer than the installed one: show the
  /// update dialog for it (bypassing the hourly throttle).
  show,

  /// The pending build is already installed (or older): clear it and
  /// fall through to the normal hourly check.
  clearAndSkip,

  /// No pending build was recorded: run the normal hourly check.
  none,
}

/// Decides what to do with a pending update build: [show] when it is
/// newer than the installed build, [clearAndSkip] when it is not, and
/// [none] when nothing was recorded. Pure (unit-tested).
PendingUpdateAction pendingUpdateAction({
  required int? pendingBuild,
  required int installedBuild,
}) {
  if (pendingBuild == null) return PendingUpdateAction.none;
  return pendingBuild > installedBuild
      ? PendingUpdateAction.show
      : PendingUpdateAction.clearAndSkip;
}

/// Picks the APK download URL from a GitHub release payload: the first
/// asset whose name ends in `.apk` (browser_download_url, public, no
/// auth). Returns null when the release has no APK asset.
String? selectApkDownloadUrl(Map<String, dynamic> release) {
  final assets = release['assets'];
  if (assets is! List) return null;
  for (final asset in assets) {
    if (asset is! Map) continue;
    final name = asset['name']?.toString() ?? '';
    final url = asset['browser_download_url']?.toString() ?? '';
    if (name.toLowerCase().endsWith('.apk') && url.isNotEmpty) return url;
  }
  return null;
}

/// Parses a GitHub release payload into an [UpdateInfo], or null when it
/// carries no usable build tag or no APK asset.
UpdateInfo? parseRelease(Map<String, dynamic> json) {
  final build = parseBuildTag(json['tag_name']?.toString());
  if (build == null) return null;
  final url = selectApkDownloadUrl(json);
  if (url == null) return null;
  return UpdateInfo(
    buildNumber: build,
    tag: json['tag_name'].toString(),
    downloadUrl: url,
    name: json['name']?.toString(),
  );
}

/// Minimal persistence for the update check: last-check time and the
/// build number the user dismissed with [لاحقاً]. Backed by the app's
/// secure storage by default; an in-memory map can be injected in tests.
class AppUpdateStore {
  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;

  AppUpdateStore({
    Future<String?> Function(String key)? read,
    Future<void> Function(String key, String value)? write,
  })  : _read = read ?? ((key) => secureStore.read(key: key)),
        _write = write ?? ((key, value) => secureStore.write(
              key: key,
              value: value,
            ));

  /// In-memory store (tests).
  factory AppUpdateStore.memory(Map<String, String> backing) =>
      AppUpdateStore(
        read: (key) async => backing[key],
        write: (key, value) async => backing[key] = value,
      );

  Future<DateTime?> lastCheck() async {
    final raw = await _read(_lastCheckKey);
    final ms = raw == null ? null : int.tryParse(raw);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> saveLastCheck(DateTime when) =>
      _write(_lastCheckKey, when.millisecondsSinceEpoch.toString());

  Future<int?> dismissedBuild() async {
    final raw = await _read(_dismissedBuildKey);
    return raw == null ? null : int.tryParse(raw);
  }

  Future<void> saveDismissedBuild(int build) =>
      _write(_dismissedBuildKey, build.toString());

  /// The build recorded from an update push notification tap, or null
  /// when none was recorded. Written by push.dart when the app opens
  /// via an `app_update` FCM message; read (and cleared) by the inbox
  /// before the throttled check.
  Future<int?> pendingBuild() async {
    final raw = await _read(_pendingBuildKey);
    return raw == null ? null : int.tryParse(raw);
  }

  Future<void> savePendingBuild(int build) =>
      _write(_pendingBuildKey, build.toString());

  Future<void> clearPendingBuild() => _write(_pendingBuildKey, '');
}

/// Outcome of handing a downloaded APK to the system installer.
enum UpdateInstallOutcome {
  /// The installer was opened; the system takes over from here.
  opened,

  /// The app may not install packages from itself yet: the user must
  /// allow "Install unknown apps" for Helba in system Settings first.
  needsPermission,

  /// Opening the installer failed (message holds the Arabic detail).
  failed,
}

class UpdateInstallResult {
  final UpdateInstallOutcome outcome;
  final String? message;

  const UpdateInstallResult(this.outcome, [this.message]);
}

/// Checks for a newer build, downloads its APK, and installs it.
///
/// The HTTP client, the install-permission calls and the file opener are
/// injectable so the whole flow is unit-testable without platform
/// channels. In production the defaults are used: a direct (non-proxied)
/// HTTP client, permission_handler, and open_filex.
class AppUpdateChecker {
  final AppUpdateStore store;
  final http.Client Function() _clientFactory;
  final Future<PermissionStatus> Function() _installPermissionStatus;
  final Future<PermissionStatus> Function() _requestInstallPermission;
  final Future<OpenResult> Function(String path) _openFile;

  AppUpdateChecker({
    AppUpdateStore? store,
    http.Client Function()? clientFactory,
    Future<PermissionStatus> Function()? installPermissionStatus,
    Future<PermissionStatus> Function()? requestInstallPermission,
    Future<OpenResult> Function(String path)? openFile,
  })  : store = store ?? AppUpdateStore(),
        _clientFactory = clientFactory ?? http.Client.new,
        _installPermissionStatus = installPermissionStatus ??
            (() => Permission.requestInstallPackages.status),
        _requestInstallPermission = requestInstallPermission ??
            (() => Permission.requestInstallPackages.request()),
        _openFile = openFile ??
            ((path) => OpenFilex.open(
                  path,
                  type: 'application/vnd.android.package-archive',
                ));

  /// Checks the latest GitHub release for a build newer than
  /// [installedBuild]. Returns the [UpdateInfo] when one exists, else
  /// null. Never throws. Runs at most once per hour unless [force] is
  /// true; the last-check time is only persisted when the API actually
  /// answered (a failed check retries on the next launch).
  Future<UpdateInfo?> checkForUpdate({
    required int installedBuild,
    bool force = false,
  }) async {
    try {
      if (!force) {
        final last = await store.lastCheck();
        if (last != null &&
            DateTime.now().difference(last) < updateCheckInterval) {
          return null;
        }
      }
      // (reached, update): reached is true when the API answered with a
      // parseable payload, even when no newer build exists.
      final (reached, update) = await _fetchLatest(installedBuild);
      if (reached) {
        await store.saveLastCheck(DateTime.now());
      }
      return update;
    } catch (_) {
      // Best-effort: any failure (storage, network, parsing) is silent.
      return null;
    }
  }

  /// Fetches the latest release directly from GitHub (see the file
  /// header: the app's DoH/proxy overrides are shadowed here so GitHub
  /// is reached with a stock client). Returns whether the API answered
  /// and, when a newer build exists, its [UpdateInfo].
  Future<(bool, UpdateInfo?)> _fetchLatest(int installedBuild) async {
    try {
      return await _runDirect(() async {
        final client = _clientFactory();
        try {
          final response = await client
              .get(
                Uri.parse(latestReleaseUrl),
                headers: {
                  'Accept': 'application/vnd.github+json',
                  'User-Agent': browserUserAgent,
                },
              )
              .timeout(const Duration(seconds: 15));
          if (response.statusCode != 200) return (false, null);
          final decoded = jsonDecode(response.body);
          if (decoded is! Map<String, dynamic>) return (false, null);
          final parsed = parseRelease(decoded);
          // The API answered with a parseable payload: reached = true
          // even when there is no newer build to offer.
          if (parsed == null) return (true, null);
          if (!isUpdateAvailable(
            installedBuild: installedBuild,
            latestBuild: parsed.buildNumber,
          )) {
            return (true, null);
          }
          return (true, parsed);
        } finally {
          client.close();
        }
      });
    } catch (_) {
      return (false, null);
    }
  }

  /// Downloads the APK for [update] into the app's cache dir
  /// (`helba-update/helba-<N>.apk`), reporting progress as 0..1 (or null
  /// while the total size is unknown). Returns the downloaded file.
  /// Throws on HTTP failure or I/O error; the caller shows the message.
  /// [targetDir] overrides the cache dir (tests); otherwise
  /// getTemporaryDirectory() is used.
  Future<io.File> downloadApk(
    UpdateInfo update, {
    required void Function(double? progress) onProgress,
    io.Directory? targetDir,
  }) async {
    final dir = targetDir ?? await getTemporaryDirectory();
    final file = io.File(
      '${dir.path}/helba-update/helba-${update.buildNumber}.apk',
    );
    await file.parent.create(recursive: true);
    await _runDirect(() async {
      final client = _clientFactory();
      try {
        final request = http.Request('GET', Uri.parse(update.downloadUrl));
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) {
          throw io.HttpException(
            'تعذّر تنزيل التحديث (رمز ${response.statusCode}).',
          );
        }
        final total = response.contentLength;
        var received = 0;
        final sink = file.openWrite();
        try {
          await for (final chunk in response.stream) {
            received += chunk.length;
            sink.add(chunk);
            onProgress(
              total != null && total > 0 ? received / total : null,
            );
          }
        } finally {
          await sink.close();
        }
        onProgress(1.0);
      } finally {
        client.close();
      }
    });
    return file;
  }

  /// True when the app is allowed to install packages from itself
  /// (Android 8+ "Install unknown apps" setting for Helba).
  Future<bool> hasInstallPermission() async {
    try {
      return (await _installPermissionStatus()).isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system "Install unknown apps" settings page for Helba
  /// and returns true when the permission is granted after the user
  /// comes back. Never throws.
  Future<bool> requestInstallPermission() async {
    try {
      return (await _requestInstallPermission()).isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Hands a downloaded APK to the system installer. Returns
  /// [UpdateInstallOutcome.opened] when the installer opened (the
  /// system takes over from there), [UpdateInstallOutcome.failed]
  /// otherwise. Never throws.
  Future<UpdateInstallResult> openInstaller(io.File apk) async {
    try {
      final result = await _openFile(apk.path);
      if (result.type == ResultType.done) {
        return const UpdateInstallResult(UpdateInstallOutcome.opened);
      }
      return UpdateInstallResult(
        UpdateInstallOutcome.failed,
        'تعذّر فتح ملف التثبيت (${result.type.name}).',
      );
    } catch (e) {
      return UpdateInstallResult(
        UpdateInstallOutcome.failed,
        'تعذّر بدء التثبيت: $e',
      );
    }
  }
}
