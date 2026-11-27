import 'package:firebase_auth/firebase_auth.dart';

class AuthenticatedUser {
  const AuthenticatedUser({
    required this.uid,
    required this.email,
    required this.idToken,
  });

  final String uid;
  final String email;
  final Future<String> Function() idToken;

  Future<String> getIdToken() => idToken();
}

abstract interface class AuthService {
  Stream<AuthenticatedUser?> get authStateChanges;
  Future<void> signIn({required String email, required String password});
  Future<void> signOut();
}

class FirebaseAuthService implements AuthService {
  FirebaseAuthService(this._auth);

  final FirebaseAuth _auth;

  @override
  Stream<AuthenticatedUser?> get authStateChanges =>
      _auth.authStateChanges().map((user) => user == null
          ? null
          : AuthenticatedUser(
              uid: user.uid,
              email: user.email ?? '',
              idToken: () async {
                final token = await user.getIdToken();
                if (token == null || token.isEmpty) {
                  throw StateError('Firebase did not return an ID token.');
                }
                return token;
              },
            ));

  @override
  Future<void> signIn({required String email, required String password}) async {
    await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  @override
  Future<void> signOut() => _auth.signOut();
}
