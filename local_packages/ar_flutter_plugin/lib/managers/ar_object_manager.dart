import 'dart:typed_data';

import 'package:ar_flutter_plugin/models/ar_anchor.dart';
import 'package:ar_flutter_plugin/models/ar_node.dart';
import 'package:ar_flutter_plugin/utils/json_converters.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart';


// Type definitions to enforce a consistent use of the API
typedef NodeTapResultHandler = void Function(List<String> nodes);
typedef NodePanStartHandler = void Function(String node);
typedef NodePanChangeHandler = void Function(String node);
typedef NodePanEndHandler = void Function(String node, Matrix4 transform);
typedef NodeRotationStartHandler = void Function(String node);
typedef NodeRotationChangeHandler = void Function(String node);
typedef NodeRotationEndHandler = void Function(String node, Matrix4 transform);

/// Manages the all node-related actions of an [ARView]
class ARObjectManager {
  /// Platform channel used for communication from and to [ARObjectManager]
  late MethodChannel _channel;

  /// Debugging status flag. If true, all platform calls are printed. Defaults to false.
  final bool debug;

  /// Callback function that is invoked when the platform detects a tap on a node
  NodeTapResultHandler? onNodeTap;
  NodePanStartHandler? onPanStart;
  NodePanChangeHandler? onPanChange;
  NodePanEndHandler? onPanEnd;
  NodeRotationStartHandler? onRotationStart;
  NodeRotationChangeHandler? onRotationChange;
  NodeRotationEndHandler? onRotationEnd;

  ARObjectManager(int id, {this.debug = false}) {
    _channel = MethodChannel('arobjects_$id');
    _channel.setMethodCallHandler(_platformCallHandler);
    if (debug) {
      print("ARObjectManager initialized");
    }
  }

  Future<void> _platformCallHandler(MethodCall call) {
    if (debug) {
      print('_platformCallHandler call ${call.method} ${call.arguments}');
    }
    try {
      switch (call.method) {
        case 'onError':
          print(call.arguments);
          break;
        case 'onNodeTap':
          if (onNodeTap != null) {
            final tappedNodes = call.arguments as List<dynamic>;
            onNodeTap!(tappedNodes
                .map((tappedNode) => tappedNode.toString())
                .toList());
          }
          break;
        case 'onPanStart':
          if (onPanStart != null) {
            final tappedNode = call.arguments as String;
            // Notify callback
            onPanStart!(tappedNode);
          }
          break;
        case 'onPanChange':
          if (onPanChange != null) {
            final tappedNode = call.arguments as String;
            // Notify callback
            onPanChange!(tappedNode);
          }
          break;
        case 'onPanEnd':
          if (onPanEnd != null) {
            final tappedNodeName = call.arguments["name"] as String;
            final transform =
                MatrixConverter().fromJson(call.arguments['transform'] as List);

            // Notify callback
            onPanEnd!(tappedNodeName, transform);
          }
          break;
        case 'onRotationStart':
          if (onRotationStart != null) {
            final tappedNode = call.arguments as String;
            onRotationStart!(tappedNode);
          }
          break;
        case 'onRotationChange':
          if (onRotationChange != null) {
            final tappedNode = call.arguments as String;
            onRotationChange!(tappedNode);
          }
          break;
        case 'onRotationEnd':
          if (onRotationEnd != null) {
            final tappedNodeName = call.arguments["name"] as String;
            final transform =
                MatrixConverter().fromJson(call.arguments['transform'] as List);

            // Notify callback
            onRotationEnd!(tappedNodeName, transform);
          }
          break;
        default:
          if (debug) {
            print('Unimplemented method ${call.method} ');
          }
      }
    } catch (e) {
      print('Error caught: ' + e.toString());
    }
    return Future.value();
  }

  /// Sets up the AR Object Manager
  onInitialize() {
    _channel.invokeMethod<void>('init', {});
  }

  /// Add given node to the given anchor of the underlying AR scene (or to its top-level if no anchor is given) and listen to any changes made to its transformation
  Future<bool?> addNode(ARNode node, {ARPlaneAnchor? planeAnchor}) async {
    try {
      node.transformNotifier.addListener(() {
        _channel.invokeMethod<void>('transformationChanged', {
          'name': node.name,
          'transformation':
              MatrixValueNotifierConverter().toJson(node.transformNotifier)
        });
      });
      if (planeAnchor != null) {
        planeAnchor.childNodes.add(node.name);
        return await _channel.invokeMethod<bool>('addNodeToPlaneAnchor',
            {'node': node.toMap(), 'anchor': planeAnchor.toJson()});
      } else {
        return await _channel.invokeMethod<bool>('addNode', node.toMap());
      }
    } on PlatformException catch (e) {
      return false;
    }
  }

  /// Remove given node from the AR Scene
  removeNode(ARNode node) {
    _channel.invokeMethod<String>('removeNode', {'name': node.name});
  }

  /// Remove a node by its name (for native sphere/line nodes)
  removeNodeByName(String name) {
    _channel.invokeMethod<String>('removeNode', {'name': name});
  }

  /// Add a native sphere marker at the given anchor (NO network/GLB required).
  /// Returns true on success. [anchorName] must match an existing anchor's name.
  Future<bool> addNativeSphereMarker({
    required String anchorName,
    required String nodeName,
    double radius = 0.025,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>('addNativeSphereMarker', {
        'anchorName': anchorName,
        'name': nodeName,
        'radius': radius,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('addNativeSphereMarker error: $e');
      return false;
    }
  }

  /// Draw a 3D line (cylinder) between two world-space positions.
  /// [name] will be used to identify and remove the line later.
  Future<bool> addNativeLine({
    required String name,
    required Vector3 from,
    required Vector3 to,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>('addNativeLine', {
        'name': name,
        'fromX': from.x.toDouble(),
        'fromY': from.y.toDouble(),
        'fromZ': from.z.toDouble(),
        'toX': to.x.toDouble(),
        'toY': to.y.toDouble(),
        'toZ': to.z.toDouble(),
      });
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('addNativeLine error: $e');
      return false;
    }
  }

  /// Draw a 3D semi-transparent volume (box) between 8 world-space points.
  Future<bool> addNativeVolume({
    required String name,
    required List<Vector3> points,
  }) async {
    try {
      final List<List<double>> serializedPoints =
          points.map((p) => [p.x, p.y, p.z]).toList();
      final result = await _channel.invokeMethod<bool>('addNativeVolume', {
        'name': name,
        'points': serializedPoints,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('addNativeVolume error: $e');
      return false;
    }
  }
}


