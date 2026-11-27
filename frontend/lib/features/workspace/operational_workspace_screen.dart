import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/models/inventory_snapshot.dart';

class OperationalWorkspaceScreen extends StatefulWidget {
  const OperationalWorkspaceScreen({
    super.key,
    required this.workspaceId,
    required this.getIdToken,
    required this.onSignOut,
    this.apiClient,
  });

  final String workspaceId;
  final Future<String> Function() getIdToken;
  final VoidCallback onSignOut;
  final ApiClient? apiClient;

  @override
  State<OperationalWorkspaceScreen> createState() =>
      _OperationalWorkspaceScreenState();
}

class _OperationalWorkspaceScreenState
    extends State<OperationalWorkspaceScreen> {
  late final ApiClient _api;
  late final Timer _poll;
  WorkspaceInfo? _info;
  InventorySnapshot? _snapshot;
  String? _role;
  bool _loading = true;
  bool _stale = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _api = widget.apiClient ?? ApiClient();
    unawaited(_refresh());
    _poll = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_loading) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _poll.cancel();
    if (widget.apiClient == null) _api.close();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final token = await widget.getIdToken();
      if (!mounted) return;
      final info = await _api.getWorkspaceInfo(
          idToken: token, workspaceId: widget.workspaceId);
      if (!mounted) return;
      final state = await _api.getWorkspaceState(
          idToken: token, workspaceId: widget.workspaceId);
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_snapshot != null && state.snapshot.version < _snapshot!.version) {
          _stale = true;
          _failure = 'The server returned an older inventory version.';
          return;
        }
        _info = info;
        _snapshot = state.snapshot;
        _role = state.role;
        _stale = false;
        _failure = null;
      });
    } on StateApiException catch (error) {
      final denied = error.failure == StateApiFailure.forbidden;
      final expired = error.failure == StateApiFailure.unauthorized;
      _onFailure(
        denied
            ? 'You do not have access to this workspace.'
            : expired
                ? 'Your session has expired. Sign in again.'
                : 'Workspace unavailable. Try again.',
        clear: denied || expired,
      );
    } on Exception {
      _onFailure('Workspace unavailable. Try again.');
    }
  }

  void _onFailure(String message, {bool clear = false}) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failure = message;
      if (clear) {
        _info = null;
        _snapshot = null;
        _role = null;
      }
      _stale = _snapshot != null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Operational workspace'),
        actions: [
          TextButton(
              onPressed: widget.onSignOut, child: const Text('Sign out')),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (_loading) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(snapshot == null
                    ? 'Loading operational workspace...'
                    : 'Refreshing operational inventory...'),
              ],
              if (_failure != null) ...[
                if (_stale) const Text('Showing stale operational inventory.'),
                Text(_failure!),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: _loading ? null : _refresh,
                  child: const Text('Refresh workspace'),
                ),
              ),
              if (snapshot != null) ...[
                Text(_info!.name,
                    style: Theme.of(context).textTheme.headlineSmall),
                Text('Version ${snapshot.version} · ${_role!} access'),
                const SizedBox(height: 18),
                if (snapshot.materials.isEmpty && snapshot.orders.isEmpty)
                  const Text('Operational inventory is empty.')
                else ...[
                  Text('Materials (${snapshot.materials.length})'),
                  for (final item in snapshot.materials)
                    ListTile(
                      title: Text(item.name),
                      subtitle:
                          Text('${item.netAvailable} ${item.unit} available'),
                    ),
                  Text('Customer orders (${snapshot.orders.length})'),
                  for (final order in snapshot.orders)
                    ListTile(
                      title: Text(order.orderId),
                      subtitle: Text(order.customer),
                      trailing: Text(order.risk.label),
                    ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
