import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/store.dart';
import 'categories.dart';
import 'models.dart';
import 'repository.dart';

enum HealthAvailability { unsupported, installRequired, available }

class HealthServiceException implements Exception {
  final String message;
  HealthServiceException(this.message);
  @override
  String toString() => message;
}

class SyncOutcome {
  final bool ok;
  final int records;
  final Map<String, String> errors;
  const SyncOutcome(
      {required this.ok, required this.records, this.errors = const {}});
}

/// Thin abstraction over the health plugin so sync logic can be tested.
abstract class HealthSource {
  Future<void> configure();
  Future<HealthConnectSdkStatus?> sdkStatus();
  Future<bool> isAvailable();
  Future<void> install();
  bool isTypeAvailable(HealthDataType type);
  Future<bool> requestAuthorization(List<HealthDataType> types);
  Future<bool?> hasPermissions(List<HealthDataType> types);
  Future<bool> isHistoryAvailable();
  Future<bool> isHistoryAuthorized();
  Future<bool> requestHistoryAuthorization();
  Future<List<HealthDataPoint>> fetch({
    required HealthDataType type,
    required DateTime start,
    required DateTime end,
  });
  Future<void> revokePermissions();
}

class PluginHealthSource implements HealthSource {
  final Health _health = Health();

  @override
  Future<void> configure() => _health.configure();

  @override
  Future<HealthConnectSdkStatus?> sdkStatus() =>
      _health.getHealthConnectSdkStatus();

  @override
  Future<bool> isAvailable() => _health.isHealthConnectAvailable();

  @override
  Future<void> install() => _health.installHealthConnect();

  @override
  bool isTypeAvailable(HealthDataType type) =>
      _health.isDataTypeAvailable(type);

  @override
  Future<bool> requestAuthorization(List<HealthDataType> types) =>
      _health.requestAuthorization(types,
          permissions: List.filled(types.length, HealthDataAccess.READ));

  @override
  Future<bool?> hasPermissions(List<HealthDataType> types) =>
      _health.hasPermissions(types,
          permissions: List.filled(types.length, HealthDataAccess.READ));

  @override
  Future<bool> isHistoryAvailable() => _health.isHealthDataHistoryAvailable();

  @override
  Future<bool> isHistoryAuthorized() => _health.isHealthDataHistoryAuthorized();

  @override
  Future<bool> requestHistoryAuthorization() =>
      _health.requestHealthDataHistoryAuthorization();

  @override
  Future<List<HealthDataPoint>> fetch({
    required HealthDataType type,
    required DateTime start,
    required DateTime end,
  }) =>
      _health.getHealthDataFromTypes(
          types: [type], startTime: start, endTime: end);

  @override
  Future<void> revokePermissions() => _health.revokePermissions();
}

class HealthService extends ChangeNotifier {
  final AppStore store;
  final HealthRepository repository;
  final HealthSource source;
  bool _configured = false;
  bool _syncing = false;
  String? _lastError;

  HealthService({
    required this.store,
    required this.repository,
    HealthSource? source,
  }) : source = source ?? PluginHealthSource();

  static const _prefix = 'health';
  static const _retentionDays = 365 * 2;

  bool get enabled => store.prefs.getBool('${_prefix}Enabled') ?? false;
  bool get autoSync => store.prefs.getBool('${_prefix}AutoSync') ?? true;
  bool get historyRequested =>
      store.prefs.getBool('${_prefix}HistoryRequested') ?? false;
  bool get syncing => _syncing;
  String? get lastError => _lastError;

  Set<HealthCategory> get categories {
    final raw = store.prefs.getString('${_prefix}Categories');
    if (raw == null || raw.isEmpty) return defaultHealthCategories;
    final names = raw.split(',').toSet();
    final selected = {
      for (final category in HealthCategory.values)
        if (names.contains(category.name)) category,
    };
    return selected.isEmpty ? defaultHealthCategories : selected;
  }

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    await source.configure();
    _configured = true;
  }

  Future<HealthAvailability> availability() async {
    if (!Platform.isAndroid) return HealthAvailability.unsupported;
    await _ensureConfigured();
    try {
      final status = await source.sdkStatus();
      return switch (status) {
        HealthConnectSdkStatus.sdkAvailable => HealthAvailability.available,
        HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired =>
          HealthAvailability.installRequired,
        HealthConnectSdkStatus.sdkUnavailable =>
          HealthAvailability.installRequired,
        _ => HealthAvailability.unsupported,
      };
    } catch (_) {
      return HealthAvailability.unsupported;
    }
  }

  Future<void> installHealthConnect() async {
    await _ensureConfigured();
    await source.install();
  }

  Future<void> saveCategories(Set<HealthCategory> categories) async {
    await store.prefs.setString(
        '${_prefix}Categories', categories.map((c) => c.name).join(','));
    notifyListeners();
  }

  Future<void> setAutoSync(bool value) async {
    await store.prefs.setBool('${_prefix}AutoSync', value);
    notifyListeners();
  }

  Future<bool> permissionsGranted() async {
    await _ensureConfigured();
    final types = androidSupportedTypes(typesForCategories(categories));
    if (types.isEmpty) return false;
    try {
      return (await source.hasPermissions(types)) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setHistoryRequested(bool value) async {
    await store.prefs.setBool('${_prefix}HistoryRequested', value);
    notifyListeners();
  }

  Future<void> requestHistoryAccess() async {
    await _ensureConfigured();
    if (!await source.isHistoryAvailable()) {
      throw HealthServiceException(
          'Full history is not available on this Health Connect version.');
    }
    final granted = await source.requestHistoryAuthorization();
    if (!granted) {
      throw HealthServiceException(
          'Health Connect did not grant full-history access.');
    }
    await store.prefs.setBool('${_prefix}HistoryRequested', true);
    notifyListeners();
  }

  Future<void> connect({
    required Set<HealthCategory> categories,
    bool requestHistory = false,
  }) async {
    if (!Platform.isAndroid) {
      throw HealthServiceException(
          'Health Connect is only available on Android.');
    }
    final availability = await this.availability();
    if (availability == HealthAvailability.installRequired) {
      await source.install();
      throw HealthServiceException(
          'Install or update Health Connect, then tap Connect again.');
    }
    if (availability != HealthAvailability.available) {
      throw HealthServiceException(
          'Health Connect is not available on this device.');
    }

    await _ensureConfigured();
    if (categories.contains(HealthCategory.activity)) {
      try {
        final status = await Permission.activityRecognition.request();
        if (!status.isGranted) {
          _lastError =
              'Activity recognition permission was denied; step data may be empty.';
        }
      } catch (_) {}
    }

    final types = androidSupportedTypes(typesForCategories(categories));
    if (types.isEmpty) {
      throw HealthServiceException(
          'No Health Connect data types are supported on this device.');
    }
    final alreadyGranted = await source.hasPermissions(types);
    if (alreadyGranted != true) {
      final granted = await source.requestAuthorization(types);
      if (!granted) {
        throw HealthServiceException(
            'Health Connect permissions were not granted.');
      }
    }

    if (requestHistory) {
      try {
        await requestHistoryAccess();
      } catch (e) {
        _lastError = e.toString();
      }
    }

    await saveCategories(categories);
    await store.prefs.setBool('${_prefix}Enabled', true);
    notifyListeners();
    await syncNow(initial: true);
  }

  Future<void> disconnect({bool deleteData = false}) async {
    try {
      await source.revokePermissions();
    } catch (_) {}
    await store.prefs.setBool('${_prefix}Enabled', false);
    if (deleteData) await repository.deleteAll();
    notifyListeners();
  }

  Future<void> deleteAllData() async {
    await repository.deleteAll();
    notifyListeners();
  }

  Future<SyncOutcome> syncNow({bool initial = false}) async {
    if (_syncing) {
      return const SyncOutcome(
          ok: false, records: 0, errors: {'sync': 'already running'});
    }
    if (!enabled) {
      throw HealthServiceException('Health Connect is not connected.');
    }
    final availability = await this.availability();
    if (availability != HealthAvailability.available) {
      throw HealthServiceException(
          'Health Connect is not available right now.');
    }
    await _ensureConfigured();
    final types = androidSupportedTypes(typesForCategories(categories));
    if (types.isEmpty) {
      throw HealthServiceException('No enabled Health Connect data types.');
    }
    _syncing = true;
    _lastError = null;
    notifyListeners();

    final errors = <String, String>{};
    var written = 0;
    try {
      final granted = await source.hasPermissions(types);
      if (granted != true) {
        _lastError =
            'Some Health Connect permissions are missing; syncing the granted types.';
      }
      final now = DateTime.now();
      final last = await repository.lastSync();
      DateTime start;
      if (initial || last == null) {
        final fullHistory =
            historyRequested && await source.isHistoryAuthorized();
        start = fullHistory
            ? DateTime(2000)
            : now.subtract(const Duration(days: 30));
      } else {
        start = last.subtract(const Duration(days: 1));
      }

      for (final type in types) {
        if (!source.isTypeAvailable(type)) continue;
        var chunkStart = start;
        var typeRecords = 0;
        String? typeError;
        while (chunkStart.isBefore(now)) {
          final chunkEnd =
              _minDateTime(chunkStart.add(const Duration(days: 30)), now);
          try {
            final points = await source.fetch(
                type: type, start: chunkStart, end: chunkEnd);
            final records = points.map((p) => _toRecord(p, now)).toList();
            typeRecords += await repository.upsertRecords(records);
          } catch (e) {
            typeError = e.toString();
            errors[type.name] = typeError;
          }
          chunkStart = chunkEnd;
        }
        written += typeRecords;
        final stamp = DateTime.now().millisecondsSinceEpoch;
        await repository.setSyncState(
          type.name,
          lastSyncedAt: stamp,
          lastSuccessAt: typeError == null ? stamp : null,
          lastError: typeError,
        );
      }
      final stamp = DateTime.now().millisecondsSinceEpoch;
      await repository.setSyncState('__all__',
          lastSyncedAt: stamp, lastSuccessAt: stamp);
      try {
        await repository.compactOlderThan(
            now.subtract(const Duration(days: _retentionDays)));
      } catch (e) {
        errors['compaction'] = e.toString();
      }
      if (errors.isNotEmpty) {
        _lastError = errors.values.first;
      }
    } finally {
      _syncing = false;
      notifyListeners();
    }

    return SyncOutcome(ok: errors.isEmpty, records: written, errors: errors);
  }

  Future<void> syncIfDue() async {
    if (!enabled || !autoSync || _syncing) return;
    final last = await repository.lastSync();
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 15)) {
      return;
    }
    try {
      final availability = await this.availability();
      if (availability != HealthAvailability.available) return;
      await syncNow();
    } catch (_) {
      // Sync is best-effort; the UI shows the last error/status.
    }
  }

  Future<Map<String, dynamic>> status() async {
    final repo = await repository.syncStatus();
    return {
      ...repo,
      'enabled': enabled,
      'autoSync': autoSync,
      'historyRequested': historyRequested,
      'categories': [for (final c in categories) c.name],
      'availability': (await availability()).name,
      'syncing': _syncing,
      'lastError': _lastError,
    };
  }

  Future<Map<String, dynamic>> todaySummary() async {
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 2));
    final to =
        DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    return repository.overview(
      from: from.millisecondsSinceEpoch,
      to: to.millisecondsSinceEpoch,
    );
  }

  HealthRecord _toRecord(HealthDataPoint p, DateTime syncedAt) {
    final value = p.value;
    final numeric = switch (value) {
      NumericHealthValue v => v.numericValue.toDouble(),
      SkinTemperatureHealthValue v => v.temperature ?? v.temperatureDelta,
      ActivityIntensityHealthValue v => v.minutes,
      NutritionHealthValue v => v.calories,
      _ => null,
    };
    final uuid = p.uuid.isNotEmpty
        ? p.uuid
        : '${p.type.name}|${p.dateFrom.millisecondsSinceEpoch}|${p.dateTo.millisecondsSinceEpoch}|${p.sourceId}|$numeric';
    String raw = '';
    try {
      raw = jsonEncode(p.toJson());
    } catch (_) {
      raw = '{}';
    }
    return HealthRecord(
      uuid: uuid,
      type: p.type.name,
      value: numeric,
      unit: p.unit.name,
      dateFrom: p.dateFrom.millisecondsSinceEpoch,
      dateTo: p.dateTo.millisecondsSinceEpoch,
      sourceId: p.sourceId,
      sourceName: p.sourceName,
      platform: p.sourcePlatform.name,
      recordingMethod: p.recordingMethod.toInt(),
      rawJson: raw,
      syncedAt: syncedAt.millisecondsSinceEpoch,
    );
  }

  DateTime _minDateTime(DateTime a, DateTime b) => a.isBefore(b) ? a : b;
}

/// Convenience for UI widgets that need a short summary.
class HealthSummary {
  final Map<String, dynamic> data;
  const HealthSummary(this.data);

  Map<String, dynamic>? get sleep {
    final s = data['sleep'];
    return s is Map ? (s['lastNight'] as Map?)?.cast<String, dynamic>() : null;
  }

  Map<String, dynamic>? get restingHeartRate {
    final h = data['heart'];
    return h is Map
        ? (h['restingHeartRate'] as Map?)?.cast<String, dynamic>()
        : null;
  }

  double? get stepsToday {
    final a = data['activity'];
    if (a is! Map) return null;
    final points = a['stepsDaily'];
    if (points is! List || points.isEmpty) return null;
    final last = points.last;
    return last is Map ? (last['value'] as num?)?.toDouble() : null;
  }
}
