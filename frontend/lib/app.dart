import 'package:flutter/material.dart';

import 'core/api/api_client.dart';
import 'features/home/home_screen.dart';
import 'theme/app_theme.dart';

class ZyroInventoryApp extends StatelessWidget {
  const ZyroInventoryApp({super.key, this.apiClient});

  final ApiClient? apiClient;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZYRO Inventory Intelligence',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: HomeScreen(apiClient: apiClient),
    );
  }
}
