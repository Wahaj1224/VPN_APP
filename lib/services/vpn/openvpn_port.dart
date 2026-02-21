import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:meta/meta.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';

import '../../core/errors/app_error.dart';
import 'models/vpn.dart';
import 'models/vpn_config.dart';
import 'models/vpn_status.dart' as model;
import 'vpn_port.dart';

/// OpenVPN port implementation using openvpn_flutter package
class OpenVpnPort implements VpnPort {
  OpenVpnPort();

  OpenVPN? _engine;
  final StreamController<String> _intentActionsController =
      StreamController<String>.broadcast();
  final StreamController<VPNStage> _stageController =
      StreamController<VPNStage>.broadcast();
  final StreamController<model.VpnStatus> _statusController =
      StreamController<model.VpnStatus>.broadcast();

  bool _isConnected = false;
  bool _isInitialized = false;
  Vpn? _currentServer;

  @override
  bool get isSupported => true;

  @override
  Stream<String> get intentActions => _intentActionsController.stream;

  @override
  Future<bool> isConnected() async => _isConnected;

  @override
  Stream<VPNStage> get stageStream => _stageController.stream;

  @override
  Stream<model.VpnStatus> get statusStream => _statusController.stream;

  @override
  Future<bool> prepare() async {
    if (!_isInitialized) {
      await initialize();
    }
    if (_engine == null) {
      return false;
    }
    if (Platform.isAndroid) {
      final granted = await _engine!.requestPermissionAndroid();
      return granted;
    }
    return true;
  }

  /// Initialize the OpenVPN engine
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _engine = OpenVPN(
        onVpnStatusChanged: (data) {
          try {
            if (data == null) {
              return;
            }
            final converted = _convertStatus(data);
            _lastStatus = converted;
            // CRITICAL FIX: Add error handling for status controller to prevent blocking
            if (!_statusController.isClosed) {
              _statusController.add(converted);
            }
          } catch (e) {
            debugPrint('[OpenVpnPort] Error processing VPN status: $e');
          }
        },
        onVpnStageChanged: (stage, rawStage) {
          try {
            _isConnected = stage == VPNStage.connected;
            // CRITICAL FIX: Add error handling for stage controller to prevent blocking
            if (!_stageController.isClosed) {
              _stageController.add(stage);
            }
            debugPrint('[OpenVpnPort] Stage changed: $stage (raw: $rawStage)');
          } catch (e) {
            debugPrint('[OpenVpnPort] Error processing VPN stage: $e');
          }
        },
      );

      await _engine!.initialize(
        groupIdentifier:
            Platform.isIOS ? 'group.com.example.hivpn' : null,
        providerBundleIdentifier:
            Platform.isIOS ? 'com.example.hivpn.VPNExtension' : null,
        localizedDescription: 'HiVPN',
      );

      _isInitialized = true;
    } catch (e) {
      print('Error initializing OpenVPN: $e');
      _isInitialized = false;
      rethrow;
    }
  }

  @override
  Future<bool> connect(Vpn server) async {
    try {
      debugPrint('[OpenVpnPort] connect() invoked for ${server.countryLong}');
      if (!_isInitialized) {
        await initialize();
      }

      if (_isConnected) {
        await disconnect();
        await Future.delayed(const Duration(seconds: 1));
      }

      _currentServer = server;

      late final String configText;
      try {
        configText = server.openVpnConfig;
        debugPrint('[OpenVpnPort] Successfully decoded OpenVPN config, length: ${configText.length}');
      } on AppError catch (error) {
        debugPrint('[OpenVpnPort] Invalid OpenVPN config: $error');
        _stageController.add(VPNStage.error);
        return false;
      }

      if (configText.isEmpty) {
        debugPrint(
            '[OpenVpnPort] Error: Empty OpenVPN config for ${server.countryLong}');
        _stageController.add(VPNStage.error);
        return false;
      }

      final sanitizedConfig = _sanitizeOpenVpnConfig(configText);
      
      // Only use credentials if they were explicitly found in the config
      // Don't default to 'vpn'/'vpn' for servers that use cert-only authentication
      final vpnUsername = sanitizedConfig.username ?? '';
      final vpnPassword = sanitizedConfig.password ?? '';
      
      if (vpnUsername.isNotEmpty) {
        debugPrint('[OpenVpnPort] Using username: $vpnUsername, password: ${vpnPassword.isNotEmpty ? "****" : "(empty)"}');
      } else {
        debugPrint('[OpenVpnPort] No credentials found in config - using cert-only authentication');
      }
      debugPrint('[OpenVpnPort] Sanitized config length: ${sanitizedConfig.config.length}');
      debugPrint('[OpenVpnPort] Server country: ${server.countryLong}');
      debugPrint('[OpenVpnPort] Config preview (first 500 chars): ${sanitizedConfig.config.substring(0, sanitizedConfig.config.length > 500 ? 500 : sanitizedConfig.config.length)}');
      
      debugPrint('[OpenVpnPort] About to call _engine.connect()...');
      debugPrint('[OpenVpnPort] Connection parameters:');
      debugPrint('[OpenVpnPort]   - Server: ${server.countryLong}');
      debugPrint('[OpenVpnPort]   - Config size: ${sanitizedConfig.config.length} bytes');
      debugPrint('[OpenVpnPort]   - Username: ${vpnUsername.isNotEmpty ? vpnUsername : "(empty)"}');
      debugPrint('[OpenVpnPort]   - certIsRequired: false');
      
      // DEBUG: Print the complete config being sent to OpenVPN
      debugPrint('[OpenVpnPort] ===== FULL CONFIG START =====');
      debugPrint(sanitizedConfig.config);
      debugPrint('[OpenVpnPort] ===== FULL CONFIG END =====');
      
      await _engine!.connect(
        sanitizedConfig.config,
        server.countryLong,
        username: vpnUsername,
        password: vpnPassword,
        certIsRequired: false,
      );

      debugPrint('[OpenVpnPort] OpenVPN connect command dispatched successfully');
      debugPrint('[OpenVpnPort] Final config being used:');
      debugPrint('[OpenVpnPort] ===== FINAL CONFIG START =====');
      debugPrint(sanitizedConfig.config);
      debugPrint('[OpenVpnPort] ===== FINAL CONFIG END =====');
      return true;
    } catch (e, stackTrace) {
      debugPrint('[OpenVpnPort] Error connecting to VPN: $e');
      debugPrint('[OpenVpnPort] Stack trace: $stackTrace');
      _isConnected = false;
      _stageController.add(VPNStage.error);
      return false;
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      debugPrint('[OpenVpnPort] disconnect() requested');
      if (_engine != null) {
        try {
          // CRITICAL FIX: Add timeout to disconnect to prevent hanging
          // If the native plugin doesn't respond, timeout after 3 seconds
          _engine!.disconnect();
          // Wait briefly to allow disconnect to process
          await Future.delayed(const Duration(milliseconds: 500)).timeout(
            const Duration(seconds: 3),
          );
        } catch (e) {
          debugPrint('[OpenVpnPort] Error calling engine.disconnect(): $e');
          // Continue with cleanup even if disconnect fails
        }
      }
      _isConnected = false;
      _currentServer = null;
      
      // CRITICAL FIX: Ensure stage is updated even if engine is stuck
      if (!_stageController.isClosed) {
        _stageController.add(VPNStage.disconnected);
      }
    } catch (e) {
      debugPrint('[OpenVpnPort] Error disconnecting from VPN: $e');
      // Don't rethrow - we want to ensure cleanup continues
      _isConnected = false;
    }
  }

  @override
  Future<Map<String, dynamic>> getTunnelStats() async {
    return _lastStatus?.toJson() ?? <String, dynamic>{};
  }

  @override
  Future<void> extendSession(Duration duration, {String? publicIp}) async {
    // Session extension is handled at the app level, not VPN level
    // This is a no-op for OpenVPN
  }

  /// Dispose resources
  void dispose() {
    try {
      if (!_intentActionsController.isClosed) {
        _intentActionsController.close();
      }
    } catch (e) {
      debugPrint('[OpenVpnPort] Error closing intent actions controller: $e');
    }
    
    try {
      if (!_stageController.isClosed) {
        _stageController.close();
      }
    } catch (e) {
      debugPrint('[OpenVpnPort] Error closing stage controller: $e');
    }
    
    try {
      if (!_statusController.isClosed) {
        _statusController.close();
      }
    } catch (e) {
      debugPrint('[OpenVpnPort] Error closing status controller: $e');
    }
  }

  model.VpnStatus _convertStatus(VpnStatus status) {
    return model.VpnStatus(
      duration: status.duration ?? '00:00:00',
      connectedOn: status.connectedOn,
      byteIn: status.byteIn ?? '0',
      byteOut: status.byteOut ?? '0',
      packetsIn: status.packetsIn ?? '0',
      packetsOut: status.packetsOut ?? '0',
    );
  }

  String _ensureTrailingNewline(String config) {
    if (config.endsWith('\n')) {
      return config;
    }
    return '$config\n';
  }

  SanitizedOpenVpnConfig _sanitizeOpenVpnConfig(String config) {
    debugPrint('[OpenVpnPort] Sanitizing OpenVPN config, original length: ${config.length}');
    var working = config.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    String? username;
    String? password;

    // Step 1: Extract and remove auth-user-pass block (with inline credentials)
    final authBlockPattern = RegExp(
      r'<auth-user-pass>(.*?)</auth-user-pass>',
      dotAll: true,
      caseSensitive: false,
    );

    final match = authBlockPattern.firstMatch(working);
    if (match != null) {
      debugPrint('[OpenVpnPort] Found auth-user-pass block in config');
      final blockContent = match.group(1) ?? '';
      final credentials = blockContent
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();

      if (credentials.isNotEmpty) {
        username = credentials[0];
        debugPrint('[OpenVpnPort] Extracted username from auth block: $username');
      }
      if (credentials.length > 1) {
        password = credentials[1];
        debugPrint('[OpenVpnPort] Extracted password from auth block: ****');
      }

      working = working.replaceRange(match.start, match.end, '');
    }

    // Step 2: Clean up any remaining auth-user-pass blocks
    working = working.replaceAll(authBlockPattern, '');

    // Step 3: Fix malformed tls-auth blocks
    // The server requires tls-auth for TLS authentication
    debugPrint('[OpenVpnPort] Fixing tls-auth blocks...');
    
    // Strategy: Extract ALL hex lines between BEGIN/END markers, even if they're orphaned
    // Then rebuild the complete tls-auth block
    
    // FIRST: Find the BEGIN marker
    final beginPattern = RegExp(
      r'-----BEGIN\s+OpenVPN\s+Static\s+key\s+V1-----',
      caseSensitive: false,
    );
    
    // SECOND: Extract ALL hex lines up to and including the last END marker
    // This handles cases where the key is split across multiple sections
    final allHexLinesPattern = RegExp(
      r'(?:-----BEGIN\s+OpenVPN\s+Static\s+key\s+V1-----.+?-----END\s+OpenVPN\s+Static\s+key\s+V1-----)|' +  // First block with BEGIN/END
      r'(\s*[a-f0-9]{32}(?:\s*\n\s*[a-f0-9]{32})*)',  // Any orphaned hex lines
      multiLine: true,
      dotAll: true,
      caseSensitive: false,
    );
    
    var validTlsAuthKey = '';
    var hasValidTlsAuth = false;
    
    // Extract all hex content between any BEGIN and the LAST END marker
    final fullMatch = RegExp(
      r'-----BEGIN\s+OpenVPN\s+Static\s+key\s+V1-----\s*((?:[a-f0-9]{32}\s*)+)\s*-----END\s+OpenVPN\s+Static\s+key\s+V1-----',
      multiLine: true,
      dotAll: true,
      caseSensitive: false,
    ).firstMatch(working);
    
    if (fullMatch != null) {
      debugPrint('[OpenVpnPort] Found BEGIN/END markers');
      // Get the hex content
      var hexContent = fullMatch.group(1) ?? '';
      hexContent = hexContent.trim();
      
      // Now find ANY remaining hex lines after the first block's END marker
      final afterFirstEnd = working.substring(fullMatch.end);
      final orphanedHexPattern = RegExp(r'^(\s*[a-f0-9]{32}(?:\s*\n\s*[a-f0-9]{32})*)', multiLine: true, caseSensitive: false);
      final orphanedMatch = orphanedHexPattern.firstMatch(afterFirstEnd);
      
      if (orphanedMatch != null) {
        final orphanedHex = orphanedMatch.group(1) ?? '';
        debugPrint('[OpenVpnPort] Found orphaned hex lines after first block: ${orphanedHex.split('\n').length} lines');
        hexContent += '\n' + orphanedHex.trim();
      }
      
      // Now reconstruct the complete key
      final hexLines = hexContent.split(RegExp(r'\s+'))
          .where((line) => line.isNotEmpty && RegExp(r'^[a-f0-9]{32}$', caseSensitive: false).hasMatch(line))
          .toList();
      
      if (hexLines.isNotEmpty) {
        debugPrint('[OpenVpnPort] Extracted ${hexLines.length} hex lines from tls-auth key');
        validTlsAuthKey = '-----BEGIN OpenVPN Static key V1-----\n' +
            hexLines.join('\n') +
            '\n-----END OpenVPN Static key V1-----';
        hasValidTlsAuth = true;
        debugPrint('[OpenVpnPort] Complete tls-auth key reconstructed, total length: ${validTlsAuthKey.length}');
      }
    }
    
    // THIRD: Remove ALL tls-auth related content (blocks, orphaned data, malformed tags)
    debugPrint('[OpenVpnPort] Removing malformed tls-auth blocks...');
    working = working.replaceAll(RegExp(r'<\s*tls-auth\s*[^>]*>.*?</\s*tls-auth\s*>', dotAll: true, multiLine: true, caseSensitive: false), '');
    // Remove BEGIN/END markers that are NOT part of our reconstructed key
    // But be careful not to remove the key material we just extracted
    working = working.replaceAll(RegExp(r'-----BEGIN\s+OpenVPN\s+Static\s+key\s+V1-----.*?-----END\s+OpenVPN\s+Static\s+key\s+V1-----', dotAll: true, multiLine: true, caseSensitive: false), '');
    working = working.replaceAll(RegExp(r'</\s*tls-auth\s*>', multiLine: true, caseSensitive: false), '');
    working = working.replaceAll(RegExp(r'<\s*//\s*tls-auth\s*>', multiLine: true, caseSensitive: false), '');
    working = working.replaceAll(RegExp(r'<\s*tls-auth\s*[^>]*>', multiLine: true, caseSensitive: false), '');
    // DO NOT remove orphaned hex lines here - they get removed when we remove the BEGIN/END blocks above
    
    // FOURTH: Keep only first key-direction line (remove duplicates and orphaned ones)
    final keyDirPattern = RegExp(r'^\s*key-direction\s+\d+\s*$', multiLine: true, caseSensitive: false);
    var foundKeyDirection = false;
    working = working.replaceAllMapped(keyDirPattern, (match) {
      if (!foundKeyDirection) {
        foundKeyDirection = true;
        debugPrint('[OpenVpnPort] Keeping key-direction directive: ${match.group(0)}');
        return match.group(0) ?? '';
      }
      debugPrint('[OpenVpnPort] Removing duplicate key-direction');
      return '';
    });
    
    // FIFTH: Re-add the valid tls-auth block if one was found
    if (hasValidTlsAuth && validTlsAuthKey.isNotEmpty) {
      debugPrint('[OpenVpnPort] Re-adding cleaned tls-auth block');
      debugPrint('[OpenVpnPort] TLS-Auth key material:');
      debugPrint(validTlsAuthKey);
      debugPrint('[OpenVpnPort] === End of TLS-Auth key ===');
      // Add it at the end, before final cleanup
      working += '\n<tls-auth>\n$validTlsAuthKey\n</tls-auth>\n';
    }
    
    // THIRD: Remove any remaining orphaned hex data or malformed content
    // BUT: Preserve hex lines that are inside <tls-auth>...</tls-auth> blocks
    var lines = working.split('\n');
    var cleanedLines = <String>[];
    var insideTlsAuthBlock = false;
    
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();
      
      // Track whether we're inside a tls-auth block
      if (trimmed.startsWith('<tls-auth')) {
        insideTlsAuthBlock = true;
        cleanedLines.add(line);
        continue;
      }
      
      if (trimmed.startsWith('</tls-auth')) {
        insideTlsAuthBlock = false;
        cleanedLines.add(line);
        continue;
      }
      
      if (trimmed.isEmpty) {
        cleanedLines.add(line);
        continue;
      }
      
      // If we're inside tls-auth block, KEEP everything (including hex lines)
      if (insideTlsAuthBlock) {
        cleanedLines.add(line);
        continue;
      }
      
      // Outside tls-auth block: Skip orphaned hex lines that appear after key END markers
      if (i > 0 && RegExp(r'^[a-f0-9]{32}$', caseSensitive: false).hasMatch(trimmed)) {
        final prevLine = lines[i - 1].trim();
        if (prevLine.contains('-----END') && !cleanedLines.isEmpty) {
          final lastCleanedLine = cleanedLines.last.trim();
          if (!lastCleanedLine.contains('<')) {
            debugPrint('[OpenVpnPort] Skipping orphaned hex data: $trimmed');
            continue;
          }
        }
      }
      
      cleanedLines.add(line);
    }
    
    working = cleanedLines.join('\n');

    // Step 4: Ensure all certificate and key blocks are properly closed
    // For blocks like <ca>, <cert>, <key>, <tls-crypt>, etc.
    final certBlockPatterns = [
      RegExp(r'<ca\s*>(.*?)(?:</ca>|$)', dotAll: true, caseSensitive: false),
      RegExp(r'<cert\s*>(.*?)(?:</cert>|$)', dotAll: true, caseSensitive: false),
      RegExp(r'<key\s*>(.*?)(?:</key>|$)', dotAll: true, caseSensitive: false),
      RegExp(r'<tls-crypt\s*>(.*?)(?:</tls-crypt>|$)', dotAll: true, caseSensitive: false),
    ];

    for (final pattern in certBlockPatterns) {
      working = working.replaceAllMapped(pattern, (match) {
        final fullMatch = match.group(0) ?? '';
        final tagStart = fullMatch.split('>')[0]; // Get <tag or <tag ...
        final tag = tagStart.replaceAll(RegExp(r'[<>\s/]'), '').trim();
        final content = match.group(1) ?? '';
        
        debugPrint('[OpenVpnPort] Ensuring proper closure for tag: <$tag>');
        return '<$tag>$content</$tag>\n';
      });
    }

    // Step 5: Handle auth-user-pass directive (as a line, not a block)
    // Only add auth-user-pass if it was explicitly in the config
    // Some servers (like EC2 with cert-only auth) don't need it
    final authLinePattern = RegExp(
      r'^\s*auth-user-pass(?:[ \t]+[^\r\n]+)?\s*$',
      multiLine: true,
    );

    var foundDirective = false;
    working = working.replaceAllMapped(authLinePattern, (match) {
      if (foundDirective) {
        return '';
      }
      foundDirective = true;
      debugPrint('[OpenVpnPort] Found auth-user-pass directive in config');
      return 'auth-user-pass';
    });

    if (!foundDirective) {
      // Don't automatically add auth-user-pass
      // Let the server decide if it needs it
      debugPrint('[OpenVpnPort] No auth-user-pass directive found, not adding one (cert-only auth)');
    }

    // Step 6: Remove any orphaned hex data that appears after all closing tags
    // This handles cases where the tls-auth block had corrupted trailing data
    debugPrint('[OpenVpnPort] Removing orphaned content after certificate blocks...');
    
    // Find the position of the last closing certificate tag
    final lastCertMatch = RegExp(
      r'</(?:ca|cert|key|tls-auth|tls-crypt)\s*>',
      caseSensitive: false,
    ).allMatches(working).lastOrNull;
    
    if (lastCertMatch != null) {
      final afterLastCert = working.substring(lastCertMatch.end);
      // Check if there's orphaned hex data (lines that are only hex characters)
      final orphanedHex = RegExp(r'^(\s*[a-f0-9]{32}\s*)+$', multiLine: true, caseSensitive: false);
      
      if (orphanedHex.hasMatch(afterLastCert)) {
        debugPrint('[OpenVpnPort] Found and removing orphaned hex data after last certificate block');
        debugPrint('[OpenVpnPort] Orphaned content: $afterLastCert');
        // Find where the garbage starts
        final lines = working.substring(0, lastCertMatch.end).split('\n');
        final cleanedContent = lines.join('\n');
        working = cleanedContent;
      } else {
        debugPrint('[OpenVpnPort] Content after last cert: $afterLastCert');
      }
    }

    // Step 7: Remove orphaned hex lines and orphaned OpenVPN markers between closing and opening tags
    // These are leftover from malformed certificate blocks
    var finalLines = working.split('\n');
    var finalCleanedLines = <String>[];
    var lastWasClosingTag = false;
    
    for (var i = 0; i < finalLines.length; i++) {
      final line = finalLines[i];
      final trimmed = line.trim();
      
      // Check if this is a closing tag
      if (trimmed.startsWith('</')) {
        finalCleanedLines.add(line);
        lastWasClosingTag = true;
        continue;
      }
      
      // Check if this is an opening tag
      if (trimmed.startsWith('<') && !trimmed.startsWith('</')) {
        lastWasClosingTag = false;
        finalCleanedLines.add(line);
        continue;
      }
      
      // If we just saw a closing tag and now we see orphaned content, skip it
      if (lastWasClosingTag) {
        // Skip hex lines
        if (RegExp(r'^[a-f0-9]{32}$', caseSensitive: false).hasMatch(trimmed)) {
          debugPrint('[OpenVpnPort] Skipping orphaned hex line between tags: $trimmed');
          continue;
        }
        // Skip orphaned OpenVPN markers
        if (trimmed.contains('-----BEGIN') || trimmed.contains('-----END')) {
          debugPrint('[OpenVpnPort] Skipping orphaned OpenVPN marker between tags: $trimmed');
          continue;
        }
      }
      
      finalCleanedLines.add(line);
    }
    
    working = finalCleanedLines.join('\n');
    
    // Step 8: Clean up excessive whitespace while preserving structure
    working = working.replaceAll(RegExp(r'\n\n+'), '\n');

    final normalized = _ensureTrailingNewline(working.trimRight());
    
    // Step 9: Ensure critical reconnection settings are present
    debugPrint('[OpenVpnPort] Ensuring reconnection settings are in config');
    var finalConfig = normalized;
    
    // Check for and add reconnect directives if not present
    if (!finalConfig.contains(RegExp(r'^\s*connect-retry\s+', multiLine: true))) {
      debugPrint('[OpenVpnPort] Adding connect-retry directive');
      finalConfig = 'connect-retry 3 5\n' + finalConfig;
    }
    
    if (!finalConfig.contains(RegExp(r'^\s*connect-retry-max\s+', multiLine: true))) {
      debugPrint('[OpenVpnPort] Adding connect-retry-max directive');
      finalConfig = 'connect-retry-max 30\n' + finalConfig;
    }
    
    if (!finalConfig.contains(RegExp(r'^\s*persist-remote-ip\s*', multiLine: true))) {
      debugPrint('[OpenVpnPort] Adding persist-remote-ip directive');
      finalConfig = 'persist-remote-ip\n' + finalConfig;
    }
    
    if (!finalConfig.contains(RegExp(r'^\s*explicit-exit-notify\s+', multiLine: true))) {
      debugPrint('[OpenVpnPort] Adding explicit-exit-notify directive');
      finalConfig = 'explicit-exit-notify 1\n' + finalConfig;
    }
    
    debugPrint('[OpenVpnPort] Sanitized config length: ${finalConfig.length}');
    debugPrint('[OpenVpnPort] Sanitized config preview (first 300 chars): ${finalConfig.substring(0, finalConfig.length > 300 ? 300 : finalConfig.length)}');

    return SanitizedOpenVpnConfig(
      config: finalConfig,
      username: username,
      password: password,
    );
  }

  @visibleForTesting
  SanitizedOpenVpnConfig debugSanitizeOpenVpnConfig(String config) {
    return _sanitizeOpenVpnConfig(config);
  }

  model.VpnStatus? _lastStatus;
}

class SanitizedOpenVpnConfig {
  const SanitizedOpenVpnConfig({
    required this.config,
    this.username,
    this.password,
  });

  final String config;
  final String? username;
  final String? password;
}
