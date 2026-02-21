import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../../../core/utils/iterable_extensions.dart';
// Ads removed for unlimited sessions
import '../../../services/notifications/session_notification_service.dart';
import '../../../services/storage/prefs.dart';
import '../../../services/time/session_clock.dart';
import '../../../services/time/session_clock_provider.dart';
import '../../../services/vpn/openvpn_port.dart';
import '../../../services/vpn/softether_port.dart';
import '../../../services/vpn/vpn_provider.dart';
import '../../../services/vpn/vpn_selection_provider.dart';
import '../../../services/vpn/models/vpn.dart';
import '../../../services/vpn/models/vpn_type.dart';
import '../../servers/domain/server.dart';
import '../../servers/domain/server_providers.dart';
import '../../settings/domain/settings_controller.dart';
import '../../../services/vpn/models/softether_config.dart';
import '../../settings/domain/vpn_protocol.dart' as settings_vpn;
import '../../speedtest/domain/speedtest_controller.dart';
import '../../speedtest/domain/speedtest_state.dart';
import '../../usage/data_usage_controller.dart';
import 'session_meta.dart';
import 'session_state.dart';
import 'session_status.dart';

const _sessionMetaPrefsKey = 'session_meta_v1';
// Unlimited session duration (effectively 100 years of connection time)
const sessionDuration = Duration(days: 36500);
const _dataLimitMessage = 'Monthly data limit reached.';
const _extendDuration = Duration(hours: 1);
const _connectionTimeoutDuration = Duration(seconds: 60);

class SessionController extends StateNotifier<SessionState> {
  SessionController(this._ref)
      : _vpnPort = _ref.read(openVpnPortProvider),
        _softEtherPort = _ref.read(softEtherPortProvider),
        _clock = _ref.read(sessionClockProvider),
        _settings = _ref.read(settingsControllerProvider.notifier),
        _notificationService =
            _ref.read(sessionNotificationServiceProvider),
        super(SessionState.initial()) {
    _speedSubscription =
        _ref.listen<SpeedTestState>(speedTestControllerProvider, _onSpeedUpdate);

    // CRITICAL FIX: Initialize notification service with timeout to prevent hanging
    // Do this in background with error handling
    unawaited(
      _notificationService
          .initialize(onAction: _handleNotificationAction)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              _log('Notification service initialization timed out');
            },
          )
          .catchError((error) {
            _log('Notification service initialization failed: $error');
          }),
    );

    // CRITICAL FIX: Setup stage stream listeners for both OpenVPN and SoftEther
    // This prevents hanging if the stream throws or becomes stuck
    _stageSubscription = _vpnPort.stageStream.listen(
      (stage) {
        try {
          unawaited(_handleVpnStage(stage as VPNStage));
        } catch (e) {
          _log('Error handling VPN stage: $e');
        }
      },
      onError: (error, stackTrace) {
        _log('VPN stage stream error: $error');
        _log('Stack trace: $stackTrace');
      },
    );

    // Also listen to SoftEther port stage stream
    _stageSubscription2 = _softEtherPort.stageStream.listen(
      (stage) {
        try {
          unawaited(_handleVpnStage(stage as VPNStage));
        } catch (e) {
          _log('Error handling SoftEther stage: $e');
        }
      },
      onError: (error, stackTrace) {
        _log('SoftEther stage stream error: $error');
        _log('Stack trace: $stackTrace');
      },
      cancelOnError: false, // Don't stop listening on error
    );

    _bootstrap();
  }

  final Ref _ref;
  final OpenVpnPort _vpnPort;
  final SoftEtherPort _softEtherPort;
  final SessionClock _clock;
  final SettingsController _settings;
  final SessionNotificationService _notificationService;

  Timer? _ticker;
  Timer? _connectionTimeoutTimer;
  Timer? _healthCheckTimer;
  StreamSubscription<String>? _intentSubscription;
  StreamSubscription<VPNStage>? _stageSubscription;
  StreamSubscription<VPNStage>? _stageSubscription2; // For SoftEther
  late final ProviderSubscription<SpeedTestState> _speedSubscription;
  int _reconnectAttempts = 0;
  bool _pendingAutoConnect = false;
  int _tickCounter = 0;
  SessionMeta? _activeMeta;
  Server? _queuedServer;
  _PendingConnection? _pendingConnection;
  Server? _currentServer;
  bool _manualDisconnectInProgress = false;
  bool _disconnectInProgress = false;
  bool _lastConnectionHealthy = true;
  Completer<void>? _ipFetchCompleter;
  VpnProtocol? _activeVpnProtocol; // Track which VPN protocol is currently active
  VPNStage? _lastVpnStage; // Track last stage to prevent duplicate processing

  void _log(String message) {
    debugPrint('[SessionController] $message');
  }

  void _startConnectionTimeout() {
    _cancelConnectionTimeout();
    _connectionTimeoutTimer = Timer(_connectionTimeoutDuration, () {
      if (state.status != SessionStatus.connecting ||
          _pendingConnection == null) {
        return;
      }
      _log(
        'Connection timed out after ${_connectionTimeoutDuration.inSeconds} seconds. Aborting attempt.',
      );
      final pending = _pendingConnection;
      _pendingConnection = null;
      state = state.copyWith(
        status: SessionStatus.error,
        errorMessage: 'Connection timed out after 60 seconds. The server may be unresponsive, blocked by your network, or experiencing high load. Please try another server or check your network settings.',
      );
      unawaited(_notificationService.clear());
      if (pending != null) {
        unawaited(_vpnPort.disconnect());
      }
    });
  }

  void _cancelConnectionTimeout() {
    _connectionTimeoutTimer?.cancel();
    _connectionTimeoutTimer = null;
  }

  Future<void> _bootstrap() async {
    // Ads removed — no initialization required

    // CRITICAL FIX: Setup intent listener with error handling
    _intentSubscription = _vpnPort.intentActions.listen(
      _handleIntentAction,
      onError: (error, stackTrace) {
        _log('Intent action stream error: $error');
      },
      cancelOnError: false,
    );

    // CRITICAL FIX: Add timeout to session restoration
    try {
      await _restoreSession().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _log('Session restoration timed out');
        },
      );
    } catch (e) {
      _log('Error restoring session: $e');
    }

    _startTicker();
    _pendingAutoConnect = true;
  }

  void _handleIntentAction(String action) {
    final normalized = action.toLowerCase();
    if (normalized.contains('extend')) {
      state = state.copyWith(extendRequested: true);
      return;
    }
    if (normalized.contains('disconnect')) {
      unawaited(disconnect(userInitiated: false));
    }
  }

  Future<void> _handleNotificationAction(String action) async {
    switch (action) {
      case SessionNotificationService.actionDisconnect:
        await disconnect();
        break;
      case SessionNotificationService.actionExtend:
        requestExtension();
        break;
    }
  }

  Future<void> _handleVpnStage(VPNStage stage) async {
    _log('VPN stage update: $stage');
    
    // CRITICAL FIX: Prevent duplicate stage processing
    if (_lastVpnStage == stage && stage == VPNStage.disconnected) {
      _log('⏭️ Skipping duplicate disconnected stage');
      return;
    }
    if (stage != VPNStage.unknown) {
      _lastVpnStage = stage;
    }
    
    if (_manualDisconnectInProgress) {
      if (stage == VPNStage.disconnected) {
        _manualDisconnectInProgress = false;
      }
      return;
    }
    if (stage == VPNStage.connected) {
      await _completePendingConnection();
      return;
    }

    if (_stageIndicatesFailure(stage)) {
      _cancelConnectionTimeout();
      final pending = _pendingConnection;
      if (pending != null) {
        _pendingConnection = null;
        await _notificationService.clear();
        state = state.copyWith(
          status: SessionStatus.error,
          errorMessage: _errorMessageForStage(stage, server: pending.server),
        );
        return;
      }
      if (state.status == SessionStatus.connecting ||
          state.status == SessionStatus.preparing) {
        await _notificationService.clear();
        state = state.copyWith(
          status: SessionStatus.error,
          errorMessage: _errorMessageForStage(stage),
        );
        return;
      }
      if (state.status == SessionStatus.connected) {
        await _handleRemoteDisconnect();
      }
    }

    // Ignore unknown stage changes during transition phases - wait for explicit connected/disconnected
    if (stage == VPNStage.unknown &&
        (state.status == SessionStatus.connecting || state.status == SessionStatus.preparing)) {
      _log('Ignoring unknown stage during connection attempt');
      return;
    }

    // Add logging for all stage changes
    _log('VPN stage changed to: $stage');
  }

  String _errorMessageForStage(VPNStage stage, {Server? server}) {
    final serverName = server?.name;
    switch (stage) {
      case VPNStage.unknown:
        if (serverName != null) {
          return 'Authentication failed while connecting to $serverName. This may be due to incorrect credentials or server issues. Please try another server.';
        }
        return 'Authentication failed. This may be due to incorrect credentials or server issues. Please try another server.';
      case VPNStage.denied:
        return 'VPN connection permission was denied. Please check app permissions and try again.';
      case VPNStage.error:
        if (serverName != null) {
          return 'Error connecting to $serverName. The server may be offline, experiencing issues, or blocked by your network. Please try another server.';
        }
        return 'Error establishing VPN connection. This could be due to server issues, network restrictions, or firewall settings. Please try another server.';
      case VPNStage.disconnected:
        if (serverName != null) {
          return 'Disconnected from $serverName. The connection may have been interrupted or timed out.';
        }
        return 'VPN connection was disconnected. The connection may have been interrupted or timed out.';
      default:
        if (serverName != null) {
          return 'Unable to establish VPN connection to $serverName. Please try another server.';
        }
        return 'Unable to establish VPN connection. Please try another server.';
    }
  }

  bool _stageIndicatesFailure(VPNStage stage) {
    switch (stage) {
      case VPNStage.unknown:
        // Unknown is only a failure if we're not actively connecting
        // During connection, we'll wait for explicit connected/disconnected signal
        return state.status == SessionStatus.connected;
      case VPNStage.disconnected:
      case VPNStage.denied:
      case VPNStage.error:
      case VPNStage.exiting:
        return true;
      default:
        return false;
    }
  }

  Future<void> _completePendingConnection() async {
    _cancelConnectionTimeout();
    final pending = _pendingConnection;
    if (pending == null) {
      return;
    }
    _pendingConnection = null;
    final server = pending.server;
    final start = DateTime.now().toUtc();
    final publicIp = pending.initialIp;

    // For SoftEther, server may be null
    if (server == null) {
      _log('Completing SoftEther connection (no server object)');
      
      // For SoftEther, verify the connection is valid before proceeding
      final selectedVpnType = _ref.read(selectedVpnTypeProvider);
      if (selectedVpnType == VpnType.softEther) {
        // CRITICAL FIX: The tunnel takes time to establish
        // Wait for tunnel establishment attempt to complete (typically 5-7 seconds)
        // Then verify the actual tunneled connection status
        _log('⏳ Waiting 7 seconds for SoftEther tunnel establishment to complete...');
        await Future.delayed(const Duration(seconds: 7));
        
        // Now check if the tunnel actually established
        final stillConnected = await _softEtherPort.isConnected();
        _log('🔍 SoftEther tunnel verification after 7 seconds: $stillConnected');
        
        if (!stillConnected) {
          _log('❌ SoftEther tunnel connection failed - aborting completion');
          state = state.copyWith(
            status: SessionStatus.error,
            errorMessage: 'SoftEther VPN tunnel failed to establish. The server may be unreachable or not properly configured.',
          );
          await _notificationService.clear();
          return;
        }
      }
      
      // Create meta for SoftEther (CRITICAL FIX)
      final softEtherMeta = SessionMeta(
        serverId: 'softether-vpn',
        serverName: 'SoftEther VPN',
        countryCode: 'SE',
        startElapsedMs: pending.startElapsedMs,
        durationMs: sessionDuration.inMilliseconds,
        publicIp: publicIp,
      );
      
      state = state.copyWith(
        status: SessionStatus.connected,
        start: start,
        duration: sessionDuration,
        startElapsedMs: pending.startElapsedMs,
        serverId: 'softether-vpn',
        serverName: 'SoftEther VPN',
        countryCode: 'SE',
        publicIp: publicIp,
        expired: false,
        sessionLocked: true,
        meta: softEtherMeta,
        errorMessage: null,
      );
      
      // Store meta and set as active
      _activeMeta = softEtherMeta;
      _lastConnectionHealthy = true;
      await _persistMeta(softEtherMeta);
      
      // Trigger IP fetch in background for SoftEther
      _ipFetchCompleter = Completer<void>();
      unawaited(
        () async {
          try {
            // We've already waited 7 seconds for tunnel establishment in _completePendingConnection()
            // Now attempt to fetch the new IP through the tunnel
            _log('🔄 Attempting to fetch new IP after SoftEther tunnel established');
            
            // Try fetching IP multiple times with longer delays
            for (int attempt = 1; attempt <= 5; attempt++) {
              // Check if cancelled between attempts
              if (_ipFetchCompleter!.isCompleted) {
                _log('IP fetch cancelled during attempt $attempt');
                return;
              }
              
              try {
                _log('📡 IP fetch attempt $attempt/5...');
                final speedController = _ref.read(speedTestControllerProvider.notifier);
                await speedController.run();
                
                final newState = _ref.read(speedTestControllerProvider);
                final newIp = newState.ip;
                _log('✅ IP fetch attempt $attempt: $newIp');
                
                if (newIp != null && newIp.isNotEmpty) {
                  // Successfully fetched IP
                  _log('🎉 Successfully retrieved IP: $newIp via SoftEther VPN proxy');
                  break;
                }
              } catch (e) {
                _log('⚠️ IP fetch attempt $attempt failed: $e');
              }
              
              // Wait before retry with increasing delays
              if (attempt < 5) {
                final delaySeconds = 2 + (attempt * 1);
                _log('⏳ Waiting ${delaySeconds}s before next IP fetch attempt...');
                await Future.delayed(Duration(seconds: delaySeconds));
              }
            }
          } catch (e) {
            _log('Error refreshing IP after SoftEther connection: $e');
          } finally {
            if (!_ipFetchCompleter!.isCompleted) {
              _ipFetchCompleter!.complete();
            }
          }
        }(),
      );
      
      return;
    }

    final meta = SessionMeta(
      serverId: server.id,
      serverName: server.name,
      countryCode: server.countryCode,
      startElapsedMs: pending.startElapsedMs,
      durationMs: sessionDuration.inMilliseconds,
      publicIp: publicIp,
    );
    _activeMeta = meta;
    _currentServer = server;
    _lastConnectionHealthy = true;
    state = state.copyWith(
      status: SessionStatus.connected,
      start: start,
      duration: sessionDuration,
      startElapsedMs: pending.startElapsedMs,
      serverId: server.id,
      serverName: server.name,
      countryCode: server.countryCode,
      publicIp: publicIp,
      expired: false,
      sessionLocked: true,
      meta: meta,
      errorMessage: null,
    );
    await _persistMeta(meta);
    await _ref.read(serverCatalogProvider.notifier).rememberSelection(server);
    _reconnectAttempts = 0;
    _queuedServer = null;

    final remaining = await _clock.remaining(
      startElapsedMs: pending.startElapsedMs,
      duration: sessionDuration,
    );
    await _notificationService.showConnected(
      server: server,
      remaining: remaining,
      state: state,
    );
  }

  Future<void> _handleRemoteDisconnect() async {
    await _forceDisconnect(clearPrefs: true);
  }

  void _onSpeedUpdate(SpeedTestState? previous, SpeedTestState next) {
    final ip = next.ip;
    if (state.status != SessionStatus.connected || ip == null || ip.isEmpty) {
      return;
    }
    if (state.publicIp == ip) {
      return;
    }
    state = state.copyWith(publicIp: ip);
    final meta = _activeMeta;
    if (meta != null) {
      final updated = meta.copyWith(publicIp: ip);
      _activeMeta = updated;
      state = state.copyWith(meta: updated);
      unawaited(_persistMeta(updated));
      unawaited(_vpnPort.extendSession(updated.duration, publicIp: ip));
    }
  }

  Future<void> _restoreSession() async {
    final prefs = await _ref.read(prefsStoreProvider.future);
    final stored = prefs.getString(_sessionMetaPrefsKey);
    if (stored == null) {
      state = SessionState.initial();
      return;
    }
    try {
      final jsonMap = jsonDecode(stored) as Map<String, dynamic>;
      final meta = SessionMeta.fromJson(jsonMap);
      final remaining = await _clock.remaining(
        startElapsedMs: meta.startElapsedMs,
        duration: meta.duration,
      );
      // Check both VPN ports (OpenVPN and SoftEther). Treat as connected if either reports connected.
      final connectedOpen = await _vpnPort.isConnected().timeout(
            const Duration(seconds: 3),
            onTimeout: () => false,
          );
      final connectedSoft = await _softEtherPort.isConnected().timeout(
            const Duration(seconds: 3),
            onTimeout: () => false,
          );
      final connected = connectedOpen || connectedSoft;
      if (!connected) {
        await _forceDisconnect(clearPrefs: true);
        return;
      }
      final elapsed = meta.duration - remaining;
      final startWall = DateTime.now().toUtc().subtract(elapsed);
      _activeMeta = meta;
      state = state.copyWith(
        status: SessionStatus.connected,
        start: startWall,
        duration: meta.duration,
        startElapsedMs: meta.startElapsedMs,
        serverId: meta.serverId,
        serverName: meta.serverName,
        countryCode: meta.countryCode,
        publicIp: meta.publicIp,
        expired: false,
        sessionLocked: true,
        meta: meta,
      );
      await _vpnPort.extendSession(Duration.zero);
    } catch (_) {
      await prefs.remove(_sessionMetaPrefsKey);
      state = SessionState.initial();
    }
  }

  Future<void> connect({
    required BuildContext context,
    required Server? server,
  }) async {
    final selectedVpnType = _ref.read(selectedVpnTypeProvider);
    _log('connect() requested for ${server?.name ?? "SoftEther"} (${server?.countryCode ?? "N/A"}), VPN Type: $selectedVpnType');

    if (state.status == SessionStatus.connected) {
      throw const AppError('Already connected.');
    }

    // Route to appropriate VPN type handler
    if (selectedVpnType == VpnType.softEther) {
      _activeVpnProtocol = null; // SoftEther uses native service, not a VPN protocol
      await _connectSoftEther();
    } else {
      if (server == null) {
        throw const AppError('Server is required for OpenVPN connections.');
      }
      _activeVpnProtocol = VpnProtocol.openvpn;
      await _connectOpenVpn(server);
    }
  }

  Future<void> _connectOpenVpn(Server server) async {
    _log('Connecting via OpenVPN to ${server.name} (${server.countryCode})');
    if (!_vpnPort.isSupported) {
      _log('Device does not support VPN');
      state = state.copyWith(
        status: SessionStatus.error,
        errorMessage: 'VPN is not supported on this device.',
      );
      return;
    }
    final settingsState = _ref.read(settingsControllerProvider);
    if (!settingsState.protocol.protocol.isSupported) {
      _log('Protocol not supported: ${settingsState.protocol.protocol}');
      state = state.copyWith(
        status: SessionStatus.error,
        errorMessage: 'Protocol not supported yet. Please select WireGuard.',
      );
      return;
    }
    state = state.copyWith(
      status: SessionStatus.preparing,
      errorMessage: null,
    );

    final prepared = await _vpnPort.prepare();
    _log('VPN permission request result: $prepared');
    if (!prepared) {
      state = state.copyWith(
        status: SessionStatus.error,
        errorMessage: 'VPN permission required.',
      );
      return;
    }

    state = state.copyWith(status: SessionStatus.connecting);
    _log('Connecting to OpenVPN server: ${server.name}');

    try {
      final initialIp = _ref.read(speedTestControllerProvider).ip;
      final startElapsed = await _clock.elapsedRealtime();

      // Convert Server to Vpn model for OpenVPN connection
      final vpnServer = Vpn(
        hostName: server.hostName ?? server.name,
        ip: server.ip ?? '',
        ping: server.pingMs?.toString() ?? '0',
        speed: server.downloadSpeed ?? server.bandwidth ?? 0,
        countryLong: server.countryName ?? server.name,
        countryShort: server.countryCode,
        numVpnSessions: server.sessions ?? 0,
        openVpnConfigDataBase64: server.openVpnConfigDataBase64 ?? '',
      );

      // Validate that we have a configuration
      if (server.openVpnConfigDataBase64 == null || server.openVpnConfigDataBase64!.isEmpty) {
        _log('Missing OpenVPN config for server ${server.id}');
        state = state.copyWith(
          status: SessionStatus.error,
          errorMessage: 'Server does not have OpenVPN configuration.',
        );
        return;
      }

      try {
        final decodedConfig = vpnServer.openVpnConfig;
        if (decodedConfig.trim().isEmpty) {
          _log('Missing OpenVPN config for server ${server.id}');
          state = state.copyWith(
            status: SessionStatus.error,
            errorMessage: 'Server does not have OpenVPN configuration.',
          );
          return;
        }
      } on AppError catch (error) {
        _log('Invalid OpenVPN config for server ${server.id}: $error');
        state = state.copyWith(
          status: SessionStatus.error,
          errorMessage:
              'Server configuration is invalid. Please choose another server.',
        );
        return;
      }

      _pendingConnection = _PendingConnection(
        server: server,
        startElapsedMs: startElapsed,
        initialIp: initialIp,
      );
      await _notificationService.showConnecting(server);
      _startConnectionTimeout();

      _log('Attempting to connect to OpenVPN server: ${vpnServer.hostName}');
      final connected = await _vpnPort.connect(vpnServer);
      _log('OpenVPN connect() returned $connected');
      if (!connected) {
        _cancelConnectionTimeout();
        _pendingConnection = null;
        await _notificationService.clear();
        state = state.copyWith(
          status: SessionStatus.error,
          errorMessage: 'Connection failed. Possible causes:\n'
              '• Server IP may be unreachable\n'
              '• Firewall blocking VPN traffic\n'
              '• Security group not allowing port\n'
              '• Invalid OpenVPN configuration\n\n'
              'Please verify your setup and try again.',
        );
        return;
      }
    } catch (e) {
      _log('OpenVPN Connection error: $e');
      _cancelConnectionTimeout();
      _pendingConnection = null;
      await _notificationService.clear();
      state = state.copyWith(
        status: SessionStatus.error,
        errorMessage: 'Unable to establish tunnel.',
      );
    }
  }

  Future<void> _connectSoftEther() async {
    _log('🔄 Starting SoftEther VPN connection process');

    final softEtherConfig = _ref.read(softEtherConfigProvider);
    if (softEtherConfig == null || !softEtherConfig.isValid) {
      _log('❌ Invalid SoftEther configuration');
      state = state.copyWith(
        status: SessionStatus.error,
        errorMessage: 'SoftEther configuration is not set or invalid. Please review your settings.',
      );
      return;
    }

    // SPECIAL HANDLING FOR L2TP/IPSec: Cannot connect programmatically on Android
    if (softEtherConfig.protocol == VpnProtocol.l2tpIpsec) {
      _log('🔒 L2TP/IPSec detected - showing setup dialog');
      // Instead of error, we'll show a setup dialog that helps user configure VPN
      // This will be handled by the UI layer
      state = state.copyWith(
        status: SessionStatus.error,
        errorMessage: 'L2TP_IPSEC_SETUP:${softEtherConfig.connectionName}:${softEtherConfig.serverAddress}:${softEtherConfig.presharedKey ?? ""}:${softEtherConfig.username}:${softEtherConfig.password}',
      );
      return;
    }

    if (!_softEtherPort.isSupported) {
      _log('❌ SoftEther not supported on this device');
      state = state.copyWith(
        status: SessionStatus.error,
        errorMessage: 'SoftEther VPN is not supported on this device.',
      );
      return;
    }

    _log('🔧 Preparing SoftEther VPN connection');
    state = state.copyWith(
      status: SessionStatus.preparing,
      errorMessage: null,
    );

    final prepared = await _softEtherPort.prepare();
    _log('✅ SoftEther permission request result: $prepared');
    if (!prepared) {
      _log('❌ VPN permission denied');
      state = state.copyWith(
        status: SessionStatus.error,
        errorMessage: 'VPN permission required.',
      );
      return;
    }

    _log('🚀 Connecting to SoftEther server');
    state = state.copyWith(status: SessionStatus.connecting);
    _log('📡 Connecting to SoftEther: ${softEtherConfig.connectionName}');

    try {
      final initialIp = _ref.read(speedTestControllerProvider).ip;
      final startElapsed = await _clock.elapsedRealtime();

      // Check if this server has OpenVPN config available
      // If so, suggest using OpenVPN for real tunneling
      final catalog = _ref.read(serverCatalogProvider);
      final matchingServer = catalog.servers.firstWhereOrNull((s) {
        final addr = softEtherConfig.serverAddress.toLowerCase();
        final endpoints = [s.endpoint, s.ip, s.hostName, s.name]
            .whereType<String>()
            .map((e) => e.toLowerCase())
            .toList();
        return endpoints.contains(addr);
      });

      if (matchingServer != null && 
          (matchingServer.openVpnConfigDataBase64?.isNotEmpty ?? false)) {
        _log('🎯 Found OpenVPN config for server - routing to OpenVPN for real tunnel');
        _log('💡 This will provide actual IP change and real VPN tunnel');
        await _connectOpenVpn(matchingServer);
        return;
      }

      _log('🔍 No OpenVPN fallback found - using native SoftEther client');
      _log('⚠️ Note: Real IP change requires native L2TP/IPSec tunnel to be established');

      // Set up pending connection for SoftEther (no server object needed)
      _pendingConnection = _PendingConnection(
        server: null, // SoftEther doesn't use a server object
        startElapsedMs: startElapsed,
        initialIp: initialIp,
      );

      // Show notification
      await _notificationService.showConnecting(
        softEtherConfig.connectionName,
      );

      _startConnectionTimeout();

      // Attempt native SoftEther connection
      // Auto-correct common port/protocol mismatches:
      // - If user selected L2TP/IPSec but left default port 5555, switch to standard L2TP port 1701.
      // - If port 5555 is used but protocol isn't SoftEther, prefer SoftEther protocol (5555 is SoftEther native port).
      SoftEtherConfig adjustedConfig = softEtherConfig;
      if (softEtherConfig.protocol == VpnProtocol.l2tpIpsec && softEtherConfig.serverPort == 5555) {
        _log('🔧 Detected L2TP/IPSec with port 5555 — adjusting port to 1701 for L2TP/IPSec');
        adjustedConfig = softEtherConfig.copyWith(serverPort: 1701);
      } else if (softEtherConfig.serverPort == 5555 && softEtherConfig.protocol != VpnProtocol.softEther) {
        _log('🔧 Server port 5555 commonly indicates native SoftEther protocol — switching protocol to SoftEther');
        adjustedConfig = softEtherConfig.copyWith(protocol: VpnProtocol.softEther);
      }

      _log('🌐 Attempting to connect to SoftEther server: ${adjustedConfig.serverAddress}:${adjustedConfig.serverPort} (protocol: ${adjustedConfig.protocol})');
      final connected = await _softEtherPort.connectSoftEther(adjustedConfig).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          _log('⏰ SoftEther connection attempt timed out after 15 seconds');
          return false;
        },
      );
      _log('📊 SoftEther connectSoftEther() returned $connected');

      if (!connected) {
        _log('❌ SoftEther connection failed');
        _cancelConnectionTimeout();
        _pendingConnection = null;
        await _notificationService.clear();
        state = state.copyWith(
          status: SessionStatus.error,
          errorMessage: 'Failed to establish SoftEther VPN connection. Please check your configuration and network settings.',
        );
        return;
      }

      // Connection successful, stream listener will handle the rest via _stageSubscription2
      _log('✅ SoftEther connection initiated successfully');
    } catch (e) {
      _log('💥 SoftEther Connection error: $e');
      _cancelConnectionTimeout();
      _pendingConnection = null;
      await _notificationService.clear();
      state = state.copyWith(
        status: SessionStatus.error,
        errorMessage: 'Unable to establish SoftEther tunnel: ${e.toString()}',
      );
    }
  }

  Future<void> disconnect({bool userInitiated = true}) async {
    if (_disconnectInProgress) {
      _log('disconnect() already in progress, ignoring');
      return;
    }
    _disconnectInProgress = true;
    
    _log('disconnect() requested. Status: ${state.status}, userInitiated: $userInitiated');
    _manualDisconnectInProgress = true;
    _cancelConnectionTimeout();
    _stopHealthCheck();
    try {
      // Capture current state before any async operations
      final wasConnected = state.status == SessionStatus.connected;
      final server = _resolveHistoryServer();
      final meta = state.meta;
      Duration? actualDuration;

      if (wasConnected && meta != null) {
        try {
          final nowMs = await _clock.elapsedRealtime();
          final elapsedMs = nowMs - meta.startElapsedMs;
          final clamped = elapsedMs.clamp(0, meta.durationMs) as num;
          actualDuration = Duration(milliseconds: clamped.toInt());
        } catch (e) {
          _log('Error calculating duration: $e');
        }
      }

      _pendingConnection = null;

      // Update UI state FIRST - this must happen immediately
      _activeMeta = null;
      _currentServer = null;
      state = SessionState.initial();
      _applyQueuedServerSelection();

      // Determine which VPN type was connected and disconnect appropriately
      final selectedVpnType = _ref.read(selectedVpnTypeProvider);

      // Now run the disconnect operations with timeout to prevent hanging
      try {
        if (selectedVpnType == VpnType.softEther) {
          _log('Disconnecting SoftEther VPN');
          await _softEtherPort.disconnect().timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              _log('SoftEther disconnect timed out after 5 seconds');
            },
          );
        } else {
          _log('Disconnecting OpenVPN');
          await _vpnPort.disconnect().timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              _log('VPN disconnect timed out after 5 seconds');
            },
          );
        }
      } catch (e) {
        _log('Error during VPN disconnect: $e');
        // Don't rethrow - we still want to clean up state
      }

      try {
        await _notificationService.clear();
      } catch (e) {
        _log('Error clearing notifications: $e');
      }

      // Run all remaining operations in background without awaiting
      if (wasConnected) {
        unawaited(
          () async {
            try {
              final stats = selectedVpnType == VpnType.softEther
                  ? await _softEtherPort.getTunnelStats().timeout(
                      const Duration(seconds: 3),
                      onTimeout: () => <String, dynamic>{},
                    )
                  : await _vpnPort.getTunnelStats().timeout(
                      const Duration(seconds: 3),
                      onTimeout: () => <String, dynamic>{},
                    );
              
              // CRITICAL FIX: Only record session if we have valid metadata with start time
              if (meta != null && actualDuration != null) {
                // Reconstruct the session with proper start time from meta
                final wallStartTime = DateTime.now().toUtc().subtract(actualDuration);
                final sessionForHistory = SessionState.initial().copyWith(
                  start: wallStartTime,
                  duration: actualDuration,
                );
                await _settings.recordSessionEnd(
                  sessionForHistory,
                  server: server,
                  stats: stats,
                );
                _log('Session end recorded successfully');
              } else {
                _log('⏭️ Skipping session recording - missing meta or invalid duration');
              }
              
              await _clearPersistedState();
            } catch (e) {
              _log('Error recording session end: $e');
            }
          }(),
        );
      }
    } catch (e) {
      _log('Unexpected error in disconnect: $e');
      // Ensure state is updated even if there's an error
      _activeMeta = null;
      _currentServer = null;
      state = SessionState.initial();
    } finally {
      _manualDisconnectInProgress = false;
      _disconnectInProgress = false;
    }
  }

  Server? _resolveHistoryServer() {
    final id = state.serverId;
    final catalog = _ref.read(serverCatalogProvider);
    if (id != null) {
      final match = catalog.servers.firstWhereOrNull((s) => s.id == id);
      if (match != null) {
        return match;
      }
    }
    return _ref.read(selectedServerProvider);
  }

  Future<void> _forceDisconnect({bool clearPrefs = false}) async {
    _cancelConnectionTimeout();
    _stopHealthCheck();
    _cancelIpFetch();
    
    // CRITICAL FIX: Only disconnect the active VPN - don't call both!
    final protocol = _activeVpnProtocol;
    if (protocol == null) {
      // SoftEther doesn't use a VPN protocol - it uses native service
      _log('Disconnecting SoftEther native service');
      await _softEtherPort.disconnect();
    } else {
      // OpenVPN uses the VPN port
      _log('Disconnecting OpenVPN service');
      await _vpnPort.disconnect();
    }
    
    if (clearPrefs) {
      await _clearPersistedMeta();
    }
    _activeMeta = null;
    _pendingConnection = null;
    _activeVpnProtocol = null;
    await _notificationService.clear();
    _currentServer = null;
    _manualDisconnectInProgress = false;
    // Only mark as expired if session actually timed out - not for normal disconnects
    state = SessionState.initial().copyWith(expired: false, sessionLocked: false);
    _applyQueuedServerSelection();
  }

  Future<void> _persistMeta(SessionMeta meta) async {
    final prefs = await _ref.read(prefsStoreProvider.future);
    final jsonStr = jsonEncode(meta.toJson());
    await prefs.setString(_sessionMetaPrefsKey, jsonStr);
  }

  Future<void> _clearPersistedMeta() async {
    final prefs = await _ref.read(prefsStoreProvider.future);
    await prefs.remove(_sessionMetaPrefsKey);
  }

  Future<void> _clearPersistedState() async {
    await _clearPersistedMeta();
  }

  void _applyQueuedServerSelection() {
    final queued = _queuedServer;
    if (queued == null) {
      return;
    }
    _ref.read(selectedServerProvider.notifier).select(queued);
    _queuedServer = null;
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) async {
      _tickCounter += 1;
      final settings = _ref.read(settingsControllerProvider);
      if (settings.batterySaverEnabled && _tickCounter % 3 != 0) {
        return;
      }
      if (state.status != SessionStatus.connected ||
          state.startElapsedMs == null ||
          state.duration == null) {
        return;
      }
      final remaining = await _clock.remaining(
        startElapsedMs: state.startElapsedMs!,
        duration: state.duration!,
      );
      // Session duration is unlimited - don't force disconnect
      // if (remaining <= Duration.zero) {
      //   await _forceDisconnect(clearPrefs: true);
      //   return;
      // }
      await _ref.read(dataUsageControllerProvider.notifier).recordTickUsage();
      final usage = _ref.read(dataUsageControllerProvider);
      if (usage.limitExceeded) {
        await _forceDisconnect(clearPrefs: true);
        state = state.copyWith(
          status: SessionStatus.error,
          errorMessage: _dataLimitMessage,
        );
        return;
      }
      final server = _currentServer;
      if (server != null) {
        // CRITICAL FIX: Don't await notification updates - they block the UI thread
        // Fire and forget with error handling to prevent UI freezing
        unawaited(
          _notificationService.updateSession(
            server: server,
            remaining: remaining,
            state: state,
          ).catchError((error) {
            _log('Notification update failed (non-critical): $error');
          }),
        );
      }
    });
    _startHealthCheck();
  }

  void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (state.status != SessionStatus.connected) {
        return;
      }

      try {
        // CRITICAL FIX: Add timeout to health check to prevent hanging
        // If VPN service is unresponsive, timeout after 3 seconds
        // Check both ports for health — consider connection healthy if either port reports connected
        final isConnectedOpen = await _vpnPort.isConnected().timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            _log('Health check timeout: VPN service not responding');
            return false;
          },
        );
        final isConnectedSoft = await _softEtherPort.isConnected().timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            _log('Health check timeout: SoftEther service not responding');
            return false;
          },
        );

        final isConnected = isConnectedOpen || isConnectedSoft;

        if (!isConnected && _lastConnectionHealthy) {
          _log('Health check failed: VPN reports disconnected');
          _lastConnectionHealthy = false;
          // Wait a moment to see if it recovers
          await Future.delayed(const Duration(seconds: 1));

          // CRITICAL FIX: Add timeout to recheck as well
          final recheckedOpen = await _vpnPort.isConnected().timeout(
            const Duration(seconds: 3),
            onTimeout: () {
              _log('Health check recheck timeout');
              return false;
            },
          );
          final recheckedSoft = await _softEtherPort.isConnected().timeout(
            const Duration(seconds: 3),
            onTimeout: () {
              _log('Health check recheck timeout (SoftEther)');
              return false;
            },
          );

          if (!(recheckedOpen || recheckedSoft)) {
            _log('Health check confirmed: VPN is disconnected, forcing disconnect');
            await _handleRemoteDisconnect();
          } else {
            _lastConnectionHealthy = true;
          }
        } else if (isConnected) {
          _lastConnectionHealthy = true;
        }
      } catch (e) {
        _log('Health check error: $e');
        // If health check throws, mark as unhealthy but don't disconnect yet
        _lastConnectionHealthy = false;
      }
    });
  }

  void _stopHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
  }

  void _cancelIpFetch() {
    if (_ipFetchCompleter != null && !_ipFetchCompleter!.isCompleted) {
      _ipFetchCompleter!.complete();
      _log('Cancelled ongoing IP fetch operation');
    }
    _ipFetchCompleter = null;
  }



  Future<void> autoConnectIfEnabled({required BuildContext context}) async {
    if (!_pendingAutoConnect) return;
    _pendingAutoConnect = false;
    final settings = _ref.read(settingsControllerProvider);
    if (!settings.autoConnect.connectOnLaunch) {
      return;
    }
    
    final selectedVpnType = _ref.read(selectedVpnTypeProvider);
    
    // Check if we have valid configuration for the selected VPN type
    if (selectedVpnType == VpnType.softEther) {
      final softEtherConfig = _ref.read(softEtherConfigProvider);
      if (softEtherConfig == null || !softEtherConfig.isValid) {
        return;
      }
    } else {
      // For OpenVPN, check if a server is selected
      final server = _ref.read(selectedServerProvider);
      if (server == null) {
        return;
      }
    }
    
    if (state.status == SessionStatus.connected) {
      return;
    }
    
    final server = _ref.read(selectedServerProvider);
    await connect(context: context, server: server);
  }

  Future<void> extendSession(BuildContext context) async {
    if (state.status != SessionStatus.connected) {
      return;
    }
    state = state.copyWith(extendRequested: false);
    // try {
    //   await _adService.unlock(duration: _extendDuration, context: context);
    //   await extend(_extendDuration);
    // } catch (error) {
    //   state = state.copyWith(errorMessage: error.toString());
    // }
  }

  void requestExtension() {
    state = state.copyWith(extendRequested: true);
  }

  Future<void> extend(Duration extra) async {
    final meta = _activeMeta;
    if (state.status != SessionStatus.connected || meta == null) {
      return;
    }
    final extended = meta.extend(extra);
    _activeMeta = extended;
    state = state.copyWith(
      duration: extended.duration,
      meta: extended,
      extendRequested: false,
    );
    await _persistMeta(extended);
    await _vpnPort.extendSession(extended.duration, publicIp: extended.publicIp);
  }

  @override
  void dispose() {
    _log('SessionController dispose() called');

    // CRITICAL FIX: Ensure all timers are cancelled to prevent memory leaks and hanging
    try {
      _cancelConnectionTimeout();
    } catch (e) {
      _log('Error cancelling connection timeout: $e');
    }

    try {
      _stopHealthCheck();
    } catch (e) {
      _log('Error stopping health check: $e');
    }

    try {
      _cancelIpFetch();
    } catch (e) {
      _log('Error cancelling IP fetch: $e');
    }

    try {
      _ticker?.cancel();
      _ticker = null;
    } catch (e) {
      _log('Error cancelling ticker: $e');
    }

    // CRITICAL FIX: Cancel all stream subscriptions to prevent resource leaks
    try {
      _intentSubscription?.cancel();
      _intentSubscription = null;
    } catch (e) {
      _log('Error cancelling intent subscription: $e');
    }

    try {
      _stageSubscription?.cancel();
      _stageSubscription = null;
    } catch (e) {
      _log('Error cancelling stage subscription: $e');
    }

    try {
      _stageSubscription2?.cancel();
      _stageSubscription2 = null;
    } catch (e) {
      _log('Error cancelling stage subscription 2 (SoftEther): $e');
    }

    try {
      _speedSubscription.close();
    } catch (e) {
      _log('Error closing speed subscription: $e');
    }

    // Clear state
    _pendingConnection = null;
    _currentServer = null;
    _activeMeta = null;
    _queuedServer = null;

    // CRITICAL FIX: Clear notifications with timeout to prevent hanging
    unawaited(
      _notificationService
          .clear()
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () {
              _log('Notification clear timeout');
            },
          )
          .catchError((error) {
            _log('Error clearing notifications: $error');
          }),
    );

    super.dispose();
    _log('SessionController dispose() completed');
  }

  Future<void> switchServer(Server server) async {
    _queuedServer = server;
    if (state.status != SessionStatus.connected) {
      _applyQueuedServerSelection();
    }
  }
}

final sessionControllerProvider =
    StateNotifierProvider<SessionController, SessionState>((ref) {
  return SessionController(ref);
});

class _PendingConnection {
  const _PendingConnection({
    required this.server,
    required this.startElapsedMs,
    required this.initialIp,
  });

  final Server? server;
  final int startElapsedMs;
  final String? initialIp;
}
