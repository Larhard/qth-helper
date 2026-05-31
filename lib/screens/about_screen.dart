import 'package:flutter/material.dart';

/// About / Legal screen.
///
/// Satisfies in-app attribution requirements for:
///   • GeoNames city / harbour data  — CC BY 4.0 (attribution required)
///   • OpenStreetMap contributors     — ODbL 1.0  (attribution required)
///   • NGA World Port Index           — public domain (attribution by custom)
///
/// The "Open Source Licences" button opens Flutter's built-in licence page,
/// which renders all package licences registered via LicenseRegistry (see
/// main.dart for the data-source entries we add there).
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: const Color(0xFFAAAAAA),
        elevation: 0,
        title: const Text('About & Legal',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Color(0xFFAAAAAA))),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: [
          // ── App identity ──────────────────────────────────────────────────
          const Text('QTH Dashboard',
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
          const SizedBox(height: 4),
          const Text('v1.1.0',
              style: TextStyle(fontSize: 13, color: Color(0xFF666666))),
          const SizedBox(height: 12),
          _disclaimer(),

          _divider(),

          // ── Legally required attribution notices ──────────────────────────
          _sectionTitle('Data Attributions'),
          const SizedBox(height: 12),

          _credit(
            icon: Icons.location_city,
            title: 'City data',
            body: 'Provided by GeoNames (geonames.org).\n'
                'Used under the Creative Commons Attribution 4.0 '
                'International licence (CC BY 4.0).\n'
                'https://creativecommons.org/licenses/by/4.0/',
          ),

          const SizedBox(height: 16),

          _credit(
            icon: Icons.anchor,
            title: 'Port data — NGA World Port Index',
            body: 'Publication 150 produced by the National Geospatial-Intelligence '
                'Agency (NGA), United States Government.\n'
                'This is a United States Government work and is not subject '
                'to copyright protection in the United States '
                '(17 U.S.C. § 105).\n'
                'https://msi.nga.mil/Publications/WPI',
          ),

          const SizedBox(height: 16),

          _credit(
            icon: Icons.map_outlined,
            title: '© OpenStreetMap contributors',
            body: 'Inland marina and harbour data (where present) obtained '
                'from OpenStreetMap via the Overpass API.\n'
                'OpenStreetMap data is made available under the '
                'Open Database Licence 1.0 (ODbL).\n'
                'The generated ports.tsv file, when it contains OSM-derived '
                'data, is a Derived Database under the ODbL and must be '
                'redistributed under ODbL 1.0.\n'
                'https://www.openstreetmap.org/copyright\n'
                'https://opendatacommons.org/licenses/odbl/1.0/',
          ),

          _divider(),

          // ── Package licences ──────────────────────────────────────────────
          _sectionTitle('Open Source Software'),
          const SizedBox(height: 8),
          const Text(
            'This app is built with Flutter and uses several open-source '
            'packages. Tap below to view their individual licences, as '
            'required by the BSD-3-Clause and MIT terms under which they '
            'are distributed.',
            style: TextStyle(
                fontSize: 13,
                color: Color(0xFF888888),
                height: 1.5),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'QTH Dashboard',
              applicationVersion: 'v1.1.0',
              applicationLegalese:
                  '© 2025 Bartłomiej Puget\n\n'
                  'City data © GeoNames (CC BY 4.0)\n'
                  'Port data: NGA WPI (public domain) + '
                  '© GeoNames (CC BY 4.0) + '
                  '© OpenStreetMap contributors (ODbL)',
            ),
            icon: const Icon(Icons.article_outlined, size: 18),
            label: const Text('Open Source Licences'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFAAAAAA),
              side: const BorderSide(color: Color(0xFF333333)),
            ),
          ),

          _divider(),

          // ── App licence ───────────────────────────────────────────────────
          _sectionTitle('App Source Code'),
          const SizedBox(height: 8),
          const Text(
            'The application source code is licensed under the MIT Licence.\n'
            'Copyright © 2025 Bartłomiej Puget.',
            style: TextStyle(
                fontSize: 13,
                color: Color(0xFF888888),
                height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _disclaimer() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFF2A2A00)),
          borderRadius: BorderRadius.circular(6),
          color: const Color(0xFF0A0A00),
        ),
        child: const Text(
          '⚠  Vibe-coded — built with AI assistance. No formal testing, '
          'safety audit, or regulatory review has been performed. '
          'Never rely on this app as your sole means of navigation.',
          style: TextStyle(
              fontSize: 12, color: Color(0xFF888844), height: 1.5),
        ),
      );

  Widget _sectionTitle(String text) => Text(text,
      style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Color(0xFF777777),
          letterSpacing: 1.5));

  Widget _divider() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Divider(color: Color(0xFF1A1A1A), height: 1),
      );

  Widget _credit({
    required IconData icon,
    required String title,
    required String body,
  }) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: const Color(0xFF555555)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFCCCCCC))),
                const SizedBox(height: 4),
                Text(body,
                    style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF777777),
                        height: 1.55)),
              ],
            ),
          ),
        ],
      );
}
