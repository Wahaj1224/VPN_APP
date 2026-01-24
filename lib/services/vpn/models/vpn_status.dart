// /// VPN connection status snapshot used for UI/notification updates.
// class VpnStatus {
//   const VpnStatus({
//     required this.duration,
//     this.connectedOn,
//     required this.byteIn,
//     required this.byteOut,
//     required this.packetsIn,
//     required this.packetsOut,
//   });
//
//   final String duration;
//   final DateTime? connectedOn;
//   final String byteIn;
//   final String byteOut;
//   final String packetsIn;
//   final String packetsOut;
//
//   factory VpnStatus.empty() => const VpnStatus(
//         duration: '00:00:00',
//         connectedOn: null,
//         byteIn: '0',
//         byteOut: '0',
//         packetsIn: '0',
//         packetsOut: '0',
//       );
//
//   Map<String, dynamic> toJson() {
//     return {
//       'duration': duration,
//       'connected_on': connectedOn?.toIso8601String(),
//       'byte_in': byteIn,
//       'byte_out': byteOut,
//       'packets_in': packetsIn,
//       'packets_out': packetsOut,
//     };
//   }
//
//   VpnStatus copyWith({
//     String? duration,
//     DateTime? connectedOn,
//     String? byteIn,
//     String? byteOut,
//     String? packetsIn,
//     String? packetsOut,
//   }) {
//     return VpnStatus(
//       duration: duration ?? this.duration,
//       connectedOn: connectedOn ?? this.connectedOn,
//       byteIn: byteIn ?? this.byteIn,
//       byteOut: byteOut ?? this.byteOut,
//       packetsIn: packetsIn ?? this.packetsIn,
//       packetsOut: packetsOut ?? this.packetsOut,
//     );
//   }
//
//   @override
//   String toString() {
//     return 'VpnStatus(duration: $duration, byteIn: $byteIn, byteOut: $byteOut)';
//   }
// }
//



/// VPN connection status snapshot used for UI/notification updates.
class VpnStatus {
  const VpnStatus({
    required this.duration,
    this.connectedOn,
    required this.byteIn,
    required this.byteOut,
    required this.packetsIn,
    required this.packetsOut,
  });

  final String duration;
  final DateTime? connectedOn;
  final String byteIn;
  final String byteOut;
  final String packetsIn;
  final String packetsOut;

  /// Empty/default VPN status
  factory VpnStatus.empty() => const VpnStatus(
    duration: '00:00:00',
    connectedOn: null,
    byteIn: '0',
    byteOut: '0',
    packetsIn: '0',
    packetsOut: '0',
  );

  /// ✅ FIX: Added fromJson factory
  factory VpnStatus.fromJson(Map<String, dynamic> json) {
    return VpnStatus(
      duration: json['duration']?.toString() ?? '00:00:00',
      connectedOn: json['connected_on'] != null
          ? DateTime.tryParse(json['connected_on'].toString())
          : null,
      byteIn: json['byte_in']?.toString() ?? '0',
      byteOut: json['byte_out']?.toString() ?? '0',
      packetsIn: json['packets_in']?.toString() ?? '0',
      packetsOut: json['packets_out']?.toString() ?? '0',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'duration': duration,
      'connected_on': connectedOn?.toIso8601String(),
      'byte_in': byteIn,
      'byte_out': byteOut,
      'packets_in': packetsIn,
      'packets_out': packetsOut,
    };
  }

  VpnStatus copyWith({
    String? duration,
    DateTime? connectedOn,
    String? byteIn,
    String? byteOut,
    String? packetsIn,
    String? packetsOut,
  }) {
    return VpnStatus(
      duration: duration ?? this.duration,
      connectedOn: connectedOn ?? this.connectedOn,
      byteIn: byteIn ?? this.byteIn,
      byteOut: byteOut ?? this.byteOut,
      packetsIn: packetsIn ?? this.packetsIn,
      packetsOut: packetsOut ?? this.packetsOut,
    );
  }

  @override
  String toString() {
    return 'VpnStatus(duration: $duration, byteIn: $byteIn, byteOut: $byteOut)';
  }
}
