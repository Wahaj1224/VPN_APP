import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:openvpn_flutter/openvpn_flutter.dart';

import 'models/vpn.dart';
import 'models/vpn_status.dart' as model;
import 'models/softether_config.dart';
import 'vpn_port.dart';
import '../../platform/softether_channel.dart';

/// SoftEther VPN port implementation
/// Communicates with SoftEther VPN server via vpncmd API
class SoftEtherPort implements VpnPort {
  SoftEtherPort();

  final StreamController<String> _intentActionsController =
      StreamController<String>.broadcast();
  final StreamController<VPNStage> _stageController =
      StreamController<VPNStage>.broadcast();
  final StreamController<model.VpnStatus> _statusController =
      StreamController<model.VpnStatus>.broadcast();

  bool _isConnected = false;
  bool _isInitialized = false;
  SoftEtherConfig? _currentConfig;
  Timer? _healthCheckTimer;
  model.VpnStatus? _lastStatus;

  @override
  bool get isSupported => true;

  @override
  Stream<String> get intentActions => _intentActionsController.stream;

  @override
  Stream<VPNStage> get stageStream => _stageController.stream;

  @override
  Stream<model.VpnStatus> get statusStream => _statusController.stream;

  /// Initialize SoftEther port
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      debugPrint('[SoftEtherPort] Initializing SoftEther VPN port');
      _isInitialized = true;
      debugPrint('[SoftEtherPort] SoftEther port initialized successfully');
    } catch (e) {
      debugPrint('[SoftEtherPort] Error initializing SoftEther: $e');
      _isInitialized = false;
      rethrow;
    }
  }

  @override
  Future<bool> prepare() async {
    if (!_isInitialized) {
      await initialize();
    }

    // Request VPN permission from Android through native channel
    final channel = SoftEtherChannel();
    final granted = await channel.prepare();
    debugPrint('[SoftEtherPort] VPN permission granted: $granted');
    return granted;
  }

  @override
  Future<bool> connect(Vpn server) async {
    // This method is for OpenVPN compatibility
    // SoftEther uses the connectSoftEther method instead
    debugPrint('[SoftEtherPort] connect(Vpn) called but SoftEther requires connectSoftEther()');
    return false;
  }

  /// Connect to SoftEther VPN with configuration
  Future<bool> connectSoftEther(SoftEtherConfig config) async {
    try {
      debugPrint('[SoftEtherPort] Connecting to SoftEther VPN: ${config.connectionName}');
      debugPrint('[SoftEtherPort] Server: ${config.serverAddress}:${config.serverPort}');
      debugPrint('[SoftEtherPort] Protocol: ${config.protocol.displayName}');

      if (!_isInitialized) {
        await initialize();
      }

      if (_isConnected) {
        await disconnect();
        await Future.delayed(const Duration(seconds: 1));
      }

      _currentConfig = config;

      // Validate configuration
      if (!config.isValid) {
        final errors = config.getErrors();
        debugPrint('[SoftEtherPort] Invalid configuration: $errors');
        _stageController.add(VPNStage.error);
        return false;
      }

      // Update status to connecting
      _stageController.add(VPNStage.connecting);

      // Try native SoftEther implementation first
      final channel = SoftEtherChannel();
      final nativeAvailable = await channel.initialize();
      if (nativeAvailable) {
        debugPrint('[SoftEtherPort] Native SoftEther client available, attempting connection...');

        final connected = await channel.connect(config);
        if (connected) {
          _isConnected = true;
          _stageController.add(VPNStage.connected);

          // Start health check
          _startHealthCheck();

          debugPrint('[SoftEtherPort] SoftEther VPN connected successfully via native client');
          return true;
        } else {
          debugPrint('[SoftEtherPort] Native SoftEther connection failed');
          _stageController.add(VPNStage.error);
          return false;
        }
      }

      // Fallback to API approach if native not available
      debugPrint('[SoftEtherPort] Native SoftEther client not available, falling back to API approach');
      final apiUrl = 'http://100.28.211.202:8000/api/softether/connect';
      debugPrint('[SoftEtherPort] Making API call to: $apiUrl');

      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'connectionName': config.connectionName,
          'serverAddress': config.serverAddress,
          'serverPort': config.serverPort,
          'protocol': config.protocol.name.toLowerCase(), // Convert enum to string
          'presharedKey': config.presharedKey,
          'username': config.username,
          'password': config.password,
          'useEncryption': config.useEncryption,
          'useCompression': config.useCompression,
        }),
      ).timeout(const Duration(seconds: 30));

      debugPrint('[SoftEtherPort] API response status: ${response.statusCode}');
      debugPrint('[SoftEtherPort] API response body: ${response.body}');

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        if (responseData['success'] == true) {
          _isConnected = true;
          _stageController.add(VPNStage.connected);

          // Start health check
          _startHealthCheck();

          debugPrint('[SoftEtherPort] SoftEther connection established successfully via API');
          return true;
        } else {
          debugPrint('[SoftEtherPort] API returned success=false: ${responseData['error']}');
          _stageController.add(VPNStage.error);
          return false;
        }
      } else {
        debugPrint('[SoftEtherPort] API call failed with status ${response.statusCode}');
        _stageController.add(VPNStage.error);
        return false;
      }
    } catch (e, stackTrace) {
      debugPrint('[SoftEtherPort] Error connecting to SoftEther VPN: $e');
      debugPrint('[SoftEtherPort] Stack trace: $stackTrace');
      _isConnected = false;
      _stageController.add(VPNStage.error);
      return false;
    }
  }

  /// Start health check timer
  void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _performHealthCheck();
    });
  }

  /// Perform health check
  Future<void> _performHealthCheck() async {
    try {
      // Check native connection status first
      final channel = SoftEtherChannel();
      final nativeConnected = await channel.isConnected();
      if (!nativeConnected) {
        debugPrint('[SoftEtherPort] Native SoftEther service disconnected');
        _isConnected = false;
        _stageController.add(VPNStage.disconnected);
        return;
      }

      // Also check API status if config available
      if (_currentConfig != null) {
        final apiUrl = 'http://100.28.211.202:8000/api/softether/status/${_currentConfig!.connectionName}';
        final response = await http.get(Uri.parse(apiUrl)).timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          final responseData = jsonDecode(response.body);
          if (responseData['success'] == true && responseData['status'] == 'connected') {
            // Still connected
            return;
          }
        }
      }

      // If we get here, connection is lost
      _isConnected = false;
      _stageController.add(VPNStage.disconnected);
    } catch (e) {
      debugPrint('[SoftEtherPort] Health check error: $e');
      // On health check error, assume connection is lost
      _isConnected = false;
      _stageController.add(VPNStage.disconnected);
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      debugPrint('[SoftEtherPort] disconnect() requested');

      // Try native disconnect first
      try {
        final channel = SoftEtherChannel();
        await channel.disconnect();
        debugPrint('[SoftEtherPort] Native SoftEther disconnect called successfully');
      } catch (e) {
        debugPrint('[SoftEtherPort] Error calling native disconnect: $e');
      }

      // Also make API call to disconnect (for cleanup)
      if (_currentConfig != null) {
        final apiUrl = 'http://100.28.211.202:8000/api/softether/disconnect';
        final response = await http.post(
          Uri.parse(apiUrl),
          headers: {
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'connectionName': _currentConfig!.connectionName,
          }),
        ).timeout(const Duration(seconds: 10));

        debugPrint('[SoftEtherPort] Disconnect API response: ${response.statusCode}');
      }

      _healthCheckTimer?.cancel();
      _healthCheckTimer = null;

      _isConnected = false;
      _currentConfig = null;

      if (!_stageController.isClosed) {
        _stageController.add(VPNStage.disconnected);
      }

      debugPrint('[SoftEtherPort] SoftEther disconnected successfully');
    } catch (e) {
      debugPrint('[SoftEtherPort] Error disconnecting from VPN: $e');
    }
  }

  @override
  Future<bool> isConnected() async {
    try {
      // Check native connection status
      final channel = SoftEtherChannel();
      final nativeConnected = await channel.isConnected();

      // Update local flag to match native status
      _isConnected = nativeConnected;

      debugPrint('[SoftEtherPort] isConnected check: native=$nativeConnected');
      return nativeConnected;
    } catch (e) {
      debugPrint('[SoftEtherPort] Error checking connection status: $e');
      return false;
    }
  }

  @override
  Future<Map<String, dynamic>> getTunnelStats() async {
    return _lastStatus?.toJson() ?? <String, dynamic>{};
  }

  @override
  Future<void> extendSession(Duration duration, {String? publicIp}) async {
    // Session extension is handled at the app level for SoftEther
    // This is a no-op
  }

  /// Dispose resources
  void dispose() {
    _healthCheckTimer?.cancel();
    try {
      if (!_intentActionsController.isClosed) {
        _intentActionsController.close();
      }
    } catch (e) {
      debugPrint('[SoftEtherPort] Error closing intent actions controller: $e');
    }

    try {
      if (!_stageController.isClosed) {
        _stageController.close();
      }
    } catch (e) {
      debugPrint('[SoftEtherPort] Error closing stage controller: $e');
    }

    try {
      if (!_statusController.isClosed) {
        _statusController.close();
      }
    } catch (e) {
      debugPrint('[SoftEtherPort] Error closing status controller: $e');
    }
  }

  /// Get current configuration
  SoftEtherConfig? get currentConfig => _currentConfig;
}
