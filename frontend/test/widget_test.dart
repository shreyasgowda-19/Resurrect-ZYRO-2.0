import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zyro_inventory_frontend/app.dart';
import 'package:zyro_inventory_frontend/core/api/api_client.dart';

final _backendButton = find.byKey(const Key('test-backend-connection-button'));

Future<void> _scrollToBackendButton(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    _backendButton,
    200,
    scrollable: find.byType(Scrollable),
  );
}

void main() {
  testWidgets('shows the project shell and unverified backend state', (tester) async {
    await tester.pumpWidget(const ZyroInventoryApp());

    expect(find.text('Team ZYRO 2.0'), findsOneWidget);
    expect(find.text('Frontend'), findsOneWidget);
    expect(find.text('Not checked'), findsOneWidget);
    await _scrollToBackendButton(tester);
    expect(_backendButton, findsOneWidget);
  });

  testWidgets('shows disconnected when the health endpoint is unavailable', (tester) async {
    final client = ApiClient(
      client: MockClient((_) async => http.Response('unavailable', 503)),
    );
    await tester.pumpWidget(ZyroInventoryApp(apiClient: client));

    await _scrollToBackendButton(tester);
    await tester.tap(_backendButton);
    await tester.pumpAndSettle();

    expect(find.text('Disconnected'), findsOneWidget);
  });

  testWidgets('shows connected when the health endpoint succeeds', (tester) async {
    final client = ApiClient(
      client: MockClient((_) async => http.Response(
        '{"status":"ok","service":"inventory-api"}',
        200,
      )),
    );
    await tester.pumpWidget(ZyroInventoryApp(apiClient: client));

    await _scrollToBackendButton(tester);
    await tester.tap(_backendButton);
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);
  });
}
