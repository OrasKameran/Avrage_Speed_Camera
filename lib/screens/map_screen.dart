// ignore_for_file: file_names
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart'; // Used for Distance calculations
import 'package:speed_camera_app_2/Services/Supabase_service.dart'; 
import 'package:speed_camera_app_2/Config/map_style.dart'; // Your TomTom Style String
import 'dart:async';
import 'package:maplibre_gl/maplibre_gl.dart' as mgl; // Native GPU Engine
import 'package:audioplayers/audioplayers.dart';
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
  bool _isCameraLocked = false; 
  final bool _isWarningEnabled = true;
  bool _isMapReady = false; 
  bool _isStyleLoaded = false;
  bool _autoStartProtectionEnabled = false;
  

  final double maxSpeedKmh = 300.0; // 300 KM/H

  StreamSubscription<Map<String, dynamic>?>?
    _serviceUpdateSubscription;

  String _selectedfacing = 'back'; // Default facing direction for new cameras
  double _calculatedSpeedKmh = 0.0;
  double trustedSpeedKmh = 0.0;
  double? _nearestCameraDistanceMeters;
  double? _displayedCameraDistanceMeters;
  bool _hasPassedNearestCamera = false;

  final AudioPlayer _beepPlayer = AudioPlayer();
  Timer? _beepTimer;

  final double _minPanelExtent = 0.12;      
  final double _maxPanelExtent = 0.50; 
  double _currentPanelHeight = 0.0;
  static const double _cameraWarningRangeMeters = 2000.0;


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

  Map<String, dynamic>? _activeCamera;

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

    _listenToProtectionService();
    _loadAutoStartPreference();

  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _beepTimer?.cancel();
    _beepPlayer.dispose();

    _nameController.dispose();
    _streetController.dispose();
    _speedController.dispose();
    _latController.dispose();
    _lngController.dispose();
    _serviceUpdateSubscription?.cancel();

    super.dispose();
  }

  @override
  Future<void> didChangeAppLifecycleState(
    AppLifecycleState state,
  ) async {
    _appIsVisible = state == AppLifecycleState.resumed;

    final service = FlutterBackgroundService();

    if (_appIsVisible) {
      bool running = await service.isRunning();

      if (!running) {
        running = await service.startService();
      }

      if (running) {
        service.invoke('appVisible');

        service.invoke(
          'setBackgroundProtection',
          {
            'enabled': _autoStartProtectionEnabled,
          },
        );
      }
    } else {
      service.invoke(
        'appHidden',
        {
          'keepRunning':
              _autoStartProtectionEnabled,
        },
      );
    }
  }

  Future<void> _stopForegroundTracking() async {
    _beepTimer?.cancel();
    _beepTimer = null;

    await _beepPlayer.stop();
  }

  Future<void> _loadAutoStartPreference() async {
    final prefs = await SharedPreferences.getInstance();

    final savedEnabled =
        prefs.getBool(
          'auto_start_protection_enabled',
        ) ??
        false;

    final service = FlutterBackgroundService();
    bool serviceRunning = await service.isRunning();

    if (!serviceRunning) {
      serviceRunning = await service.startService();
    }

    final protectionActive = savedEnabled;
    

    if (!mounted) return;

    setState(() {
      _autoStartProtectionEnabled =
          protectionActive;
    });

    await _stopForegroundTracking();
  }

  Future<void> _toggleProtection() async {
    final service = FlutterBackgroundService();
    final prefs = await SharedPreferences.getInstance();

    final bool newValue = !_autoStartProtectionEnabled;

    await prefs.setBool(
      'auto_start_protection_enabled',
      newValue,
    );

    final bool serviceRunning = await service.isRunning();

    if (!serviceRunning) {
      final bool started = await service.startService();

      if (!started) {
        debugPrint('Failed to start protection service');
        return;
      }
    }

    service.invoke(
      'setBackgroundProtection',
      {
        'enabled': newValue,
      },
    );

    if (!mounted) return;

    setState(() {
      _autoStartProtectionEnabled = newValue;
    });
  }
 
  void _listenToProtectionService() {
    _serviceUpdateSubscription =
        FlutterBackgroundService()
            .on('protectionUpdate')
            .listen((event) {
      if (event == null || !mounted) return;

      final distanceValue = event['cameraDistance'];

      final double? distance =
          distanceValue is num &&
                  distanceValue.isFinite
              ? distanceValue.toDouble()
              : null;

      setState(() {
        _currentLocation = LatLng(
          (event['latitude'] as num).toDouble(),
          (event['longitude'] as num).toDouble(),
        );

        _calculatedSpeedKmh =
            (event['speedKmh'] as num).toDouble();

        _nearestCameraDistanceMeters = distance;
        _displayedCameraDistanceMeters = distance;

        _activeCamera = {
          'name': event['cameraName'],
          'speed_limit': event['speedLimit'],
          'street_name': event['streetName'] ?? '',
        };

        _hasPassedNearestCamera = false;
      });
    });
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
