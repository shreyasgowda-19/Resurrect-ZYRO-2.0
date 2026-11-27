import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'core/auth/auth_service.dart';
import 'firebase_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final options = FirebaseConfig.webOptions;
    if (options == null) {
      runApp(const ZyroInventoryApp(
        startupError:
            'Supply the registered Firebase Web configuration using FIREBASE_* dart defines.',
      ));
      return;
    }
    await Firebase.initializeApp(options: options);
    runApp(ZyroInventoryApp(
      authService: FirebaseAuthService(FirebaseAuth.instance),
    ));
  } on FirebaseException {
    runApp(const ZyroInventoryApp(
      startupError:
          'Firebase could not be initialized. Check the Web app configuration and authorized domains.',
    ));
  } on Exception {
    runApp(const ZyroInventoryApp(
      startupError:
          'Firebase could not be initialized. Check the Web app configuration and try again.',
    ));
  }
}
