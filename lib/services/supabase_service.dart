import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {
  final _client = Supabase.instance.client;

  // Fetch all cameras from the cloud
  Future<List<dynamic>> fetchCameras() async {
    try {
      final List<dynamic> response = await _client
          .from('speed_cameras')
          .select();
      return response;
    } catch (e) {
      print('Database Error (fetch): $e');
      rethrow;
    }
  }

  // Insert a newly pinned camera
  Future<void> insertCamera({
    required String name,
    required String streetName,
    required double lat,
    required double lng,
    required int speedLimit,
    required String facing,
  }) async {
    try {
      await _client.from('speed_cameras').insert({
        'name': name.isEmpty ? 'Radar Gantry' : name,
        'street_name': streetName,
        'latitude': lat,
        'longitude': lng,
        'speed_limit': speedLimit,
        'facing': facing,
      });
    } catch (e) {
      print('Database Error (insert): $e');
      rethrow;
    }
  }
}