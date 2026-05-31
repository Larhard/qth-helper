import 'dart:math';

/// Derives a smoothed track bearing from a dynamically maintained spatial buffer.
///
/// ### Why not first-to-last?
/// The naive approach — `bearing(buffer.first, buffer.last)` — has two fragile
/// endpoints. A noisy last fix corrupts the bearing immediately, and the bearing
/// jumps when the oldest "anchor" cycles out of a full buffer.
///
/// ### Weighted vector sum
/// Every consecutive step in the buffer contributes a heading vector weighted by:
///   - **step distance** — longer steps are more reliable
///   - **recency** — newer steps matter more (linear ramp: oldest ≈ 1/n, newest = 1)
///
/// The resultant vector's direction is the bearing. A noise spike — a single short
/// step in a random direction — contributes ~1/n of the weight of the newest step
/// and is drowned out by the accumulated direction of sustained travel.
///
/// ### Buffer eviction
/// When the buffer exceeds [maxSize]:
///   - If the span (first → last) already exceeds [maxSpanM], the oldest point
///     is evicted — the buffer slides forward as a spatial window.
///   - Otherwise, the consecutive pair with the smallest separation is collapsed
///     by removing its older member. This maximises spatial diversity rather than
///     blindly evicting the oldest sample, so the bearing stays well-conditioned
///     even after long stationary periods with occasional jitter.
class TrackBearingEstimator {
  TrackBearingEstimator({
    this.maxSize = 10,
    this.minSepM = 8.0,
    this.maxSpanM = 80.0,
  });

  /// Maximum number of points to hold in the buffer.
  final int maxSize;

  /// Minimum distance (metres) from the last stored point before a new point is
  /// accepted. Acts as a noise floor — not a speed gate — so slow walking still
  /// accumulates data.
  final double minSepM;

  /// Once the straight-line span between the oldest and newest stored points
  /// exceeds this (metres), eviction switches to removing the oldest point
  /// (sliding spatial window) instead of collapsing the densest cluster.
  /// 80 m means the bearing adapts within ~80 m of a direction change —
  /// about 90 s at hiking pace, fast enough for switchback trails.
  final double maxSpanM;

  final _buf = <_Pt>[];

  /// Latest computed bearing in degrees [0, 360), or null if fewer than two
  /// points have been accepted.
  double? bearing;

  /// Feed a new GPS fix. The bearing is updated synchronously if the point
  /// passes the separation filter.
  void update(double lat, double lon) {
    if (_buf.isNotEmpty && _buf.last.distTo(lat, lon) < minSepM) return;

    _buf.add(_Pt(lat, lon));
    if (_buf.length > maxSize) _evict();
    bearing = _buf.length >= 2 ? _computeBearing() : null;
  }

  /// Discard all stored points and reset the bearing. Call when GPS signal is
  /// lost or position stream is restarted so stale spatial data is not mixed
  /// with a fresh session.
  void clear() {
    _buf.clear();
    bearing = null;
  }

  void _evict() {
    // Once the buffer spans beyond maxSpanM we have ample spatial coverage;
    // just slide the window forward.
    if (_buf.first.distTo(_buf.last.lat, _buf.last.lon) > maxSpanM) {
      _buf.removeAt(0);
      return;
    }

    // Below maxSpanM: maximise spatial spread by collapsing the densest cluster.
    // Find the consecutive pair (i, i+1) with the smallest separation and remove
    // point i.  The newest point is never a removal candidate.
    int evictIdx = 0;
    double minD = double.infinity;
    for (int i = 0; i < _buf.length - 1; i++) {
      final d = _buf[i].distTo(_buf[i + 1].lat, _buf[i + 1].lon);
      if (d < minD) {
        minD = d;
        evictIdx = i;
      }
    }
    _buf.removeAt(evictIdx);
  }

  double _computeBearing() {
    // Accumulate north (sumN) and east (sumE) components of all step vectors.
    // Weight for step (i-1 → i) = distance × recency, where recency = i / n
    // (ranges from 1/n for the oldest step to (n-1)/n for the newest step).
    double sumN = 0.0;
    double sumE = 0.0;
    final n = _buf.length;
    for (int i = 1; i < n; i++) {
      final d = _buf[i - 1].distTo(_buf[i].lat, _buf[i].lon);
      if (d < 0.5) continue; // skip sub-metre floating-point noise
      final b = _bearingRad(_buf[i - 1], _buf[i]);
      final w = d * (i / n);
      sumN += cos(b) * w;
      sumE += sin(b) * w;
    }
    if (sumN.abs() < 1e-9 && sumE.abs() < 1e-9) return 0.0;
    return (atan2(sumE, sumN) * 180 / pi + 360) % 360;
  }
}

// ── Internal helpers ──────────────────────────────────────────────────────────

class _Pt {
  const _Pt(this.lat, this.lon);

  final double lat;
  final double lon;

  /// Flat-earth distance in metres. Error < 0.3 % within 10 km.
  double distTo(double lat2, double lon2) {
    final dLat = (lat2 - lat) * 111320.0;
    final dLon = (lon2 - lon) * 111320.0 * cos(lat * _deg2rad);
    return sqrt(dLat * dLat + dLon * dLon);
  }
}

double _bearingRad(_Pt a, _Pt b) {
  final dLon = (b.lon - a.lon) * _deg2rad;
  final lat1 = a.lat * _deg2rad;
  final lat2 = b.lat * _deg2rad;
  return atan2(
    sin(dLon) * cos(lat2),
    cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon),
  );
}

const _deg2rad = pi / 180;
