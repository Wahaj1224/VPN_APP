import 'dart:async';
import 'package:flutter/services.dart';

import '../services/vpn/models/softether_config.dart';

/// Platform channel wrapper for native SoftEther client implementation.
class SoftEtherChannel {
  static const _channel = MethodChannel('hivpn/softether');

  Future<bool> initialize() async {
    try {
      final res = await _channel.invokeMethod<bool>('initialize');
      return res ?? false;
    } on PlatformException catch (e) {
      // Native not implemented or failed
      return false;
    }
  }

  Future<bool> prepare() async {
    try {
      final res = await _channel.invokeMethod<bool>('prepare');
      return res ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> connect(SoftEtherConfig config) async {
    try {
      final res = await _channel.invokeMethod<bool>('connect', config.toJson());
      return res ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> disconnect() async {
    try {
      final res = await _channel.invokeMethod<bool>('disconnect');
      return res ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> isConnected() async {
    try {
      final res = await _channel.invokeMethod<bool>('isConnected');
      return res ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<Map<String, dynamic>> getStats() async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getStats');
      return Map<String, dynamic>.from(res ?? {});
    } on PlatformException {
      return <String, dynamic>{};
    }
  }
}
