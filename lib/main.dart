import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'utils/units.dart';
import 'package:flutter/services.dart' show SystemChrome, SystemUiMode;
import 'package:get_storage/get_storage.dart';
import 'screens/home_screen.dart';
import 'services/city_service.dart';
import 'services/waypoint_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  _registerDataLicences();
  await GetStorage.init();
  WaypointService.instance.load();
  await CityService.instance.load();
  runApp(const QthHelperApp());
}

/// Register third-party DATA licences with Flutter's LicenseRegistry so they
/// appear alongside package licences in showLicensePage().
///
/// This satisfies the in-app licence-text reproduction requirement of the
/// BSD-3-Clause licences (Flutter SDK, url_launcher) and provides the
/// attribution notice required by CC BY 4.0 (GeoNames) and ODbL (OSM).
void _registerDataLicences() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      ['GeoNames city and harbour data'],
      '''
Creative Commons Attribution 4.0 International (CC BY 4.0)

Data provider: GeoNames — https://www.geonames.org
Files derived from this source:
  assets/cities.tsv
  assets/cities_precise.tsv  (generated locally)
  assets/cities_detailed.tsv (generated locally)
  portions of assets/ports.tsv (generated locally)

You are free to copy, redistribute, and adapt this data in any medium or
format for any purpose, even commercially, provided you give appropriate
credit to GeoNames, provide a link to the licence, and indicate whether
any changes were made.

Full licence text: https://creativecommons.org/licenses/by/4.0/legalcode
''',
    );

    yield const LicenseEntryWithLineBreaks(
      ['NGA World Port Index (WPI)'],
      '''
United States Government Work — Public Domain

Data provider: National Geospatial-Intelligence Agency (NGA)
Publication 150 — World Port Index
Source: https://msi.nga.mil/Publications/WPI

This work was produced by an officer or employee of the United States
Government as part of their official duties and is not protected by
US copyright (17 U.S.C. § 105).

This designation does not automatically confer public-domain status
outside the United States; users in other jurisdictions should verify
their local law before redistribution.
''',
    );

    yield const LicenseEntryWithLineBreaks(
      ['OpenStreetMap contributors'],
      '''
Open Database Licence 1.0 (ODbL)

Data provider: OpenStreetMap contributors — https://www.openstreetmap.org
Retrieved via Overpass API — https://overpass-api.de

This notice applies when assets/ports.tsv was generated with the
--countries option in scripts/fetch_ports.py, which adds inland marina
and harbour data from OpenStreetMap.

The generated ports.tsv file is a Derived Database under the ODbL. Any
person who redistributes that file must make it available under the
ODbL 1.0 and include the attribution notice:
  "Contains data © OpenStreetMap contributors (ODbL)"

The ODbL share-alike requirement applies to the DATABASE FILE ONLY. It
does not extend to the application source code (MIT licence) or to the
compiled APK.

Full licence text: https://opendatacommons.org/licenses/odbl/1.0/
Attribution guidelines: https://www.openstreetmap.org/copyright
''',
    );
  });
}

class QthHelperApp extends StatelessWidget {
  const QthHelperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QTH Dashboard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        // Disable Material 3's scroll-under surface tint — it turns AppBars and
        // bottom sheets grey when content scrolls beneath them, which clashes
        // with the app's custom day/night colour system.
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.black,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        colorScheme: const ColorScheme.dark(
          surface: Colors.black,
          surfaceTint: Colors.transparent,
        ),
        // Tooltips: M3 inverseSurface defaults to near-white — wrong for night mode.
        // Use kNBg (near-black, dark-red family) + kN1 (medium red) so no grey
        // ever appears in night mode.  In day mode the near-black bg + red text
        // looks dark but remains readable and is consistent with the red palette.
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: kNBg,  // 0xFF1A0000 — near-black from the night palette
            borderRadius: BorderRadius.circular(4),
          ),
          textStyle: const TextStyle(
            color: kN1,   // 0xFFCC1111 — primary red
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
          waitDuration: const Duration(milliseconds: 600),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
