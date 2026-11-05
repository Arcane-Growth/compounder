import 'package:health/health.dart';

enum HealthCategory {
  sleep(
    'Sleep',
    'Bedtime, wake time, sleep stages and efficiency.',
    [
      HealthDataType.SLEEP_SESSION,
      HealthDataType.SLEEP_ASLEEP,
      HealthDataType.SLEEP_AWAKE,
      HealthDataType.SLEEP_AWAKE_IN_BED,
      HealthDataType.SLEEP_DEEP,
      HealthDataType.SLEEP_LIGHT,
      HealthDataType.SLEEP_OUT_OF_BED,
      HealthDataType.SLEEP_REM,
      HealthDataType.SLEEP_UNKNOWN,
    ],
    defaultEnabled: true,
  ),
  heart(
    'Heart',
    'Heart rate, resting heart rate and heart-rate variability.',
    [
      HealthDataType.HEART_RATE,
      HealthDataType.RESTING_HEART_RATE,
      HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
    ],
    defaultEnabled: true,
  ),
  activity(
    'Activity',
    'Steps, distance, calories, floors, speed and workouts.',
    [
      HealthDataType.STEPS,
      HealthDataType.DISTANCE_DELTA,
      HealthDataType.SPEED,
      HealthDataType.FLIGHTS_CLIMBED,
      HealthDataType.ACTIVE_ENERGY_BURNED,
      HealthDataType.TOTAL_CALORIES_BURNED,
      HealthDataType.BASAL_ENERGY_BURNED,
      HealthDataType.WORKOUT,
      HealthDataType.ACTIVITY_INTENSITY,
    ],
    defaultEnabled: true,
  ),
  vitals(
    'Vitals',
    'Blood oxygen, respiratory rate, temperature, blood pressure and glucose.',
    [
      HealthDataType.BLOOD_OXYGEN,
      HealthDataType.RESPIRATORY_RATE,
      HealthDataType.BODY_TEMPERATURE,
      HealthDataType.SKIN_TEMPERATURE,
      HealthDataType.BLOOD_PRESSURE_SYSTOLIC,
      HealthDataType.BLOOD_PRESSURE_DIASTOLIC,
      HealthDataType.BLOOD_GLUCOSE,
    ],
    defaultEnabled: true,
  ),
  body(
    'Body measurements',
    'Weight, height, body fat, lean mass, body water and BMI.',
    [
      HealthDataType.WEIGHT,
      HealthDataType.HEIGHT,
      HealthDataType.BODY_FAT_PERCENTAGE,
      HealthDataType.LEAN_BODY_MASS,
      HealthDataType.BODY_WATER_MASS,
      HealthDataType.BODY_MASS_INDEX,
    ],
    defaultEnabled: true,
  ),
  nutrition(
    'Nutrition & hydration',
    'Meals and water logged in other Health Connect apps. Off by default to avoid double-counting Compounder meals.',
    [
      HealthDataType.NUTRITION,
      HealthDataType.WATER,
    ],
    defaultEnabled: false,
  ),
  cycle(
    'Cycle',
    'Menstruation flow records.',
    [
      HealthDataType.MENSTRUATION_FLOW,
    ],
    defaultEnabled: false,
  );

  const HealthCategory(this.label, this.description, this.types,
      {required this.defaultEnabled});

  final String label;
  final String description;
  final List<HealthDataType> types;
  final bool defaultEnabled;

  static HealthCategory? forType(HealthDataType type) {
    for (final category in HealthCategory.values) {
      if (category.types.contains(type)) return category;
    }
    return null;
  }
}

Set<HealthCategory> get defaultHealthCategories => {
      for (final category in HealthCategory.values)
        if (category.defaultEnabled) category,
    };

List<HealthDataType> typesForCategories(Iterable<HealthCategory> categories) {
  final seen = <HealthDataType>{};
  final types = <HealthDataType>[];
  for (final category in categories) {
    for (final type in category.types) {
      if (seen.add(type)) types.add(type);
    }
  }
  return types;
}

List<HealthDataType> androidSupportedTypes(Iterable<HealthDataType> types) =>
    types.where(dataTypeKeysAndroid.contains).toList();

enum HealthAggregation { sum, average, minMax, latest, list }

class HealthMetricInfo {
  final String label;
  final String unit;
  final HealthAggregation aggregation;

  const HealthMetricInfo(this.label, this.unit, this.aggregation);
}

const Map<String, HealthMetricInfo> healthMetrics = {
  'HEART_RATE': HealthMetricInfo('Heart rate', 'bpm', HealthAggregation.minMax),
  'RESTING_HEART_RATE':
      HealthMetricInfo('Resting heart rate', 'bpm', HealthAggregation.latest),
  'HEART_RATE_VARIABILITY_RMSSD': HealthMetricInfo(
      'Heart-rate variability', 'ms', HealthAggregation.latest),
  'STEPS': HealthMetricInfo('Steps', 'count', HealthAggregation.sum),
  'DISTANCE_DELTA': HealthMetricInfo('Distance', 'm', HealthAggregation.sum),
  'SPEED': HealthMetricInfo('Speed', 'm/s', HealthAggregation.average),
  'FLIGHTS_CLIMBED':
      HealthMetricInfo('Floors climbed', 'count', HealthAggregation.sum),
  'ACTIVE_ENERGY_BURNED':
      HealthMetricInfo('Active calories', 'kcal', HealthAggregation.sum),
  'TOTAL_CALORIES_BURNED':
      HealthMetricInfo('Total calories', 'kcal', HealthAggregation.sum),
  'BASAL_ENERGY_BURNED':
      HealthMetricInfo('Basal calories', 'kcal', HealthAggregation.sum),
  'WORKOUT': HealthMetricInfo('Workouts', 'sessions', HealthAggregation.list),
  'ACTIVITY_INTENSITY':
      HealthMetricInfo('Activity intensity', 'minutes', HealthAggregation.sum),
  'BLOOD_OXYGEN':
      HealthMetricInfo('Blood oxygen', '%', HealthAggregation.latest),
  'RESPIRATORY_RATE': HealthMetricInfo(
      'Respiratory rate', 'breaths/min', HealthAggregation.latest),
  'BODY_TEMPERATURE':
      HealthMetricInfo('Body temperature', '°C', HealthAggregation.latest),
  'SKIN_TEMPERATURE':
      HealthMetricInfo('Skin temperature', '°C', HealthAggregation.latest),
  'BLOOD_PRESSURE_SYSTOLIC':
      HealthMetricInfo('Systolic pressure', 'mmHg', HealthAggregation.list),
  'BLOOD_PRESSURE_DIASTOLIC':
      HealthMetricInfo('Diastolic pressure', 'mmHg', HealthAggregation.list),
  'BLOOD_GLUCOSE':
      HealthMetricInfo('Blood glucose', 'mg/dL', HealthAggregation.list),
  'WEIGHT': HealthMetricInfo('Weight', 'kg', HealthAggregation.latest),
  'HEIGHT': HealthMetricInfo('Height', 'm', HealthAggregation.latest),
  'BODY_FAT_PERCENTAGE':
      HealthMetricInfo('Body fat', '%', HealthAggregation.latest),
  'LEAN_BODY_MASS':
      HealthMetricInfo('Lean body mass', 'kg', HealthAggregation.latest),
  'BODY_WATER_MASS':
      HealthMetricInfo('Body water mass', 'kg', HealthAggregation.latest),
  'BODY_MASS_INDEX': HealthMetricInfo('BMI', '', HealthAggregation.latest),
  'NUTRITION': HealthMetricInfo('Nutrition', 'kcal', HealthAggregation.sum),
  'WATER': HealthMetricInfo('Water', 'L', HealthAggregation.sum),
  'MENSTRUATION_FLOW':
      HealthMetricInfo('Menstruation flow', '', HealthAggregation.list),
  'SLEEP_ASLEEP':
      HealthMetricInfo('Sleep (asleep)', 'min', HealthAggregation.sum),
  'SLEEP_DEEP': HealthMetricInfo('Deep sleep', 'min', HealthAggregation.sum),
  'SLEEP_LIGHT': HealthMetricInfo('Light sleep', 'min', HealthAggregation.sum),
  'SLEEP_REM': HealthMetricInfo('REM sleep', 'min', HealthAggregation.sum),
  'SLEEP_AWAKE':
      HealthMetricInfo('Awake during sleep', 'min', HealthAggregation.sum),
  'SLEEP_UNKNOWN':
      HealthMetricInfo('Sleep (unknown stage)', 'min', HealthAggregation.sum),
  'SLEEP_IN_BED': HealthMetricInfo('Time in bed', 'min', HealthAggregation.sum),
  'SLEEP_OUT_OF_BED':
      HealthMetricInfo('Out of bed', 'min', HealthAggregation.sum),
  'SLEEP_AWAKE_IN_BED':
      HealthMetricInfo('Awake in bed', 'min', HealthAggregation.sum),
  'SLEEP_SESSION':
      HealthMetricInfo('Sleep session', 'min', HealthAggregation.sum),
};

HealthMetricInfo metricInfo(String type) =>
    healthMetrics[type] ??
    HealthMetricInfo(
        type.replaceAll('_', ' ').toLowerCase(), '', HealthAggregation.list);

bool isSleepType(String type) => type.startsWith('SLEEP_');

String metricLabel(String type) => metricInfo(type).label;

String metricUnit(String type) => metricInfo(type).unit;

HealthAggregation metricAggregation(String type) =>
    metricInfo(type).aggregation;
