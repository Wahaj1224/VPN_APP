import 'dart:convert';
import 'package:http/http.dart' as http;
import '../domain/server.dart';

class ServerApiService {
  static const String apiUrl = "http://35.172.184.131:3000/vpn/servers";

  static Future<List<Server>> fetchServers() async {
    try {
      final response = await http.get(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
        },
      ).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw Exception('Request timeout while fetching servers');
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        List servers = data["servers"] ?? [];

        return servers.map((s) {
          return Server(
            id: s["id"] ?? "unknown",
            name: s["name"] ?? "Unknown Server",
            countryCode: s["countryCode"] ?? "XX",
            countryName: s["countryName"] ?? "Unknown",
            endpoint: s["endpoint"] ?? "",
            ip: s["ip"] ?? "",
            publicKey: s["publicKey"] ?? "openvpn",
            allowedIps: s["allowedIps"] ?? "0.0.0.0/0, ::/0",
            hostName: s["hostName"] ?? s["name"] ?? "unknown",
            pingMs: s["pingMs"] ?? 0,
            bandwidth: s["bandwidth"] ?? 0,
            downloadSpeed: s["downloadSpeed"] ?? 0,
            uploadSpeed: s["uploadSpeed"] ?? 0,
            sessions: s["sessions"] ?? 0,
            openVpnConfigDataBase64: s["ovpnConfig"] ?? "",
            regionName: s["regionName"],
            cityName: s["cityName"],
            score: (s["score"] as num?)?.toDouble(),
          );
        }).toList();
      } else {
        throw Exception(
          "Failed to load servers: HTTP ${response.statusCode} - ${response.body}",
        );
      }
    } catch (e) {
      throw Exception("Failed to fetch servers from API: $e");
    }
  }
}
