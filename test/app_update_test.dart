import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_file_plus/open_file_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:helba/src/app_update.dart';

Map<String, dynamic> releaseJson({
  String tag = 'build-99',
  List<Map<String, dynamic>>? assets,
}) =>
    {
      'tag_name': tag,
      'name': 'Helba build 99',
      'assets': assets ??
          [
            {
              'name': 'helba-android-apk.apk',
              'browser_download_url':
                  'https://example.com/helba-99.apk',
            },
          ],
    };

void main() {
  group('parseBuildTag', () {
    test('parses build-<N> tags', () {
      expect(parseBuildTag('build-98'), 98);
      expect(parseBuildTag('build-0'), 0);
      expect(parseBuildTag('build-1000000'), 1000000);
      expect(parseBuildTag('  build-99  '), 99);
    });

    test('rejects malformed tags', () {
      expect(parseBuildTag(null), isNull);
      expect(parseBuildTag(''), isNull);
      expect(parseBuildTag('v1.0'), isNull);
      expect(parseBuildTag('build-'), isNull);
      expect(parseBuildTag('build-abc'), isNull);
      expect(parseBuildTag('build-9a'), isNull);
      expect(parseBuildTag('Build-99'), isNull);
      expect(parseBuildTag('build-99-extra'), isNull);
    });
  });

  group('isUpdateAvailable', () {
    test('newer build is an update', () {
      expect(
        isUpdateAvailable(installedBuild: 98, latestBuild: 99),
        isTrue,
      );
      expect(
        isUpdateAvailable(installedBuild: 0, latestBuild: 1),
        isTrue,
      );
    });

    test('same or older build is not an update', () {
      expect(
        isUpdateAvailable(installedBuild: 99, latestBuild: 99),
        isFalse,
      );
      expect(
        isUpdateAvailable(installedBuild: 100, latestBuild: 99),
        isFalse,
      );
      expect(
        isUpdateAvailable(installedBuild: 98, latestBuild: null),
        isFalse,
      );
    });
  });

  group('shouldPromptForUpdate', () {
    test('prompts when never dismissed', () {
      const update = UpdateInfo(
        buildNumber: 99,
        tag: 'build-99',
        downloadUrl: 'https://example.com/helba-99.apk',
      );
      expect(
        shouldPromptForUpdate(update: update, dismissedBuild: null),
        isTrue,
      );
    });

    test('does not nag for the dismissed build (or an older one)', () {
      const update = UpdateInfo(
        buildNumber: 99,
        tag: 'build-99',
        downloadUrl: 'https://example.com/helba-99.apk',
      );
      expect(
        shouldPromptForUpdate(update: update, dismissedBuild: 99),
        isFalse,
      );
      expect(
        shouldPromptForUpdate(update: update, dismissedBuild: 100),
        isFalse,
      );
      expect(
        shouldPromptForUpdate(update: update, dismissedBuild: 98),
        isTrue,
      );
    });
  });

  group('selectApkDownloadUrl', () {
    test('picks the first .apk asset', () {
      expect(
        selectApkDownloadUrl(releaseJson()),
        'https://example.com/helba-99.apk',
      );
    });

    test('skips non-apk assets and returns null when none exist', () {
      expect(
        selectApkDownloadUrl(releaseJson(assets: [
          {'name': 'notes.txt', 'browser_download_url': 'https://x/n.txt'},
          {'name': 'helba.apk', 'browser_download_url': 'https://x/h.apk'},
        ])),
        'https://x/h.apk',
      );
      expect(
        selectApkDownloadUrl(releaseJson(assets: [
          {'name': 'notes.txt', 'browser_download_url': 'https://x/n.txt'},
        ])),
        isNull,
      );
      expect(selectApkDownloadUrl({}), isNull);
      expect(selectApkDownloadUrl({'assets': 'not-a-list'}), isNull);
    });
  });

  group('parseRelease', () {
    test('parses a full release payload', () {
      final info = parseRelease(releaseJson());
      expect(info, isNotNull);
      expect(info!.buildNumber, 99);
      expect(info.tag, 'build-99');
      expect(info.downloadUrl, 'https://example.com/helba-99.apk');
    });

    test('returns null for a bad tag or a missing APK asset', () {
      expect(parseRelease(releaseJson(tag: 'v1.0')), isNull);
      expect(parseRelease(releaseJson(assets: [])), isNull);
    });
  });

  group('AppUpdateStore (memory)', () {
    test('round-trips last-check time and dismissed build', () async {
      final backing = <String, String>{};
      final store = AppUpdateStore.memory(backing);
      expect(await store.lastCheck(), isNull);
      expect(await store.dismissedBuild(), isNull);
      final when = DateTime(2026, 11, 6, 14, 0);
      await store.saveLastCheck(when);
      await store.saveDismissedBuild(99);
      expect(await store.lastCheck(), when);
      expect(await store.dismissedBuild(), 99);
    });
  });

  group('AppUpdateChecker.checkForUpdate', () {
    test('returns the update when a newer build is published', () async {
      var calls = 0;
      final checker = AppUpdateChecker(
        store: AppUpdateStore.memory({}),
        clientFactory: () => MockClient((request) async {
          calls++;
          expect(request.url.toString(), latestReleaseUrl);
          return http.Response(jsonEncode(releaseJson()), 200);
        }),
      );
      final update = await checker.checkForUpdate(installedBuild: 98);
      expect(update, isNotNull);
      expect(update!.buildNumber, 99);
      expect(calls, 1);
    });

    test('returns null when the installed build is current', () async {
      final checker = AppUpdateChecker(
        store: AppUpdateStore.memory({}),
        clientFactory: () => MockClient((request) async =>
            http.Response(jsonEncode(releaseJson(tag: 'build-98')), 200)),
      );
      expect(
        await checker.checkForUpdate(installedBuild: 98),
        isNull,
      );
    });

    test('silently skips on API errors, bad JSON and transport failure',
        () async {
      Future<UpdateInfo?> runWith(http.Client client) =>
          AppUpdateChecker(
            store: AppUpdateStore.memory({}),
            clientFactory: () => client,
          ).checkForUpdate(installedBuild: 98);

      expect(
        await runWith(MockClient(
            (request) async => http.Response('not found', 404))),
        isNull,
      );
      expect(
        await runWith(
            MockClient((request) async => http.Response('not json', 200))),
        isNull,
      );
      expect(
        await runWith(MockClient(
            (request) async => throw io.SocketException('no network'))),
        isNull,
      );
      expect(
        await runWith(MockClient((request) async =>
            http.Response(jsonEncode(releaseJson(tag: 'weird')), 200))),
        isNull,
      );
    });

    test('checks at most once per day; force bypasses the throttle',
        () async {
      var calls = 0;
      final store = AppUpdateStore.memory({});
      AppUpdateChecker make() => AppUpdateChecker(
            store: store,
            clientFactory: () => MockClient((request) async {
              calls++;
              return http.Response(jsonEncode(releaseJson()), 200);
            }),
          );
      // First check hits the API and records the time.
      expect((await make().checkForUpdate(installedBuild: 98))?.buildNumber,
          99);
      expect(calls, 1);
      // Second check within the day is skipped silently.
      expect(await make().checkForUpdate(installedBuild: 98), isNull);
      expect(calls, 1);
      // Forced check goes through again.
      expect(
          (await make().checkForUpdate(installedBuild: 98, force: true))
              ?.buildNumber,
          99);
      expect(calls, 2);
    });

    test('a failed check does not consume the daily slot', () async {
      var calls = 0;
      final store = AppUpdateStore.memory({});
      AppUpdateChecker make() => AppUpdateChecker(
            store: store,
            clientFactory: () => MockClient((request) async {
              calls++;
              return http.Response('error', 500);
            }),
          );
      expect(await make().checkForUpdate(installedBuild: 98), isNull);
      expect(await make().checkForUpdate(installedBuild: 98), isNull);
      expect(calls, 2);
      expect(await store.lastCheck(), isNull);
    });
  });

  group('AppUpdateChecker.downloadApk', () {
    test('writes the APK bytes and reports progress', () async {
      final bytes = List<int>.generate(1000, (i) => i % 256);
      final dir = await io.Directory.systemTemp.createTemp('helba-update-');
      try {
        const update = UpdateInfo(
          buildNumber: 99,
          tag: 'build-99',
          downloadUrl: 'https://example.com/helba-99.apk',
        );
        final seen = <double?>[];
        final checker = AppUpdateChecker(
          store: AppUpdateStore.memory({}),
          clientFactory: () => MockClient((request) async =>
              http.Response.bytes(bytes, 200)),
        );
        final file = await checker.downloadApk(
          update,
          onProgress: seen.add,
          targetDir: dir,
        );
        expect(await file.readAsBytes(), bytes);
        expect(file.path, contains('helba-99.apk'));
        expect(seen, contains(1.0));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('throws on HTTP failure', () async {
      const update = UpdateInfo(
        buildNumber: 99,
        tag: 'build-99',
        downloadUrl: 'https://example.com/helba-99.apk',
      );
      final dir = await io.Directory.systemTemp.createTemp('helba-update-');
      try {
        final checker = AppUpdateChecker(
          store: AppUpdateStore.memory({}),
          clientFactory: () => MockClient(
              (request) async => http.Response('nope', 404)),
        );
        await expectLater(
          checker.downloadApk(update, onProgress: (_) {}, targetDir: dir),
          throwsA(isA<io.HttpException>()),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('AppUpdateChecker install flow', () {
    AppUpdateChecker make({
      PermissionStatus status = PermissionStatus.granted,
      PermissionStatus afterRequest = PermissionStatus.granted,
      OpenResult? openResult,
      bool openThrows = false,
    }) =>
        AppUpdateChecker(
          store: AppUpdateStore.memory({}),
          installPermissionStatus: () async => status,
          requestInstallPermission: () async => afterRequest,
          openFile: (path) async {
            if (openThrows) throw Exception('open failed');
            return openResult ?? OpenResult();
          },
        );

    test('opens the installer when permission is granted', () async {
      final checker = make();
      expect(await checker.hasInstallPermission(), isTrue);
      final file = io.File('/tmp/helba-99.apk');
      final result = await checker.openInstaller(file);
      expect(result.outcome, UpdateInstallOutcome.opened);
    });

    test('reports needsPermission when the install gate is off', () async {
      final checker = make(status: PermissionStatus.denied);
      expect(await checker.hasInstallPermission(), isFalse);
      expect(await checker.requestInstallPermission(), isTrue);
    });

    test('requestInstallPermission reports a still-denied gate', () async {
      final checker = make(
        status: PermissionStatus.denied,
        afterRequest: PermissionStatus.denied,
      );
      expect(await checker.requestInstallPermission(), isFalse);
    });

    test('failed open returns a failed result with a message', () async {
      final checker = make(
        openResult: OpenResult(
          type: ResultType.error,
          message: 'no app to open',
        ),
      );
      final result = await checker.openInstaller(io.File('/tmp/x.apk'));
      expect(result.outcome, UpdateInstallOutcome.failed);
      expect(result.message, isNotNull);
    });

    test('an open that throws returns a failed result, never throws',
        () async {
      final checker = make(openThrows: true);
      final result = await checker.openInstaller(io.File('/tmp/x.apk'));
      expect(result.outcome, UpdateInstallOutcome.failed);
    });
  });
}
