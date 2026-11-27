import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zyro_inventory_frontend/app.dart';
import 'package:zyro_inventory_frontend/core/api/api_client.dart';
import 'package:zyro_inventory_frontend/core/auth/auth_service.dart';

final _backendButton = find.byKey(const Key('test-backend-connection-button'));

Future<void> _scrollToBackendButton(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    _backendButton,
    200,
    scrollable: find.byType(Scrollable),
  );
}

class _FakeAuthService implements AuthService {
  @override
  Stream<AuthenticatedUser?> get authStateChanges => Stream.value(
        AuthenticatedUser(
            uid: 'test-user',
            email: 'planner@example.com',
            idToken: () async => 'test-id-token'),
      );

  @override
  Future<void> signIn(
      {required String email, required String password}) async {}

  @override
  Future<void> signOut() async {}
}

class _PendingAuthService implements AuthService {
  final _controller = StreamController<AuthenticatedUser?>.broadcast();

  @override
  Stream<AuthenticatedUser?> get authStateChanges => _controller.stream;

  @override
  Future<void> signIn(
      {required String email, required String password}) async {}

  @override
  Future<void> signOut() async {}

  Future<void> close() => _controller.close();
}

ApiClient _apiClient({int healthStatus = 503}) => ApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/me')) {
          expect(request.headers['Authorization'], 'Bearer test-id-token');
          return http.Response(
            '{"uid":"test-user","email":"planner@example.com","role":"planner"}',
            200,
          );
        }
        return http.Response(
          healthStatus == 200
              ? '{"status":"ok","service":"inventory-api"}'
              : 'unavailable',
          healthStatus,
        );
      }),
    );

void main() {
  testWidgets('shows sign-in form while auth state is still loading',
      (tester) async {
    final authService = _PendingAuthService();
    addTearDown(authService.close);

    await tester.pumpWidget(ZyroInventoryApp(authService: authService));

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Work email'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
  });

  testWidgets('shows the project shell and unverified backend state',
      (tester) async {
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Team ZYRO 2.0'), findsOneWidget);
    expect(find.text('Frontend'), findsOneWidget);
    expect(find.text('Not checked'), findsOneWidget);
    expect(find.text('planner@example.com'), findsOneWidget);
    expect(find.text('Planner access'), findsOneWidget);
    await _scrollToBackendButton(tester);
    expect(_backendButton, findsOneWidget);
  });

  testWidgets('shows disconnected when the health endpoint is unavailable',
      (tester) async {
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(healthStatus: 503),
    ));
    await tester.pumpAndSettle();

    await _scrollToBackendButton(tester);
    await tester.tap(_backendButton);
    await tester.pumpAndSettle();

    expect(find.text('Disconnected'), findsOneWidget);
  });

  testWidgets('shows connected when the health endpoint succeeds',
      (tester) async {
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(healthStatus: 200),
    ));
    await tester.pumpAndSettle();

    await _scrollToBackendButton(tester);
    await tester.tap(_backendButton);
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);
  });
}
