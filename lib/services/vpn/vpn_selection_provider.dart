import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/data/settings_repository.dart';
import 'models/vpn_type.dart';
import 'models/softether_config.dart';
import 'softether_port.dart';
import 'vpn_provider.dart';
import '../../platform/softether_channel.dart';

/// Provider for the selected VPN type (OpenVPN or SoftEther)
/// Now loads from persistent storage on initialization
final selectedVpnTypeProvider =
    StateNotifierProvider<VpnTypeNotifier, VpnType>((ref) {
  final settingsRepo = ref.watch(settingsRepositoryProvider);
  
  // Load initial VPN type from repository if available
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

class VpnTypeNotifier extends StateNotifier<VpnType> {
  VpnTypeNotifier({
    SettingsRepository? repository,
    VpnType initialType = VpnType.openVpn,
  })  : _repository = repository,
        super(initialType);

  final SettingsRepository? _repository;

  Future<void> selectVpnType(VpnType type) async {
    state = type;
    // Persist the selection to storage
    await _repository?.saveVpnType(type.name);
  }
}

/// Provider for SoftEther configuration
/// Now loads from persistent storage on initialization
final softEtherConfigProvider =
    StateNotifierProvider<SoftEtherConfigNotifier, SoftEtherConfig?>((ref) {
  final settingsRepo = ref.watch(settingsRepositoryProvider);
  
  // Load initial SoftEther config from repository if available
  SoftEtherConfig? initialConfig;
  if (settingsRepo != null) {
    initialConfig = settingsRepo.loadSoftEtherConfig();
  }
  
  return SoftEtherConfigNotifier(
    repository: settingsRepo,
    initialConfig: initialConfig,
  );
});

class SoftEtherConfigNotifier extends StateNotifier<SoftEtherConfig?> {
  SoftEtherConfigNotifier({
    SettingsRepository? repository,
    SoftEtherConfig? initialConfig,
  })  : _repository = repository,
        super(initialConfig);

  final SettingsRepository? _repository;

  Future<void> setSoftEtherConfig(SoftEtherConfig config) async {
    state = config;
    // Persist the configuration to storage
    await _repository?.saveSoftEtherConfig(config);
  }

  Future<void> clearConfig() async {
    state = null;
    // Clear from storage
    await _repository?.clearSoftEtherConfig();
  }

  bool hasValidConfig() => state != null && state!.isValid;
}

/// Provider for SoftEther port
final softEtherPortProvider = Provider<SoftEtherPort>((ref) {
  final port = SoftEtherPort();
  port.initialize().catchError((error) {
    print('Failed to initialize SoftEther: $error');
  });
  ref.onDispose(port.dispose);
  return port;
});

/// Provider to detect if native SoftEther channel is available
final softEtherNativeAvailableProvider = FutureProvider<bool>((ref) async {
  final ch = SoftEtherChannel();
  final ok = await ch.initialize();
  return ok;
});

/// Provider to get the active VPN port based on selected type
final activeVpnPortProvider = Provider<dynamic>((ref) {
  final selectedType = ref.watch(selectedVpnTypeProvider);

  if (selectedType == VpnType.openVpn) {
    return ref.watch(openVpnPortProvider);
  } else {
    return ref.watch(softEtherPortProvider);
  }
});

/// Provider for checking if VPN is currently configured
final isVpnConfiguredProvider = Provider<bool>((ref) {
  final selectedType = ref.watch(selectedVpnTypeProvider);
  final softEtherConfig = ref.watch(softEtherConfigProvider);

  if (selectedType == VpnType.openVpn) {
    // OpenVPN is always available with server selection
    return true;
  } else {
    // SoftEther needs valid configuration and native support
    final nativeAvailable = ref.watch(softEtherNativeAvailableProvider).asData?.value ?? false;
    return softEtherConfig != null && softEtherConfig.isValid && nativeAvailable;
  }
});
