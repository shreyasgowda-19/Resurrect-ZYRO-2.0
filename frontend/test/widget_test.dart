import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zyro_inventory_frontend/app.dart';
import 'package:zyro_inventory_frontend/core/api/api_client.dart';
import 'package:zyro_inventory_frontend/core/auth/auth_service.dart';
import 'package:zyro_inventory_frontend/core/models/inventory_snapshot.dart';

import 'fixtures/local_demo_snapshot.dart';

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

ApiClient _apiClient({int healthStatus = 503, int stateStatus = 200}) =>
    ApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/me')) {
          expect(request.headers['Authorization'], 'Bearer test-id-token');
          return http.Response(
            '{"uid":"test-user","email":"planner@example.com","role":"planner"}',
            200,
          );
        }
        if (request.url.path.endsWith('/state')) {
          expect(request.headers['Authorization'], 'Bearer test-id-token');
          return http.Response(
            stateStatus == 200
                ? jsonEncode(localDemoSnapshotJson)
                : 'backend unavailable',
            stateStatus,
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
  final viewports = <(String, Size)>[
    ('1366x768', const Size(1366, 768)),
    ('1280x720', const Size(1280, 720)),
    ('1920x1080', const Size(1920, 1080)),
    ('390x844', const Size(390, 844)),
  ];

  for (final viewport in viewports) {
    testWidgets('dashboard has no overflow at ${viewport.$1}', (tester) async {
      tester.view.physicalSize = viewport.$2;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(ZyroInventoryApp(
        authService: _FakeAuthService(),
        apiClient: _apiClient(),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final mainScroll = find.byKey(const Key('dashboard-main-scroll'));
      expect(mainScroll, findsOneWidget);
      expect(
          find.byKey(const Key('materials-horizontal-scroll')), findsOneWidget);
      if (viewport.$2.width >= 980) {
        expect(
            find.byKey(const Key('orders-horizontal-scroll')), findsOneWidget);
      }
      await tester.drag(mainScroll, const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(find.text('ORD-1043'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.text('ORD-1043'));
      await tester.tap(find.text('ORD-1043'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('order-shortage-details')), findsOneWidget);
      expect(
          find.byKey(const Key('shortages-horizontal-scroll')), findsOneWidget);
      expect(tester.takeException(), isNull);

      if (viewport.$2.width < 980) {
        await tester.tap(find.byKey(const Key('dashboard-menu-button')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Sign out').last);
      await tester.pumpAndSettle();
      expect(find.text('Sign out?'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });
  }

  test('parses snapshot counts and keeps backend values authoritative', () {
    final snapshot = InventorySnapshot.fromJson(localDemoSnapshotJson);

    expect(snapshot.version, 7);
    expect(snapshot.totalOrders, 4);
    expect(snapshot.onTrackOrders, 1);
    expect(snapshot.atRiskOrders, 1);
    expect(snapshot.criticalOrders, 1);
    expect(snapshot.delayedOrders, 1);
    expect(snapshot.materialsWithShortages, 1);
    expect(snapshot.materials.first.netAvailable, 0);
    expect(snapshot.materials[1].netAvailable, -100);
  });

  test('parses missing projected dates and slack as null', () {
    final snapshot = InventorySnapshot.fromJson(localDemoSnapshotJson);
    final atRisk =
        snapshot.orders.firstWhere((order) => order.risk == OrderRisk.atRisk);

    expect(atRisk.materialReadyDate, isNull);
    expect(atRisk.projectedShipDate, isNull);
    expect(atRisk.projectedDeliveryDate, isNull);
    expect(atRisk.slackDays, isNull);
  });

  test('rejects malformed or unknown risk data', () {
    final invalid = Map<String, dynamic>.from(localDemoSnapshotJson);
    final invalidOrders = List<Map<String, dynamic>>.from(
      (localDemoSnapshotJson['orders']! as List).cast<Map<String, dynamic>>(),
    );
    invalidOrders[0] = {...invalidOrders[0], 'risk': 'predicted'};
    invalid['orders'] = invalidOrders;

    expect(() => InventorySnapshot.fromJson(invalid), throwsFormatException);
  });

  testWidgets('shows sign-in form while auth state is still loading',
      (tester) async {
    final authService = _PendingAuthService();
    addTearDown(authService.close);

    await tester.pumpWidget(ZyroInventoryApp(authService: authService));

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Work email'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
  });

  testWidgets('renders the snapshot dashboard with verified user context',
      (tester) async {
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Inventory dashboard'), findsOneWidget);
    expect(find.text('Customer orders'), findsWidgets);
    expect(find.text('Material inventory'), findsOneWidget);
    expect(find.textContaining('planner@example.com'), findsOneWidget);
    expect(find.textContaining('Planner'), findsWidgets);
    expect(find.text('DEMO DATA'), findsOneWidget);
    expect(find.text('ORD-1042'), findsOneWidget);
    expect(find.text('600'), findsOneWidget);
  });

  testWidgets('filters dashboard orders by backend risk status',
      (tester) async {
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(),
    ));
    await tester.pumpAndSettle();

    final filter = find.byKey(const Key('risk-filter-dropdown'));
    await tester.ensureVisible(filter);
    await tester.tap(filter);
    await tester.pumpAndSettle();
    await tester.tap(find.text('At risk').last);
    await tester.pumpAndSettle();

    expect(find.text('ORD-1043'), findsOneWidget);
    expect(find.text('ORD-1042'), findsNothing);
  });

  testWidgets('shows unavailable backend snapshot error with retry',
      (tester) async {
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(stateStatus: 503),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Inventory snapshot unavailable'), findsOneWidget);
    expect(find.textContaining('required inventory service is unavailable'),
        findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('shows disconnected when the health endpoint is unavailable',
      (tester) async {
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(healthStatus: 503),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Backend unavailable'), findsOneWidget);
  });

  testWidgets('shows connected when the health endpoint succeeds',
      (tester) async {
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(healthStatus: 200),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Backend connected'), findsOneWidget);
  });
}
