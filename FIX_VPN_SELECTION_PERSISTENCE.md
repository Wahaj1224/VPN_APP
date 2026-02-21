# VPN Selection & SoftEther Configuration Persistence Fix

## Problem Description
The app had a critical bug where the selected VPN type (OpenVPN vs SoftEther) and SoftEther configuration details were not being persisted. This caused the following issues:

1. When user selected **SoftEther VPN** in settings and configured the connection details
2. The selection was only stored in memory (in-app state)
3. When navigating to the connect page, the connection would fail because:
   - The `selectedVpnTypeProvider` always defaulted to **OpenVPN** instead of reading the saved selection
   - The `softEtherConfigProvider` was **null** because the config details were not persisted

## Root Cause Analysis

### Issue 1: VPN Type Selection Not Persisted
**File:** `lib/services/vpn/vpn_selection_provider.dart`

**Problem:**
```dart
final selectedVpnTypeProvider =
    StateNotifierProvider<VpnTypeNotifier, VpnType>((ref) {
      return VpnTypeNotifier(VpnType.openVpn);  // ALWAYS defaults to OpenVPN!
    });
```

The provider was initialized with `VpnType.openVpn` as the hardcoded default, with no persistence mechanism. When the select button was tapped, the state was updated in memory only.

### Issue 2: SoftEther Config Not Persisted
**File:** `lib/services/vpn/vpn_selection_provider.dart`

**Problem:**
```dart
final softEtherConfigProvider =
    StateNotifierProvider<SoftEtherConfigNotifier, SoftEtherConfig?>((ref) {
      return SoftEtherConfigNotifier(null);  // Always null initially!
    });
```

Similarly, the SoftEther config was never saved to persistent storage.

## Solution Implemented

### 1. Added Persistence to SettingsRepository
**File:** `lib/features/settings/data/settings_repository.dart`

Added VPN type and SoftEther config persistence:

```dart
// Added constants
static const _vpnTypeKey = 'settings_vpn_type';
static const _softEtherConfigKey = 'settings_softether_config';

// Load/save VPN type
String? loadVpnType() => _prefs.getString(_vpnTypeKey);
Future<void> saveVpnType(String type) => _prefs.setString(_vpnTypeKey, type);

// Load/save SoftEther config
SoftEtherConfig? loadSoftEtherConfig() { ... }
Future<void> saveSoftEtherConfig(SoftEtherConfig config) { ... }
Future<void> clearSoftEtherConfig() { ... }
```

### 2. Updated selectedVpnTypeProvider
**File:** `lib/services/vpn/vpn_selection_provider.dart`

Now loads persisted VPN type on initialization:

```dart
final selectedVpnTypeProvider =
    StateNotifierProvider<VpnTypeNotifier, VpnType>((ref) {
  final settingsRepo = ref.watch(settingsRepositoryProvider);
  
  VpnType initialType = VpnType.openVpn;
  if (settingsRepo != null) {
    final savedType = settingsRepo.loadVpnType();
    if (savedType != null) {
      initialType = VpnType.fromString(savedType) ?? VpnType.openVpn;
    }
  }
  
  return VpnTypeNotifier(
    repository: settingsRepo,
    initialType: initialType,
  );
});
```

### 3. Updated VpnTypeNotifier
Made it async and persist selections:

```dart
class VpnTypeNotifier extends StateNotifier<VpnType> {
  VpnTypeNotifier({
    SettingsRepository? repository,
    VpnType initialType = VpnType.openVpn,
  })  : _repository = repository,
        super(initialType);

  final SettingsRepository? _repository;

  Future<void> selectVpnType(VpnType type) async {
    state = type;
    await _repository?.saveVpnType(type.name);
  }
}
```

### 4. Updated softEtherConfigProvider
Similarly loads and persists SoftEther config:

```dart
final softEtherConfigProvider =
    StateNotifierProvider<SoftEtherConfigNotifier, SoftEtherConfig?>((ref) {
  final settingsRepo = ref.watch(settingsRepositoryProvider);
  
  SoftEtherConfig? initialConfig;
  if (settingsRepo != null) {
    initialConfig = settingsRepo.loadSoftEtherConfig();
  }
  
  return SoftEtherConfigNotifier(
    repository: settingsRepo,
    initialConfig: initialConfig,
  );
});
```

### 5. Updated SoftEtherConfigNotifier
Made it async and persist configurations:

```dart
class SoftEtherConfigNotifier extends StateNotifier<SoftEtherConfig?> {
  SoftEtherConfigNotifier({
    SettingsRepository? repository,
    SoftEtherConfig? initialConfig,
  })  : _repository = repository,
        super(initialConfig);

  final SettingsRepository? _repository;

  Future<void> setSoftEtherConfig(SoftEtherConfig config) async {
    state = config;
    await _repository?.saveSoftEtherConfig(config);
  }

  Future<void> clearConfig() async {
    state = null;
    await _repository?.clearSoftEtherConfig();
  }
}
```

### 6. Updated UI Call Sites
**File:** `lib/features/onboarding/presentation/vpn_type_selection_screen.dart`

Updated to properly handle async calls:

```dart
// When confirming selection
await ref.read(selectedVpnTypeProvider.notifier).selectVpnType(_selectedType!);

// When config changes
unawaited(
  ref.read(softEtherConfigProvider.notifier).setSoftEtherConfig(config),
);
```

## How the Fix Works

### Flow Before Fix:
1. User selects SoftEther → State updated in memory only
2. User navigates to connect page
3. `selectedVpnTypeProvider` reads default value (OpenVPN) ❌
4. Connection fails or connects to wrong VPN

### Flow After Fix:
1. User selects SoftEther → **Saved to SharedPreferences** ✓
2. User sets SoftEther config → **Saved to SharedPreferences** ✓  
3. User navigates to connect page
4. `selectedVpnTypeProvider` **loads from SharedPreferences** → SoftEther ✓
5. `softEtherConfigProvider` **loads from SharedPreferences** → Valid config ✓
6. Connection code reads the correct VPN type and config
7. **Successfully connects to SoftEther VPN** ✓

## Files Modified

1. **lib/features/settings/data/settings_repository.dart**
   - Added VPN type and SoftEther config persistence methods

2. **lib/services/vpn/vpn_selection_provider.dart**
   - Updated `selectedVpnTypeProvider` to load from storage
   - Updated `VpnTypeNotifier` to be async and persist selections
   - Updated `softEtherConfigProvider` to load from storage
   - Updated `SoftEtherConfigNotifier` to be async and persist config

3. **lib/features/onboarding/presentation/vpn_type_selection_screen.dart**
   - Added async/await for VPN type selection confirmation
   - Added unawaited for SoftEther config changes

## Testing Recommendations

1. **Test 1: Verify OpenVPN still works (default)**
   - Open app → Connect to OpenVPN server → Should work ✓

2. **Test 2: Verify SoftEther selection persists**
   - Select SoftEther → Close app → Reopen → Verify SoftEther is still selected ✓

3. **Test 3: Verify SoftEther config persists**
   - Configure SoftEther connection details → Close app → Reopen → Verify config is still there ✓

4. **Test 4: Verify SoftEther connection works**
   - Select SoftEther with valid config → Navigate to connect → Attempt connection → Should try to connect to SoftEther server ✓

5. **Test 5: Verify user can switch between VPN types**
   - Select SoftEther → Close app → Reopen → Select OpenVPN → Close app → Reopen → Verify OpenVPN is selected ✓

## Impact on Existing Code

- ✓ No breaking changes to public APIs
- ✓ Backward compatible (defaults to OpenVPN if no saved selection)
- ✓ Follows existing patterns used in `SettingsController`
- ✓ Uses existing `SettingsRepository` infrastructure
