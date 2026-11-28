import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/models/inventory_snapshot.dart';

class MaterialEditor extends StatefulWidget {
  const MaterialEditor({
    super.key,
    required this.api,
    required this.workspaceId,
    required this.version,
    required this.getIdToken,
    this.material,
  });

  final ApiClient api;
  final String workspaceId;
  final int version;
  final Future<String> Function() getIdToken;
  final MaterialInventory? material;

  @override
  State<MaterialEditor> createState() => _MaterialEditorState();
}

class _MaterialEditorState extends State<MaterialEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _id;
  late final TextEditingController _name;
  late final TextEditingController _unit;
  late final TextEditingController _threshold;
  late final TextEditingController _description;
  String? _mutationId;
  String? _error;
  bool _saving = false;
  bool _duplicateSku = false;

  @override
  void initState() {
    super.initState();
    final item = widget.material;
    _id = TextEditingController(text: item?.materialId);
    _name = TextEditingController(text: item?.name);
    _unit = TextEditingController(text: item?.unit);
    _threshold =
        TextEditingController(text: (item?.reorderThreshold ?? 0).toString());
    _description = TextEditingController(text: item?.description);
  }

  @override
  void dispose() {
    for (final controller in [_id, _name, _unit, _threshold, _description]) {
      controller.dispose();
    }
    super.dispose();
  }

  String _newId() {
    final random = Random.secure();
    return List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
      _duplicateSku = false;
      _mutationId ??= _newId();
    });
    try {
      final token = await widget.getIdToken();
      if (!mounted) return;
      final description = _description.text.trim();
      final result = await widget.api.saveWorkspaceMaterial(
        idToken: token,
        workspaceId: widget.workspaceId,
        materialId: _id.text.trim().toUpperCase(),
        create: widget.material == null,
        name: _name.text.trim(),
        unit: _unit.text.trim(),
        reorderThreshold: int.parse(_threshold.text.trim()),
        description: description.isEmpty ? null : description,
        expectedVersion: widget.version,
        mutationId: _mutationId!,
      );
      if (mounted) {
        setState(() => _saving = false);
        Navigator.pop(context, result);
      }
    } on WorkspaceMaterialException catch (error) {
      if (!mounted) return;
      if (error.code == 'STALE_VERSION' ||
          error.status == 401 ||
          error.status == 403 ||
          error.code == 'MUTATION_ID_CONFLICT' ||
          error.status == 404) {
        setState(() => _saving = false);
        Navigator.pop(
            context,
            error.status == 401 || error.status == 403
                ? 'ACCESS_CHANGED'
                : error.code);
        return;
      }
      setState(() {
        _saving = false;
        if (!error.retryable) _mutationId = null;
        _duplicateSku = error.code == 'DUPLICATE_MATERIAL';
        _error = _duplicateSku
            ? null
            : error.retryable
                ? 'The result could not be confirmed. Retry the same request or close and refresh.'
                : 'The material was not saved. Check the submitted fields.';
      });
    } on Exception {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Unable to complete the request. Retry or close and refresh.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final creating = widget.material == null;
    final editable = _mutationId == null;
    return PopScope(
      canPop: !_saving && _mutationId == null,
      child: AlertDialog(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(creating ? 'Add Material' : 'Edit Material'),
            if (_duplicateSku)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    'A material with this SKU already exists.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                  ),
                ),
              ),
          ],
        ),
        content: SizedBox(
          width: 450,
          child: SingleChildScrollView(
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: _id,
                    onChanged: (_) {
                      if (_duplicateSku) setState(() => _duplicateSku = false);
                    },
                    readOnly: !creating || !editable,
                    decoration:
                        const InputDecoration(labelText: 'Material ID / SKU'),
                    validator: (value) =>
                        RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
                                .hasMatch(value?.trim() ?? '')
                            ? null
                            : 'Enter a valid material ID (1–64 characters).',
                  ),
                  TextFormField(
                    controller: _name,
                    readOnly: !editable,
                    maxLength: 120,
                    decoration:
                        const InputDecoration(labelText: 'Material name'),
                    validator: (value) =>
                        (value ?? '').trim().isEmpty ? 'Enter a name.' : null,
                  ),
                  TextFormField(
                    controller: _unit,
                    readOnly: !editable,
                    maxLength: 32,
                    decoration:
                        const InputDecoration(labelText: 'Unit of measurement'),
                    validator: (value) =>
                        (value ?? '').trim().isEmpty ? 'Enter a unit.' : null,
                  ),
                  TextFormField(
                    controller: _threshold,
                    readOnly: !editable,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'Reorder threshold'),
                    validator: (value) {
                      final text = (value ?? '').trim();
                      final parsed = int.tryParse(text);
                      return RegExp(r'^\d+$').hasMatch(text) &&
                              parsed != null &&
                              parsed <= 9007199254740991
                          ? null
                          : 'Enter a non-negative whole number in range.';
                    },
                  ),
                  TextFormField(
                    controller: _description,
                    readOnly: !editable,
                    maxLength: 500,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                        labelText: 'Description (optional)'),
                  ),
                  if (_error != null)
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  if (_saving) const LinearProgressIndicator(),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving
                ? null
                : () => Navigator.pop(
                    context, _mutationId == null ? null : 'REFRESH'),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_mutationId != null && !_saving
                ? 'Retry save'
                : 'Save material'),
          ),
        ],
      ),
    );
  }
}
