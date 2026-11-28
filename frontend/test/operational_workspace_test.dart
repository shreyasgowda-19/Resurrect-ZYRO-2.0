import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zyro_inventory_frontend/core/api/api_client.dart';
import 'package:zyro_inventory_frontend/core/auth/auth_service.dart';
import 'package:zyro_inventory_frontend/features/auth/auth_gate.dart';

const workspace = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class _Auth implements AuthService {
  @override
  Stream<AuthenticatedUser?> get authStateChanges => Stream.value(
        AuthenticatedUser(
          uid: 'workspace-member',
          email: 'member@example.test',
          idToken: () async => 'mock-workspace-token',
        ),
      );

  @override
  Future<void> signIn(
      {required String email, required String password}) async {}

  @override
  Future<void> signOut() async {}
}

void main() {
  testWidgets(
      'selected workspace only uses scoped endpoints and clears revoked data',
      (tester) async {
    var status = 200;
    var version = 2;
    final paths = <String>[];
    final client = ApiClient(client: MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer mock-workspace-token');
      paths.add(request.url.path);
      final common = {
        'workspace_id': workspace,
        'role': 'approver',
        'data_mode': 'operational',
      };
      if (request.url.path == '/workspaces/$workspace') {
        return http.Response(
            jsonEncode({...common, 'name': 'Operations'}), 200);
      }
      expect(request.url.path, '/workspaces/$workspace/state');
      return http.Response(
        jsonEncode({
          ...common,
          'version': version,
          'as_of_date': '2026-12-01',
          'materials': [],
          'orders': [],
          'supply_lots': [],
          'order_requirements': [],
          'recent_events': [],
          'alerts': [],
        }),
        status,
      );
    }));
    await tester.pumpWidget(MaterialApp(
      home: AuthGate(
          authService: _Auth(), apiClient: client, workspaceId: workspace),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Operational inventory is empty.'), findsOneWidget);
    expect(find.textContaining('Version 2'), findsOneWidget);
    expect(paths, ['/workspaces/$workspace', '/workspaces/$workspace/state']);

    await tester.tap(find.byKey(const Key('dashboard-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inventory'));
    await tester.pumpAndSettle();
    expect(find.text('No materials in this workspace.'), findsOneWidget);

    version = 1;
    await tester.tap(find.byKey(const Key('dashboard-refresh-button')));
    await tester.pumpAndSettle();
    expect(find.text('Showing stale operational inventory.'), findsOneWidget);
    expect(find.textContaining('Version 2'), findsOneWidget);

    status = 503;
    await tester.tap(find.byKey(const Key('dashboard-refresh-button')));
    await tester.pumpAndSettle();
    expect(find.text('Workspace unavailable. Try again.'), findsOneWidget);
    expect(find.text('Showing stale operational inventory.'), findsOneWidget);

    status = 403;
    await tester.tap(find.byKey(const Key('dashboard-refresh-button')));
    await tester.pumpAndSettle();
    expect(
        find.text('You do not have access to this workspace.'), findsOneWidget);
    expect(find.text('Operational inventory is empty.'), findsNothing);
    expect(find.textContaining('Version 2'), findsNothing);
    expect(paths.every((p) => p.startsWith('/workspaces/$workspace')), isTrue);
    await tester.pumpWidget(const SizedBox());
    client.close();
  });

  test('rejects cross-workspace and demo-mode responses', () async {
    for (final response in [
      {'workspace_id': 'wrong', 'data_mode': 'operational'},
      {'workspace_id': workspace, 'data_mode': 'demo'},
    ]) {
      final client = ApiClient(client: MockClient((request) async {
        expect(request.url.path, '/workspaces/$workspace');
        return http.Response(
            jsonEncode({...response, 'role': 'planner', 'name': 'Operations'}),
            200);
      }));
      await expectLater(
        client.getWorkspaceInfo(idToken: 'mock', workspaceId: workspace),
        throwsA(isA<StateApiException>().having((error) => error.failure,
            'failure', StateApiFailure.malformedResponse)),
      );
      client.close();
    }
  });
}
