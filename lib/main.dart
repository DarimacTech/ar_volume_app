import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:ar_flutter_plugin/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin/models/ar_anchor.dart';
import 'package:ar_flutter_plugin/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin/datatypes/config_planedetection.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AR Volume Measure',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black87,
          elevation: 0,
        ),
      ),
      home: const ARScreen(),
    );
  }
}

// ─── Data model for a placed corner point ─────────────────────────────────────
class _CornerPoint {
  final Vector3 worldPosition;
  final ARAnchor anchor;
  final String sphereNodeName; // native sphere name

  const _CornerPoint({
    required this.worldPosition,
    required this.anchor,
    required this.sphereNodeName,
  });
}

class ARScreen extends StatefulWidget {
  const ARScreen({super.key});

  @override
  State<ARScreen> createState() => _ARScreenState();
}

class _ARScreenState extends State<ARScreen> with WidgetsBindingObserver {
  // ─── AR Managers ─────────────────────────────────────────────────────────
  ARSessionManager? _arSessionManager;
  ARObjectManager? _arObjectManager;
  ARAnchorManager? _arAnchorManager;

  // ─── State ────────────────────────────────────────────────────────────────
  final List<_CornerPoint> _corners = [];

  // Line node names (so we can remove them on reset/undo)
  final List<String> _lineNodeNames = [];
  String? _volumeNodeName;

  double _length = 0, _width = 0, _height = 0, _volume = 0;
  bool _isProcessingTap = false;
  bool _arReady = false;
  String _statusMessage = '📱 Move phone slowly to scan a flat surface…';
  String? _validationWarning;

  static const int _maxCorners = 8;
  static const double _minDistance = 0.02; // 2 cm minimum between points
  static const double _maxDistance = 10.0; // 10 m sanity limit
  int _nodeCounter = 0; // ensures unique names

  String _uniqueName(String prefix) => '${prefix}_${_nodeCounter++}';

  // ─── Lifecycle ────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // _disposeAR is async but dispose() is sync.
    // We fire it unawaited — it runs on the platform channel which is
    // still alive long enough for the method calls to be queued.
    unawaited(_disposeAR());
    super.dispose();
  }

  // Note: AR session lifecycle (pause/resume) is handled automatically by
  // the plugin's native ActivityLifecycleCallbacks in AndroidARView.kt

  Future<void> _disposeAR() async {
    try {
      // Remove all line nodes
      for (final name in _lineNodeNames) {
        _arObjectManager?.removeNodeByName(name);
      }
      // Remove all sphere markers and anchors
      for (final corner in _corners) {
        _arObjectManager?.removeNodeByName(corner.sphereNodeName);
        _arAnchorManager?.removeAnchor(corner.anchor);
      }
      if (_volumeNodeName != null) {
      _arObjectManager?.removeNodeByName(_volumeNodeName!);
      _volumeNodeName = null;
    }
    _arSessionManager?.dispose();
    } catch (e) {
      debugPrint('disposeAR error: $e');
    }
  }

  // ─── AR Init ──────────────────────────────────────────────────────────────
  void onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) {
    _arSessionManager = sessionManager;
    _arObjectManager = objectManager;
    _arAnchorManager = anchorManager;

    _arSessionManager!.onInitialize(
      showFeaturePoints: false, // ← MUST be false: true causes OOM crash at 60fps
      showPlanes: true,
      showAnimatedGuide: true,
      handleTaps: true,
    );
    _arObjectManager!.onInitialize();
    _arSessionManager!.onPlaneOrPointTap = _onTap;

    if (!mounted) return;
    setState(() {
      _arReady = true;
      _statusMessage = '📱 Move phone slowly to scan a flat surface…';
    });
  }

  // ─── Tap Handler ──────────────────────────────────────────────────────────
  Future<void> _onTap(List<ARHitTestResult> hits) async {
    if (_isProcessingTap) return;
    if (hits.isEmpty) return;
    if (_corners.length >= _maxCorners) {
      _showSnack('✅ All 8 corners placed! Check measurements or tap ↺ to reset.');
      return;
    }

    // Set BEFORE try so finally always clears it
    _isProcessingTap = true;

    try {
      final hit = hits.first;
      final position = hit.worldTransform.getTranslation();

      // ── Validation ──────────────────────────────────────────────────────
      // Check distance from first corner only for max-distance (not every corner)
      if (_corners.isNotEmpty) {
        final distFromFirst = (position - _corners[0].worldPosition).length;
        if (distFromFirst > _maxDistance) {
          _showSnack('⚠️ Point too far from Corner 1 (>10 m). Scan the correct surface.');
          return; // finally will clear _isProcessingTap
        }
      }
      for (final c in _corners) {
        final dist = (c.worldPosition - position).length;
        if (dist < _minDistance) {
          _showSnack('⚠️ Too close to an existing corner. Tap further away.');
          return; // finally will clear _isProcessingTap
        }
      }

      // ── Place anchor ────────────────────────────────────────────────────
      final anchor = ARPlaneAnchor(transformation: hit.worldTransform);
      final bool anchorAdded = await _arAnchorManager?.addAnchor(anchor) ?? false;
      if (!anchorAdded) {
        debugPrint('Anchor add failed');
        _showSnack('Could not place anchor. Tap on a detected plane (white grid).');
        return; // finally will clear _isProcessingTap
      }

      // ── Place native sphere marker ───────────────────────────────────────
      final sphereName = _uniqueName('sphere');
      final bool sphereAdded = await _arObjectManager?.addNativeSphereMarker(
            anchorName: anchor.name,
            nodeName: sphereName,
            radius: 0.025,
          ) ??
          false;

      if (!mounted) return;

      if (sphereAdded) {
        final newCorner = _CornerPoint(
          worldPosition: position,
          anchor: anchor,
          sphereNodeName: sphereName,
        );

        // ── Add corner FIRST so index math is correct ────────────────────
        setState(() {
          _corners.add(newCorner);
          _updateCalculations();
          _statusMessage = _getInstructionText();
        });

        // ── Draw edges AFTER setState (corner is now in list) ────────────
        final n = _corners.length; // length AFTER adding

        if (n >= 2) {
          // Sequential base edges: 1→2, 2→3, 3→4
          if (n <= 4) {
            await _drawLineBetween(
              _corners[n - 2].worldPosition,
              _corners[n - 1].worldPosition,
              label: 'baseEdge_${n - 1}',
            );
          }
          // Close base rectangle
          if (n == 4) {
            await _drawLineBetween(
              _corners[3].worldPosition,
              _corners[0].worldPosition,
              label: 'baseLine_close',
            );
          }
          // Sequential top edges: 5→6, 6→7, 7→8
          if (n >= 5 && n <= 8) {
            await _drawLineBetween(
              _corners[n - 2].worldPosition,
              _corners[n - 1].worldPosition,
              label: 'topEdge_${n - 1}',
            );
          }
          // Close top rectangle + draw all 4 vertical edges
          if (n == 8) {
            // Remove all temporary lines first
            for (final name in _lineNodeNames) {
              _arObjectManager?.removeNodeByName(name);
            }
            _lineNodeNames.clear();

            // Draw the cohesive 3D Volume (Mesh)
            final volName = _uniqueName('volume_box');
            final pts = _corners.map((c) => c.worldPosition).toList();
            final ok = await _arObjectManager?.addNativeVolume(
              name: volName,
              points: pts,
            ) ?? false;
            if (ok) _volumeNodeName = volName;
          }
        }

        _showSnack(
          'Corner $n placed!',
          duration: const Duration(milliseconds: 700),
        );
      } else {
        // Sphere failed → clean up anchor
        _arAnchorManager?.removeAnchor(anchor);
        _showSnack('Failed to place marker. Try tapping again.');
        debugPrint('Native sphere add failed – anchor cleaned up');
      }
    } catch (e) {
      debugPrint('onTap error: $e');
      if (mounted) _showSnack('Error placing point. Try again.');
    } finally {
      // ALWAYS clears the lock, even on early return
      _isProcessingTap = false;
    }
  }


  Future<void> _drawLineBetween(Vector3 from, Vector3 to, {required String label}) async {
    final lineName = _uniqueName(label);
    final ok = await _arObjectManager?.addNativeLine(
          name: lineName,
          from: from,
          to: to,
        ) ??
        false;
    if (ok) _lineNodeNames.add(lineName);
  }

  // ─── Calculations ─────────────────────────────────────────────────────────
  void _updateCalculations() {
    _length = 0;
    _width = 0;
    _height = 0;
    _volume = 0;
    _validationWarning = null;

    final pts = _corners.map((c) => c.worldPosition).toList();
    final n = pts.length;

    if (n >= 2) _length = _dist(pts[0], pts[1]);
    if (n >= 3) _width = _dist(pts[1], pts[2]);

    if (n == _maxCorners) {
      // Base face (corners 0-3)
      final d12 = _dist(pts[0], pts[1]);
      final d23 = _dist(pts[1], pts[2]);
      final d34 = _dist(pts[2], pts[3]);
      final d41 = _dist(pts[3], pts[0]);

      // Top face (corners 4-7)
      final d56 = _dist(pts[4], pts[5]);
      final d67 = _dist(pts[5], pts[6]);
      final d78 = _dist(pts[6], pts[7]);
      final d85 = _dist(pts[7], pts[4]);

      final avgL = (d12 + d34) / 2;
      final avgW = (d23 + d41) / 2;
      final avgTopL = (d56 + d78) / 2;
      final avgTopW = (d67 + d85) / 2;

      final baseArea = avgL * avgW;
      final topArea = avgTopL * avgTopW;

      // Height = average of 4 vertical edges
      final h1 = _dist(pts[0], pts[4]);
      final h2 = _dist(pts[1], pts[5]);
      final h3 = _dist(pts[2], pts[6]);
      final h4 = _dist(pts[3], pts[7]);
      _height = (h1 + h2 + h3 + h4) / 4;
      _length = (avgL + avgTopL) / 2;
      _width = (avgW + avgTopW) / 2;

      // Prismatoid: (A_base + A_top) / 2 × height
      _volume = ((baseArea + topArea) / 2) * _height;

      // ── Sanity validation ──────────────────────────────────────────────
      final heightVariance = [h1, h2, h3, h4]
          .map((h) => (h - _height).abs())
          .reduce((a, b) => a + b) / 4;
      if (heightVariance > 0.05) {
        _validationWarning =
            '⚠️ Height inconsistency detected (${(heightVariance * 100).toStringAsFixed(1)} cm off). Re-place top corners more carefully.';
      }
      if (_length < 0.03 || _width < 0.03 || _height < 0.03) {
        _validationWarning = '⚠️ Object may be too small. Check if corners are correct.';
      }
    }
  }

  double _dist(Vector3 a, Vector3 b) => (a - b).length;

  // ─── Reset / Undo ─────────────────────────────────────────────────────────
  Future<void> _resetPoints() async {
    if (_isProcessingTap) return; // prevent double-tap
    _isProcessingTap = true;
    try {
      // Remove all lines
      for (final name in _lineNodeNames) {
        _arObjectManager?.removeNodeByName(name);
      }
      // Remove all spheres and anchors
      for (final corner in _corners) {
        _arObjectManager?.removeNodeByName(corner.sphereNodeName);
        _arAnchorManager?.removeAnchor(corner.anchor);
      }

      // Remove volume box
    if (_volumeNodeName != null) {
      _arObjectManager?.removeNodeByName(_volumeNodeName!);
      _volumeNodeName = null;
    }

    if (!mounted) return;
      setState(() {
        _corners.clear();
        _lineNodeNames.clear();
        _updateCalculations();
        _statusMessage = '📱 Tap a flat surface to place Corner 1';
      });
      _showSnack('Measurement reset ✓');
    } finally {
      _isProcessingTap = false;
    }
  }


  Future<void> _removeLastPoint() async {
    if (_corners.isEmpty) return;
    if (_isProcessingTap) return; // prevent double-tap undo desync

    _isProcessingTap = true;
    try {
      // Remove ALL lines first
      for (final name in _lineNodeNames) {
        _arObjectManager?.removeNodeByName(name);
      }
      _lineNodeNames.clear();

      // Remove volume box if exists
    if (_volumeNodeName != null) {
      _arObjectManager?.removeNodeByName(_volumeNodeName!);
      _volumeNodeName = null;
    }

    final last = _corners.last;
      _arObjectManager?.removeNodeByName(last.sphereNodeName);
      _arAnchorManager?.removeAnchor(last.anchor);

      if (!mounted) return;
      setState(() {
        _corners.removeLast();
        _updateCalculations();
        _statusMessage = _getInstructionText();
      });

      // Redraw remaining lines
      await _redrawAllLines();

      _showSnack('Last corner removed', duration: const Duration(milliseconds: 700));
    } finally {
      _isProcessingTap = false;
    }
  }

  /// Redraws all edge lines based on current _corners list (after undo)
  Future<void> _redrawAllLines() async {
    final pts = _corners.map((c) => c.worldPosition).toList();
    final n = pts.length;

    // Base face sequential edges
    for (int i = 1; i < n && i < 4; i++) {
      await _drawLineBetween(pts[i - 1], pts[i], label: 'baseEdge_$i');
    }
    // Close base face for n >= 4
    if (n >= 4) {
      await _drawLineBetween(pts[3], pts[0], label: 'baseLine_close');
    }
    // Top face sequential edges (indices 4-7)
    for (int i = 5; i < n; i++) {
      await _drawLineBetween(pts[i - 1], pts[i], label: 'topEdge_$i');
    }
    // Close top face + vertical edges
    if (n == 8) {
      await _drawLineBetween(pts[7], pts[4], label: 'topLine_close');
      for (int i = 0; i < 4; i++) {
        await _drawLineBetween(pts[i], pts[i + 4], label: 'vertEdge_$i');
      }
    }
  }

  // ─── UI Helpers ───────────────────────────────────────────────────────────
  String _getInstructionText() {
    const labels = [
      '📍 Tap → Base Corner 1 (any corner of the base)',
      '📍 Tap → Base Corner 2 (adjacent to Corner 1)',
      '📍 Tap → Base Corner 3 (opposite Corner 2)',
      '📍 Tap → Base Corner 4 (complete the base rectangle)',
      '📍 Tap → Top Corner 1 (directly above Base Corner 1)',
      '📍 Tap → Top Corner 2 (directly above Base Corner 2)',
      '📍 Tap → Top Corner 3 (directly above Base Corner 3)',
      '📍 Tap → Top Corner 4 (directly above Base Corner 4)',
    ];
    if (_corners.length < labels.length) return labels[_corners.length];
    return '✅ All 8 corners placed! Review measurements above.';
  }

  void _showSnack(String msg, {Duration duration = const Duration(seconds: 2)}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: duration,
        backgroundColor: Colors.grey[900],
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
  }

  // ─── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AR Volume Measure',
            style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Remove last corner',
            onPressed: _corners.isEmpty || _isProcessingTap ? null : _removeLastPoint,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reset all',
            onPressed: _corners.isEmpty ? null : _resetPoints,
          ),
        ],
      ),
      body: Stack(
        children: [
          // ── AR View ─────────────────────────────────────────────────────
          ARView(
            onARViewCreated: onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
          ),

          // ── Measurement card ─────────────────────────────────────────────
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: _MeasurementCard(
              length: _length,
              width: _width,
              height: _height,
              volume: _volume,
              statusMessage: _statusMessage,
              validationWarning: _validationWarning,
              cornerCount: _corners.length,
              maxCorners: _maxCorners,
            ),
          ),

          // ── AR not ready overlay ─────────────────────────────────────────
          if (!_arReady)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.cyanAccent),
                    SizedBox(height: 16),
                    Text('Initializing AR Camera…',
                        style: TextStyle(color: Colors.white, fontSize: 16)),
                  ],
                ),
              ),
            ),

          // ── Processing tap spinner ───────────────────────────────────────
          if (_isProcessingTap)
            const Positioned(
              bottom: 32,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5, color: Colors.cyanAccent),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Measurement Card Widget ──────────────────────────────────────────────────
class _MeasurementCard extends StatelessWidget {
  const _MeasurementCard({
    required this.length,
    required this.width,
    required this.height,
    required this.volume,
    required this.statusMessage,
    required this.cornerCount,
    required this.maxCorners,
    this.validationWarning,
  });

  final double length, width, height, volume;
  final String statusMessage;
  final String? validationWarning;
  final int cornerCount, maxCorners;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.black.withValues(alpha: 0.80),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      elevation: 10,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Progress
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Corners: $cornerCount / $maxCorners',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                if (cornerCount == maxCorners)
                  const Icon(Icons.check_circle, color: Colors.greenAccent, size: 16),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: cornerCount / maxCorners,
                minHeight: 5,
                backgroundColor: Colors.white12,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(Colors.cyanAccent),
              ),
            ),
            const SizedBox(height: 12),

            // Dimensions
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _Stat(label: 'Length', value: length),
                _Stat(label: 'Width', value: width),
                _Stat(label: 'Height', value: height),
              ],
            ),
            const Divider(color: Colors.white24, height: 18),

            // Volume
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Column(
                  children: [
                    Text(
                      '${volume.toStringAsFixed(4)} m³',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold),
                    ),
                    if (volume > 0)
                      Text(
                        '≈ ${(volume * 1000).toStringAsFixed(2)} L   /   '
                        '${(volume * 1000000).toStringAsFixed(0)} cm³',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11),
                      ),
                  ],
                ),
              ],
            ),

            // Validation warning
            if (validationWarning != null) ...[
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
                ),
                child: Text(
                  validationWarning!,
                  style: const TextStyle(
                      color: Colors.orangeAccent, fontSize: 11),
                  textAlign: TextAlign.center,
                ),
              ),
            ],

            const SizedBox(height: 8),
            Text(
              statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: const TextStyle(color: Colors.white54, fontSize: 11)),
        Text(
          '${value.toStringAsFixed(3)} m',
          style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 13),
        ),
      ],
    );
  }
}
