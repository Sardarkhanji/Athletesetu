import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

enum PermissionGroup { recording, location, nearbyDevices, photos }

class PermissionOutcome {
  const PermissionOutcome(this.granted, {this.permanentlyDenied = false});
  final bool granted;
  final bool permanentlyDenied;
}

/// Thin wrapper over permission_handler, grouped by feature need.
class PermissionService {
  const PermissionService();

  List<Permission> _permissionsFor(PermissionGroup g) => switch (g) {
        PermissionGroup.recording => [Permission.camera, Permission.microphone],
        PermissionGroup.location => [Permission.locationWhenInUse],
        PermissionGroup.nearbyDevices => Platform.isAndroid
            ? [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.nearbyWifiDevices]
            : [Permission.bluetooth],
        PermissionGroup.photos => Platform.isIOS ? [Permission.photos] : <Permission>[],
      };

  Future<PermissionOutcome> request(PermissionGroup group) async {
    final perms = _permissionsFor(group);
    if (perms.isEmpty) return const PermissionOutcome(true);
    final statuses = await perms.request();
    // Microphone is optional for recording: video works muted.
    final required = group == PermissionGroup.recording ? [Permission.camera] : perms;
    final granted = required.every((p) => statuses[p]?.isGranted ?? false);
    final permanentlyDenied = required.any((p) => statuses[p]?.isPermanentlyDenied ?? false);
    return PermissionOutcome(granted, permanentlyDenied: permanentlyDenied);
  }

  Future<bool> isGranted(Permission p) => p.isGranted;

  Future<bool> openSettings() => openAppSettings();
}

final permissionServiceProvider = Provider((ref) => const PermissionService());

/// Free-space probe through the native `athletesetu/storage` channel
/// (StatFs on Android, volumeAvailableCapacityForImportantUsage on iOS).
class StorageProbe {
  static const _channel = MethodChannel('athletesetu/storage');
  static const lowThresholdBytes = 500 * 1024 * 1024;

  static Future<int?> freeBytes() async {
    try {
      final v = await _channel.invokeMethod<int>('freeBytes');
      return v;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
}

/// Re-checked whenever invalidated (e.g. after recording or clearing videos).
final freeStorageProvider = FutureProvider<int?>((ref) => StorageProbe.freeBytes());
