import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fimber/fimber.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trios/mod_manager/mod_manager_logic.dart';
import 'package:trios/models/mod_info.dart';
import 'package:trios/models/mod_variant.dart';
import 'package:trios/trios/settings/settings.dart';
import 'package:trios/trios/trios_theme.dart';
import 'package:trios/utils/extensions.dart';
import 'package:trios/utils/platform_paths.dart';
import 'package:trios/utils/util.dart';

import '../models/enabled_mods.dart';

// part 'generated/app_state.g.dart';

class AppState {
  static TriOSTheme theme = TriOSTheme();
  static final selfUpdateDownloadProgress =
      StateProvider<double?>((ref) => null);
  static final isLoadingLog = StateProvider<bool>((ref) => false);

  static final modVariants = FutureProvider<List<ModVariant>>((ref) async {
    final gamePath =
        ref.read(appSettings.select((value) => value.gameDir))?.toDirectory();
    if (gamePath == null) {
      return [];
    }

    return await getModsInFolder(gamePath.resolve("mods").toDirectory());
  });

  static StreamController<File>? _enabledModsWatcher;

  static final enabledMods = FutureProvider<EnabledMods>((ref) async {
    final modsFolder =
        ref.read(appSettings.select((value) => value.modsDir))?.toDirectory();

    if (modsFolder == null || !modsFolder.existsSync()) {
      return const EnabledMods({});
    } else {
      final enabledModsFile = getEnabledModsFile(modsFolder);
      if (!enabledModsFile.existsSync()) {
        return const EnabledMods({});
      }

      if (_enabledModsWatcher == null) {
        _enabledModsWatcher = StreamController<File>();
        _enabledModsWatcher?.stream.listen((event) {
          ref.invalidateSelf();
        });

        pollFileForModification(enabledModsFile, _enabledModsWatcher!);
      }

      var enabledMods = await getEnabledMods(modsFolder);
      return enabledMods;
    }
  });

  static final enabledModIds = FutureProvider<List<String>>((ref) async {
    return ref.watch(enabledMods).value?.enabledMods.toList() ?? [];
  });

  static final starsectorVersion = FutureProvider<String?>((ref) async {
    final gamePath = ref
        .read(appSettings.select((value) => value.gameDir))
        ?.toDirectory();
    if (gamePath == null) {
      return null;
    }
    try {
      final versionInLog = await readStarsectorVersionFromLog(gamePath);
      if (versionInLog != null) {
        // If found in log, update the last saved version
        ref
            .read(appSettings.notifier)
            .update((s) => s.copyWith(lastStarsectorVersion: versionInLog));
        return versionInLog;
      } else {
        // Fallback to last saved version
        return ref
            .read(appSettings.select((value) => value.lastStarsectorVersion));
      }
    } catch (e, stack) {
      Fimber.w("Failed to read starsector version from log",
          ex: e, stacktrace: stack);
      return ref
          .read(appSettings.select((value) => value.lastStarsectorVersion));
    }
  });
}

Future<String?> readStarsectorVersionFromLog(Directory gamePath) async {
  const versionContains = r"Starting Starsector";
  final versionRegex = RegExp(r"Starting Starsector (.*) launcher");
  final logfile = utf8.decode(
      getLogPath(gamePath)
          .readAsBytesSync()
          .toList(),
      allowMalformed: true);
  for (var line in logfile.split("\n")) {
    if (line.contains(versionContains)) {
      try {
        final version = versionRegex.firstMatch(line)!.group(1);
        if (version == null) {
          continue;
        }

        return version;
      } catch (_) {
        continue;
      }
    }
  }

  return null;
}

/// Initialized in main.dart
late SharedPreferences sharedPrefs;

var currentFileHandles = 0;
var maxFileHandles = 2000;

Future<T> withFileHandleLimit<T>(Future<T> Function() function) async {
  while (currentFileHandles + 1 > maxFileHandles) {
    Fimber.v(
        "Waiting for file handles to free up. Current file handles: $currentFileHandles");
    await Future.delayed(const Duration(milliseconds: 100));
  }
  currentFileHandles++;
  try {
    return await function();
  } finally {
    currentFileHandles--;
  }
}