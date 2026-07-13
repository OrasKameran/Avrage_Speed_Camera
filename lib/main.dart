import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:speed_camera_app_2/screens/map_screen.dart';
import 'package:speed_camera_app_2/Services/protection_service.dart';

@pragma('vm:entry-point')
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://qjtnnxqwgytjysvxztnu.supabase.co',
    publishableKey:
        'sb_publishable_8f2VbpP5Qf30BO2jYqUV7Q_tCGVw26Z',
  );

  await initializeProtectionService();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Be Gharama',
      debugShowCheckedModeBanner: false,
      home: MapScreen(),
    );
  }
}