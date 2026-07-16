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
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
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
  Timer? _recenterDebounceTimer;
  final double _minPanelExtent = 0.12;      
  final double _maxPanelExtent = 0.50; 
  double _currentPanelHeight = 0.0;
  static const double _cameraWarningRangeMeters = 200.0;
  late final AnimationController _warningPulseController;
  late final Animation<double> _warningPulse;


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

  double? _currentSpeedLimit() {
    final value = _activeCamera?['speed_limit'];

    if (value is num) {
      return value.toDouble();
    }

    return null;
  }

  double _speedingPercentage() {
    final limit = _currentSpeedLimit();

    if (limit == null || limit <= 0) {
      return 0.0;
    }

    return ((_calculatedSpeedKmh - limit) / limit)
        .clamp(0.0, double.infinity);
  }

  Color? _speedingWarningColor() {
    final percentage = _speedingPercentage();

    if (percentage <= 0) {
      return null;
    }

    if (percentage <= 0.10) {
      return Colors.orange;
    }

    return Colors.red;
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _listenToProtectionService();
    _loadAutoStartPreference();

    _warningPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _warningPulse = CurvedAnimation(
      parent: _warningPulseController,
      curve: Curves.easeInOut,
    );

    _warningPulseController.repeat(reverse: true);
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
    _warningPulseController.dispose();

    _serviceUpdateSubscription?.cancel();
    _recenterDebounceTimer?.cancel();

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

  void _scheduleRecenterAfterPan() {
    _recenterDebounceTimer?.cancel();

    if (!_isCameraLocked) return;

    _recenterDebounceTimer = Timer(
      const Duration(seconds: 5),
      () {
        if (!_isCameraLocked ||
            !_isMapReady ||
            _mapController == null ||
            _currentLocation == null) {
          return;
        }

        _mapController!.animateCamera(
          mgl.CameraUpdate.newLatLng(
            mgl.LatLng(
              _currentLocation!.latitude,
              _currentLocation!.longitude,
            ),
          ),
        );
      },
    );
  }

  Future<void> _syncCamerasToMap() async {
    final controller = _mapController;

    if (controller == null || !_isStyleLoaded) return;

    try {
      final data = await _dbService.fetchCameras();
      _rawCameraData =
          List<Map<String, dynamic>>.from(data);

      // await controller.clearSymbols();
      // await controller.clearCircles();

      for (var camera in _rawCameraData) {
        final double lat = _readDouble(camera['latitude']);
        final double lng = _readDouble(camera['longitude']);
        final int speedLimit = _readInt(camera['speed_limit']);
        final mgl.LatLng cameraPoint = mgl.LatLng(lat, lng);

        await controller.addCircle(
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

        await controller.addSymbol(
          mgl.SymbolOptions(
            geometry: cameraPoint,
            textField: '$speedLimit KM/H',
            textOffset: const Offset(0, 1.5),
            textSize: 11,
            textColor: '#FF9800',
            textHaloColor: '#000000',
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
              trackCameraPosition: true,
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
                controller.onSymbolTapped.add((symbol) {
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

              onCameraMove: (cameraPosition) {
                _recenterDebounceTimer?.cancel();
              },

              onCameraIdle: () {
                _scheduleRecenterAfterPan();
              },

              onStyleLoadedCallback: () async {
                _isStyleLoaded = true;

                await Future<void>.delayed(
                  const Duration(milliseconds: 500),
                );

                if (!mounted) return;

                await _syncCamerasToMap();
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
              bottom: _currentPanelHeight > 0
                  ? _currentPanelHeight + 20
                  : (MediaQuery.of(context).size.height * _minPanelExtent) + 20,
              left: 20,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(
                  begin: 0,
                  end: _calculatedSpeedKmh,
                ),
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOutCubic,
                builder: (context, animatedSpeed, child) {
                  final double? speedLimit =
                      _activeCamera?['speed_limit'] is num
                          ? (_activeCamera!['speed_limit'] as num).toDouble()
                          : null;

                  final bool isSpeeding =
                      speedLimit != null && animatedSpeed > speedLimit;

                  final bool isFarOver =
                      speedLimit != null && animatedSpeed > speedLimit + 15;

                  final Color speedBorderColor = isFarOver
                      ? Colors.red
                      : isSpeeding
                          ? Colors.orange
                          : Colors.black;

                  return SizedBox(
                    width: 125,
                    height: 125,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          bottom: 0,
                          left: 0,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOutCubic,
                            width: 105,
                            height: 105,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: speedBorderColor,
                                width: 6,
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black38,
                                  blurRadius: 10,
                                  offset: Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Center(
                              child: AnimatedDefaultTextStyle(
                                duration: const Duration(milliseconds: 300),
                                style: TextStyle(
                                  color: isSpeeding
                                      ? speedBorderColor
                                      : Colors.black,
                                  fontSize: 42,
                                  fontWeight: FontWeight.w900,
                                ),
                                child: Text(
                                  animatedSpeed.toStringAsFixed(0),
                                ),
                              ),
                            ),
                          ),
                        ),

                        Positioned(
                          top: 0,
                          right: 0,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            width: 58,
                            height: 58,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: speedLimit == null
                                    ? Colors.grey
                                    : Colors.red,
                                width: 6,
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black26,
                                  blurRadius: 6,
                                  offset: Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                speedLimit == null
                                    ? '--'
                                    : speedLimit.toStringAsFixed(0),
                                style: TextStyle(
                                  color: speedLimit == null
                                      ? Colors.grey
                                      : Colors.black,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

            Positioned(
              top: 90,
              left: 20,
              right: 20,
              child: IgnorePointer(
                ignoring: !_isWarningEnabled || !_shouldShowCameraWarning(),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  opacity: _shouldShowCameraWarning() ? 1.0 : 0.0,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    offset: _shouldShowCameraWarning()
                        ? Offset.zero
                        : const Offset(0, -0.15),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutCubic,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: _warningBackgroundColor(),
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black38,
                            blurRadius: 14,
                            offset: Offset(0, 6),
                          ),
                        ],
                      ),
                      child: SizedBox(
                        height: 115,
                        child: Row(
                          children: [
                            Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                color: _warningTextColor().withValues(alpha: 0.14),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.speed_rounded,
                                color: _warningTextColor(),
                                size: 38,
                              ),
                            ),

                            const SizedBox(width: 18),

                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'SPEED CAMERA AHEAD',
                                    style: TextStyle(
                                      color: _warningTextColor()
                                          .withValues(alpha: 0.75),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.8,
                                    ),
                                  ),

                                  const SizedBox(height: 8),

                                  TweenAnimationBuilder<double>(
                                    tween: Tween<double>(
                                      begin: 0,
                                      end: _displayedCameraDistanceMeters ?? 0,
                                    ),
                                    duration: const Duration(milliseconds: 350),
                                    curve: Curves.easeOutCubic,
                                    builder: (context, animatedDistance, child) {
                                      return Text(
                                        '${animatedDistance.toStringAsFixed(0)} m',
                                        style: TextStyle(
                                          color: _warningTextColor(),
                                          fontSize: 40,
                                          height: 1,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      );
                                    },
                                  ),

                                  if ((_activeCamera?['street_name'] ?? '')
                                      .toString()
                                      .trim()
                                      .isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      _activeCamera!['street_name'].toString(),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: _warningTextColor()
                                            .withValues(alpha: 0.7),
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ],
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
                  setState(() {
                    _isCameraLocked = !_isCameraLocked;
                  });

                  if (_isCameraLocked) {
                    if (_currentLocation != null &&
                        _isMapReady &&
                        _mapController != null) {
                      _mapController!.animateCamera(
                        mgl.CameraUpdate.newLatLng(
                          mgl.LatLng(
                            _currentLocation!.latitude,
                            _currentLocation!.longitude,
                          ),
                        ),
                      );
                    }
                  } else {
                    _recenterDebounceTimer?.cancel();
                    _recenterDebounceTimer = null;
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