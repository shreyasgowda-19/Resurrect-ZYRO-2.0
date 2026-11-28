import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/models/inventory_snapshot.dart';
import '../dashboard/dashboard_screen.dart';
import 'material_editor.dart';

class OperationalWorkspaceScreen extends StatefulWidget {
  const OperationalWorkspaceScreen({
    super.key,
    required this.workspaceId,
    required this.getIdToken,
    required this.onSignOut,
    this.apiClient,
    this.email = '',
  });

  final String workspaceId;
  final String email;
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
  bool _editorOpen = false;
  String? _notice;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _api = widget.apiClient ?? ApiClient();
    unawaited(_refresh());
    _poll = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_loading && !_editorOpen) unawaited(_refresh());
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

  Future<void> _editMaterial([MaterialInventory? item]) async {
    final snapshot = _snapshot;
    if (_editorOpen ||
        _loading ||
        _stale ||
        _role != 'planner' ||
        snapshot == null) {
      return;
    }
    setState(() {
      _editorOpen = true;
      _notice = null;
    });
    final outcome = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => MaterialEditor(
        api: _api,
        workspaceId: widget.workspaceId,
        version: snapshot.version,
        getIdToken: widget.getIdToken,
        material: item,
      ),
    );
    if (!mounted) return;
    setState(() {
      _editorOpen = false;
      _notice = switch (outcome) {
        'applied' ||
        'duplicate' =>
          item == null ? 'Material added.' : 'Material updated.',
        'STALE_VERSION' =>
          'Inventory changed. Review the refreshed workspace before editing.',
        'ACCESS_CHANGED' => 'Planner access is required to save a material.',
        'REFRESH' => null,
        null => null,
        _ => 'The material could not be saved. Review the refreshed workspace.',
      };
    });
    if (outcome != null) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final canEdit = _role == 'planner' && !_loading && !_stale && !_editorOpen;
    return DashboardScreen(
      uid: '',
      email: widget.email,
      role: _role ?? '',
      getIdToken: widget.getIdToken,
      apiClient: _api,
      onSignOut: widget.onSignOut,
      operational: OperationalDashboardData(
        name: _info?.name,
        snapshot: snapshot,
        loading: _loading,
        stale: _stale,
        failure: _failure,
        refresh: () {
          if (!_loading && !_editorOpen) unawaited(_refresh());
        },
        materials: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_notice != null) Text(_notice!),
            if (_role == 'planner')
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: canEdit ? () => _editMaterial() : null,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Material'),
                ),
              ),
            if (snapshot?.materials.isEmpty == true)
              const Card(
                  child:
                      ListTile(title: Text('No materials in this workspace.'))),
            for (final item
                in snapshot?.materials ?? const <MaterialInventory>[])
              Card(
                child: ListTile(
                  title: Text(item.name),
                  subtitle: Text([
                    '${item.materialId} · ${item.onHand} ${item.unit} on hand',
                    '${item.incoming} incoming ? ${item.allocated} allocated ? ${item.netAvailable} available',
                    'Reorder threshold ${item.reorderThreshold}',
                    if (item.description?.isNotEmpty == true) item.description!,
                  ].join('\n')),
                  trailing: _role == 'planner'
                      ? IconButton(
                          tooltip: 'Edit ${item.materialId}',
                          onPressed: canEdit ? () => _editMaterial(item) : null,
                          icon: const Icon(Icons.edit_outlined),
                        )
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
