import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen(
      {super.key,
      this.apiClient,
      this.verifiedEmail,
      this.role,
      this.onSignOut});

  final ApiClient? apiClient;
  final String? verifiedEmail;
  final String? role;
  final VoidCallback? onSignOut;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final ApiClient _apiClient = widget.apiClient ?? ApiClient();
  bool _checking = false;
  bool? _connected;

  Future<void> _checkBackend() async {
    setState(() => _checking = true);
    final connected = await _apiClient.checkHealth();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _connected = connected;
    });
  }

  @override
  void dispose() {
    if (widget.apiClient == null) _apiClient.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final horizontalPadding = width < 600 ? 20.0 : 48.0;
    final statusText = switch (_connected) {
      true => 'Connected',
      false => 'Disconnected',
      null => 'Not checked',
    };
    final statusColor = _connected == true
        ? const Color(0xFF54D39A)
        : _connected == false
            ? const Color(0xFFFF7777)
            : const Color(0xFFB5B6BE);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: ListView(
              padding: EdgeInsets.symmetric(
                  horizontal: horizontalPadding, vertical: 32),
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(13),
                        gradient: const LinearGradient(
                          colors: [Color(0xFF4D8DFF), Color(0xFF9B78FF)],
                        ),
                      ),
                      child:
                          const Icon(Icons.auto_awesome, color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    Text('ZYRO 2.0',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ],
                ),
                SizedBox(height: width < 600 ? 56 : 96),
                Text('SMART INVENTORY INTELLIGENCE',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: const Color(0xFF9B78FF),
                          letterSpacing: 2.2,
                        )),
                const SizedBox(height: 16),
                Text('Human-AI Collaborative\nInventory Intelligence',
                    style: (width < 600
                            ? Theme.of(context).textTheme.headlineMedium
                            : Theme.of(context).textTheme.displaySmall)
                        ?.copyWith(fontWeight: FontWeight.w700, height: 1.12)),
                const SizedBox(height: 18),
                Text(
                    'Helping manufacturers anticipate material shortages and protect customer deliveries.',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: const Color(0xFFB5B6BE), height: 1.5)),
                if (widget.verifiedEmail != null && widget.role != null) ...[
                  const SizedBox(height: 26),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 14),
                      child: Row(children: [
                        const Icon(Icons.verified_user_outlined,
                            color: Color(0xFF54D39A)),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text(widget.verifiedEmail!,
                                  style:
                                      Theme.of(context).textTheme.titleSmall),
                              const SizedBox(height: 3),
                              Text(
                                  '${widget.role![0].toUpperCase()}${widget.role!.substring(1)} access',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                          color: const Color(0xFFB5B6BE))),
                            ])),
                        if (widget.onSignOut != null)
                          TextButton.icon(
                              onPressed: widget.onSignOut,
                              icon: const Icon(Icons.logout),
                              label: const Text('Sign out')),
                      ]),
                    ),
                  ),
                ],
                const SizedBox(height: 36),
                Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    const _StatusCard(
                        label: 'Team',
                        value: 'Team ZYRO 2.0',
                        icon: Icons.groups_outlined),
                    const _StatusCard(
                        label: 'Frontend',
                        value: 'Ready',
                        icon: Icons.web_outlined,
                        positive: true),
                    _StatusCard(
                        label: 'Backend API',
                        value: statusText,
                        icon: Icons.hub_outlined,
                        valueColor: statusColor),
                  ],
                ),
                const SizedBox(height: 22),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    key: const Key('test-backend-connection-button'),
                    onPressed: _checking ? null : _checkBackend,
                    icon: _checking
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.wifi_tethering),
                    label: Text(_checking
                        ? 'Checking connection…'
                        : 'Test backend connection'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.label,
    required this.value,
    required this.icon,
    this.positive = false,
    this.valueColor,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool positive;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(icon, color: const Color(0xFF8D8F9A)),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: const Color(0xFF9B9CA5))),
                      const SizedBox(height: 5),
                      Text(value,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: valueColor ??
                                    (positive ? const Color(0xFF54D39A) : null),
                              )),
                    ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
