import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/vpn/models/softether_config.dart';
import '../../../services/storage/prefs.dart';
import '../domain/auto_connect_rules.dart';
import '../domain/protocol_config.dart';
import '../domain/split_tunnel_config.dart';

class SettingsRepository {
  SettingsRepository(this._prefs);

  final PrefsStore _prefs;

  static const _protocolKey = 'settings_protocol';
  static const _splitTunnelKey = 'settings_split_tunnel';
  static const _autoConnectKey = 'settings_auto_connect';
  static const _batterySaverKey = 'settings_battery_saver';
  static const _networkQualityKey = 'settings_network_quality';
  static const _appearanceAccentKey = 'settings_accent';
  static const _vpnTypeKey = 'settings_vpn_type';
  static const _softEtherConfigKey = 'settings_softether_config';

  ProtocolConfig loadProtocol() {
    final jsonString = _prefs.getString(_protocolKey);
    return ProtocolConfig.fromJson(_decode(jsonString));
  }

  Future<void> saveProtocol(ProtocolConfig config) async {
    await _prefs.setString(_protocolKey, json.encode(config.toJson()));
  }

  SplitTunnelConfig loadSplitTunnel() {
    final jsonString = _prefs.getString(_splitTunnelKey);
    return SplitTunnelConfig.fromJson(_decode(jsonString));
  }

  Future<void> saveSplitTunnel(SplitTunnelConfig config) async {
    await _prefs.setString(_splitTunnelKey, json.encode(config.toJson()));
  }

  AutoConnectRules loadAutoConnect() {
    final jsonString = _prefs.getString(_autoConnectKey);
    return AutoConnectRules.fromJson(_decode(jsonString));
  }

  Future<void> saveAutoConnect(AutoConnectRules rules) async {
    await _prefs.setString(_autoConnectKey, json.encode(rules.toJson()));
  }

  bool loadBatterySaver() =>
      _prefs.getBool(_batterySaverKey, defaultValue: false);

  Future<void> saveBatterySaver(bool value) async {
    await _prefs.setBool(_batterySaverKey, value);
  }

  bool loadNetworkQuality() =>
      _prefs.getBool(_networkQualityKey, defaultValue: true);

  Future<void> saveNetworkQuality(bool value) async {
    await _prefs.setBool(_networkQualityKey, value);
  }

  String? loadAccent() => _prefs.getString(_appearanceAccentKey);

  Future<void> saveAccent(String name) =>
      _prefs.setString(_appearanceAccentKey, name);

  String? loadVpnType() => _prefs.getString(_vpnTypeKey);

  Future<void> saveVpnType(String type) =>
      _prefs.setString(_vpnTypeKey, type);

  SoftEtherConfig? loadSoftEtherConfig() {
    final jsonString = _prefs.getString(_softEtherConfigKey);
    if (jsonString == null) return null;
    try {
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return SoftEtherConfig.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSoftEtherConfig(SoftEtherConfig config) async {
    await _prefs.setString(_softEtherConfigKey, jsonEncode(config.toJson()));
  }

  Future<void> clearSoftEtherConfig() async {
    await _prefs.remove(_softEtherConfigKey);
  }

  Map<String, dynamic>? _decode(String? jsonString) {
    if (jsonString == null) return null;
    try {
      return json.decode(jsonString) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}

final settingsRepositoryProvider = Provider<SettingsRepository?>((ref) {
  final prefsAsync = ref.watch(prefsStoreProvider);
  return prefsAsync.whenOrNull(data: SettingsRepository.new);
});
