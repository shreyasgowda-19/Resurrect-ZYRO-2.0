import 'recommendation_models.dart';

enum ProposalStatus {
  pending('pending'),
  approved('approved'),
  rejected('rejected');

  const ProposalStatus(this.wireValue);
  final String wireValue;

  static ProposalStatus parse(Object? value) =>
      ProposalStatus.values.firstWhere((status) => status.wireValue == value,
          orElse: () =>
              throw FormatException('Unknown proposal status: $value'));
}

enum ProposalExecutionStatus {
  notExecuted('not_executed'),
  demoPoCreated('demo_po_created'),
  awaitingSupplierConfirmation('awaiting_supplier_confirmation');

  const ProposalExecutionStatus(this.wireValue);
  final String wireValue;

  static ProposalExecutionStatus parse(Object? value) =>
      ProposalExecutionStatus.values.firstWhere(
        (status) => status.wireValue == value,
        orElse: () =>
            throw FormatException('Unknown proposal execution status: $value'),
      );
}

class ApprovalProposal {
  const ApprovalProposal({
    required this.proposalId,
    required this.orderId,
    required this.recommendationId,
    required this.actionType,
    required this.snapshotVersion,
    required this.status,
    required this.isStale,
    required this.createdBy,
    required this.createdAt,
    required this.recommendation,
    required this.simulation,
    required this.decidedBy,
    required this.decidedAt,
    required this.decisionReason,
    required this.purchaseOrderId,
    required this.executionStatus,
  });

  final String proposalId;
  final String orderId;
  final String recommendationId;
  final RecommendationAction actionType;
  final int snapshotVersion;
  final ProposalStatus status;
  final bool isStale;
  final String createdBy;
  final DateTime createdAt;
  final InventoryRecommendation recommendation;
  final SimulationResult simulation;
  final String? decidedBy;
  final DateTime? decidedAt;
  final String? decisionReason;
  final String? purchaseOrderId;
  final ProposalExecutionStatus executionStatus;

  factory ApprovalProposal.fromJson(Map<String, dynamic> json) {
    final recommendation = _proposalMap(json['recommendation']);
    final simulation = _proposalMap(json['simulation']);
    final parsedRecommendation =
        InventoryRecommendation.fromJson(recommendation);
    final parsedSimulation = SimulationResult.fromJson(simulation);
    final proposal = ApprovalProposal(
      proposalId: _proposalString(json, 'proposal_id'),
      orderId: _proposalString(json, 'order_id'),
      recommendationId: _proposalString(json, 'recommendation_id'),
      actionType: RecommendationAction.parse(json['action_type']),
      snapshotVersion: _proposalInt(json, 'snapshot_version'),
      status: ProposalStatus.parse(json['status']),
      isStale: _proposalBool(json, 'is_stale'),
      createdBy: _proposalString(json, 'created_by'),
      createdAt: _proposalTimestamp(json, 'created_at'),
      recommendation: parsedRecommendation,
      simulation: parsedSimulation,
      decidedBy: _proposalNullableString(json, 'decided_by'),
      decidedAt: _proposalNullableTimestamp(json, 'decided_at'),
      decisionReason: _proposalNullableString(json, 'decision_reason'),
      purchaseOrderId: _proposalNullableString(json, 'purchase_order_id'),
      executionStatus: ProposalExecutionStatus.parse(json['execution_status']),
    );
    if (proposal.orderId != parsedSimulation.orderId ||
        proposal.recommendationId != parsedRecommendation.recommendationId ||
        proposal.recommendationId != parsedSimulation.recommendationId ||
        proposal.actionType != parsedRecommendation.actionType ||
        proposal.snapshotVersion != parsedSimulation.version) {
      throw const FormatException(
          'Proposal evidence does not match its identifiers or version.');
    }
    return proposal;
  }
}

class DemoPurchaseOrder {
  const DemoPurchaseOrder({
    required this.purchaseOrderId,
    required this.proposalId,
    required this.orderId,
    required this.supplierId,
    required this.materialId,
    required this.quantity,
    required this.expectedDeliveryDate,
    required this.estimatedIncrementalCost,
    required this.currency,
    required this.status,
    required this.createdBy,
    required this.createdAt,
  });

  final String purchaseOrderId;
  final String proposalId;
  final String orderId;
  final String supplierId;
  final String materialId;
  final int quantity;
  final DateTime expectedDeliveryDate;
  final num? estimatedIncrementalCost;
  final String? currency;
  final String status;
  final String createdBy;
  final DateTime createdAt;

  factory DemoPurchaseOrder.fromJson(Map<String, dynamic> json) =>
      DemoPurchaseOrder(
        purchaseOrderId: _proposalString(json, 'purchase_order_id'),
        proposalId: _proposalString(json, 'proposal_id'),
        orderId: _proposalString(json, 'order_id'),
        supplierId: _proposalString(json, 'supplier_id'),
        materialId: _proposalString(json, 'material_id'),
        quantity: _proposalInt(json, 'quantity', nonNegative: true),
        expectedDeliveryDate: _proposalDate(json, 'expected_delivery_date'),
        estimatedIncrementalCost:
            _proposalNullableNumber(json, 'estimated_incremental_cost'),
        currency: _proposalNullableString(json, 'currency'),
        status: _proposalEnum(json, 'status', const {'demo_created'}),
        createdBy: _proposalString(json, 'created_by'),
        createdAt: _proposalTimestamp(json, 'created_at'),
      );
}

class ApprovalAuditRecord {
  const ApprovalAuditRecord({
    required this.auditId,
    required this.action,
    required this.actorUid,
    required this.actorRole,
    required this.proposalId,
    required this.timestamp,
    required this.version,
    required this.summary,
  });

  final String auditId;
  final String action;
  final String actorUid;
  final String actorRole;
  final String proposalId;
  final DateTime timestamp;
  final int version;
  final String summary;

  factory ApprovalAuditRecord.fromJson(Map<String, dynamic> json) =>
      ApprovalAuditRecord(
        auditId: _proposalString(json, 'audit_id'),
        action: _proposalEnum(json, 'action', const {
          'proposal_submitted',
          'proposal_approved',
          'proposal_rejected',
          'purchase_order_created',
          'expedite_authorized',
        }),
        actorUid: _proposalString(json, 'actor_uid'),
        actorRole: _proposalString(json, 'actor_role'),
        proposalId: _proposalString(json, 'proposal_id'),
        timestamp: _proposalTimestamp(json, 'timestamp'),
        version: _proposalInt(json, 'version', nonNegative: true),
        summary: _proposalString(json, 'summary'),
      );
}

class ApprovalBoard {
  const ApprovalBoard({
    required this.version,
    required this.proposals,
    required this.purchaseOrders,
    required this.auditLogs,
  });

  final int version;
  final List<ApprovalProposal> proposals;
  final List<DemoPurchaseOrder> purchaseOrders;
  final List<ApprovalAuditRecord> auditLogs;

  factory ApprovalBoard.fromJson(Map<String, dynamic> json) => ApprovalBoard(
        version: _proposalInt(json, 'version', nonNegative: true),
        proposals: _proposalList(json, 'proposals', ApprovalProposal.fromJson),
        purchaseOrders:
            _proposalList(json, 'purchase_orders', DemoPurchaseOrder.fromJson),
        auditLogs:
            _proposalList(json, 'audit_logs', ApprovalAuditRecord.fromJson),
      );
}

class ProposalSubmissionResult {
  const ProposalSubmissionResult({
    required this.status,
    required this.version,
    required this.proposal,
  });

  final String status;
  final int version;
  final ApprovalProposal proposal;

  factory ProposalSubmissionResult.fromJson(Map<String, dynamic> json) {
    final status = _proposalString(json, 'status');
    if (status != 'created' && status != 'duplicate') {
      throw const FormatException('Invalid proposal submission status.');
    }
    final version = _proposalInt(json, 'version', nonNegative: true);
    final proposal = ApprovalProposal.fromJson(_proposalMap(json['proposal']));
    if (proposal.snapshotVersion != version) {
      throw const FormatException(
          'Proposal response version does not match its snapshot.');
    }
    return ProposalSubmissionResult(
      status: status,
      version: version,
      proposal: proposal,
    );
  }
}

class ProposalDecisionRequest {
  const ProposalDecisionRequest({
    required this.decisionId,
    required this.decision,
    required this.expectedVersion,
    required this.reason,
    required this.acknowledgeDemoAssumptions,
  });

  final String decisionId;
  final String decision;
  final int expectedVersion;
  final String reason;
  final bool acknowledgeDemoAssumptions;

  Map<String, dynamic> toJson() => {
        'decision_id': decisionId,
        'decision': decision,
        'expected_version': expectedVersion,
        'reason': reason,
        'acknowledge_demo_assumptions': acknowledgeDemoAssumptions,
      };
}

class ProposalDecisionResult {
  const ProposalDecisionResult({
    required this.status,
    required this.version,
    required this.proposal,
    required this.purchaseOrder,
  });

  final String status;
  final int version;
  final ApprovalProposal proposal;
  final DemoPurchaseOrder? purchaseOrder;

  factory ProposalDecisionResult.fromJson(Map<String, dynamic> json) {
    final status = _proposalString(json, 'status');
    if (status != 'applied' && status != 'duplicate') {
      throw const FormatException('Invalid proposal decision status.');
    }
    final rawPurchaseOrder = json['purchase_order'];
    return ProposalDecisionResult(
      status: status,
      version: _proposalInt(json, 'version', nonNegative: true),
      proposal: ApprovalProposal.fromJson(_proposalMap(json['proposal'])),
      purchaseOrder: rawPurchaseOrder == null
          ? null
          : DemoPurchaseOrder.fromJson(_proposalMap(rawPurchaseOrder)),
    );
  }
}

List<T> _proposalList<T>(Map<String, dynamic> json, String key,
    T Function(Map<String, dynamic>) parse) {
  final value = json[key];
  if (value is! List) throw FormatException('Expected $key to be a list.');
  return List<T>.unmodifiable(value.map((item) => parse(_proposalMap(item))));
}

Map<String, dynamic> _proposalMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  throw const FormatException('Expected a proposal JSON object.');
}

String _proposalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Expected $key to be a non-empty string.');
  }
  return value;
}

String _proposalEnum(
    Map<String, dynamic> json, String key, Set<String> allowedValues) {
  final value = _proposalString(json, key);
  if (!allowedValues.contains(value)) {
    throw FormatException('Unexpected $key value: $value');
  }
  return value;
}

String? _proposalNullableString(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) throw FormatException('Expected $key to exist.');
  final value = json[key];
  if (value != null && value is! String) {
    throw FormatException('Expected $key to be a string or null.');
  }
  return value as String?;
}

bool _proposalBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('Expected $key to be a boolean.');
  return value;
}

int _proposalInt(Map<String, dynamic> json, String key,
    {bool nonNegative = false}) {
  final value = json[key];
  if (value is! int || (nonNegative && value < 0)) {
    throw FormatException('Expected $key to be an integer.');
  }
  return value;
}

num? _proposalNullableNumber(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) throw FormatException('Expected $key to exist.');
  final value = json[key];
  if (value != null && (value is! num || !value.isFinite)) {
    throw FormatException('Expected $key to be a finite number or null.');
  }
  return value as num?;
}

DateTime _proposalTimestamp(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('Expected $key to be a timestamp.');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('Invalid $key timestamp.');
  return parsed;
}

DateTime? _proposalNullableTimestamp(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) {
    throw FormatException('Expected $key to exist.');
  }
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('Expected $key to be a timestamp or null.');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('Invalid $key timestamp.');
  return parsed;
}

DateTime _proposalDate(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw FormatException('Expected $key in YYYY-MM-DD format.');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null || parsed.toIso8601String().substring(0, 10) != value) {
    throw FormatException('Invalid $key date.');
  }
  return parsed;
}
