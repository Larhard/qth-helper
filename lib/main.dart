import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChrome, SystemUiMode;
import 'package:get_storage/get_storage.dart';
import 'screens/home_screen.dart';
import 'services/city_service.dart';
import 'services/waypoint_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  // Screen-on wakelock is handled natively in MainActivity.kt via
  // FLAG_KEEP_SCREEN_ON — no plugin required.
  await GetStorage.init();
  WaypointService.instance.load();
  await CityService.instance.load();
  runApp(const QthHelperApp());
}

class QthHelperApp extends StatelessWidget {
  const QthHelperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QTH Helper',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const HomeScreen(),
    );
  }
}
