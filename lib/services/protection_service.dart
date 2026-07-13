import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const String _supabaseUrl =
    'https://qjtnnxqwgytjysvxztnu.supabase.co';

const String _supabaseKey =
    'sb_publishable_8f2VbpP5Qf30BO2jYqUV7Q_tCGVw26Z';

const double _warningRangeMeters = 200.0;

Future<void> initializeProtectionService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: protectionServiceEntryPoint,
      autoStart: false,
      autoStartOnBoot: false,
      isForegroundMode: true,
      initialNotificationTitle: 'Be Gharama protection',
      initialNotificationContent: 'Starting camera protection…',
      foregroundServiceNotificationId: 1001,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: protectionServiceEntryPoint,
    ),
  );
}

@pragma('vm:entry-point')
Future<void> protectionServiceEntryPoint(
  ServiceInstance service,
) async {
  DartPluginRegistrant.ensureInitialized();

  final SupabaseClient database = SupabaseClient(
    _supabaseUrl,
    _supabaseKey,
  );

  final AudioPlayer beepPlayer = AudioPlayer();

  StreamSubscription<Position>? positionSubscription;
  Timer? beepTimer;

  List<Map<String, dynamic>> cameras = [];

  bool warningActive = false;
  double? nearestDistance;
  Map<String, dynamic>? nearestCamera;

  Future<void> updateNotification({
    required String title,
    required String content,
  }) async {
    if (service is AndroidServiceInstance) {
      await service.setForegroundNotificationInfo(
        title: title,
        content: content,
      );
    }
  }

  Future<void> loadCameras() async {
    try {
      final response = await database
          .from('speed_cameras')
          .select();

      cameras = List<Map<String, dynamic>>.from(response);

      await updateNotification(
        title: 'Be Gharama protection',
        content: '${cameras.length} cameras loaded',
      );
    } catch (error) {
      await updateNotification(
        title: 'Be Gharama protection',
        content: 'Could not load camera data',
      );

      print('BACKGROUND CAMERA LOAD ERROR: $error');
    }
  }

  double calculateNearestCameraDistance(
    Position position,
  ) {
    if (cameras.isEmpty) {
      nearestCamera = null;
      return double.infinity;
    }

    const distanceCalculator = Distance();

    final userPoint = LatLng(
      position.latitude,
      position.longitude,
    );

    double closestDistance = double.infinity;
    Map<String, dynamic>? closestCamera;

    for (final camera in cameras) {
      final latitude =
          (camera['latitude'] as num).toDouble();

      final longitude =
          (camera['longitude'] as num).toDouble();

      final cameraPoint = LatLng(latitude, longitude);

      final distance = distanceCalculator.as(
        LengthUnit.Meter,
        userPoint,
        cameraPoint,
      );

      if (distance < closestDistance) {
        closestDistance = distance;
        closestCamera = camera;
      }
    }

    nearestCamera = closestCamera;
    return closestDistance;
  }

  Future<void> playWarningBeep() async {
    const int sampleRate = 44100;
    const double frequency = 880.0;
    const double durationSeconds = 0.15;
    const int amplitude = 16000;

    final int sampleCount =
        (sampleRate * durationSeconds).round();

    final BytesBuilder bytes = BytesBuilder();

    void writeString(String value) {
      bytes.add(value.codeUnits);
    }

    void writeInt16(int value) {
      bytes.add([
        value & 0xff,
        (value >> 8) & 0xff,
      ]);
    }

    void writeInt32(int value) {
      bytes.add([
        value & 0xff,
        (value >> 8) & 0xff,
        (value >> 16) & 0xff,
        (value >> 24) & 0xff,
      ]);
    }

    final int dataSize = sampleCount * 2;

    writeString('RIFF');
    writeInt32(36 + dataSize);
    writeString('WAVE');

    writeString('fmt ');
    writeInt32(16);
    writeInt16(1);
    writeInt16(1);
    writeInt32(sampleRate);
    writeInt32(sampleRate * 2);
    writeInt16(2);
    writeInt16(16);

    writeString('data');
    writeInt32(dataSize);

    for (int i = 0; i < sampleCount; i++) {
      final double time = i / sampleRate;

      final int sample = (
        math.sin(
          2 * math.pi * frequency * time,
        ) *
        amplitude
      ).round();

      writeInt16(sample);
    }

    await beepPlayer.stop();
    await beepPlayer.play(
      BytesSource(bytes.toBytes()),
    );
  }

  void stopWarning() {
    beepTimer?.cancel();
    beepTimer = null;
    warningActive = false;
  }

  void startWarning() {
    if (warningActive) return;

    warningActive = true;

    playWarningBeep();

    beepTimer = Timer.periodic(
      const Duration(milliseconds: 1200),
      (_) {
        if (warningActive) {
          playWarningBeep();
        }
      },
    );
  }

  service.on('stopService').listen((event) async {
    stopWarning();

    await positionSubscription?.cancel();
    positionSubscription = null;

    await beepPlayer.stop();
    await beepPlayer.dispose();

    await service.stopSelf();
  });

  await loadCameras();

  AndroidSettings locationSettings =
      AndroidSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 5,
    intervalDuration: Duration(seconds: 1),
  );

  positionSubscription = Geolocator.getPositionStream(
    locationSettings: locationSettings,
  ).listen(
    (Position position) async {
      nearestDistance =
          calculateNearestCameraDistance(position);

      final double speedKmh =
          math.max(0, position.speed * 3.6);

      final bool cameraIsNear =
          nearestDistance != null &&
          nearestDistance!.isFinite &&
          nearestDistance! <= _warningRangeMeters;

      if (cameraIsNear) {
        startWarning();

        final cameraName =
            nearestCamera?['name']?.toString() ??
            'Speed camera';

        final speedLimit =
            nearestCamera?['speed_limit']?.toString() ??
            '--';

        await updateNotification(
          title: '⚠ $cameraName ahead',
          content:
              '${nearestDistance!.round()} m · '
              'Limit $speedLimit km/h · '
              'Speed ${speedKmh.round()} km/h',
        );
      } else {
        stopWarning();

        await updateNotification(
          title: 'Be Gharama protection',
          content:
              'Protection active · '
              '${speedKmh.round()} km/h',
        );
      }

      service.invoke(
        'protectionUpdate',
        {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'speedKmh': speedKmh,
          'cameraDistance': nearestDistance,
          'warningActive': cameraIsNear,
          'cameraName': nearestCamera?['name'],
          'speedLimit': nearestCamera?['speed_limit'],
        },
      );
    },
    onError: (Object error) async {
      stopWarning();

      await updateNotification(
        title: 'Be Gharama protection',
        content: 'Location tracking error',
      );

      print('BACKGROUND LOCATION ERROR: $error');
    },
  );
}