import 'inventory_snapshot.dart';

enum RecommendationAction {
  expediteExistingLot('expedite_existing_lot'),
  alternateSupplierPo('alternate_supplier_po');

  const RecommendationAction(this.wireValue);
  final String wireValue;

  static RecommendationAction parse(Object? value) {
    if (value is! String) {
      throw const FormatException('Invalid recommendation action type.');
    }
    return RecommendationAction.values.firstWhere(
      (action) => action.wireValue == value,
      orElse: () =>
          throw FormatException('Unknown recommendation action: $value'),
    );
  }
}

class InventoryRecommendation {
  const InventoryRecommendation({
    required this.recommendationId,
    required this.actionType,
    required this.title,
    required this.explanation,
    required this.materialId,
    required this.supplierId,
    required this.lotId,
    required this.quantity,
    required this.proposedEta,
    required this.estimatedIncrementalCost,
    required this.currency,
    required this.assumptions,
    required this.evidence,
  });

  final String recommendationId;
  final RecommendationAction actionType;
  final String title;
  final String explanation;
  final String materialId;
  final String supplierId;
  final String? lotId;
  final int quantity;
  final DateTime proposedEta;
  final num? estimatedIncrementalCost;
  final String? currency;
  final List<String> assumptions;
  final List<String> evidence;

  factory InventoryRecommendation.fromJson(Map<String, dynamic> json) =>
      InventoryRecommendation(
        recommendationId: _recommendationString(json, 'recommendation_id'),
        actionType: RecommendationAction.parse(json['action_type']),
        title: _recommendationString(json, 'title'),
        explanation: _recommendationString(json, 'explanation'),
        materialId: _recommendationString(json, 'material_id'),
        supplierId: _recommendationString(json, 'supplier_id'),
        lotId: _nullableString(json, 'lot_id'),
        quantity: _recommendationInt(json, 'quantity', nonNegative: true),
        proposedEta: _recommendationDate(json, 'proposed_eta'),
        estimatedIncrementalCost:
            _nullableNumber(json, 'estimated_incremental_cost'),
        currency: _nullableString(json, 'currency'),
        assumptions: _stringList(json, 'assumptions'),
        evidence: _stringList(json, 'evidence'),
      );
}

class RecommendationResult {
  const RecommendationResult({
    required this.orderId,
    required this.version,
    required this.dataMode,
    required this.recommendations,
  });

  final String orderId;
  final int version;
  final String dataMode;
  final List<InventoryRecommendation> recommendations;

  factory RecommendationResult.fromJson(Map<String, dynamic> json) =>
      RecommendationResult(
        orderId: _recommendationString(json, 'order_id'),
        version: _recommendationInt(json, 'version', nonNegative: true),
        dataMode: _recommendationString(json, 'data_mode'),
        recommendations: List<InventoryRecommendation>.unmodifiable(
          _recommendationList(json, 'recommendations').map((entry) =>
              InventoryRecommendation.fromJson(_recommendationMap(entry))),
        ),
      );
}

class OrderOutcome {
  const OrderOutcome({
    required this.projectedShipDate,
    required this.projectedDeliveryDate,
    required this.slackDays,
    required this.risk,
  });

  final DateTime? projectedShipDate;
  final DateTime? projectedDeliveryDate;
  final int? slackDays;
  final OrderRisk risk;

  factory OrderOutcome.fromJson(Map<String, dynamic> json) {
    final rawSlack = json['slack_days'];
    if (!json.containsKey('slack_days') ||
        (rawSlack != null && rawSlack is! int)) {
      throw const FormatException(
          'Expected slack_days to be an integer or null.');
    }
    return OrderOutcome(
      projectedShipDate: _nullableDate(json, 'projected_ship_date'),
      projectedDeliveryDate: _nullableDate(json, 'projected_delivery_date'),
      slackDays: rawSlack as int?,
      risk: OrderRisk.parse(json['risk']),
    );
  }
}

class AffectedOrderOutcome {
  const AffectedOrderOutcome({
    required this.orderId,
    required this.before,
    required this.after,
  });

  final String orderId;
  final OrderOutcome before;
  final OrderOutcome after;

  factory AffectedOrderOutcome.fromJson(Map<String, dynamic> json) =>
      AffectedOrderOutcome(
        orderId: _recommendationString(json, 'order_id'),
        before: OrderOutcome.fromJson(_recommendationMap(json['before'])),
        after: OrderOutcome.fromJson(_recommendationMap(json['after'])),
      );
}

class SimulationResult {
  const SimulationResult({
    required this.orderId,
    required this.recommendationId,
    required this.version,
    required this.hypothetical,
    required this.before,
    required this.after,
    required this.affectedOrders,
    required this.estimatedIncrementalCost,
    required this.currency,
    required this.assumptions,
    required this.warnings,
  });

  final String orderId;
  final String recommendationId;
  final int version;
  final bool hypothetical;
  final OrderOutcome before;
  final OrderOutcome after;
  final List<AffectedOrderOutcome> affectedOrders;
  final num? estimatedIncrementalCost;
  final String? currency;
  final List<String> assumptions;
  final List<String> warnings;

  factory SimulationResult.fromJson(Map<String, dynamic> json) {
    if (json['hypothetical'] != true) {
      throw const FormatException(
          'Simulation must be explicitly hypothetical.');
    }
    return SimulationResult(
      orderId: _recommendationString(json, 'order_id'),
      recommendationId: _recommendationString(json, 'recommendation_id'),
      version: _recommendationInt(json, 'version', nonNegative: true),
      hypothetical: true,
      before: OrderOutcome.fromJson(_recommendationMap(json['before'])),
      after: OrderOutcome.fromJson(_recommendationMap(json['after'])),
      affectedOrders: List<AffectedOrderOutcome>.unmodifiable(
        _recommendationList(json, 'affected_orders').map(
            (item) => AffectedOrderOutcome.fromJson(_recommendationMap(item))),
      ),
      estimatedIncrementalCost:
          _nullableNumber(json, 'estimated_incremental_cost'),
      currency: _nullableString(json, 'currency'),
      assumptions: _stringList(json, 'assumptions'),
      warnings: _stringList(json, 'warnings'),
    );
  }
}

String _recommendationString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Expected $key to be a non-empty string.');
  }
  return value;
}

String? _nullableString(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) {
    throw FormatException('Expected $key to be present.');
  }
  final value = json[key];
  if (value != null && value is! String) {
    throw FormatException('Expected $key to be a string or null.');
  }
  return value as String?;
}

num? _nullableNumber(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) {
    throw FormatException('Expected $key to be present.');
  }
  final value = json[key];
  if (value != null && (value is! num || !value.isFinite)) {
    throw FormatException('Expected $key to be a finite number or null.');
  }
  return value as num?;
}

int _recommendationInt(Map<String, dynamic> json, String key,
    {bool nonNegative = false}) {
  final value = json[key];
  if (value is! int || (nonNegative && value < 0)) {
    throw FormatException('Expected $key to be an integer.');
  }
  return value;
}

DateTime _recommendationDate(Map<String, dynamic> json, String key) {
  final value = json[key];
  final date = _parseRecommendationDate(value, key);
  if (date == null) throw FormatException('Expected $key to be a date.');
  return date;
}

DateTime? _nullableDate(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) {
    throw FormatException('Expected $key to be present.');
  }
  final value = json[key];
  if (value == null) return null;
  return _parseRecommendationDate(value, key);
}

DateTime? _parseRecommendationDate(Object? value, String key) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw FormatException('Expected $key in YYYY-MM-DD format or null.');
  }
  final date = DateTime.tryParse(value);
  if (date == null || date.toIso8601String().substring(0, 10) != value) {
    throw FormatException('Invalid $key date.');
  }
  return date;
}

List<Object?> _recommendationList(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List) throw FormatException('Expected $key to be a list.');
  return value.cast<Object?>();
}

List<String> _stringList(Map<String, dynamic> json, String key) {
  final values = _recommendationList(json, key);
  if (values.any((value) => value is! String)) {
    throw FormatException('Expected $key to contain only strings.');
  }
  return List<String>.unmodifiable(values.cast<String>());
}

Map<String, dynamic> _recommendationMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  throw const FormatException('Expected a JSON object.');
}
