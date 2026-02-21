import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';

import '../../../services/vpn/models/vpn_type.dart';
import '../../../services/vpn/models/softether_config.dart';
import '../../../services/vpn/vpn_selection_provider.dart';
import '../../../theme/colors.dart';
import 'softether_config_form.dart';

class VpnTypeSelectionScreen extends ConsumerStatefulWidget {
  const VpnTypeSelectionScreen({super.key});

  @override
  ConsumerState<VpnTypeSelectionScreen> createState() =>
      _VpnTypeSelectionScreenState();
}

class _VpnTypeSelectionScreenState extends ConsumerState<VpnTypeSelectionScreen> {
  VpnType? _selectedType;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = HiVpnColors();
    final softEtherConfig = ref.watch(softEtherConfigProvider);
    final nativeAvailable = ref.watch(softEtherNativeAvailableProvider).asData?.value ?? false;
    // Allow SoftEther selection always (for L2TP/IPSec manual setup)
    final softEtherSelectable = true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select VPN Type'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Choose your VPN provider',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              // OpenVPN Card
              _buildVpnTypeCard(
                type: VpnType.openVpn,
                isSelected: _selectedType == VpnType.openVpn,
                title: 'OpenVPN',
                description: 'Connect to OpenVPN servers',
                icon: Icons.cloud,
                onTap: () {
                  setState(() => _selectedType = VpnType.openVpn);
                },
              ),
              const SizedBox(height: 16),
              // SoftEther Card
              _buildVpnTypeCard(
                type: VpnType.softEther,
                isSelected: _selectedType == VpnType.softEther,
                title: 'SoftEther',
                description: 'Configure SoftEther VPN connection',
                icon: Icons.vpn_lock,
                onTap: softEtherSelectable
                    ? () {
                        setState(() => _selectedType = VpnType.softEther);
                      }
                    : () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('SoftEther native support is not available on this device.'),
                          ),
                        );
                      },
              ),
              const SizedBox(height: 24),
              // SoftEther Configuration Form
              if (_selectedType == VpnType.softEther)
                SoftEtherConfigForm(
                  onConfigChanged: (config) {
                    unawaited(
                      ref
                          .read(softEtherConfigProvider.notifier)
                          .setSoftEtherConfig(config),
                    );
                  },
                ),
              const SizedBox(height: 24),
              // Confirm Button
              ElevatedButton(
                onPressed: _selectedType != null
                    ? () async {
                        if (_selectedType == VpnType.softEther) {
                          final config = ref.read(softEtherConfigProvider);
                          if (config == null || !config.isValid) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Please complete SoftEther configuration.'),
                              ),
                            );
                            return;
                          }
                        }
                        await ref
                            .read(selectedVpnTypeProvider.notifier)
                            .selectVpnType(_selectedType!);
                        if (mounted) {
                          Navigator.of(context).pop();
                        }
                      }
                    : null,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('Confirm Selection'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVpnTypeCard({
    required VpnType type,
    required bool isSelected,
    required String title,
    required String description,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.outline.withOpacity(0.2),
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
          color: theme.colorScheme.surface,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                icon,
                size: 40,
                color: isSelected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface.withOpacity(0.5),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: isSelected
                            ? theme.colorScheme.primary
                            : null,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Icon(
                  Icons.check_circle,
                  color: theme.colorScheme.primary,
                  size: 24,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
