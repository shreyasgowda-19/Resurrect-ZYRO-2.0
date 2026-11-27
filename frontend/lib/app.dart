import 'package:flutter/material.dart';

import 'core/api/api_client.dart';
import 'core/auth/auth_service.dart';
import 'features/auth/auth_gate.dart';
import 'theme/app_theme.dart';

class ZyroInventoryApp extends StatelessWidget {
  const ZyroInventoryApp(
      {super.key, this.apiClient, this.authService, this.startupError});

  final ApiClient? apiClient;
  final AuthService? authService;
  final String? startupError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZYRO Inventory Intelligence',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: startupError != null
          ? _StartupFailure(message: startupError!)
          : AuthGate(authService: authService!, apiClient: apiClient),
    );
  }
}

class _StartupFailure extends StatelessWidget {
  const _StartupFailure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.cloud_off_outlined,
                        size: 36, color: Color(0xFFFF7777)),
                    const SizedBox(height: 16),
                    Text('Application setup required',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 10),
                    Text(message, textAlign: TextAlign.center),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
}
