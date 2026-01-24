import 'dart:convert';
import 'package:flutter/services.dart';
import '../domain/server.dart';

class LocalServerProvider {
  static Future<Server> loadMyServer() async {
    final ovpn = await rootBundle.loadString('assets/vpn/myserver.ovpn');
    
    // Encode the raw OVPN content as base64
    final base64Config = base64Encode(utf8.encode(ovpn));

    return Server(
      id: 'ec2-private-vpn',
      name: 'My EC2 VPN',
      countryCode: 'EC2',
      countryName: 'Private VPN',
      publicKey: 'openvpn',
      endpoint: '18.212.249.64:1194',
      allowedIps: '0.0.0.0/0, ::/0',
      hostName: 'EC2-VPN',
      ip: '18.212.249.64',
      pingMs: 5,
      bandwidth: 100000,
      downloadSpeed: 100000,
      uploadSpeed: 100000,
      sessions: 1,
      openVpnConfigDataBase64: base64Config,
    );
  }
}
