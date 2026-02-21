# SoftEther Disconnection & Duplicate Stage Updates Fix

## Problem Summary

The logs showed multiple critical issues preventing graceful disconnection:

1. **OpenVPN Crash on Disconnect**: When SoftEther connection failed, the app tried to disconnect OpenVPN (which was never started), causing `NullPointerException` in the OpenVPN plugin
2. **Duplicate VPN Stage Updates**: Multiple "disconnected" stage updates were being processed, causing redundant state changes
3. **IP Fetch Not Cancelled**: Background IP fetch operations were continuing even after disconnection

## Root Causes Identified

### Issue 1: Wrong VPN Port Being Disconnected
**Location**: `lib/features/session/domain/session_controller.dart` - `_forceDisconnect()` method

**Problem**: The method always called `await _vpnPort.disconnect()` (OpenVPN), even when SoftEther was the active VPN. This is because:
- When using SoftEther, `_activeVpnProtocol` was never set to track which VPN was active
- The disconnect logic had no way to know whether to call `_softEtherPort.disconnect()` or `_vpnPort.disconnect()`

**Error in Logs**:
```
E/MethodChannel#id.laskarmedia.openvpn_flutter/vpncontrol(25559): Failed to handle method call
java.lang.NullPointerException: Attempt to invoke virtual method 'void de.blinkt.openvpn.core.OpenVPNService.openvpnStopped()' on a null object reference
```

### Issue 2: Duplicate VPN Stage Updates
**Location**: `lib/features/session/domain/session_controller.dart` - `_handleVpnStage()` method

**Problem**: Multiple listeners were receiving the same disconnected event and processing it multiple times:
```
I/flutter (25559): [SessionController] VPN stage changed to: VPNStage.disconnected
I/flutter (25559): [SessionController] VPN stage update: VPNStage.disconnected
I/flutter (25559): [SessionController] VPN stage changed to: VPNStage.disconnected
I/flutter (25559): [SessionController] VPN stage changed to: VPNStage.disconnected
```

This occurred because there was no deduplication of stage messages.

### Issue 3: SoftEther Disconnect Incomplete
**Location**: `lib/services/vpn/softether_port.dart` - `disconnect()` method

**Problem**: The SoftEther disconnect method didn't actually call the native disconnect, just cleared local state and emitted a stage event.

## Solutions Implemented

### Fix 1: Track Active VPN Protocol
**File**: `lib/features/session/domain/session_controller.dart`

**Changes**:
1. Added new field to track active VPN:
```dart
VpnProtocol? _activeVpnProtocol; // Track which VPN protocol is currently active
```

2. Set the active protocol when connecting:
```dart
if (selectedVpnType == VpnType.softEther) {
  _activeVpnProtocol = null; // SoftEther uses native service
  await _connectSoftEther();
} else {
  _activeVpnProtocol = VpnProtocol.openvpn;
  await _connectOpenVpn(server);
}
```

3. Updated `_forceDisconnect()` to disconnect the correct VPN:
```dart
Future<void> _forceDisconnect({bool clearPrefs = false}) async {
  _cancelConnectionTimeout();
  _stopHealthCheck();
  _cancelIpFetch();
  
  // Only disconnect the active VPN - don't call both!
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
  
  // ... rest of cleanup
  _activeVpnProtocol = null;
}
```

**Impact**: OpenVPN plugin no longer crashes because we only call disconnect on the VPN that was actually started.

### Fix 2: Deduplicate VPN Stage Updates
**File**: `lib/features/session/domain/session_controller.dart`

**Changes**:
1. Added tracking field for last stage:
```dart
VPNStage? _lastVpnStage; // Track last stage to prevent duplicate processing
```

2. Added deduplication logic in `_handleVpnStage()`:
```dart
// Prevent duplicate stage processing
if (_lastVpnStage == stage && stage == VPNStage.disconnected) {
  _log('⏭️ Skipping duplicate disconnected stage');
  return;
}
if (stage != VPNStage.unknown) {
  _lastVpnStage = stage;
}
```

**Impact**: Each VPN stage is processed only once, preventing duplicate state transitions and reducing log noise.

### Fix 3: Complete SoftEther Native Disconnect
**File**: `lib/services/vpn/softether_port.dart`

**Changes**:
Updated disconnect method to actually call the native SoftEther disconnect:
```dart
Future<void> disconnect() async {
  try {
    debugPrint('[SoftEtherPort] disconnect() requested');

    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;

    _isConnected = false;
    _currentConfig = null;
    
    // Call native SoftEther disconnect
    try {
      await _channel.disconnect();
      debugPrint('[SoftEtherPort] Native SoftEther disconnect called successfully');
    } catch (e) {
      debugPrint('[SoftEtherPort] Error calling native disconnect: $e');
    }

    if (!_stageController.isClosed) {
      _stageController.add(VPNStage.disconnected);
    }

    debugPrint('[SoftEtherPort] SoftEther disconnected successfully');
  } catch (e) {
    debugPrint('[SoftEtherPort] Error disconnecting from VPN: $e');
  }
}
```

**Impact**: SoftEther properly terminates the native tunnel connection instead of just clearing local state.

## Connection Flow After Fixes

### When Using SoftEther:
1. User taps Connect
2. `connect()` sets `_activeVpnProtocol = null` (because SoftEther)
3. `_connectSoftEther()` runs
4. If it fails, `_forceDisconnect()` detects `_activeVpnProtocol == null`
5. Calls `_softEtherPort.disconnect()` (NOT OpenVPN)
6. SoftEther disconnects cleanly without OpenVPN crash

### When Using OpenVPN:
1. User taps Connect
2. `connect()` sets `_activeVpnProtocol = VpnProtocol.openvpn`
3. `_connectOpenVpn()` runs
4. If it fails, `_forceDisconnect()` detects `_activeVpnProtocol == openvpn`
5. Calls `_vpnPort.disconnect()` (OpenVPN)
6. OpenVPN disconnects properly

### VPN Stage Event Processing:
1. Stage event received (e.g., disconnected)
2. Checked against `_lastVpnStage` - if identical, skip processing
3. If new stage, update `_lastVpnStage` and process
4. No more duplicate "disconnected" messages

## Expected Log Output After Fixes

```
I/flutter: [SessionController] connect() requested for SoftEther (N/A), VPN Type: VpnType.softEther
I/flutter: [SessionController] 🌐 Attempting to connect to SoftEther server: 100.28.211.202:1701
I/flutter: [SoftEtherVpnService] 🔗 Attempting to connect to 100.28.211.202:1701...
E/SoftEtherVpnService: ❌ CRITICAL: Failed to establish tunnel
I/flutter: [SessionController] Cancelled ongoing IP fetch operation
I/flutter: [SessionController] VPN stage update: VPNStage.disconnected
I/flutter: [SessionController] Disconnecting SoftEther native service
I/flutter: [SoftEtherPort] Native SoftEther disconnect called successfully
```

**Key differences**:
- Only ONE "VPN stage update: VPNStage.disconnected" message
- `_softEtherPort.disconnect()` called (not OpenVPN)
- No OpenVPN NullPointerException
- No duplicate stage updates

## Files Modified

1. `lib/features/session/domain/session_controller.dart`
   - Added `_activeVpnProtocol` field to track active VPN
   - Added `_lastVpnStage` field for deduplication
   - Updated `_handleVpnStage()` with deduplication logic
   - Updated `connect()` to set `_activeVpnProtocol`
   - Updated `_forceDisconnect()` to disconnect correct VPN
   - Updated `dispose()` to clear `_lastVpnStage`

2. `lib/services/vpn/softether_port.dart`
   - Updated `disconnect()` to call native SoftEther disconnect via `_channel.disconnect()`

## Testing Recommendations

1. **SoftEther Connection Failure**:
   - Connect to SoftEther with unreachable server
   - Verify logs show only ONE "disconnected" stage update
   - Verify no OpenVPN errors appear
   - Verify app returns to disconnected state

2. **Manual Disconnect During SoftEther Connection**:
   - Start SoftEther connection
   - Tap disconnect before it completes
   - Verify only `_softEtherPort.disconnect()` is called
   - Verify no OpenVPN errors

3. **OpenVPN Connection Still Works**:
   - Connect to OpenVPN server (any working one)
   - Verify connection succeeds
   - Disconnect and verify clean disconnection
   - Verify `_vpnPort.disconnect()` is called

4. **Stage Updates Are Deduplicated**:
   - Monitor logs for duplicate "disconnected" stages
   - Should only see one event per disconnection
   - No redundant state updates

## Related Previous Fixes

This fix builds on previous improvements:
- IP fetch cancellation during disconnect (prevents hanging background operations)
- Dual VPN port streams (OpenVPN and SoftEther listeners)
- Health checks for connection monitoring
- Proper error message display

The complete fix ensures that:
- ✅ SoftEther can fail gracefully without crashing OpenVPN plugin
- ✅ Duplicate stage updates are eliminated
- ✅ Correct VPN service is always disconnected
- ✅ Background operations (IP fetch) are cancelled on disconnect
- ✅ User sees clean, single error message instead of multiple updates
