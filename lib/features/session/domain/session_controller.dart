import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../../../core/utils/iterable_extensions.dart';
import '../../../services/ads/rewarded_ad_service.dart';
import '../../../services/notifications/session_notification_service.dart';
import '../../../services/storage/prefs.dart';
import '../../../services/time/session_clock.dart';
import '../../../services/time/session_clock_provider.dart';
import '../../../services/vpn/openvpn_port.dart';
import '../../../services/vpn/vpn_provider.dart';
import '../../../services/vpn/models/vpn.dart';
import '../../servers/domain/server.dart';
import '../../servers/domain/server_providers.dart';
import '../../settings/domain/settings_controller.dart';
import '../../settings/domain/vpn_protocol.dart';
import '../../speedtest/domain/speedtest_controller.dart';
import '../../speedtest/domain/speedtest_state.dart';
import '../../usage/data_usage_controller.dart';
import 'session_meta.dart';
import 'session_state.dart';
import 'session_status.dart';

const _sessionMetaPrefsKey = 'session_meta_v1';
const sessionDuration = Duration(hours: 1);
const _dataLimitMessage = 'Monthly data limit reached.';
const _extendDuration = Duration(hours: 1);
const _connectionTimeoutDuration = Duration(seconds: 60);

class SessionController extends StateNotifier<SessionState> {
  SessionController(this._ref)
      : _vpnPort = _ref.read(openVpnPortProvider),
        _adService = _ref.read(rewardedAdServiceProvider),
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
    
    // CRITICAL FIX: Setup stage stream listener with error handling
    // This prevents hanging if the stream throws or becomes stuck
    _stageSubscription = _vpnPort.stageStream.listen(
      (stage) {
        try {
          unawaited(_handleVpnStage(stage));
        } catch (e) {
          _log('Error handling VPN stage: $e');
        }
      },
      onError: (error, stackTrace) {
        _log('VPN stage stream error: $error');
        _log('Stack trace: $stackTrace');
      },
      cancelOnError: false, // Don't stop listening on error
    );
    
    _bootstrap();
  }

  final Ref _ref;
  final OpenVpnPort _vpnPort;
  final RewardedAdService _adService;
  final SessionClock _clock;
  final SettingsController _settings;
  final SessionNotificationService _notificationService;

  Timer? _ticker;
  Timer? _connectionTimeoutTimer;
  Timer? _healthCheckTimer;
  StreamSubscription<String>? _intentSubscription;
  StreamSubscription<VPNStage>? _stageSubscription;
  late final ProviderSubscription<SpeedTestState> _speedSubscription;
  int _reconnectAttempts = 0;
  bool _pendingAutoConnect = false;
  int _tickCounter = 0;
  SessionMeta? _activeMeta;
  Server? _queuedServer;
  _PendingConnection? _pendingConnection;
  Server? _currentServer;
  bool _manualDisconnectInProgress = false;
  bool _lastConnectionHealthy = true;

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
    try {
      // CRITICAL FIX: Add timeout to ad service initialization
      await _adService.initialize().timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          _log('Ad service initialization timed out');
        },
      );
    } catch (error) {
      _log('Ad service initialization failed: $error');
    }
    
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
      final connected = await _vpnPort.isConnected();
      if (!connected || remaining == Duration.zero) {
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
    required Server server,
  }) async {
    _log('connect() requested for ${server.name} (${server.countryCode})');
    if (state.status == SessionStatus.connected) {
      throw const AppError('Already connected.');
    }
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

    // try {
    //   await _adService.unlock(duration: sessionDuration, context: context);
    // } catch (error) {
    //   _log('Ad unlock failed: $error');
    //   state = state.copyWith(
    //     status: SessionStatus.disconnected,
    //     errorMessage: 'Ad must be completed to connect.',
    //   );
    //   return;
    // }

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
    _log('Connecting to VPN ${server.name} (${server.countryCode})');

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

      _log('Attempting to connect to VPN server: ${vpnServer.hostName}, IP: ${vpnServer.ip}');
      _log('Config length: ${vpnServer.openVpnConfig.length}');
      
      final connected = await _vpnPort.connect(vpnServer);
      _log('OpenVPN connect() returned $connected');
      if (!connected) {
        _cancelConnectionTimeout();
        _pendingConnection = null;
        await _notificationService.clear();
        state = state.copyWith(
          status: SessionStatus.error,
          errorMessage: 'Connection failed. Possible causes:\n'
              '• Server IP (18.212.249.64:1194) may be unreachable\n'
              '• Firewall blocking VPN traffic\n'
              '• EC2 security group not allowing UDP 1194\n'
              '• Invalid OpenVPN configuration\n\n'
              'Please verify your EC2 setup and try again.',
        );
        return;
      }
    } catch (e) {
      _log('Connection error: $e');
      _cancelConnectionTimeout();
      _pendingConnection = null;
      await _notificationService.clear();
      state = state.copyWith(
        status: SessionStatus.error,
        errorMessage: 'Unable to establish tunnel.',
      );
    }
  }

  Future<void> disconnect({bool userInitiated = true}) async {
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
      
      // Now run the disconnect operations with timeout to prevent hanging
      try {
        await _vpnPort.disconnect().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            _log('VPN disconnect timed out after 5 seconds');
          },
        );
      } catch (e) {
        _log('Error during VPN disconnect: $e');
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
              final stats = await _vpnPort.getTunnelStats().timeout(
                const Duration(seconds: 3),
                onTimeout: () => <String, dynamic>{},
              );
              final sessionForHistory = actualDuration != null
                  ? SessionState.initial().copyWith(duration: actualDuration)
                  : SessionState.initial();
              await _settings.recordSessionEnd(
                sessionForHistory,
                server: server,
                stats: stats,
              );
              await _clearPersistedState();
              _log('Session end recorded successfully');
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
    await _vpnPort.disconnect();
    if (clearPrefs) {
      await _clearPersistedMeta();
    }
    _activeMeta = null;
    _pendingConnection = null;
    await _notificationService.clear();
    _currentServer = null;
    _manualDisconnectInProgress = false;
    state = SessionState.initial().copyWith(expired: true, sessionLocked: false);
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
      if (remaining <= Duration.zero) {
        await _forceDisconnect(clearPrefs: true);
        return;
      }
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
        final isConnected = await _vpnPort.isConnected().timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            _log('Health check timeout: VPN service not responding');
            return false;
          },
        );
        
        if (!isConnected && _lastConnectionHealthy) {
          _log('Health check failed: VPN reports disconnected');
          _lastConnectionHealthy = false;
          // Wait a moment to see if it recovers
          await Future.delayed(const Duration(seconds: 1));
          
          // CRITICAL FIX: Add timeout to recheck as well
          final rechecked = await _vpnPort.isConnected().timeout(
            const Duration(seconds: 3),
            onTimeout: () {
              _log('Health check recheck timeout');
              return false;
            },
          );
          
          if (!rechecked) {
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



  Future<void> autoConnectIfEnabled({required BuildContext context}) async {
    if (!_pendingAutoConnect) return;
    _pendingAutoConnect = false;
    final settings = _ref.read(settingsControllerProvider);
    if (!settings.autoConnect.connectOnLaunch) {
      return;
    }
    final server = _ref.read(selectedServerProvider);
    if (server == null) {
      return;
    }
    if (state.status == SessionStatus.connected) {
      return;
    }
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

  final Server server;
  final int startElapsedMs;
  final String? initialIp;
}
