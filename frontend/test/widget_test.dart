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
import 'package:zyro_inventory_frontend/core/models/ai_copilot_models.dart';
import 'package:zyro_inventory_frontend/core/models/proposal_models.dart';
import 'package:zyro_inventory_frontend/core/models/recommendation_models.dart';

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
        Future<http.Response> Function(http.Request request)? onRecommendations,
        Future<http.Response> Function(http.Request request)? onSimulation,
        Future<http.Response> Function()? onProposals,
        Future<http.Response> Function(http.Request request)?
            onProposalSubmission,
        Future<http.Response> Function(http.Request request)?
            onProposalDecision,
        Future<http.Response> Function(http.Request request)? onAiAsk,
        Future<http.Response> Function()? onAiBriefing,
        Future<http.Response> Function()? onState,
        int Function()? stateRequestCount,
        int Function()? proposalRequestCount}) =>
    ApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/me')) {
          expectSync(request.headers['Authorization'], 'Bearer test-id-token');
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
          expectSync(request.headers['Authorization'], 'Bearer test-id-token');
          if (onState != null) return onState();
          return http.Response(
            stateStatus == 200
                ? jsonEncode(localDemoSnapshotJson)
                : 'backend unavailable',
            stateStatus,
          );
        }
        if (request.url.path.endsWith('/events')) {
          expectSync(request.headers['Authorization'], 'Bearer test-id-token');
          return onEvent?.call(request) ??
              Future.value(http.Response('{}', 500));
        }
        if (request.url.path.endsWith('/recommendations')) {
          expectSync(request.headers['Authorization'], 'Bearer test-id-token');
          return onRecommendations?.call(request) ??
              Future.value(http.Response('{}', 500));
        }
        if (request.url.path.endsWith('/simulate')) {
          expectSync(request.headers['Authorization'], 'Bearer test-id-token');
          return onSimulation?.call(request) ??
              Future.value(http.Response('{}', 500));
        }
        if (request.url.path.startsWith('/proposals/') &&
            request.url.path.endsWith('/decision')) {
          expectSync(request.headers['Authorization'], 'Bearer test-id-token');
          return onProposalDecision?.call(request) ??
              Future.value(http.Response('{}', 500));
        }
        if (request.url.path.endsWith('/ai/ask')) {
          expectSync(request.headers['Authorization'], 'Bearer test-id-token');
          return onAiAsk?.call(request) ??
              Future.value(http.Response('{}', 500));
        }
        if (request.url.path.endsWith('/ai/briefing')) {
          expectSync(request.headers['Authorization'], 'Bearer test-id-token');
          return onAiBriefing?.call() ??
              Future.value(http.Response(
                  jsonEncode(_aiBriefingJson(includeInsights: false)), 200));
        }
        if (request.url.path.endsWith('/proposals') &&
            request.method == 'POST') {
          expectSync(request.headers['Authorization'], 'Bearer test-id-token');
          return onProposalSubmission?.call(request) ??
              Future.value(http.Response('{}', 500));
        }
        if (request.url.path.endsWith('/proposals') &&
            request.method == 'GET') {
          expectSync(request.headers['Authorization'], 'Bearer test-id-token');
          proposalRequestCount?.call();
          return onProposals?.call() ??
              Future.value(http.Response(
                  jsonEncode({
                    'version': 7,
                    'proposals': [],
                    'purchase_orders': [],
                    'audit_logs': [],
                  }),
                  200));
        }
        return http.Response(
          healthStatus == 200
              ? '{"status":"ok","service":"inventory-api"}'
              : 'unavailable',
          healthStatus,
        );
      }),
    );

Future<void> _openRecommendationsForOrder(WidgetTester tester,
    {String orderId = 'ORD-1043'}) async {
  final order = find.text(orderId).first;
  await tester.ensureVisible(order);
  await tester.tap(order);
  await tester.pumpAndSettle();
  expect(find.byKey(Key('recommendation-workspace-$orderId')), findsOneWidget);
}

Future<void> _openSimulatedRecommendation(WidgetTester tester,
    {required ApiClient apiClient}) async {
  await tester.pumpWidget(ZyroInventoryApp(
    authService: _FakeAuthService(),
    apiClient: apiClient,
  ));
  await tester.pumpAndSettle();
  await _openRecommendationsForOrder(tester);
  var action = find.byKey(const Key('generate-recommendations-ORD-1043'));
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
  action = find.byKey(const Key('simulate-REC-EXPEDITE-7-1043'));
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
}

Map<String, dynamic> _aiEvidenceJson({
  String evidenceId = 'EV-ORDER-1043',
  String sourceType = 'order',
  String sourceId = 'ORD-1043',
}) =>
    {
      'evidence_id': evidenceId,
      'source_type': sourceType,
      'source_id': sourceId,
      'summary': 'Backend reports the current order status.',
    };

Map<String, dynamic> _aiAnswerJson({
  int version = 7,
  String role = 'planner',
  String mode = 'gemini',
}) =>
    {
      'version': version,
      'role': role,
      'mode': mode,
      'answer': 'The backend reports ORD-1043 is at risk.',
      'evidence': [_aiEvidenceJson()],
      'suggested_questions': ['Which material is affecting ORD-1043?'],
      'warnings': ['This answer reflects snapshot v$version.'],
    };

Map<String, dynamic> _aiBriefingJson({
  int version = 7,
  String role = 'planner',
  String mode = 'deterministic_fallback',
  bool includeInsights = true,
}) =>
    {
      'version': version,
      'role': role,
      'mode': mode,
      'headline':
          role == 'planner' ? 'Orders need attention' : 'Review decisions',
      'summary': 'Briefing summary from verified backend records.',
      'insights': includeInsights
          ? [
              {
                'title': 'Order risk',
                'description': 'Review the backend-reported status.',
                'severity': 'warning',
                'order_id': 'ORD-1043',
                'evidence': [_aiEvidenceJson()],
                'suggested_question': 'Explain ORD-1043.',
              },
            ]
          : <Map<String, dynamic>>[],
      'warnings': mode == 'deterministic_fallback'
          ? ['Gemini is unavailable; verified backend facts are used.']
          : <String>[],
    };

Future<void> _openCopilot(WidgetTester tester) async {
  final nav = find.text('AI Copilot').first;
  await tester.ensureVisible(nav);
  await tester.tap(nav);
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('ai-conversation-panel')), findsOneWidget);
}

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

  test('parses typed recommendation and hypothetical simulation responses', () {
    final recommendations =
        RecommendationResult.fromJson(localRecommendationResponse);
    final simulation = SimulationResult.fromJson(localSimulationResponse);

    expect(recommendations.version, 7);
    expect(recommendations.recommendations, hasLength(2));
    expect(
        recommendations.recommendations.first.estimatedIncrementalCost, isNull);
    expect(recommendations.recommendations.first.lotId, 'LOT-7002');
    expect(simulation.hypothetical, isTrue);
    expect(simulation.before.projectedDeliveryDate, isNull);
    expect(simulation.after.risk, OrderRisk.onTrack);
    expect(simulation.affectedOrders.single.orderId, 'ORD-1044');
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
    var stateRequests = 0;
    await tester.pumpWidget(ZyroInventoryApp(
        authService: _FakeAuthService(),
        apiClient: _apiClient(
            stateRequestCount: () => stateRequests++,
            onEvent: (request) async {
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
    expect(stateRequests, 2,
        reason: 'a successful event immediately refreshes inventory state');
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
    await tester.pump(const Duration(seconds: 10));
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

  testWidgets(
      'state polling uses ten seconds, skips overlap and stops after disposal',
      (tester) async {
    var stateRequests = 0;
    var proposalRequests = 0;
    final oldResponse = Completer<http.Response>();
    final client = _apiClient(
        stateRequestCount: () => stateRequests++,
        proposalRequestCount: () => proposalRequests++,
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
    expect(proposalRequests, 1);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(stateRequests, 2);
    expect(proposalRequests, 1);
    tester
        .widget<OutlinedButton>(
            find.byKey(const Key('dashboard-refresh-button')))
        .onPressed!
        .call();
    expect(stateRequests, 2,
        reason: 'manual refresh must not overlap a pending request');
    oldResponse.complete(http.Response(
        jsonEncode({...localDemoSnapshotJson, 'version': 7}), 200));
    await tester.pumpAndSettle();
    expect(stateRequests, 3,
        reason: 'a queued refresh runs after the pending request completes');
    expect(find.textContaining('Version 8'), findsOneWidget,
        reason: 'a lower version must not replace the current snapshot');
    final proposalRequestsBeforeDispose = proposalRequests;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
    expect(stateRequests, 3);
    expect(proposalRequests, proposalRequestsBeforeDispose,
        reason: 'proposal polling timers must stop after disposal');
  });

  testWidgets('proposal polling is independent at fifteen seconds',
      (tester) async {
    var stateRequests = 0;
    var proposalRequests = 0;
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        stateRequestCount: () => stateRequests++,
        proposalRequestCount: () => proposalRequests++,
      ),
    ));
    await tester.pumpAndSettle();
    expect(stateRequests, 1);
    expect(proposalRequests, 1);

    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(stateRequests, 2);
    expect(proposalRequests, 1);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(stateRequests, 2,
        reason:
            'proposal polling does not depend on inventory version changes');
    expect(proposalRequests, 2);
  });

  testWidgets(
      'polling pauses while inactive and refreshes immediately on resume',
      (tester) async {
    var stateRequests = 0;
    var proposalRequests = 0;
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        stateRequestCount: () => stateRequests++,
        proposalRequestCount: () => proposalRequests++,
      ),
    ));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 45));
    expect(stateRequests, 1);
    expect(proposalRequests, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(stateRequests, 2);
    expect(proposalRequests, 2);
  });

  testWidgets('network and 503 failures retain data and recover with backoff',
      (tester) async {
    var stateRequests = 0;
    var proposalRequests = 0;
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        stateRequestCount: () => stateRequests++,
        proposalRequestCount: () => proposalRequests++,
        onState: () async {
          if (stateRequests == 2) throw http.ClientException('offline');
          return http.Response(jsonEncode(localDemoSnapshotJson), 200);
        },
        onProposals: () async => http.Response(
          jsonEncode({
            'version': 7,
            'proposals': [],
            'purchase_orders': [],
            'audit_logs': [],
          }),
          proposalRequests == 2 ? 503 : 200,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stale-snapshot-banner')), findsOneWidget);
    expect(find.textContaining('Last successful refresh:'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(stateRequests, 3,
        reason: 'temporary network errors retry after the initial backoff');
    expect(find.byKey(const Key('stale-snapshot-banner')), findsNothing);
    expect(find.text('600'), findsOneWidget,
        reason: 'last successful inventory data remains visible on failure');

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(proposalRequests, 2);
    expect(find.byKey(const Key('stale-proposals-banner')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(proposalRequests, 3,
        reason: 'HTTP 503 retries automatically after the initial backoff');
    expect(find.byKey(const Key('stale-proposals-banner')), findsNothing);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(stateRequests, 4,
        reason: 'normal polling resumes after connectivity recovers');
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

  testWidgets(
      'generates recommendations using the current version and renders evidence',
      (tester) async {
    http.Request? recommendationRequest;
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(onRecommendations: (request) async {
        recommendationRequest = request;
        return http.Response(jsonEncode(localRecommendationResponse), 200);
      }),
    ));
    await tester.pumpAndSettle();
    await _openRecommendationsForOrder(tester);
    final generate = find.byKey(const Key('generate-recommendations-ORD-1043'));
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();

    expect(recommendationRequest?.method, 'POST');
    expect(recommendationRequest?.url.path, '/recommendations');
    expect(recommendationRequest?.headers['Authorization'],
        'Bearer test-id-token');
    final body =
        jsonDecode(recommendationRequest!.body) as Map<String, dynamic>;
    expect(body, {'order_id': 'ORD-1043', 'expected_version': 7});
    expect(find.text('Expedite existing steel lot'), findsOneWidget);
    expect(find.text('Not available'), findsOneWidget);
    expect(find.text('Current ETA is 11 Dec 2026.'), findsOneWidget);
    expect(find.text('Supplier can meet the proposed ETA.'), findsOneWidget);
  });

  testWidgets('recommendation generation exposes a loading state',
      (tester) async {
    final response = Completer<http.Response>();
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(onRecommendations: (_) => response.future),
    ));
    await tester.pumpAndSettle();
    await _openRecommendationsForOrder(tester);
    final generate = find.byKey(const Key('generate-recommendations-ORD-1043'));
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pump();
    expect(find.text('Generating…'), findsOneWidget);
    expect(tester.widget<FilledButton>(generate).onPressed, isNull);
    response
        .complete(http.Response(jsonEncode(localRecommendationResponse), 200));
    await tester.pumpAndSettle();
    expect(find.text('Expedite existing steel lot'), findsOneWidget);
  });

  testWidgets(
      'simulation shows hypothetical before-after and collateral outcomes',
      (tester) async {
    http.Request? simulationRequest;
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        onRecommendations: (_) async =>
            http.Response(jsonEncode(localRecommendationResponse), 200),
        onSimulation: (request) async {
          simulationRequest = request;
          return http.Response(jsonEncode(localSimulationResponse), 200);
        },
      ),
    ));
    await tester.pumpAndSettle();
    await _openRecommendationsForOrder(tester);
    final generate = find.byKey(const Key('generate-recommendations-ORD-1043'));
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();
    final simulate = find.byKey(const Key('simulate-REC-EXPEDITE-7-1043'));
    await tester.ensureVisible(simulate);
    await tester.tap(simulate);
    await tester.pumpAndSettle();

    expect(simulationRequest?.method, 'POST');
    expect(simulationRequest?.url.path, '/simulate');
    final body = jsonDecode(simulationRequest!.body) as Map<String, dynamic>;
    expect(body, {
      'order_id': 'ORD-1043',
      'recommendation_id': 'REC-EXPEDITE-7-1043',
      'expected_version': 7,
    });
    expect(find.text('HYPOTHETICAL'), findsOneWidget);
    expect(find.textContaining('Before'), findsWidgets);
    expect(find.text('Other affected orders (1)'), findsOneWidget);
    expect(find.text('ORD-1044'), findsWidgets);
    expect(find.textContaining('Other orders may be affected'), findsOneWidget);
    expect(find.text('Estimated incremental cost'), findsWidgets);
  });

  testWidgets('simulation backend failures show a retry action',
      (tester) async {
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        onRecommendations: (_) async =>
            http.Response(jsonEncode(localRecommendationResponse), 200),
        onSimulation: (_) async => http.Response(
            '{"detail":{"code":"SERVICE_UNAVAILABLE","message":"Try later"}}',
            503),
      ),
    ));
    await tester.pumpAndSettle();
    await _openRecommendationsForOrder(tester);
    final generate = find.byKey(const Key('generate-recommendations-ORD-1043'));
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();
    final simulate = find.byKey(const Key('simulate-REC-EXPEDITE-7-1043'));
    await tester.ensureVisible(simulate);
    await tester.tap(simulate);
    await tester.pumpAndSettle();
    expect(find.textContaining('required backend service is unavailable'),
        findsOneWidget);
    expect(find.text('Retry simulation'), findsOneWidget);
  });

  testWidgets(
      'simulates multiple options for side-by-side comparison on wide screens',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        onRecommendations: (_) async =>
            http.Response(jsonEncode(localRecommendationResponse), 200),
        onSimulation: (request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
              jsonEncode({
                ...localSimulationResponse,
                'recommendation_id': body['recommendation_id']
              }),
              200);
        },
      ),
    ));
    await tester.pumpAndSettle();
    await _openRecommendationsForOrder(tester);
    final generate = find.byKey(const Key('generate-recommendations-ORD-1043'));
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();
    for (final id in ['REC-EXPEDITE-7-1043', 'REC-ALT-7-1043']) {
      final simulate = find.byKey(Key('simulate-$id'));
      await tester.ensureVisible(simulate);
      await tester.tap(simulate);
      await tester.pumpAndSettle();
    }
    final firstCard = tester.getTopLeft(
        find.byKey(const Key('recommendation-card-REC-EXPEDITE-7-1043')));
    final secondCard = tester.getTopLeft(
        find.byKey(const Key('recommendation-card-REC-ALT-7-1043')));
    expect(secondCard.dx, greaterThan(firstCard.dx + 100));
    expect(find.byKey(const Key('simulation-result-REC-EXPEDITE-7-1043')),
        findsOneWidget);
    expect(find.byKey(const Key('simulation-result-REC-ALT-7-1043')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty recommendation response is clearly displayed',
      (tester) async {
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
          onRecommendations: (_) async => http.Response(
              jsonEncode(
                  {...localRecommendationResponse, 'recommendations': []}),
              200)),
    ));
    await tester.pumpAndSettle();
    await _openRecommendationsForOrder(tester);
    final generate = find.byKey(const Key('generate-recommendations-ORD-1043'));
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();
    expect(find.textContaining('backend returned no recommendations'),
        findsOneWidget);
  });

  testWidgets('recommendation errors show retry controls', (tester) async {
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
          onRecommendations: (_) async => http.Response(
              '{"detail":{"code":"SERVICE_UNAVAILABLE","message":"Try later"}}',
              503)),
    ));
    await tester.pumpAndSettle();
    await _openRecommendationsForOrder(tester);
    final generate = find.byKey(const Key('generate-recommendations-ORD-1043'));
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();
    expect(find.textContaining('required backend service is unavailable'),
        findsOneWidget);
    expect(find.byKey(const Key('retry-recommendations-ORD-1043')),
        findsOneWidget);
  });

  testWidgets(
      'HTTP 409 refreshes current state without retrying old recommendations',
      (tester) async {
    var recommendationRequests = 0;
    var stateRequests = 0;
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        stateRequestCount: () => stateRequests++,
        onState: () async => http.Response(
            jsonEncode({
              ...localDemoSnapshotJson,
              'version': stateRequests == 1 ? 7 : 8,
            }),
            200),
        onRecommendations: (_) async {
          recommendationRequests++;
          return http.Response(
              '{"detail":{"code":"STALE_VERSION","message":"Snapshot is stale."}}',
              409);
        },
      ),
    ));
    await tester.pumpAndSettle();
    await _openRecommendationsForOrder(tester);
    final generate = find.byKey(const Key('generate-recommendations-ORD-1043'));
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();
    expect(recommendationRequests, 1);
    expect(stateRequests, 2);
    expect(find.textContaining('snapshot changed'), findsOneWidget);
    expect(find.textContaining('Version 8'), findsOneWidget);
  });

  testWidgets('polling marks recommendation and simulation results outdated',
      (tester) async {
    var stateRequests = 0;
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        stateRequestCount: () => stateRequests++,
        onState: () async => http.Response(
            jsonEncode({
              ...localDemoSnapshotJson,
              'version': stateRequests == 1 ? 7 : 8,
            }),
            200),
        onRecommendations: (_) async =>
            http.Response(jsonEncode(localRecommendationResponse), 200),
        onSimulation: (_) async =>
            http.Response(jsonEncode(localSimulationResponse), 200),
      ),
    ));
    await tester.pumpAndSettle();
    await _openRecommendationsForOrder(tester);
    var action = find.byKey(const Key('generate-recommendations-ORD-1043'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    action = find.byKey(const Key('simulate-REC-EXPEDITE-7-1043'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('recommendations-outdated')), findsOneWidget);
    expect(find.byKey(const Key('simulation-outdated-REC-EXPEDITE-7-1043')),
        findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('simulate-REC-EXPEDITE-7-1043')))
            .onPressed,
        isNull);
    expect(find.text('Regenerate for v8'), findsOneWidget);
  });

  testWidgets(
      'planner and approver can generate and simulate read-only options',
      (tester) async {
    for (final role in ['planner', 'approver']) {
      await tester.pumpWidget(ZyroInventoryApp(
        authService: _FakeAuthService(),
        apiClient: _apiClient(
          role: role,
          onRecommendations: (_) async =>
              http.Response(jsonEncode(localRecommendationResponse), 200),
          onSimulation: (_) async =>
              http.Response(jsonEncode(localSimulationResponse), 200),
        ),
      ));
      await tester.pumpAndSettle();
      await _openRecommendationsForOrder(tester);
      var action = find.byKey(const Key('generate-recommendations-ORD-1043'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      action = find.byKey(const Key('simulate-REC-EXPEDITE-7-1043'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('simulation-result-REC-EXPEDITE-7-1043')),
          findsOneWidget);
      expect(find.text('Approve'), findsNothing);
    }
  });

  testWidgets('recommendation and simulation workspace fits mobile and desktop',
      (tester) async {
    for (final size in [const Size(390, 844), const Size(1280, 900)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(ZyroInventoryApp(
        authService: _FakeAuthService(),
        apiClient: _apiClient(
          onRecommendations: (_) async =>
              http.Response(jsonEncode(localRecommendationResponse), 200),
          onSimulation: (_) async =>
              http.Response(jsonEncode(localSimulationResponse), 200),
        ),
      ));
      await tester.pumpAndSettle();
      await _openRecommendationsForOrder(tester);
      var action = find.byKey(const Key('generate-recommendations-ORD-1043'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      action = find.byKey(const Key('simulate-REC-EXPEDITE-7-1043'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });

  test('parses proposal, purchase order, audit and decision response models',
      () {
    final board = ApprovalBoard.fromJson(localApprovalBoardJson);
    expect(board.proposals.single.proposalId, 'PROP-7-1043-EXPEDITE');
    expect(board.proposals.single.simulation.hypothetical, isTrue);
    expect(board.purchaseOrders.single.status, 'demo_created');
    expect(board.auditLogs.single.actorRole, 'planner');
    final decision = ProposalDecisionResult.fromJson(localProposalDecisionJson);
    expect(decision.status, 'applied');
    expect(decision.version, 8);
    expect(decision.proposal.executionStatus,
        ProposalExecutionStatus.awaitingSupplierConfirmation);
  });

  testWidgets('planner submits only a current successfully simulated option',
      (tester) async {
    var submissions = 0;
    var proposalRequests = 0;
    await _openSimulatedRecommendation(
      tester,
      apiClient: _apiClient(
        proposalRequestCount: () => proposalRequests++,
        onRecommendations: (_) async =>
            http.Response(jsonEncode(localRecommendationResponse), 200),
        onSimulation: (_) async =>
            http.Response(jsonEncode(localSimulationResponse), 200),
        onProposalSubmission: (request) async {
          submissions++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['order_id'], 'ORD-1043');
          expect(body['recommendation_id'], 'REC-EXPEDITE-7-1043');
          expect(body['expected_version'], 7);
          return http.Response(jsonEncode(localProposalSubmissionJson), 200);
        },
      ),
    );
    final submit = find.byKey(const Key('submit-proposal-REC-EXPEDITE-7-1043'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(submissions, 1);
    expect(proposalRequests, 2,
        reason: 'a successful submission immediately refreshes proposals');
    expect(find.textContaining('Submitted as proposal PROP-7-1043-EXPEDITE'),
        findsOneWidget);
  });

  testWidgets('approver can view proposals but cannot submit planner proposals',
      (tester) async {
    await _openSimulatedRecommendation(
      tester,
      apiClient: _apiClient(
        role: 'approver',
        onProposals: () async =>
            http.Response(jsonEncode(localApprovalBoardJson), 200),
        onRecommendations: (_) async =>
            http.Response(jsonEncode(localRecommendationResponse), 200),
        onSimulation: (_) async =>
            http.Response(jsonEncode(localSimulationResponse), 200),
      ),
    );
    expect(find.byKey(const Key('submit-proposal-REC-EXPEDITE-7-1043')),
        findsNothing);
    final approve =
        find.byKey(const Key('approve-proposal-PROP-7-1043-EXPEDITE'));
    await tester.ensureVisible(approve);
    expect(approve, findsOneWidget);
  });

  testWidgets('proposal submission failures are visible and retryable',
      (tester) async {
    await _openSimulatedRecommendation(
      tester,
      apiClient: _apiClient(
        onRecommendations: (_) async =>
            http.Response(jsonEncode(localRecommendationResponse), 200),
        onSimulation: (_) async =>
            http.Response(jsonEncode(localSimulationResponse), 200),
        onProposalSubmission: (_) async => http.Response(
            '{"detail":{"code":"SERVICE_UNAVAILABLE","message":"Try later"}}',
            503),
      ),
    );
    final submit = find.byKey(const Key('submit-proposal-REC-EXPEDITE-7-1043'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.textContaining('required backend service is unavailable'),
        findsOneWidget);
    expect(find.byKey(const Key('retry-proposal-REC-EXPEDITE-7-1043')),
        findsOneWidget);
  });

  testWidgets('approver confirms approval with reason and demo assumption ack',
      (tester) async {
    var sentRequest = <String, dynamic>{};
    var proposalRequests = 0;
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        role: 'approver',
        proposalRequestCount: () => proposalRequests++,
        onProposals: () async =>
            http.Response(jsonEncode(localApprovalBoardJson), 200),
        onProposalDecision: (request) async {
          sentRequest = jsonDecode(request.body) as Map<String, dynamic>;
          expect(request.url.path, '/proposals/PROP-7-1043-EXPEDITE/decision');
          return http.Response(jsonEncode(localProposalDecisionJson), 200);
        },
      ),
    ));
    await tester.pumpAndSettle();
    final approve =
        find.byKey(const Key('approve-proposal-PROP-7-1043-EXPEDITE'));
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    final confirm =
        find.byKey(const Key('confirm-decision-PROP-7-1043-EXPEDITE'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.enterText(
        find.byKey(const Key('decision-reason-PROP-7-1043-EXPEDITE')),
        'Reviewed simulation and recovery evidence.');
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    final ack = find.byKey(const Key('acknowledge-demo-PROP-7-1043-EXPEDITE'));
    await tester.ensureVisible(ack);
    await tester.tap(ack);
    await tester.pumpAndSettle();
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(sentRequest['decision'], 'approve');
    expect(sentRequest['expected_version'], 7);
    expect(sentRequest['acknowledge_demo_assumptions'], isTrue);
    expect(sentRequest['reason'], 'Reviewed simulation and recovery evidence.');
    expect(sentRequest['decision_id'], matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(proposalRequests, 2,
        reason: 'a successful decision immediately refreshes proposal data');
    expect(
        find.textContaining('awaiting supplier confirmation'), findsOneWidget);
  });

  testWidgets('approver rejection requires a reason but not supplier ack',
      (tester) async {
    Map<String, dynamic>? sentRequest;
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        role: 'approver',
        onProposals: () async =>
            http.Response(jsonEncode(localApprovalBoardJson), 200),
        onProposalDecision: (request) async {
          sentRequest = jsonDecode(request.body) as Map<String, dynamic>;
          final payload = {
            ...localProposalDecisionJson,
            'proposal': {
              ...localProposalDecisionJson['proposal'] as Map<String, dynamic>,
              'status': 'rejected',
              'execution_status': 'not_executed',
              'purchase_order_id': null,
            },
          };
          return http.Response(jsonEncode(payload), 200);
        },
      ),
    ));
    await tester.pumpAndSettle();
    final reject =
        find.byKey(const Key('reject-proposal-PROP-7-1043-EXPEDITE'));
    await tester.ensureVisible(reject);
    await tester.tap(reject);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('decision-reason-PROP-7-1043-EXPEDITE')),
        'Evidence does not support this option.');
    await tester.pump();
    final confirm =
        find.byKey(const Key('confirm-decision-PROP-7-1043-EXPEDITE'));
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(sentRequest?['decision'], 'reject');
    expect(sentRequest?['acknowledge_demo_assumptions'], isFalse);
    expect(sentRequest?['reason'], 'Evidence does not support this option.');
  });

  testWidgets('approver cannot approve their own proposal', (tester) async {
    final selfProposal = {
      ...localApprovalProposal,
      'created_by': 'test-user',
    };
    final board = {
      ...localApprovalBoardJson,
      'proposals': [selfProposal],
    };
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        role: 'approver',
        onProposals: () async => http.Response(jsonEncode(board), 200),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
        find.byKey(const Key('proposal-card-PROP-7-1043-EXPEDITE')));
    expect(find.byKey(const Key('approve-proposal-PROP-7-1043-EXPEDITE')),
        findsNothing);
    expect(find.text('You submitted this proposal and cannot approve it.'),
        findsOneWidget);
  });

  testWidgets('stale proposal approvals are disabled', (tester) async {
    final staleProposal = {
      ...localApprovalProposal,
      'snapshot_version': 6,
      'is_stale': true,
      'simulation': {...localSimulationResponse, 'version': 6},
    };
    final board = {
      ...localApprovalBoardJson,
      'proposals': [staleProposal],
    };
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        role: 'approver',
        onProposals: () async => http.Response(jsonEncode(board), 200),
      ),
    ));
    await tester.pumpAndSettle();
    final approve =
        find.byKey(const Key('approve-proposal-PROP-7-1043-EXPEDITE'));
    await tester.ensureVisible(approve);
    expect(tester.widget<FilledButton>(approve).onPressed, isNull);
    expect(find.text('OUTDATED'), findsOneWidget);
  });

  testWidgets(
      'HTTP 409 refreshes state and proposals without retrying decision',
      (tester) async {
    var decisionRequests = 0;
    var stateRequests = 0;
    var proposalRequests = 0;
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        role: 'approver',
        stateRequestCount: () => stateRequests++,
        onState: () async =>
            http.Response(jsonEncode(localDemoSnapshotJson), 200),
        onProposals: () async {
          proposalRequests++;
          return http.Response(jsonEncode(localApprovalBoardJson), 200);
        },
        onProposalDecision: (_) async {
          decisionRequests++;
          return http.Response(
              '{"detail":{"code":"STALE_VERSION","message":"Refresh and review."}}',
              409);
        },
      ),
    ));
    await tester.pumpAndSettle();
    final approve =
        find.byKey(const Key('approve-proposal-PROP-7-1043-EXPEDITE'));
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('decision-reason-PROP-7-1043-EXPEDITE')),
        'Reviewed current proposal evidence.');
    await tester.pump();
    final ack = find.byKey(const Key('acknowledge-demo-PROP-7-1043-EXPEDITE'));
    await tester.ensureVisible(ack);
    await tester.tap(ack);
    await tester.pumpAndSettle();
    final confirm =
        find.byKey(const Key('confirm-decision-PROP-7-1043-EXPEDITE'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(decisionRequests, 1);
    expect(stateRequests, greaterThanOrEqualTo(2));
    expect(proposalRequests, greaterThanOrEqualTo(2));
    expect(find.textContaining('inventory version changed'), findsOneWidget);
  });

  testWidgets('proposal submission prevents duplicate taps while pending',
      (tester) async {
    final response = Completer<http.Response>();
    var submissions = 0;
    await _openSimulatedRecommendation(
      tester,
      apiClient: _apiClient(
        onRecommendations: (_) async =>
            http.Response(jsonEncode(localRecommendationResponse), 200),
        onSimulation: (_) async =>
            http.Response(jsonEncode(localSimulationResponse), 200),
        onProposalSubmission: (_) {
          submissions++;
          return response.future;
        },
      ),
    );
    final submit = find.byKey(const Key('submit-proposal-REC-EXPEDITE-7-1043'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pump();
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    expect(submissions, 1);
    response
        .complete(http.Response(jsonEncode(localProposalSubmissionJson), 200));
    await tester.pumpAndSettle();
    expect(submissions, 1);
  });

  testWidgets('uncertain decision retry reuses identical decision ID and body',
      (tester) async {
    final bodies = <String>[];
    var attempt = 0;
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        role: 'approver',
        onProposals: () async =>
            http.Response(jsonEncode(localApprovalBoardJson), 200),
        onProposalDecision: (request) async {
          bodies.add(request.body);
          attempt++;
          if (attempt == 1) throw http.ClientException('response lost');
          return http.Response(jsonEncode(localProposalDecisionJson), 200);
        },
      ),
    ));
    await tester.pumpAndSettle();
    final approve =
        find.byKey(const Key('approve-proposal-PROP-7-1043-EXPEDITE'));
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('decision-reason-PROP-7-1043-EXPEDITE')),
        'Reviewed and approved for demonstration.');
    await tester.pump();
    final ack = find.byKey(const Key('acknowledge-demo-PROP-7-1043-EXPEDITE'));
    await tester.ensureVisible(ack);
    await tester.tap(ack);
    await tester.pumpAndSettle();
    final confirm =
        find.byKey(const Key('confirm-decision-PROP-7-1043-EXPEDITE'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('retry-decision-PROP-7-1043-EXPEDITE')),
        findsOneWidget);
    await tester
        .tap(find.byKey(const Key('retry-decision-PROP-7-1043-EXPEDITE')));
    await tester.pumpAndSettle();
    expect(bodies, hasLength(2));
    expect(bodies[1], bodies[0]);
    final decisionId = (jsonDecode(bodies.first) as Map)['decision_id'];
    expect(decisionId, matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  testWidgets('approval dashboard displays backend PO and audit history',
      (tester) async {
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        onProposals: () async =>
            http.Response(jsonEncode(localApprovalBoardJson), 200),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('purchase-order-DPO-001')));
    expect(find.text('DPO-001'), findsOneWidget);
    expect(find.text('DEMO ONLY'), findsOneWidget);
    expect(
        find.textContaining('not real supplier transactions'), findsOneWidget);
    expect(find.textContaining('AUDIT-001'), findsOneWidget);
    expect(find.textContaining('Proposal submitted · Planner'), findsOneWidget);
  });

  testWidgets('approval workspace fits mobile and desktop widths',
      (tester) async {
    for (final size in [const Size(390, 844), const Size(1280, 900)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(ZyroInventoryApp(
        authService: _FakeAuthService(),
        apiClient: _apiClient(
          onProposals: () async =>
              http.Response(jsonEncode(localApprovalBoardJson), 200),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
          find.byKey(const Key('proposal-card-PROP-7-1043-EXPEDITE')));
      expect(find.byKey(const Key('demo-purchase-orders')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });

  test('parses strict T5 answer and briefing contracts', () {
    final answer = AiAnswer.fromJson(_aiAnswerJson());
    expect(answer.evidence.single.sourceId, 'ORD-1043');
    expect(answer.mode, AiResponseMode.gemini);
    final briefing = AiBriefing.fromJson(_aiBriefingJson(role: 'approver'));
    expect(briefing.role, 'approver');
    expect(briefing.insights.single.orderId, 'ORD-1043');
    expect(() => AiAnswer.fromJson({..._aiAnswerJson(), 'mode': 'invented'}),
        throwsFormatException);
  });

  test('both AI endpoints accept a response taking longer than five seconds',
      () async {
    final api = _apiClient(
      onAiAsk: (_) async {
        await Future<void>.delayed(const Duration(seconds: 6));
        return http.Response(jsonEncode(_aiAnswerJson()), 200);
      },
      onAiBriefing: () async {
        await Future<void>.delayed(const Duration(seconds: 6));
        return http.Response(jsonEncode(_aiBriefingJson()), 200);
      },
    );
    addTearDown(api.close);
    final watch = Stopwatch()..start();
    final answerFuture = api.postAiQuestion(
      idToken: 'test-id-token',
      question: 'Explain current order risks.',
      orderId: null,
      expectedVersion: 7,
    );
    final briefingFuture = api.getAiBriefing(idToken: 'test-id-token');
    final answer = await answerFuture;
    final briefing = await briefingFuture;
    expect(watch.elapsed, greaterThan(const Duration(seconds: 5)));
    expect(answer.answer, contains('ORD-1043'));
    expect(briefing.mode, AiResponseMode.deterministicFallback);
  });

  test('both AI endpoints map timeout failures to the AI timeout error',
      () async {
    final api = _apiClient(
      onAiAsk: (_) async => throw TimeoutException('Mocked ask timeout.'),
      onAiBriefing: () async =>
          throw TimeoutException('Mocked briefing timeout.'),
    );
    addTearDown(api.close);
    final expectedTimeout = throwsA(isA<AiApiException>()
        .having((error) => error.failure, 'failure', AiApiFailure.timeout));
    await expectLater(
      api.postAiQuestion(
        idToken: 'test-id-token',
        question: 'Explain current order risks.',
        orderId: null,
        expectedVersion: 7,
      ),
      expectedTimeout,
    );
    await expectLater(
      api.getAiBriefing(idToken: 'test-id-token'),
      expectedTimeout,
    );
  });

  testWidgets('AI Copilot submits authenticated question and renders evidence',
      (tester) async {
    http.Request? submitted;
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        onAiAsk: (request) async {
          submitted = request;
          return http.Response(jsonEncode(_aiAnswerJson()), 200);
        },
      ),
    ));
    await tester.pumpAndSettle();
    await _openCopilot(tester);
    await tester.enterText(
        find.byKey(const Key('ai-question-input')), 'Why is ORD-1043 at risk?');
    final submit = find.byKey(const Key('ai-ask-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(submitted, isNotNull);
    expect(submitted!.url.path, endsWith('/ai/ask'));
    final body = jsonDecode(submitted!.body) as Map<String, dynamic>;
    expect(body['question'], 'Why is ORD-1043 at risk?');
    expect(body['order_id'], isNull);
    expect(body['expected_version'], 7);
    expect(
        find.text('The backend reports ORD-1043 is at risk.'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-evidence-0')), findsOneWidget);
    expect(find.text('Gemini AI'), findsOneWidget);
    expect(find.textContaining('This answer reflects snapshot v7.'),
        findsOneWidget);
  });

  testWidgets('deterministic fallback AI answers render normally',
      (tester) async {
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        onAiAsk: (_) async => http.Response(
            jsonEncode(_aiAnswerJson(mode: 'deterministic_fallback')), 200),
      ),
    ));
    await tester.pumpAndSettle();
    await _openCopilot(tester);
    await tester.enterText(
        find.byKey(const Key('ai-question-input')), 'Why is ORD-1043 at risk?');
    final submit = find.byKey(const Key('ai-ask-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(
        find.text('The backend reports ORD-1043 is at risk.'), findsOneWidget);
    expect(find.text('Evidence-based fallback'), findsWidgets);
    expect(find.textContaining('Uses verified backend data'), findsWidgets);
  });

  testWidgets(
      'briefing refreshes do not overlap or submit concurrent questions',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final firstBriefing = Completer<http.Response>();
    var briefingRequests = 0;
    var activeBriefings = 0;
    var maxActiveBriefings = 0;
    var askRequests = 0;
    Future<http.Response> loadBriefing() {
      briefingRequests++;
      activeBriefings++;
      if (activeBriefings > maxActiveBriefings) {
        maxActiveBriefings = activeBriefings;
      }
      final response = briefingRequests == 1
          ? firstBriefing.future
          : Future<http.Response>.value(
              http.Response(jsonEncode(_aiBriefingJson()), 200));
      return response.whenComplete(() => activeBriefings--);
    }

    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        onAiBriefing: loadBriefing,
        onAiAsk: (_) async {
          askRequests++;
          return http.Response(jsonEncode(_aiAnswerJson()), 200);
        },
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final nav = find.text('AI Copilot').first;
    await tester.ensureVisible(nav);
    await tester.tap(nav);
    await tester.pump(const Duration(milliseconds: 250));
    final askButton = find.byKey(const Key('ai-ask-submit'));
    await tester.ensureVisible(askButton);
    expect(tester.widget<FilledButton>(askButton).onPressed, isNull);
    expect(askRequests, 0);

    firstBriefing.complete(http.Response(jsonEncode(_aiBriefingJson()), 200));
    await tester.pumpAndSettle();
    expect(maxActiveBriefings, 1);
    expect(briefingRequests, lessThanOrEqualTo(2));
    expect(askRequests, 0);
    expect(tester.widget<FilledButton>(askButton).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI fallback briefing is backend sourced and role-specific',
      (tester) async {
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        role: 'approver',
        onAiBriefing: () async =>
            http.Response(jsonEncode(_aiBriefingJson(role: 'approver')), 200),
      ),
    ));
    await tester.pumpAndSettle();
    await _openCopilot(tester);
    expect(find.text('Review decisions'), findsOneWidget);
    expect(find.text('Which proposals require approval?'), findsOneWidget);
    expect(find.text('Evidence-based fallback'), findsWidgets);
    expect(find.textContaining('Gemini is unavailable'), findsNWidgets(2));
  });

  testWidgets('briefing renders repeated backend titles and warnings safely',
      (tester) async {
    final briefing = _aiBriefingJson();
    final insight =
        (briefing['insights'] as List).first as Map<String, dynamic>;
    briefing['insights'] = [
      insight,
      {
        ...insight,
        'evidence': [_aiEvidenceJson(), _aiEvidenceJson()],
      },
    ];
    briefing['warnings'] = ['Repeated warning', 'Repeated warning'];

    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        onAiBriefing: () async => http.Response(jsonEncode(briefing), 200),
      ),
    ));
    await tester.pumpAndSettle();
    await _openCopilot(tester);
    expect(find.text('Order risk'), findsNWidgets(2));
    expect(find.text('Repeated warning'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale AI question refreshes and retries only after user action',
      (tester) async {
    var asks = 0;
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        onAiAsk: (request) async {
          asks++;
          if (asks == 1) {
            return http.Response(
                jsonEncode({
                  'detail': {
                    'code': 'STALE_VERSION',
                    'message': 'Refresh the dashboard before asking again.'
                  }
                }),
                409);
          }
          return http.Response(jsonEncode(_aiAnswerJson()), 200);
        },
      ),
    ));
    await tester.pumpAndSettle();
    await _openCopilot(tester);
    await tester.enterText(
        find.byKey(const Key('ai-question-input')), 'Explain risks.');
    await tester.ensureVisible(find.byKey(const Key('ai-ask-submit')));
    await tester.tap(find.byKey(const Key('ai-ask-submit')));
    await tester.pumpAndSettle();
    expect(asks, 1);
    expect(find.byKey(const Key('ai-manual-retry')), findsOneWidget);
    expect(find.textContaining('Refresh the dashboard'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ai-manual-retry')));
    await tester.pumpAndSettle();
    expect(asks, 2);
    expect(
        find.text('The backend reports ORD-1043 is at risk.'), findsOneWidget);
  });

  testWidgets(
      'AI backend failures remain visible and contextual prompts bind order',
      (tester) async {
    http.Request? submitted;
    await tester.pumpWidget(ZyroInventoryApp(
      authService: _FakeAuthService(),
      apiClient: _apiClient(
        onAiBriefing: () async =>
            http.Response(jsonEncode(_aiBriefingJson()), 200),
        onAiAsk: (request) async {
          submitted = request;
          return http.Response(
              '{"detail":{"message":"AI service unavailable"}}', 503);
        },
      ),
    ));
    await tester.pumpAndSettle();
    await _openCopilot(tester);
    await tester.ensureVisible(find.text('Order risk'));
    await tester.tap(find.text('Ask about this insight'));
    await tester.pumpAndSettle();
    expect(submitted, isNotNull);
    final body = jsonDecode(submitted!.body) as Map<String, dynamic>;
    expect(body['order_id'], 'ORD-1043');
    expect(find.text('AI service unavailable'), findsOneWidget);
  });

  testWidgets('AI Copilot layout remains responsive on mobile and desktop',
      (tester) async {
    for (final size in [const Size(390, 844), const Size(1280, 900)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(ZyroInventoryApp(
        authService: _FakeAuthService(),
        apiClient: _apiClient(),
      ));
      await tester.pumpAndSettle();
      await _openCopilot(tester);
      expect(tester.takeException(), isNull);
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });
}
