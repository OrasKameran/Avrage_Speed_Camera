import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:speed_camera_app_2/screens/map_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await Supabase.initialize(
    url: 'https://qjtnnxqwgytjysvxztnu.supabase.co',
    publishableKey: 'sb_publishable_8f2VbpP5Qf30BO2jYqUV7Q_tCGVw26Z',
  );

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Erbil Speed Camera App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
      ),
      home: MapScreen(), // Target screen points smoothly
    );
  }
}