// ignore_for_file: file_names

import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart'; // Used for Distance calculations
import 'package:speed_camera_app_2/Services/Supabase_service.dart'; 
import 'package:speed_camera_app_2/Config/map_style.dart'; // Your TomTom Style String
import 'dart:async';
import 'package:maplibre_gl/maplibre_gl.dart' as mgl; // Native GPU Engine

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final SupabaseService _dbService = SupabaseService(); 
  
  LatLng? _currentLocation;
  mgl.MapLibreMapController? _mapController;
  
  bool _isLoading = false;
  bool _isEditMode = false;
  bool _isTrackingAverageSpeed = false;
  bool _isCameraLocked = false; 
  bool _isMapReady = false; 
  bool _isStyleLoaded = false;

  final double maxSpeedKmh = 250.0; // 250 KM/H

  StreamSubscription<Position>? _positionStream;
  Position? _lastSpeedPosition;
  final Queue<Position> _positionHistory = Queue<Position>(); // logging recent positions for potential future use

  String _selectedfacing = 'back'; // Default facing direction for new cameras
  DateTime? _entryTime;
  LatLng? _entryCameraPoint;
  double _liveAverageSpeed = 0.0;
  double _calculatedSpeedKmh = 0.0;
  double trustedSpeedKmh = 0.0;
  double? _nearestCameraDistanceMeters;
  final double _minPanelExtent = 0.12; 
  final double _maxPanelExtent = 0.50; 
  double _currentPanelHeight = 0.0;
  static const double _cameraWarningRangeMeters = 200.0;
  int rejectedSpeed = 0; // Counter for rejected speed calculations exceeding max threshold
  int acceptedSpeed = 0; // Counter for accepted speed calculations within max threshold
  double displaySpeed = 0; // Smoothed speed for display purposes

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
    

  double _calculateCurrentSpeedKmh(Position position) {
    _isPositionTrusted(position);
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

    debugPrint("Prev: ${previousPosition.latitude}, ${previousPosition.longitude}");
    debugPrint("Curr: ${position.latitude}, ${position.longitude}");
    const Distance distanceCalculator = Distance();

    final distanceMeters = distanceCalculator.as(
      LengthUnit.Meter,
      LatLng(previousPosition.latitude, previousPosition.longitude),
      LatLng(position.latitude, position.longitude),
    );

    final calculatedSpeedKmh = (distanceMeters / secondsPassed) * 3.6;
    if (calculatedSpeedKmh > maxSpeedKmh) {
      rejectedSpeed++;
      debugPrint(
      "Calculated speed exceeds max threshold: ${calculatedSpeedKmh.toStringAsFixed(1)} KM/H");
      return displaySpeed;
    }

    acceptedSpeed++;

    double trustedSpeedKmh;

    if (gpsSpeedKmh.isFinite && gpsSpeedKmh > 1.0 && gpsSpeedKmh <= maxSpeedKmh) {
      trustedSpeedKmh = gpsSpeedKmh;
    } else {
      trustedSpeedKmh = calculatedSpeedKmh;
    }
    
    debugPrint("GPS: ${gpsSpeedKmh.toStringAsFixed(1)} | Calculated: ${calculatedSpeedKmh.toStringAsFixed(1)}");
      debugPrint(
        "Acc: ${position.accuracy.toStringAsFixed(1)}m | "
        "GPS: ${gpsSpeedKmh.toStringAsFixed(1)} | "
        "Calc: ${calculatedSpeedKmh.toStringAsFixed(1)} "
        "Time: ${secondsPassed.toStringAsFixed(2)}s | "
        "Distance: ${distanceMeters.toStringAsFixed(1)}m",
      );
    return trustedSpeedKmh;
  }

  double? _calculateNearestCameraDistanceMeters(Position userPosition) {
    if (_rawCameraData.isEmpty) return null;

    const Distance distanceCalculator = Distance();
    final userLatLng = LatLng(userPosition.latitude, userPosition.longitude);
    double? nearestDistance;

    for (final camera in _rawCameraData) {
      final cameraPoint = LatLng(
        _readDouble(camera['latitude']),
        _readDouble(camera['longitude']),
      );
      final distanceToCamera = distanceCalculator.as(
        LengthUnit.Meter,
        userLatLng,
        cameraPoint,
      );

      if (nearestDistance == null || distanceToCamera < nearestDistance) {
        nearestDistance = distanceToCamera;
      }
    }

    return nearestDistance;
  }

  @override
  void initState() {
    super.initState();
    _startLiveTracking();
  }

  @override
  void dispose() {
    _positionStream?.cancel(); 
    _nameController.dispose();
    _streetController.dispose();
    _speedController.dispose();
    _latController.dispose();
    _lngController.dispose();
    super.dispose();
  }

  void _startLiveTracking() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    //if (permission == LocationPermission.whileInUse) {
      // The app has permission to access location only while in use. You can still track the user's location, but it may not work in the background or when the app is closed.
      // later, you might want to inform the user that for full functionality, they should grant "Always" permission.
    //}

    if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
      const LocationSettings locationSettings = LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1, 
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
        
        if (mounted) {
          setState(() {
            _currentLocation = LatLng(position.latitude, position.longitude);
            _calculatedSpeedKmh = _calculateCurrentSpeedKmh(position);
            _nearestCameraDistanceMeters = nearestCameraDistance;
            _lastSpeedPosition = position;
          });
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
      _syncCamerasToMap();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _currentLocation == null
      ? const Center(child: CircularProgressIndicator())
      : Stack( 
          children: [
            // HIGH PERFORMANCE NATIVE GPU VIEWPORT
            mgl.MapLibreMap(
              styleString: tomtomHybridStyle, // Consumes your split TomTom server JSON
              initialCameraPosition: mgl.CameraPosition(
                target: mgl.LatLng(_currentLocation!.latitude, _currentLocation!.longitude),
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
                  }
                }
              },
            ),               

            Positioned(
              top: 20,
              left: 20,
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
                        "${displaySpeed.toStringAsFixed(0)} KM/H",
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
                ignoring: _nearestCameraDistanceMeters == null ||
                    _nearestCameraDistanceMeters! > _cameraWarningRangeMeters,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  opacity: (_nearestCameraDistanceMeters != null &&
                          _nearestCameraDistanceMeters! <= _cameraWarningRangeMeters)
                      ? 1.0
                      : 0.0,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    offset: (_nearestCameraDistanceMeters != null &&
                            _nearestCameraDistanceMeters! <= _cameraWarningRangeMeters)
                        ? Offset.zero
                        : const Offset(0, -0.12),
                    child: Card(
                      color: Color.lerp(
                        Colors.black.withValues(alpha: 0.82),
                        Colors.red.withValues(alpha: 0.94),
                        _nearestCameraDistanceMeters == null
                            ? 0.0
                            : (1 -
                                    (_nearestCameraDistanceMeters! /
                                        _cameraWarningRangeMeters))
                                .clamp(0.0, 1.0),
                      ),
                      elevation: 6,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              "CAMERA AHEAD",
                              style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "${(_nearestCameraDistanceMeters ?? 0).toStringAsFixed((_nearestCameraDistanceMeters ?? 0) >= 10 ? 0 : 1)} M",
                              style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.bold),
                            ),
                            const Text(
                              "Slow down smoothly",
                              style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            if (_isTrackingAverageSpeed)
              Positioned(
                top: 245,
                left: 20,
                right: 20,
                child: Card(
                  color: _liveAverageSpeed > 100 ? Colors.red.withValues(alpha: 0.9) : Colors.black.withValues(alpha: 0.8),
                  elevation: 6,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        const Text(
                          "LIVE ZONE AVERAGE SPEED",
                          style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          "${_liveAverageSpeed.toStringAsFixed(0)} KM/H",
                          style: const TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          _liveAverageSpeed > 100 ? "⚠️ TOO FAST! SLOW DOWN!" : "✅ SAFE SPEED",
                          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                      ],
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
                    _isEditMode = !_isEditMode;
                  });
                  // ignore: use_build_context_synchronously
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Map editing mode toggled: $_isEditMode")),
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
