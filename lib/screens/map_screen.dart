// ignore_for_file: file_names

import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart'; // Used for Distance calculations
import 'package:speed_camera_app_2/Services/Supabase_service.dart'; 
import 'package:speed_camera_app_2/Config/map_style.dart'; // Your TomTom Style String
import 'dart:async';
import 'package:maplibre_gl/maplibre_gl.dart' as mgl; // Native GPU Engine
import 'package:audioplayers/audioplayers.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';


class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with WidgetsBindingObserver {
  final SupabaseService _dbService = SupabaseService(); 
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  
  LatLng? _currentLocation;
  mgl.MapLibreMapController? _mapController;
  
  bool _appIsVisible = true;
  bool _isLoading = false;
  bool _isEditMode = false;
  bool _isTrackingAverageSpeed = false;
  bool _isCameraLocked = false; 
  final bool _isWarningEnabled = true;
  bool _isMapReady = false; 
  bool _isStyleLoaded = false;
  bool _autoStartProtectionEnabled = false;
  

  final double maxSpeedKmh = 300.0; // 300 KM/H

  StreamSubscription<Position>? _positionStream;
  Position? _lastSpeedPosition;
  final Queue<Position> _positionHistory = Queue<Position>(); 

  String _selectedfacing = 'back'; // Default facing direction for new cameras
  DateTime? _entryTime;
  LatLng? _entryCameraPoint;
  // ignore: unused_field
  double _liveAverageSpeed = 0.0;
  double _calculatedSpeedKmh = 0.0;
  double trustedSpeedKmh = 0.0;
  double? _nearestCameraDistanceMeters;
  double? _displayedCameraDistanceMeters;
  double? _previousNearestCameraDistanceMeters;
  double? _closestDistanceToCurrentCameraMeters;
  bool _hasPassedNearestCamera = false;

  DateTime? _displayedDistanceReachedZeroAt;
  Timer? _distancePredictionTimer;
  DateTime? _lastDistanceGpsUpdateTime;
  double? _lastRealCameraDistanceMeters;

  final AudioPlayer _beepPlayer = AudioPlayer();
  Timer? _beepTimer;
  bool _isBeepingActive = false;

  final double _minPanelExtent = 0.12;      
  final double _maxPanelExtent = 0.50; 
  double _currentPanelHeight = 0.0;
  static const double _cameraWarningRangeMeters = 200.0;


  // Form Field Controllers
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _streetController = TextEditingController();
  final TextEditingController _speedController = TextEditingController(text: "100");
  final TextEditingController _latController = TextEditingController();
  final TextEditingController _lngController = TextEditingController();
  // final String _selectedfacing = 'back';
  
  // Track loaded database cameras locally to match taps to data indices
  List<Map<String, dynamic>> _rawCameraData = [];

  double _readDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.parse(value.toString());
  }

  int _readInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.parse(value.toString());
  }

  double _angleDifference(double angle1, double angle2) {
    final double difference = (angle1 - angle2).abs() % 360;
    return difference > 180 ? 360 - difference : difference;
  }

  bool _isCameraInFrontOfDriver(Position userPosition, LatLng cameraPoint) {
  final double heading = userPosition.heading;

  if (!heading.isFinite || heading < 0) {
    return true;
  }

  const Distance distanceCalculator = Distance();

  final double bearingToCamera = distanceCalculator.bearing(
    LatLng(userPosition.latitude, userPosition.longitude),
    cameraPoint,
  );

  final double difference = _angleDifference(heading, bearingToCamera);

  return difference <= 70.0;
}

  bool _isCameraFacingDriver(Position userPosition, LatLng cameraPoint, String facing) {
    final double heading = userPosition.heading;

    if (!heading.isFinite || heading < 0) {
      return true;
    }

    const Distance distanceCalculator = Distance();

    final double bearingToCamera = distanceCalculator.bearing(
      LatLng(userPosition.latitude, userPosition.longitude),
      cameraPoint,
    );

    final double difference = _angleDifference(heading, bearingToCamera);

    if (facing == 'front') {
      return difference <= 70.0;
    }

    if (facing == 'back') {
      return difference <= 70.0;
    }

    return true;
  }

  double _calculateLiveSpeedKmh({
    required Position position,
    required double distanceTraveledMeters,
  }) {
    final gpsSpeedKmh = position.speed * 3.6;
    if (gpsSpeedKmh.isFinite && gpsSpeedKmh > 1.0) {
      return gpsSpeedKmh;
    }

    final secondsPassed =
        position.timestamp.difference(_entryTime!).inMilliseconds / 1000;
    if (secondsPassed > 0) {
      return (distanceTraveledMeters / secondsPassed) * 3.6;
    }

    final fallbackSecondsPassed =
        DateTime.now().difference(_entryTime!).inMilliseconds / 1000;
    if (fallbackSecondsPassed > 0) {
      return (distanceTraveledMeters / fallbackSecondsPassed) * 3.6;
    }

    return 0.0;
  }

  // ignore: unused_element
  _isPositionTrusted(Position newPosition){
    for (int i = 0; i < _positionHistory.length; i++) {
      final Position oldPosition = _positionHistory.elementAt(i);
      final double distance = Distance().as(
        LengthUnit.Meter,
        LatLng(oldPosition.latitude, oldPosition.longitude),
        LatLng(newPosition.latitude, newPosition.longitude),
      );
      debugPrint("Distance from history point $i: ${distance.toStringAsFixed(2)} meters");
    }
    return true;
  }
  
    double _calculateDistance(Position previous, Position current) {
      return const Distance().as(
        LengthUnit.Meter,
        LatLng(previous.latitude, previous.longitude),
        LatLng(current.latitude, current.longitude),
      );
    }

    double _calculateSpeed(double distanceMeters, double secondsPassed) {
      return (distanceMeters / secondsPassed) * 3.6;
    }

  bool _isSpeedReadingValid (Position previous, Position current, double calculatedSpeedKmh) { 
    final double distance = Distance().as( 
      LengthUnit.Meter, LatLng(previous.latitude, previous.longitude), 
      LatLng(current.latitude, current.longitude), 
    ); 
    if (current.accuracy > 10.0) return false;
    
    if (current.timestamp.difference(previous.timestamp).inMilliseconds < 500) return false;
    
    if (calculatedSpeedKmh > maxSpeedKmh) return false;
    
    if (distance < 5.0) return false;

    if (current.speed < 1.0) return false;
    
  return true; 
  }
      
  double _calculateCurrentSpeedKmh(Position position) {
    
    final gpsSpeedKmh = position.speed * 3.6;
    final previousPosition = _lastSpeedPosition;

    if (previousPosition == null) {
      return gpsSpeedKmh.isFinite && gpsSpeedKmh > 1.0
      ? gpsSpeedKmh
      : _calculatedSpeedKmh;
    }

    final secondsPassed = position.timestamp.difference(previousPosition.timestamp).inMilliseconds /1000;

    if (secondsPassed <= 0) {
      return gpsSpeedKmh.isFinite && gpsSpeedKmh > 1.0
      ? gpsSpeedKmh
      : _calculatedSpeedKmh;
    }

    final distanceMeters = _calculateDistance(
      previousPosition,
      position,
    );

    final calculatedSpeedKmh = _calculateSpeed(
      distanceMeters, 
      secondsPassed
    );

    double trustedSpeedKmh;

    if (!_isSpeedReadingValid(previousPosition, position, calculatedSpeedKmh)) {
      trustedSpeedKmh = _calculatedSpeedKmh;
    } else {
      trustedSpeedKmh = gpsSpeedKmh;
    }
    
    return trustedSpeedKmh;
  }

  double _calculateAverageRecentSpeedKmh() {
  if (_positionHistory.length < 2) return _calculatedSpeedKmh;

  final positions = _positionHistory.toList();
  final int startIndex = positions.length > 10 ? positions.length - 10 : 0;

  double totalSpeed = 0.0;
  int validReadings = 0;

  for (int i = startIndex + 1; i < positions.length; i++) {
    final previous = positions[i - 1];
    final current = positions[i];

    final secondsPassed =
        current.timestamp.difference(previous.timestamp).inMilliseconds / 1000;

    if (secondsPassed <= 0) continue;

    const Distance distanceCalculator = Distance();

    final distanceMeters = distanceCalculator.as(
      LengthUnit.Meter,
      LatLng(previous.latitude, previous.longitude),
      LatLng(current.latitude, current.longitude),
    );

    final speedKmh = (distanceMeters / secondsPassed) * 3.6;

    if (speedKmh.isFinite && speedKmh >= 0 && speedKmh <= 180) {
      totalSpeed += speedKmh;
      validReadings++;
    }
  }

  if (validReadings == 0) return _calculatedSpeedKmh;

  return totalSpeed / validReadings;
}

  Map<String, dynamic>? _activeCamera;
  
  double? _calculateNearestCameraDistanceMeters(Position userPosition) {
    if (_rawCameraData.isEmpty) return null;

    const Distance distanceCalculator = Distance();
    final userLatLng = LatLng(userPosition.latitude, userPosition.longitude);
    double? nearestDistance;
    Map<String, dynamic>? nearestCamera;

    for (final camera in _rawCameraData) {
      final cameraPoint = LatLng(
        _readDouble(camera['latitude']),
        _readDouble(camera['longitude']),
      );

      final String facing = camera['facing']?.toString() ?? 'back';

      // if (!_isCameraInFrontOfDriver(userPosition, cameraPoint)) {
      //   continue;
      // }

      // if (!_isCameraFacingDriver(userPosition, cameraPoint, facing)) {
      //   continue;
      // }

      final distanceToCamera = distanceCalculator.as(
        LengthUnit.Meter,
        userLatLng,
        cameraPoint,
      );

      if (nearestDistance == null || distanceToCamera < nearestDistance) {
        nearestDistance = distanceToCamera;
        nearestCamera = camera;
      }
    }
    _activeCamera = nearestCamera;
    return nearestDistance;
  }

  Color _warningBackgroundColor() {
    if (_activeCamera == null) {
      return Colors.black;
    }

    final double limit =
        (_activeCamera!['speed_limit'] as num).toDouble();

    final double distance =
        _nearestCameraDistanceMeters ?? _cameraWarningRangeMeters;

    final double opacity =
        (1 - (distance / _cameraWarningRangeMeters))
            .clamp(0.15, 1.0);

    // Under the speed limit
    if (_calculatedSpeedKmh <= limit) {
      return Colors.white.withValues(alpha: opacity);
    }

    // Slightly over
    if (_calculatedSpeedKmh <= limit + 15) {
      return Colors.orange.withValues(alpha: opacity);
    }

    // Well over
    return Colors.red.withValues(alpha: opacity);
  }

  Color _warningTextColor() {
    if (_activeCamera == null) return Colors.white;

    final double limit =
        (_activeCamera!['speed_limit'] as num).toDouble();

    return _calculatedSpeedKmh <= limit
        ? Colors.black
        : Colors.white;
  }

  bool _shouldShowCameraWarning() {
    return !_hasPassedNearestCamera &&
        _displayedCameraDistanceMeters != null &&
        _displayedCameraDistanceMeters! > 0 &&
        _displayedCameraDistanceMeters! <= _cameraWarningRangeMeters;
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _loadAutoStartPreference();
    _startDistancePredictionTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appIsVisible = state == AppLifecycleState.resumed;

    if (_autoStartProtectionEnabled) {
      // Background service owns tracking.
      _stopForegroundTracking();
      return;
    }

    if (_appIsVisible) {
      // App is open and protection toggle is OFF.
      _startLiveTracking();
    } else {
      // No background protection requested, so save battery.
      _stopForegroundTracking();
    }
  }

  Future<void> _stopForegroundTracking() async {
    await _positionStream?.cancel();
    _positionStream = null;

    _beepTimer?.cancel();
    _beepTimer = null;

    _isBeepingActive = false;
    await _beepPlayer.stop();
  }

  @override
  void dispose() {
    _positionStream?.cancel(); 
    _distancePredictionTimer?.cancel();
    _beepTimer?.cancel();
    _beepPlayer.dispose();

    _nameController.dispose();
    _streetController.dispose();
    _speedController.dispose();
    _latController.dispose();
    _lngController.dispose();
    
    
    super.dispose();
  }

  Future<void> _loadAutoStartPreference() async {
    final prefs = await SharedPreferences.getInstance();

    final enabled =
        prefs.getBool(
          'auto_start_protection_enabled',
        ) ??
        false;

    final service = FlutterBackgroundService();
    final running = await service.isRunning();

    if (!mounted) return;

    setState(() {
      _autoStartProtectionEnabled =
          enabled && running;
    });
  }


  Future<void> _toggleProtection() async {
    final service = FlutterBackgroundService();
    final prefs = await SharedPreferences.getInstance();

    if (_autoStartProtectionEnabled) {
      service.invoke('stopService');

      await prefs.setBool(
        'auto_start_protection_enabled',
        false,
      );

      if (!mounted) return;

      setState(() {
        _autoStartProtectionEnabled = false;
      });
    } else {
      final alreadyRunning = await service.isRunning();

      final started = alreadyRunning
          ? true
          : await service.startService();

      if (!started) {
        debugPrint('Failed to start protection service');
        return;
      }

      await prefs.setBool(
        'auto_start_protection_enabled',
        true,
      );

      if (!mounted) return;

      setState(() {
        _autoStartProtectionEnabled = true;
      });
    }
  }

  Future<void> _playWarningBeep() async {
    const int sampleRate = 44100;
    const double frequency = 880.0;
    const double durationSeconds = 0.15;
    const int amplitude = 16000;

    final int sampleCount = (sampleRate * durationSeconds).round();
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
      final double t = i / sampleRate;
      final int sample =
          (math.sin(2 * math.pi * frequency * t) * amplitude).round();
      writeInt16(sample);
    }

    await _beepPlayer.stop();
    await _beepPlayer.play(BytesSource(bytes.toBytes()));
  }

  void _updateWarningBeep() {
    print("BEEP CHECK: shouldBeep = ${_shouldShowCameraWarning()}, distance = $_displayedCameraDistanceMeters");
    final bool shouldBeep = _shouldShowCameraWarning();

    if (!shouldBeep) {
      _beepTimer?.cancel();
      _beepTimer = null;
      _isBeepingActive = false;
      return;
    }

    if (_isBeepingActive) return;

    _isBeepingActive = true;

    _beepTimer = Timer.periodic(const Duration(milliseconds: 1200), (timer) {
      if (!_shouldShowCameraWarning()) {
        timer.cancel();
        _beepTimer = null;
        _isBeepingActive = false;
        return;
      }

      _playWarningBeep();
    });
  }

  void _startDistancePredictionTimer() {
    _distancePredictionTimer ??=
    Timer.periodic(const Duration(milliseconds: 2000), (timer) {
      if (!mounted) return;

      if (_lastRealCameraDistanceMeters == null ||
        _lastDistanceGpsUpdateTime == null ||
        _hasPassedNearestCamera ||
        _lastRealCameraDistanceMeters! > _cameraWarningRangeMeters) {
        setState(() {
          _displayedCameraDistanceMeters = null;
        });
        return;
      }

      final double averageSpeedKmh = _calculateAverageRecentSpeedKmh();

      final double speedMetersPerSecond =
          (averageSpeedKmh / 3.6).clamp(0.0, 60.0);

      final double secondsSinceGpsUpdate =
          DateTime.now()
                  .difference(_lastDistanceGpsUpdateTime!)
                  .inMilliseconds /
              1000;

      final double predictedDistance =
          _lastRealCameraDistanceMeters! -
              (speedMetersPerSecond * secondsSinceGpsUpdate);

      setState(() {
        _displayedCameraDistanceMeters =
            predictedDistance.clamp(0.0, _cameraWarningRangeMeters);

        if (_displayedCameraDistanceMeters == 0.0) {
          _displayedDistanceReachedZeroAt ??= DateTime.now();

          final bool stayedAtZeroFor3Seconds =
              DateTime.now().difference(_displayedDistanceReachedZeroAt!).inSeconds >= 3;

          if (stayedAtZeroFor3Seconds) {
            _hasPassedNearestCamera = true;
            _nearestCameraDistanceMeters = null;
            _displayedCameraDistanceMeters = null;
          }
        } else {
          _displayedDistanceReachedZeroAt = null;
        }
      });
    });
  }

  void _startLiveTracking() async {
    if (_positionStream != null) return;
    if (_autoStartProtectionEnabled) return;
    if (!_appIsVisible) return;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    //if (permission == LocationPermission.whileInUse) {
      // The app has permission to access location only while in use. You can still track the user's location, but it may not work in the background or when the app is closed.
      // later, you might want to inform the user that for full functionality, they should grant "Always" permission.
    //}

    if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
      final LocationSettings locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: 'Speed camera warning active',
          notificationText: 'Tracking your location for camera alerts',
          enableWakeLock: true,
        ),
      );

      _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings)
        .listen((Position position) {
          if (_positionHistory.length >= 10) {
            _positionHistory.removeFirst();
            _positionHistory.add(position);
          } else {
            _positionHistory.add(position);
          }

        final nearestCameraDistance = _calculateNearestCameraDistanceMeters(position);
        if (nearestCameraDistance != null) {
          if (_closestDistanceToCurrentCameraMeters == null ||
              nearestCameraDistance < _closestDistanceToCurrentCameraMeters!) {
            _closestDistanceToCurrentCameraMeters = nearestCameraDistance;
          }
        }
        final bool passedCamera =
          _previousNearestCameraDistanceMeters != null &&
          nearestCameraDistance != null &&
          _closestDistanceToCurrentCameraMeters != null &&
          _closestDistanceToCurrentCameraMeters! <= 60.0 &&
          nearestCameraDistance > _previousNearestCameraDistanceMeters! + 8.0;
        
        if (mounted) {
          setState(() {
            _currentLocation = LatLng(position.latitude, position.longitude);
            _calculatedSpeedKmh = _calculateCurrentSpeedKmh(position);
            if (passedCamera) {
              _hasPassedNearestCamera = true;
            }
            if (nearestCameraDistance == null ||
              nearestCameraDistance > _cameraWarningRangeMeters + 100) {
              _hasPassedNearestCamera = false;
              _closestDistanceToCurrentCameraMeters = null;
              _displayedDistanceReachedZeroAt = null;
            }
            if (_hasPassedNearestCamera) {
              _nearestCameraDistanceMeters = null;
              _displayedCameraDistanceMeters = null;
              _lastRealCameraDistanceMeters = null;
            } else {
              _nearestCameraDistanceMeters = nearestCameraDistance;
              _displayedCameraDistanceMeters = nearestCameraDistance;
              _lastRealCameraDistanceMeters = nearestCameraDistance;
              _lastDistanceGpsUpdateTime = DateTime.now();
            }
            _previousNearestCameraDistanceMeters = nearestCameraDistance;
            _lastSpeedPosition = position;
          });
          _updateWarningBeep();
        }

        // Native GPU camera updates do not block the UI thread loop
        if (_isCameraLocked && _isMapReady && _mapController != null && _currentLocation != null) {
          _mapController!.animateCamera(
            mgl.CameraUpdate.newLatLng(
              mgl.LatLng(_currentLocation!.latitude, _currentLocation!.longitude),
            ),
          );
        }

        _checkCameraGeofences(position);

        if (_isTrackingAverageSpeed && _entryCameraPoint != null && _entryTime != null) {
          const Distance distanceCalculator = Distance();
            
          double distanceTraveledMeters = distanceCalculator.as(
            LengthUnit.Meter,
            _entryCameraPoint!,
            LatLng(position.latitude, position.longitude),
          );

          if (mounted) {
            setState(() {
              _liveAverageSpeed = _calculateLiveSpeedKmh(
                position: position,
                distanceTraveledMeters: distanceTraveledMeters,
              );
            });
          }
        }
      });
    }
  }

  void _checkCameraGeofences(Position userPosition) {
    if (_rawCameraData.isEmpty) return;

    const Distance distanceCalculator = Distance();
    final LatLng userLatLng = LatLng(userPosition.latitude, userPosition.longitude);

    for (var camera in _rawCameraData) {
      final LatLng cameraPoint = LatLng(
        _readDouble(camera['latitude']),
        _readDouble(camera['longitude']),
      );
      double distanceToCamera = distanceCalculator.as(LengthUnit.Meter, userLatLng, cameraPoint);

      if (distanceToCamera <= 25.0) {
        if (!_isTrackingAverageSpeed) {
          if (mounted) {
            setState(() {
              _isTrackingAverageSpeed = true;
              _entryTime = userPosition.timestamp;
              _entryCameraPoint = cameraPoint;
              _liveAverageSpeed = 0.0; 
            });
          }
          return;
        } 
        else if (_isTrackingAverageSpeed && cameraPoint != _entryCameraPoint) {
          if (mounted) {
            setState(() {
              _isTrackingAverageSpeed = false;
              _entryTime = null;
              _entryCameraPoint = null;
            });
          }
          
          // ignore: use_build_context_synchronously      
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Sector complete! Tracking stopped."), backgroundColor: Colors.green),
          );
          break;
        }
      }
    }
  }

  Future<void> _syncCamerasToMap() async {
    if (_mapController == null || !_isStyleLoaded) return;

    try {
      final data = await _dbService.fetchCameras(); 
      _rawCameraData = List<Map<String, dynamic>>.from(data);

      // Clear previous symbols to avoid duplicates on data refreshes
      await _mapController!.clearSymbols();
      await _mapController!.clearCircles();

      for (var camera in _rawCameraData) {
        final double lat = _readDouble(camera['latitude']);
        final double lng = _readDouble(camera['longitude']);
        final int speedLimit = _readInt(camera['speed_limit']);
        final mgl.LatLng cameraPoint = mgl.LatLng(lat, lng);

        await _mapController!.addCircle(
          mgl.CircleOptions(
            geometry: cameraPoint,
            circleRadius: 7.0,
            circleColor: "#FF6D00",
            circleOpacity: 0.9,
            circleStrokeColor: "#FFFFFF",
            circleStrokeWidth: 2.0,
            circleStrokeOpacity: 0.85,
          ),
        );

        // Adds the location natively to the map's GPU canvas stream
        await _mapController!.addSymbol(
          mgl.SymbolOptions(
            geometry: cameraPoint,
            iconSize: 1.5,
            textField: "$speedLimit KM/H",
            textOffset: const Offset(0, 1.5),
            textSize: 11,
            textColor: "#FF9800",
            textHaloColor: "#000000",
            textHaloWidth: 1.0,
          ),
        );
      }
    } catch (e) {
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error syncing cameras: $e')),
      );
    }
  }


  // ignore: unused_element
  Future<void> _submitCameraData() async {
    if (_latController.text.isEmpty || _lngController.text.isEmpty) return;

    setState(() => _isLoading = true);
    try {
      await _dbService.insertCamera(
        name: _nameController.text,
        streetName: _streetController.text,
        lat: double.parse(_latController.text),
        lng: double.parse(_lngController.text),
        speedLimit: int.parse(_speedController.text),
        facing: _selectedfacing,
      );

      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Camera successfully registered!'), backgroundColor: Colors.green),
      );

      _nameController.clear();
      _streetController.clear();
      _latController.clear();
      _lngController.clear();
      _speedController.clear();
      _syncCamerasToMap();
      _isEditMode = false;
    } catch (e) {
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _showAddCameraSheet() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  "Add Speed Camera",
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 20),

                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: "Camera Name",
                    border: OutlineInputBorder(),
                  ),
                ),

                const SizedBox(height: 15),

                TextField(
                  controller: _streetController,
                  decoration: const InputDecoration(
                    labelText: "Street Name",
                    border: OutlineInputBorder(),
                  ),
                ),

                const SizedBox(height: 15),

                TextField(
                  controller: _speedController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: "Speed Limit",
                    border: OutlineInputBorder(),
                  ),
                ),

                const SizedBox(height: 15),

                DropdownButtonFormField<String>(
                  value: _selectedfacing,
                  decoration: const InputDecoration(
                    labelText: "Camera Facing",
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: "front",
                      child: Text("Front"),
                    ),
                    DropdownMenuItem(
                      value: "back",
                      child: Text("Back"),
                    ),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _selectedfacing = value!;
                    });
                  },
                ),

                const SizedBox(height: 15),

                TextField(
                  controller: _latController,
                  readOnly: true,
                  decoration: const InputDecoration(
                    labelText: "Latitude",
                    border: OutlineInputBorder(),
                  ),
                ),

                const SizedBox(height: 15),

                TextField(
                  controller: _lngController,
                  readOnly: true,
                  decoration: const InputDecoration(
                    labelText: "Longitude",
                    border: OutlineInputBorder(),
                  ),
                ),

                const SizedBox(height: 25),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      await _submitCameraData();

                      if (context.mounted) {
                        Navigator.pop(context);
                      }
                    },
                    child: const Text("Save Camera"),
                  ),
                ),

                const SizedBox(height: 15),
              ],
            ),
          ),
        );
      },
    );
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              const ListTile(
                title: Text(
                  "Speed Camera App",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text("Settings and protection"),
              ),
              const Divider(),
              SwitchListTile(
                title: const Text('Background protection'),
                subtitle: Text(
                  _autoStartProtectionEnabled
                      ? 'Protection is running'
                      : 'Protection is stopped',
                ),
                value: _autoStartProtectionEnabled,
                onChanged: (_) {
                  _toggleProtection();
                },
              ),
            ],
          ),
        ),
      ),
      body: Stack(
          children: [
            // HIGH PERFORMANCE NATIVE GPU VIEWPORT
            mgl.MapLibreMap(
              styleString: tomtomHybridStyle, // Consumes your split TomTom server JSON
              initialCameraPosition: mgl.CameraPosition(
                target: mgl.LatLng(
                    _currentLocation?.latitude ?? 36.1911,
                    _currentLocation?.longitude ?? 44.0092,
                  ),
                zoom: 14.0,
              ),
              myLocationEnabled: true, // Native blue location dot tracked by operating system
              myLocationRenderMode: mgl.MyLocationRenderMode.compass, // Rotates the blue dot to match device heading
              
              onMapCreated: (mgl.MapLibreMapController controller) {
                _mapController = controller;
                _isMapReady = true;
                
                // Set up the tap listener for GPU items
                _mapController!.onSymbolTapped.add((symbol) {
                  // Find the matching camera data dictionary matching this coordinate signature
                  final match = _rawCameraData.firstWhere(
                    (c) => (c['latitude'] - symbol.options.geometry!.latitude).abs() < 0.0001,
                    orElse: () => {},
                  );
                  if (match.isNotEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("${match['name']} on ${match['street_name']} (${match['speed_limit']} km/h)")),
                    );
                  }
                });
              },

              onStyleLoadedCallback: () {
                _isStyleLoaded = true;
                _syncCamerasToMap();
              },
              
              onMapClick: (point, latLng) {
                if (_isEditMode) {
                  if (mounted) {
                    setState(() {
                      _latController.text = latLng.latitude.toString();
                      _lngController.text = latLng.longitude.toString();
                    });

                    _showAddCameraSheet();
                  }
                }
              }
            ),       

            Positioned(
              top: 20,
              left: 20,
              child: FloatingActionButton.small(
                heroTag: "btn_menu",
                backgroundColor: Colors.black.withValues(alpha: 0.8),
                foregroundColor: Colors.white,
                onPressed: () {
                  _scaffoldKey.currentState?.openDrawer();
                },
                child: const Icon(Icons.menu),
              ),
            ),        

            Positioned(
              top: 20,
              left: 75,
              child: Card(
                color: _calculatedSpeedKmh > 100
                    ? Colors.red.withValues(alpha: 0.9)
                    : Colors.black.withValues(alpha: 0.8),
                elevation: 6,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        "LIVE SPEED",
                        style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "${_calculatedSpeedKmh.toStringAsFixed(0)} KM/H",
                        style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            Positioned(
              top: 105,
              left: 20,
              right: 20,
              child: IgnorePointer(
                ignoring: !_isWarningEnabled ||
                _nearestCameraDistanceMeters == null ||
                !_shouldShowCameraWarning(),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  opacity: _shouldShowCameraWarning() ? 1.0 : 0.0,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    offset: _shouldShowCameraWarning()
                      ? Offset.zero
                      : const Offset(0, -0.12),
                    child: Card(
                      color: _warningBackgroundColor(),
                      elevation: 6,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
                        child: Stack(
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 8, right: 80),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.camera_alt, color: _warningTextColor(), size: 18),
                                      const SizedBox(width: 8),
                                      Text(
                                        "SPEED CAMERA",
                                        style: TextStyle(
                                          color: _warningTextColor().withValues(alpha: 0.75),
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 1,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    "${(_displayedCameraDistanceMeters ?? 0).toStringAsFixed(0)} meters away",
                                    style: TextStyle(
                                      color: _warningTextColor(),
                                      fontSize: 54,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  LinearProgressIndicator(
                                    value: _displayedCameraDistanceMeters == null
                                      ? 0
                                      : (1 - (_displayedCameraDistanceMeters! / _cameraWarningRangeMeters))
                                          .clamp(0.0, 1.0),
                                    minHeight: 6,
                                    borderRadius: BorderRadius.circular(10),
                                    backgroundColor: Colors.white24,
                                    valueColor: AlwaysStoppedAnimation<Color>(_warningTextColor()),
                                  ),
                                  const SizedBox(height: 16),
                                  const SizedBox(height: 72),
                                  Text(
                                    _activeCamera?['street_name'] ?? "",
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: _warningTextColor().withValues(alpha: 0.75),
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    _calculatedSpeedKmh >
                                            ((_activeCamera?['speed_limit'] ?? 999) as num).toDouble()
                                        ? "⚠ SLOW DOWN"
                                        : "✓ Speed OK",
                                    style: TextStyle(
                                      color: _warningTextColor(),
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            Positioned(
                              top: 0,
                              right: 0,
                              child: Container(
                                width: 72,
                                height: 72,
                                decoration: const BoxDecoration(
                                  color: Colors.red,
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: Container(
                                    width: 56,
                                    height: 56,
                                    decoration: const BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Center(
                                      child: Text(
                                        "${_activeCamera?['speed_limit'] ?? '--'}",
                                        style: const TextStyle(
                                          color: Colors.black,
                                          fontSize: 22,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

              NotificationListener<DraggableScrollableNotification>(
                onNotification: (notification) {
                  if (mounted) {
                    setState(() {
                      _currentPanelHeight = notification.extent * MediaQuery.of(context).size.height;
                    });
                  }
                  return true;
                },
                child: DraggableScrollableSheet(
                  initialChildSize: _minPanelExtent,
                  minChildSize: _minPanelExtent,
                  maxChildSize: _maxPanelExtent,
                  builder: (BuildContext context, ScrollController scrollController) {
                    return Container(
                      decoration: BoxDecoration(
                        color: Colors.black, 
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(30),
                          topRight: Radius.circular(30),
                        ),
                        boxShadow: [
                          BoxShadow(color: Colors.black, blurRadius: 10, offset: const Offset(0, -3))
                        ],
                      ),
                      child: SingleChildScrollView(
                        controller: scrollController, 
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 12.0),
                          child: Column(
                            children: [
                              Container(
                                width: 50,
                                height: 5,
                                decoration: BoxDecoration(
                                  color: Colors.white24,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              const SizedBox(height: 20),
                              Container(
                                height: 50,
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(15),
                                ),
                                child: const Center(
                                  child: Text("Search Bar coming here...", style: TextStyle(color: Colors.white30)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            

            Positioned(
              bottom: _currentPanelHeight > 0 
                  ? _currentPanelHeight + 15 
                  : (MediaQuery.of(context).size.height * _minPanelExtent) + 15,
              right: 20,
              child: FloatingActionButton(
                heroTag: "btn_curator_toggle",
                backgroundColor: Colors.orangeAccent,
                foregroundColor: Colors.black,
                onPressed: () {
                  setState(() {
                    _isEditMode = true;
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text("Map editing mode enabled. Tap on the map to select a location."),
                    ),
                  );
                },
                child: Icon(_isEditMode ? Icons.close : Icons.edit_road_rounded), 
              ),
            ),
          

            if (_isLoading)
              Positioned.fill(
                child: Container(
                  color: Colors.black38, 
                  child: const Center(
                    child: CircularProgressIndicator(), 
                  ),
                ),
              ),
      
            Positioned(
              bottom: _currentPanelHeight > 0 
              ? _currentPanelHeight + 85 
              : (MediaQuery.of(context).size.height * _minPanelExtent) + 85,
              right: 20,
              child: FloatingActionButton(
                heroTag: "btn_snap",
                backgroundColor: _isCameraLocked ? Colors.blue : Colors.white,
                foregroundColor: _isCameraLocked ? Colors.white : Colors.blue,
                onPressed: () {
                  if (mounted) {
                    setState(() {
                      _isCameraLocked = !_isCameraLocked; 
                      if (_isCameraLocked && _currentLocation != null && _isMapReady) {
                        _mapController!.animateCamera(
                          mgl.CameraUpdate.newLatLng(
                            mgl.LatLng(_currentLocation!.latitude, _currentLocation!.longitude),
                          ),
                        );
                      }
                    });
                  }
                },
                child: Icon(_isCameraLocked ? Icons.gps_fixed : Icons.gps_not_fixed),
              ), 
            ),
          ],
        ),
    );
  }
}
