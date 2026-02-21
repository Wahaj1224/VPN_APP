/// Enum for VPN vendor types
enum VpnType {
  openVpn('OpenVPN'),
  softEther('SoftEther');

  final String displayName;
  const VpnType(this.displayName);

  /// Get enum from string
  static VpnType? fromString(String? value) {
    return VpnType.values.where((e) => e.name == value).firstOrNull;
  }

  /// Convert to string
  String toStringValue() => name;
}

/// VPN Protocol types for SoftEther
enum VpnProtocol {
  softEther('SoftEther (Native)'),
  l2tpIpsec('L2TP/IPSec with Pre-Shared Key'),
  sstp('SSTP'),
  openvpn('OpenVPN'),
  wireguard('WireGuard');

  final String displayName;
  const VpnProtocol(this.displayName);

  static VpnProtocol? fromString(String? value) {
    return VpnProtocol.values.where((e) => e.name == value).firstOrNull;
  }

  String toStringValue() => name;
}
