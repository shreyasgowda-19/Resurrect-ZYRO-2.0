import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zyro_inventory_frontend/core/api/api_client.dart';
import 'package:zyro_inventory_frontend/features/workspace/operational_workspace_screen.dart';

const workspaceId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, dynamic> response(String role) =>
    {'workspace_id': workspaceId, 'data_mode': 'operational', 'role': role};

Map<String, dynamic> item(Map<String, dynamic> fields) => {
      'material_id': 'RESIN-01',
      'name': fields['name'],
      'unit': fields['unit'],
      'reorder_threshold': fields['reorder_threshold'],
      'description': fields['description'],
      'on_hand': 0,
      'incoming': 0,
      'allocated': 0,
      'net_available': 0,
    };

Map<String, dynamic> state(String role, int version, List<dynamic> materials) =>
    {
      ...response(role),
      'as_of_date': '2026-12-01',
      'version': version,
      'materials': materials,
      'orders': [],
      'supply_lots': [],
      'order_requirements': [],
      'recent_events': [],
      'alerts': [],
    };

http.Response jsonResponse(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status);

Widget workspace(ApiClient api) => MaterialApp(
      home: OperationalWorkspaceScreen(
        workspaceId: workspaceId,
        getIdToken: () async => 'test-id-token',
        onSignOut: () {},
        apiClient: api,
      ),
    );

void main() {
  testWidgets(
      'planner adds and edits real workspace materials with an identical retry',
      (tester) async {
    var version = 1;
    Map<String, dynamic>? material;
    final writes = <http.Request>[];
    final api = ApiClient(client: MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer test-id-token');
      expect(request.url.path, startsWith('/workspaces/$workspaceId'));
      if (request.method == 'GET') {
        return request.url.path.endsWith('/state')
            ? jsonResponse(
                state('planner', version, [if (material != null) material!]))
            : jsonResponse({...response('planner'), 'name': 'Operations'});
      }
      writes.add(request);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body.containsKey('on_hand'), isFalse);
      expect(body.containsKey('role'), isFalse);
      expect(body['expected_version'], version);
      if (writes.length == 1) {
        return jsonResponse({
          'detail': {'code': 'SERVICE_UNAVAILABLE'}
        }, 503);
      }
      if (request.method == 'POST') {
        expect(body['material_id'], 'RESIN-01');
        expect(writes.first.body, request.body);
      } else {
        expect(request.method, 'PATCH');
        expect(body.containsKey('material_id'), isFalse);
        expect(request.url.path, endsWith('/materials/RESIN-01'));
      }
      material = item(body);
      version++;
      return jsonResponse({
        'status': 'applied',
        'workspace_id': workspaceId,
        'version': version,
        'material': material,
      });
    }));
    tester.view.physicalSize = const Size(1200, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspace(api));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('overview-total-orders')), findsOneWidget);
    await tester.tap(find.text('AI Copilot'));
    await tester.pumpAndSettle();
    expect(find.text('AI Copilot is unavailable for operational workspaces.'),
        findsOneWidget);
    await tester.tap(find.text('Inventory'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Material'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save material'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'resin-01');
    await tester.enterText(fields.at(1), 'Production resin');
    await tester.enterText(fields.at(2), 'kg');
    await tester.enterText(fields.at(3), '15');
    await tester.tap(find.text('Save material'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Retry the same request'), findsOneWidget);
    await tester.tap(find.text('Retry save'));
    await tester.pumpAndSettle();
    expect(find.text('Material added.'), findsOneWidget);
    expect(find.text('Production resin'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit RESIN-01'));
    await tester.pumpAndSettle();
    await tester.enterText(fields.at(1), 'Updated resin');
    await tester.tap(find.text('Save material'));
    await tester.pumpAndSettle();
    expect(find.text('Material updated.'), findsOneWidget);
    expect(find.text('Updated resin'), findsOneWidget);
    expect(find.textContaining('0 kg on hand'), findsOneWidget);
    expect(writes.length, 3);
    await tester.pumpWidget(const SizedBox());
    api.close();
  });

  testWidgets(
      'duplicate SKU stays visible in a short dialog and is correctable',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final writes = <Map<String, dynamic>>[];
    final api = ApiClient(client: MockClient((request) async {
      if (request.method == 'GET') {
        return request.url.path.endsWith('/state')
            ? jsonResponse(state('planner', 5, []))
            : jsonResponse({...response('planner'), 'name': 'Operations'});
      }
      writes.add(jsonDecode(request.body) as Map<String, dynamic>);
      if (writes.length == 1) {
        return jsonResponse({
          'detail': {
            'code': 'DUPLICATE_MATERIAL',
            'message': 'This material ID already exists.',
          }
        }, 409);
      }
      return jsonResponse({
        'status': 'applied',
        'workspace_id': workspaceId,
        'version': 6,
        'material': {...item(writes.last), 'material_id': 'CU-002'},
      });
    }));
    await tester.pumpWidget(workspace(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inventory'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Material'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    final inputs = ['cu-001', 'Copper sheet', 'kg', '12', 'Retain this'];
    for (var i = 0; i < inputs.length; i++) {
      await tester.ensureVisible(fields.at(i));
      await tester.enterText(fields.at(i), inputs[i]);
    }
    await tester.tap(find.text('Save material'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.text('A material with this SKU already exists.').hitTestable(),
      findsOneWidget,
    );
    for (var i = 0; i < inputs.length; i++) {
      expect(tester.widget<TextFormField>(fields.at(i)).controller!.text,
          inputs[i]);
    }
    await tester.ensureVisible(fields.first);
    await tester.enterText(fields.first, 'cu-002');
    await tester.tap(find.text('Save material'));
    await tester.pumpAndSettle();
    expect(writes.map((body) => body['material_id']), ['CU-001', 'CU-002']);
    expect(writes.last['mutation_id'], isNot(writes.first['mutation_id']));
    expect(writes.last['description'], 'Retain this');
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    api.close();
  });

  testWidgets('approver can read material metadata without mutation controls',
      (tester) async {
    final api = ApiClient(client: MockClient((request) async {
      expect(request.method, 'GET');
      final material = item({
        'name': 'Production resin',
        'unit': 'kg',
        'reorder_threshold': 15,
        'description': 'Blue formulation',
      });
      return request.url.path.endsWith('/state')
          ? jsonResponse(state('approver', 2, [material]))
          : jsonResponse({...response('approver'), 'name': 'Operations'});
    }));
    tester.view.physicalSize = const Size(1200, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspace(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inventory'));
    await tester.pumpAndSettle();
    expect(find.text('Production resin'), findsOneWidget);
    expect(find.textContaining('Reorder threshold 15'), findsOneWidget);
    expect(find.text('Add Material'), findsNothing);
    expect(find.byTooltip('Edit RESIN-01'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    api.close();
  });
}
