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

ApiClient _apiClient(
        {int healthStatus = 503,
        int stateStatus = 200,
        String role = 'planner',
        Future<http.Response> Function(http.Request request)? onEvent,
        Future<http.Response> Function()? onState,
        int Function()? stateRequestCount}) =>
    ApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/me')) {
          expect(request.headers['Authorization'], 'Bearer test-id-token');
          return http.Response(
            jsonEncode({
              'uid': 'test-user',
              'email': 'planner@example.com',
              'role': role
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/state')) {
          stateRequestCount?.call();
          expect(request.headers['Authorization'], 'Bearer test-id-token');
          if (onState != null) return onState();
          return http.Response(
            stateStatus == 200
                ? jsonEncode(localDemoSnapshotJson)
                : 'backend unavailable',
            stateStatus,
          );
        }
        if (request.url.path.endsWith('/events')) {
          expect(request.headers['Authorization'], 'Bearer test-id-token');
          return onEvent?.call(request) ??
              Future.value(http.Response('{}', 500));
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
    expect(snapshot.supplyLots.first.lotId, 'LOT-7001');
    expect(snapshot.orderRequirements.first.requiredQuantity, 1000);
    expect(snapshot.recentEvents.first.eventId, 'evt-demo-1');
    expect(snapshot.alerts.first.newRisk, OrderRisk.atRisk);
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

  testWidgets('planner submits a material receipt with backend identifiers',
      (tester) async {
    http.Request? submitted;
    await tester.pumpWidget(ZyroInventoryApp(
        authService: _FakeAuthService(),
        apiClient: _apiClient(onEvent: (request) async {
          submitted = request;
          return http.Response(
              '{"event_id":"${jsonDecode(request.body)['event_id']}","status":"applied","version":8}',
              200);
        })));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('receipt-quantity')));
    await tester.enterText(find.byKey(const Key('receipt-quantity')), '25');
    await tester.pump();
    await tester.tap(find.byKey(const Key('submit-receipt-event')));
    await tester.pumpAndSettle();
    expect(submitted, isNotNull);
    final body = jsonDecode(submitted!.body) as Map<String, dynamic>;
    expect(body['event_type'], 'material_receipt');
    expect(body['expected_version'], 7);
    expect((body['payload'] as Map<String, dynamic>)['lot_id'], 'LOT-7001');
    expect((body['payload'] as Map<String, dynamic>)['quantity'], 25);
    expect(body['event_id'], matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(find.text('Event applied (snapshot v8).'), findsOneWidget);
  });

  testWidgets(
      'valid Submit Event invokes POST and generates unique 32-character hex IDs',
      (tester) async {
    final postRequests = <http.Request>[];
    await tester.pumpWidget(ZyroInventoryApp(
        authService: _FakeAuthService(),
        apiClient: _apiClient(onEvent: (request) async {
          postRequests.add(request);
          final event = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
              jsonEncode({
                'event_id': event['event_id'],
                'status': 'applied',
                'version': 8
              }),
              200);
        })));
    await tester.pumpAndSettle();
    final quantity = find.byKey(const Key('receipt-quantity'));
    await tester.ensureVisible(quantity);
    await tester.enterText(quantity, '12');
    await tester.pump();
    final submit = find.byKey(const Key('submit-receipt-event'));
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(postRequests, hasLength(1));
    expect(postRequests.first.method, 'POST');
    expect(postRequests.first.url.path, '/events');
    expect(postRequests.first.headers['Authorization'], 'Bearer test-id-token');
    final requestBody =
        jsonDecode(postRequests.first.body) as Map<String, dynamic>;
    expect(requestBody['event_type'], 'material_receipt');
    expect(requestBody['expected_version'], 7);
    expect(requestBody['event_id'], matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(find.text('Event applied (snapshot v8).'), findsOneWidget);

    await tester.enterText(quantity, '12');
    await tester.pump();
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(postRequests, hasLength(2));
    final secondBody =
        jsonDecode(postRequests.last.body) as Map<String, dynamic>;
    expect(secondBody['event_id'], matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(secondBody['event_id'], isNot(requestBody['event_id']));
    expect(
        postRequests.every((request) =>
            request.method == 'POST' &&
            request.url.path == '/events' &&
            request.headers['Authorization'] == 'Bearer test-id-token'),
        isTrue);
  });

  testWidgets('invalid or unsafe quantities disable event submission',
      (tester) async {
    await tester.pumpWidget(ZyroInventoryApp(
        authService: _FakeAuthService(), apiClient: _apiClient()));
    await tester.pumpAndSettle();
    final receipt = find.byKey(const Key('receipt-quantity'));
    await tester.ensureVisible(receipt);
    await tester.enterText(receipt, '0');
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('submit-receipt-event')))
            .onPressed,
        isNull);
    final adjustment = find.byKey(const Key('adjustment-quantity'));
    await tester.ensureVisible(adjustment);
    await tester.enterText(adjustment, '-601');
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('submit-adjustment-event')))
            .onPressed,
        isNull);
  });

  testWidgets('duplicate taps are prevented while event request is pending',
      (tester) async {
    final response = Completer<http.Response>();
    var eventRequests = 0;
    http.Request? submitted;
    await tester.pumpWidget(ZyroInventoryApp(
        authService: _FakeAuthService(),
        apiClient: _apiClient(onEvent: (request) {
          eventRequests++;
          submitted = request;
          return response.future;
        })));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('receipt-quantity'));
    await tester.ensureVisible(field);
    await tester.enterText(field, '4');
    await tester.pump();
    final submit = find.byKey(const Key('submit-receipt-event'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pump();
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    expect(eventRequests, 1);
    final eventId = jsonDecode(submitted!.body)['event_id'];
    response.complete(http.Response(
        jsonEncode({'event_id': eventId, 'status': 'duplicate', 'version': 8}),
        200));
    await tester.pumpAndSettle();
    expect(find.text('This event was already applied (snapshot v8).'),
        findsOneWidget);
  });

  testWidgets('retry after an uncertain response reuses the original event',
      (tester) async {
    var attempts = 0;
    final bodies = <Map<String, dynamic>>[];
    await tester.pumpWidget(ZyroInventoryApp(
        authService: _FakeAuthService(),
        apiClient: _apiClient(onEvent: (request) async {
          attempts++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          bodies.add(body);
          if (attempts == 1) {
            return http.Response(
                '{"detail":{"code":"SERVICE_UNAVAILABLE","message":"Retry"}}',
                503);
          }
          return http.Response(
              jsonEncode({
                'event_id': body['event_id'],
                'status': 'applied',
                'version': 8
              }),
              200);
        })));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('receipt-quantity'));
    await tester.ensureVisible(field);
    await tester.enterText(field, '25');
    await tester.pump();
    final submit = find.byKey(const Key('submit-receipt-event'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    final retry = find.byKey(const Key('retry-event'));
    expect(retry, findsOneWidget);
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(bodies[1], equals(bodies[0]));
    expect(find.text('Event applied (snapshot v8).'), findsOneWidget);
  });

  testWidgets('stale version refreshes without resubmitting the event',
      (tester) async {
    var eventRequests = 0;
    var stateRequests = 0;
    final client = _apiClient(
        stateRequestCount: () => stateRequests++,
        onEvent: (_) async {
          eventRequests++;
          return http.Response(
              '{"detail":{"code":"STALE_VERSION","message":"Refresh the dashboard before submitting another event."}}',
              409);
        });
    await tester.pumpWidget(
        ZyroInventoryApp(authService: _FakeAuthService(), apiClient: client));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('receipt-quantity'));
    await tester.ensureVisible(field);
    await tester.enterText(field, '4');
    await tester.pump();
    final submit = find.byKey(const Key('submit-receipt-event'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(eventRequests, 1);
    expect(stateRequests, 2);
    expect(
        find.textContaining(
            'Refresh the dashboard before submitting another event.'),
        findsOneWidget);
  });

  testWidgets('renders backend risk alerts and event history', (tester) async {
    await tester.pumpWidget(ZyroInventoryApp(
        authService: _FakeAuthService(), apiClient: _apiClient()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('risk-alert-alert-demo-1')), findsOneWidget);
    expect(find.textContaining('On track → At risk'), findsOneWidget);
    expect(find.textContaining('snapshot v7'), findsWidgets);
    expect(find.byKey(const Key('event-history-evt-demo-1')), findsOneWidget);
    expect(find.textContaining('Supplier ETA updated for LOT-7001'),
        findsOneWidget);
  });

  testWidgets(
      'new critical risk alerts are highlighted once and open the order',
      (tester) async {
    var stateRequests = 0;
    final alerted = {
      ...localDemoSnapshotJson,
      'version': 8,
      'alerts': [
        ...localDemoSnapshotJson['alerts']! as List,
        {
          'alert_id': 'alert-critical-8',
          'order_id': 'ORD-1044',
          'previous_risk': 'at_risk',
          'new_risk': 'critical',
          'message': 'Supplier delay increased material risk.',
          'event_id': 'evt-8',
          'version': 8,
        }
      ],
    };
    final client = _apiClient(
        stateRequestCount: () => stateRequests++,
        onState: () async => http.Response(
            jsonEncode(stateRequests == 1 ? localDemoSnapshotJson : alerted),
            200));
    await tester.pumpWidget(
        ZyroInventoryApp(authService: _FakeAuthService(), apiClient: client));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    final alert = find.byKey(const Key('risk-alert-alert-critical-8'));
    expect(alert, findsOneWidget);
    expect(tester.widget<Card>(alert).color, const Color(0xFF3A252B));
    expect(find.text('NEW'), findsOneWidget);
    await tester.ensureVisible(alert);
    await tester.tap(alert);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('order-shortage-details')), findsOneWidget);
    expect(find.text('NEW'), findsNothing);
  });

  testWidgets('approver can inspect events but has read-only event controls',
      (tester) async {
    await tester.pumpWidget(ZyroInventoryApp(
        authService: _FakeAuthService(),
        apiClient: _apiClient(role: 'approver')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('event-history-evt-demo-1')), findsOneWidget);
    expect(find.byKey(const Key('risk-alert-alert-demo-1')), findsOneWidget);
    expect(find.text('Manufacturing Events'), findsNothing);
    expect(find.byKey(const Key('submit-receipt-event')), findsNothing);
  });

  testWidgets('polling refreshes every five seconds and stops after disposal',
      (tester) async {
    var stateRequests = 0;
    final oldResponse = Completer<http.Response>();
    final client = _apiClient(
        stateRequestCount: () => stateRequests++,
        onState: () {
          if (stateRequests == 1) {
            return Future.value(http.Response(
                jsonEncode({...localDemoSnapshotJson, 'version': 8}), 200));
          }
          if (stateRequests == 2) return oldResponse.future;
          return Future.value(http.Response(
              jsonEncode({...localDemoSnapshotJson, 'version': 7}), 200));
        });
    await tester.pumpWidget(
        ZyroInventoryApp(authService: _FakeAuthService(), apiClient: client));
    await tester.pumpAndSettle();
    expect(stateRequests, 1);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(stateRequests, 2);
    await tester.pump(const Duration(seconds: 5));
    expect(stateRequests, 2,
        reason: 'polling must not overlap a pending request');
    oldResponse.complete(http.Response(
        jsonEncode({...localDemoSnapshotJson, 'version': 7}), 200));
    await tester.pumpAndSettle();
    expect(find.textContaining('Version 8'), findsOneWidget,
        reason: 'a lower version must not replace the current snapshot');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
    expect(stateRequests, 2);
  });

  testWidgets('event forms remain responsive at mobile and laptop widths',
      (tester) async {
    for (final size in [const Size(390, 844), const Size(1280, 720)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(ZyroInventoryApp(
          authService: _FakeAuthService(), apiClient: _apiClient()));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('eta-lot-select')));
      expect(find.byKey(const Key('eta-lot-select')), findsOneWidget);
      expect(find.byKey(const Key('submit-adjustment-event')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });
}
