import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/auth/auth_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.authService});

  final AuthService authService;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.authService.signIn(
        email: _emailController.text,
        password: _passwordController.text,
      );
    } on FirebaseAuthException catch (error) {
      setState(() => _error = switch (error.code) {
            'invalid-email' => 'Enter a valid email address.',
            'user-disabled' =>
              'This account is disabled. Contact your administrator.',
            'user-not-found' ||
            'wrong-password' ||
            'invalid-credential' =>
              'Email or password is incorrect.',
            'too-many-requests' =>
              'Too many attempts. Wait a moment and try again.',
            'network-request-failed' =>
              'Could not reach the sign-in service. Check your connection.',
            _ => 'Sign-in failed. Please try again.',
          });
    } on Exception {
      setState(() => _error = 'Sign-in failed. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 1000;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
                horizontal: compact ? 20 : 40, vertical: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: compact
                  ? _loginCard(context, width, compact)
                  : Row(children: [
                      Expanded(child: _brandPanel(context)),
                      const SizedBox(width: 36),
                      SizedBox(
                          width: 420,
                          child: _loginCard(context, width, compact)),
                    ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _brandPanel(BuildContext context) => Padding(
        padding: const EdgeInsets.all(34),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _brand(),
          const SizedBox(height: 72),
          const Icon(Icons.insights_outlined,
              size: 54, color: Color(0xFF9B78FF)),
          const SizedBox(height: 24),
          Text('Inventory clarity\nfor every decision.',
              style: Theme.of(context)
                  .textTheme
                  .displaySmall
                  ?.copyWith(fontWeight: FontWeight.w700, height: 1.1)),
          const SizedBox(height: 18),
          Text(
              'A secure workspace for planning materials, protecting deliveries and coordinating approvals.',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: const Color(0xFFB5B6BE), height: 1.55)),
          const SizedBox(height: 34),
          const _Capability(
              icon: Icons.track_changes_outlined,
              text: 'Plan with verified inventory context'),
          const SizedBox(height: 14),
          const _Capability(
              icon: Icons.verified_user_outlined,
              text: 'Review actions with role-based access'),
        ]),
      );

  Widget _loginCard(BuildContext context, double width, bool compact) => Card(
        child: Padding(
          padding: EdgeInsets.all(compact && width < 400 ? 22 : 32),
          child: Form(
            key: _formKey,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (compact) ...[_brand(), const SizedBox(height: 36)],
                  Text('Welcome back',
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text('Sign in with your organization account.',
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: const Color(0xFFB5B6BE))),
                  const SizedBox(height: 28),
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [
                      AutofillHints.username,
                      AutofillHints.email
                    ],
                    decoration: const InputDecoration(
                        labelText: 'Work email',
                        prefixIcon: Icon(Icons.email_outlined)),
                    validator: (value) => value == null || !value.contains('@')
                        ? 'Enter a valid email address.'
                        : null,
                  ),
                  const SizedBox(height: 18),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.password],
                    onFieldSubmitted: (_) => _loading ? null : _signIn(),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        tooltip: _obscurePassword
                            ? 'Show password'
                            : 'Hide password',
                        onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword),
                        icon: Icon(_obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined),
                      ),
                    ),
                    validator: (value) => value == null || value.isEmpty
                        ? 'Enter your password.'
                        : null,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: Text(_error!,
                          style: const TextStyle(color: Color(0xFFFF7777))),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _loading ? null : _signIn,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: _loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Sign in'),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                      'Access is provisioned by your administrator. Public registration is unavailable.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: const Color(0xFF9B9CA5))),
                ]),
          ),
        ),
      );

  Widget _brand() => Row(children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              gradient: const LinearGradient(
                  colors: [Color(0xFF4D8DFF), Color(0xFF9B78FF)])),
          child: const Icon(Icons.auto_awesome, color: Colors.white),
        ),
        const SizedBox(width: 12),
        const Text('ZYRO 2.0',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      ]);
}

class _Capability extends StatelessWidget {
  const _Capability({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 19, color: const Color(0xFF54D39A)),
        const SizedBox(width: 12),
        Text(text, style: Theme.of(context).textTheme.bodyMedium),
      ]);
}
