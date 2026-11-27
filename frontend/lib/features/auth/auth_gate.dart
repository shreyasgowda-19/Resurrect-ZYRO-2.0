import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/auth_service.dart';
import '../home/home_screen.dart';
import 'login_screen.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key, required this.authService, this.apiClient});

  final AuthService authService;
  final ApiClient? apiClient;

  @override
  Widget build(BuildContext context) => StreamBuilder<AuthenticatedUser?>(
        stream: authService.authStateChanges,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const _AuthMessage(
              title: 'Authentication unavailable',
              message:
                  'We could not check your sign-in session. Please reload the application.',
            );
          }
          if (!snapshot.hasData &&
              snapshot.connectionState == ConnectionState.waiting) {
            // Keep sign-in available while Firebase restores a persisted
            // session. Authenticated users still move to profile verification
            // when the stream emits its first event.
            return LoginScreen(authService: authService);
          }
          final user = snapshot.data;
          if (user == null) return LoginScreen(authService: authService);
          return _ProfileLoader(
            user: user,
            authService: authService,
            apiClient: apiClient,
          );
        },
      );
}

class _ProfileLoader extends StatefulWidget {
  const _ProfileLoader(
      {required this.user, required this.authService, this.apiClient});

  final AuthenticatedUser user;
  final AuthService authService;
  final ApiClient? apiClient;

  @override
  State<_ProfileLoader> createState() => _ProfileLoaderState();
}

class _ProfileLoaderState extends State<_ProfileLoader> {
  late final ApiClient _apiClient;
  late Future<AuthProfile> _profile;

  @override
  void initState() {
    super.initState();
    _apiClient = widget.apiClient ?? ApiClient();
    _loadProfile();
  }

  void _loadProfile() {
    _profile = () async {
      final idToken = await widget.user.getIdToken();
      return _apiClient.getCurrentUser(idToken: idToken);
    }();
  }

  @override
  void dispose() {
    if (widget.apiClient == null) _apiClient.close();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ProfileLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.uid != widget.user.uid) _loadProfile();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AuthProfile>(
        future: _profile,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
                body: Center(child: CircularProgressIndicator()));
          }
          if (snapshot.hasError) {
            final error = snapshot.error;
            final message = error is AuthApiException
                ? switch (error.failure) {
                    AuthApiFailure.unauthorized =>
                      'Your session has expired. Sign in again to continue.',
                    AuthApiFailure.forbidden =>
                      'Your account does not have permission to access this workspace.',
                    AuthApiFailure.connectivity =>
                      'The service is unavailable. Check your connection and try again.',
                    AuthApiFailure.invalidResponse =>
                      'The service returned an unexpected response. Please try again later.',
                  }
                : 'We could not verify your account. Please try again.';
            return _AuthMessage(
              title: 'Account verification failed',
              message: message,
              onRetry: () => setState(_loadProfile),
              onSignOut: () => widget.authService.signOut(),
            );
          }
          final profile = snapshot.data!;
          if (profile.role != 'planner' && profile.role != 'approver') {
            return _AuthMessage(
              title: 'Access not assigned',
              message:
                  'Your account is authenticated, but it does not have an assigned planner or approver role.',
              onSignOut: () => widget.authService.signOut(),
            );
          }
          return HomeScreen(
            apiClient: widget.apiClient,
            verifiedEmail: profile.email,
            role: profile.role,
            onSignOut: () => _confirmSignOut(context, widget.authService),
          );
        },
      );
}

Future<void> _confirmSignOut(
    BuildContext context, AuthService authService) async {
  final shouldSignOut = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Sign out?'),
      content:
          const Text('You will need to sign in again to access the workspace.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out')),
      ],
    ),
  );
  if (shouldSignOut == true) await authService.signOut();
}

class _AuthMessage extends StatelessWidget {
  const _AuthMessage(
      {required this.title,
      required this.message,
      this.onRetry,
      this.onSignOut});

  final String title;
  final String message;
  final VoidCallback? onRetry;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.shield_outlined,
                            color: Color(0xFF9B78FF), size: 32),
                        const SizedBox(height: 18),
                        Text(title,
                            style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 10),
                        Text(message,
                            style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: 20),
                        Wrap(spacing: 10, children: [
                          if (onRetry != null)
                            FilledButton(
                                onPressed: onRetry,
                                child: const Text('Try again')),
                          if (onSignOut != null)
                            TextButton(
                                onPressed: onSignOut,
                                child: const Text('Sign out')),
                        ]),
                      ]),
                ),
              ),
            ),
          ),
        ),
      );
}
