import 'vpn_type.dart';

/// SoftEther VPN Configuration
class SoftEtherConfig {
  /// Connection identifier/name
  final String connectionName;

  /// Server address or IP
  final String serverAddress;

  /// Server port (default 5555)
  final int serverPort;

  /// VPN protocol type
  final VpnProtocol protocol;

  /// Pre-shared key (for L2TP/IPSec)
  final String? presharedKey;

  /// Username for authentication
  final String username;

  /// Password for authentication
  final String password;

  /// Whether to use encryption
  final bool useEncryption;

  /// Whether to use compression
  final bool useCompression;

  const SoftEtherConfig({
    required this.connectionName,
    required this.serverAddress,
    this.serverPort = 5555,
    required this.protocol,
    this.presharedKey,
    required this.username,
    required this.password,
    this.useEncryption = true,
    this.useCompression = false,
  });

  /// Copy with new values
  SoftEtherConfig copyWith({
    String? connectionName,
    String? serverAddress,
    int? serverPort,
    VpnProtocol? protocol,
    String? presharedKey,
    String? username,
    String? password,
    bool? useEncryption,
    bool? useCompression,
  }) {
    return SoftEtherConfig(
      connectionName: connectionName ?? this.connectionName,
      serverAddress: serverAddress ?? this.serverAddress,
      serverPort: serverPort ?? this.serverPort,
      protocol: protocol ?? this.protocol,
      presharedKey: presharedKey ?? this.presharedKey,
      username: username ?? this.username,
      password: password ?? this.password,
      useEncryption: useEncryption ?? this.useEncryption,
      useCompression: useCompression ?? this.useCompression,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'connectionName': connectionName,
      'serverAddress': serverAddress,
      'serverPort': serverPort,
      'protocol': protocol.name,
      'presharedKey': presharedKey,
      'username': username,
      'password': password,
      'useEncryption': useEncryption,
      'useCompression': useCompression,
    };
  }

  /// Create from JSON
  factory SoftEtherConfig.fromJson(Map<String, dynamic> json) {
    return SoftEtherConfig(
      connectionName: json['connectionName'] as String? ?? '',
      serverAddress: json['serverAddress'] as String? ?? '',
      serverPort: json['serverPort'] as int? ?? 5555,
      protocol: VpnProtocol.fromString(json['protocol'] as String?) ?? VpnProtocol.l2tpIpsec,
      presharedKey: json['presharedKey'] as String?,
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      useEncryption: json['useEncryption'] as bool? ?? true,
      useCompression: json['useCompression'] as bool? ?? false,
    );
  }

  /// Validate configuration
  bool get isValid {
    if (connectionName.isEmpty) return false;
    if (serverAddress.isEmpty) return false;
    if (username.isEmpty) return false;
    if (password.isEmpty) return false;
    if (protocol == VpnProtocol.l2tpIpsec && (presharedKey?.isEmpty ?? true)) {
      return false;
    }
    return true;
  }

  /// Get validation errors
  List<String> getErrors() {
    final errors = <String>[];
    if (connectionName.isEmpty) errors.add('Connection name is required');
    if (serverAddress.isEmpty) errors.add('Server address is required');
    if (username.isEmpty) errors.add('Username is required');
    if (password.isEmpty) errors.add('Password is required');
    if (protocol == VpnProtocol.l2tpIpsec && (presharedKey?.isEmpty ?? true)) {
      errors.add('Pre-shared key is required for L2TP/IPSec');
    }
    return errors;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SoftEtherConfig &&
          runtimeType == other.runtimeType &&
          connectionName == other.connectionName &&
          serverAddress == other.serverAddress &&
          serverPort == other.serverPort &&
          protocol == other.protocol &&
          presharedKey == other.presharedKey &&
          username == other.username &&
          password == other.password &&
          useEncryption == other.useEncryption &&
          useCompression == other.useCompression;

  @override
  int get hashCode =>
      connectionName.hashCode ^
      serverAddress.hashCode ^
      serverPort.hashCode ^
      protocol.hashCode ^
      presharedKey.hashCode ^
      username.hashCode ^
      password.hashCode ^
      useEncryption.hashCode ^
      useCompression.hashCode;

  @override
  String toString() =>
      'SoftEtherConfig(connectionName: $connectionName, serverAddress: $serverAddress, serverPort: $serverPort, protocol: $protocol, username: $username, presharedKey: ${presharedKey != null ? '***' : 'null'}, password: ***, useEncryption: $useEncryption, useCompression: $useCompression)';
}
//
// /// SoftEther VPN Configuration
// class SoftEtherConfig {
//   /// Connection identifier/name
//   final String connectionName;
//
//   /// Server address or IP
//   final String serverAddress;
//
//   /// Server port (default 5555)
//   final int serverPort;
//
//   /// VPN protocol type
//   final VpnProtocol protocol;
//
//   /// Pre-shared key (for L2TP/IPSec)
//   final String? presharedKey;
//
//   /// Username for authentication
//   final String username;
//
//   /// Password for authentication
//   final String password;
//
//   /// Whether to use encryption
//   final bool useEncryption;
//
//   /// Whether to use compression
//   final bool useCompression;
//
//   const SoftEtherConfig({
//     required this.connectionName,
//     required this.serverAddress,
//     this.serverPort = 5555,
//     required this.protocol,
//     this.presharedKey,
//     required this.username,
//     required this.password,
//     this.useEncryption = true,
//     this.useCompression = false,
//   });
//
//   /// Copy with new values
//   SoftEtherConfig copyWith({
//     String? connectionName,
//     String? serverAddress,
//     int? serverPort,
//     VpnProtocol? protocol,
//     String? presharedKey,
//     String? username,
//     String? password,
//     bool? useEncryption,
//     bool? useCompression,
//   }) {
//     return SoftEtherConfig(
//       connectionName: connectionName ?? this.connectionName,
//       serverAddress: serverAddress ?? this.serverAddress,
//       serverPort: serverPort ?? this.serverPort,
//       protocol: protocol ?? this.protocol,
//       presharedKey: presharedKey ?? this.presharedKey,
//       username: username ?? this.username,
//       password: password ?? this.password,
//       useEncryption: useEncryption ?? this.useEncryption,
//       useCompression: useCompression ?? this.useCompression,
//     );
//   }
//
//   /// Convert to JSON
//   Map<String, dynamic> toJson() {
//     return {
//       'connectionName': connectionName,
//       'serverAddress': serverAddress,
//       'serverPort': serverPort,
//       'protocol': protocol.name,
//       'presharedKey': presharedKey,
//       'username': username,
//       'password': password,
//       'useEncryption': useEncryption,
//       'useCompression': useCompression,
//     };
//   }
//
//   /// Create from JSON
//   factory SoftEtherConfig.fromJson(Map<String, dynamic> json) {
//     return SoftEtherConfig(
//       connectionName: json['connectionName'] as String? ?? '',
//       serverAddress: json['serverAddress'] as String? ?? '',
//       serverPort: json['serverPort'] as int? ?? 5555,
//       protocol: VpnProtocol.fromString(json['protocol'] as String?) ?? VpnProtocol.l2tpIpsec,
//       presharedKey: json['presharedKey'] as String?,
//       username: json['username'] as String? ?? '',
//       password: json['password'] as String? ?? '',
//       useEncryption: json['useEncryption'] as bool? ?? true,
//       useCompression: json['useCompression'] as bool? ?? false,
//     );
//   }
//
//   /// Validate configuration
//   bool get isValid {
//     if (connectionName.isEmpty) return false;
//     if (serverAddress.isEmpty) return false;
//     if (username.isEmpty) return false;
//     if (password.isEmpty) return false;
//     if (protocol == VpnProtocol.l2tpIpsec && (presharedKey?.isEmpty ?? true)) {
//       return false;
//     }
//     return true;
//   }
//
//   /// Get validation errors
//   List<String> getErrors() {
//     final errors = <String>[];
//     if (connectionName.isEmpty) errors.add('Connection name is required');
//     if (serverAddress.isEmpty) errors.add('Server address is required');
//     if (username.isEmpty) errors.add('Username is required');
//     if (password.isEmpty) errors.add('Password is required');
//     if (protocol == VpnProtocol.l2tpIpsec && (presharedKey?.isEmpty ?? true)) {
//       errors.add('Pre-shared key is required for L2TP/IPSec');
//     }
//     return errors;
//   }
//
//   @override
//   bool operator ==(Object other) =>
//       identical(this, other) ||
//       other is SoftEtherConfig &&
//           runtimeType == other.runtimeType &&
//           connectionName == other.connectionName &&
//           serverAddress == other.serverAddress &&
//           serverPort == other.serverPort &&
//           protocol == other.protocol &&
//           presharedKey == other.presharedKey &&
//           username == other.username &&
//           password == other.password &&
//           useEncryption == other.useEncryption &&
//           useCompression == other.useCompression;
//
//   @override
//   int get hashCode =>
//       connectionName.hashCode ^
//       serverAddress.hashCode ^
//       serverPort.hashCode ^
//       protocol.hashCode ^
//       presharedKey.hashCode ^
//       username.hashCode ^
//       password.hashCode ^
//       useEncryption.hashCode ^
//       useCompression.hashCode;
//
//   @override
//   String toString() =>
//       'SoftEtherConfig(connectionName: $connectionName, serverAddress: $serverAddress, serverPort: $serverPort, protocol: $protocol, username: $username, presharedKey: ${presharedKey != null ? '***' : 'null'}, password: ***, useEncryption: $useEncryption, useCompression: $useCompression)';
// }



//
// import 'vpn_type.dart';
//
// /// SoftEther VPN Configuration
// class SoftEtherConfig {
//   /// Connection identifier/name
//   final String connectionName;
//
//   /// Server address or IP
//   final String serverAddress;
//
//   /// Server port (default 5555)
//   final int serverPort;
//
//   /// VPN protocol type
//   final VpnProtocol protocol;
//
//   /// Pre-shared key (for L2TP/IPSec)
//   final String? presharedKey;
//
//   /// Username for authentication
//   final String username;
//
//   /// Password for authentication
//   final String password;
//
//   /// Whether to use encryption
//   final bool useEncryption;
//
//   /// Whether to use compression
//   final bool useCompression;
//
//   const SoftEtherConfig({
//     required this.connectionName,
//     required this.serverAddress,
//     this.serverPort = 5555,
//     required this.protocol,
//     this.presharedKey,
//     required this.username,
//     required this.password,
//     this.useEncryption = true,
//     this.useCompression = false,
//   });
//
//   /// Copy with new values
//   SoftEtherConfig copyWith({
//     String? connectionName,
//     String? serverAddress,
//     int? serverPort,
//     VpnProtocol? protocol,
//     String? presharedKey,
//     String? username,
//     String? password,
//     bool? useEncryption,
//     bool? useCompression,
//   }) {
//     return SoftEtherConfig(
//       connectionName: connectionName ?? this.connectionName,
//       serverAddress: serverAddress ?? this.serverAddress,
//       serverPort: serverPort ?? this.serverPort,
//       protocol: protocol ?? this.protocol,
//       presharedKey: presharedKey ?? this.presharedKey,
//       username: username ?? this.username,
//       password: password ?? this.password,
//       useEncryption: useEncryption ?? this.useEncryption,
//       useCompression: useCompression ?? this.useCompression,
//     );
//   }
//
//   /// Convert to JSON
//   Map<String, dynamic> toJson() {
//     return {
//       'connectionName': connectionName,
//       'serverAddress': serverAddress,
//       'serverPort': serverPort,
//       'protocol': protocol.name,
//       'presharedKey': presharedKey,
//       'username': username,
//       'password': password,
//       'useEncryption': useEncryption,
//       'useCompression': useCompression,
//     };
//   }
//
//   /// Create from JSON
//   factory SoftEtherConfig.fromJson(Map<String, dynamic> json) {
//     return SoftEtherConfig(
//       connectionName: json['connectionName'] as String? ?? '',
//       serverAddress: json['serverAddress'] as String? ?? '',
//       serverPort: json['serverPort'] as int? ?? 5555,
//       protocol: VpnProtocol.fromString(json['protocol'] as String?) ??
//           VpnProtocol.l2tpIpsec,
//       presharedKey: json['presharedKey'] as String?,
//       username: json['username'] as String? ?? '',
//       password: json['password'] as String? ?? '',
//       useEncryption: json['useEncryption'] as bool? ?? true,
//       useCompression: json['useCompression'] as bool? ?? false,
//     );
//   }
//
//   /// Validate configuration
//   bool get isValid {
//     if (connectionName.isEmpty) return false;
//     if (serverAddress.isEmpty) return false;
//     if (username.isEmpty) return false;
//     if (password.isEmpty) return false;
//     if (protocol == VpnProtocol.l2tpIpsec && (presharedKey?.isEmpty ?? true)) {
//       return false;
//     }
//     return true;
//   }
//
//   /// Get validation errors
//   List<String> getErrors() {
//     final errors = <String>[];
//     if (connectionName.isEmpty) errors.add('Connection name is required');
//     if (serverAddress.isEmpty) errors.add('Server address is required');
//     if (username.isEmpty) errors.add('Username is required');
//     if (password.isEmpty) errors.add('Password is required');
//     if (protocol == VpnProtocol.l2tpIpsec && (presharedKey?.isEmpty ?? true)) {
//       errors.add('Pre-shared key is required for L2TP/IPSec');
//     }
//     return errors;
//   }
//
//   @override
//   bool operator ==(Object other) =>
//       identical(this, other) ||
//           other is SoftEtherConfig &&
//               runtimeType == other.runtimeType &&
//               connectionName == other.connectionName &&
//               serverAddress == other.serverAddress &&
//               serverPort == other.serverPort &&
//               protocol == other.protocol &&
//               presharedKey == other.presharedKey &&
//               username == other.username &&
//               password == other.password &&
//               useEncryption == other.useEncryption &&
//               useCompression == other.useCompression;
//
//   @override
//   int get hashCode =>
//       connectionName.hashCode ^
//       serverAddress.hashCode ^
//       serverPort.hashCode ^
//       protocol.hashCode ^
//       presharedKey.hashCode ^
//       username.hashCode ^
//       password.hashCode ^
//       useEncryption.hashCode ^
//       useCompression.hashCode;
//
//   @override
//   String toString() =>
//       'SoftEtherConfig(connectionName: $connectionName, serverAddress: $serverAddress, serverPort: $serverPort, protocol: $protocol, username: $username, presharedKey: ${presharedKey != null ? '***' : 'null'}, password: ***, useEncryption: $useEncryption, useCompression: $useCompression)';
// }
