enum OrderPriority { high, medium, low }

enum OrderRisk {
  onTrack('on_track', 'On track'),
  atRisk('at_risk', 'At risk'),
  critical('critical', 'Critical'),
  delayed('delayed', 'Delayed');

  const OrderRisk(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static OrderRisk parse(Object? value) {
    if (value is! String) throw const FormatException('Invalid order risk.');
    return OrderRisk.values.firstWhere(
      (risk) => risk.wireValue == value,
      orElse: () => throw FormatException('Unknown order risk: $value'),
    );
  }
}

class MaterialInventory {
  const MaterialInventory({
    required this.materialId,
    required this.name,
    required this.unit,
    required this.onHand,
    required this.incoming,
    required this.allocated,
    required this.netAvailable,
    this.reorderThreshold = 0,
    this.description,
  });

  final String materialId;
  final String name;
  final String unit;
  final int onHand;
  final int incoming;
  final int allocated;
  final int netAvailable;
  final int reorderThreshold;
  final String? description;

  factory MaterialInventory.fromJson(Map<String, dynamic> json) =>
      MaterialInventory(
        materialId: _requiredString(json, 'material_id'),
        name: _requiredString(json, 'name'),
        unit: _requiredString(json, 'unit'),
        onHand: _requiredInt(json, 'on_hand', nonNegative: true),
        incoming: _requiredInt(json, 'incoming', nonNegative: true),
        allocated: _requiredInt(json, 'allocated', nonNegative: true),
        netAvailable: _requiredInt(json, 'net_available'),
        reorderThreshold: json.containsKey('reorder_threshold')
            ? _requiredInt(json, 'reorder_threshold', nonNegative: true)
            : 0,
        description: json['description'] == null
            ? null
            : (json['description'] is String
                ? json['description'] as String
                : throw const FormatException('Invalid material description.')),
      );
}

class MaterialShortage {
  const MaterialShortage({
    required this.materialId,
    required this.required,
    required this.available,
    required this.shortage,
  });

  final String materialId;
  final int required;
  final int available;
  final int shortage;

  factory MaterialShortage.fromJson(Map<String, dynamic> json) =>
      MaterialShortage(
        materialId: _requiredString(json, 'material_id'),
        required: _requiredInt(json, 'required', nonNegative: true),
        available: _requiredInt(json, 'available', nonNegative: true),
        shortage: _requiredInt(json, 'shortage', nonNegative: true),
      );
}

class CustomerOrder {
  const CustomerOrder({
    required this.orderId,
    required this.customer,
    required this.priority,
    required this.crd,
    required this.materialReadyDate,
    required this.projectedShipDate,
    required this.projectedDeliveryDate,
    required this.slackDays,
    required this.risk,
    required this.shortages,
  });

  final String orderId;
  final String customer;
  final OrderPriority priority;
  final DateTime? crd;
  final DateTime? materialReadyDate;
  final DateTime? projectedShipDate;
  final DateTime? projectedDeliveryDate;
  final int? slackDays;
  final OrderRisk risk;
  final List<MaterialShortage> shortages;

  factory CustomerOrder.fromJson(Map<String, dynamic> json) {
    final priorityValue = _requiredString(json, 'priority');
    final priority = switch (priorityValue) {
      'high' => OrderPriority.high,
      'medium' => OrderPriority.medium,
      'low' => OrderPriority.low,
      _ => throw FormatException('Unknown order priority: $priorityValue'),
    };
    final rawShortages = json['shortages'];
    if (rawShortages is! List) {
      throw const FormatException('Expected shortages to be a list.');
    }
    if (!json.containsKey('slack_days')) {
      throw const FormatException('Expected slack_days to be present.');
    }
    final slackValue = json['slack_days'];
    if (slackValue != null && slackValue is! int) {
      throw const FormatException(
          'Expected slack_days to be an integer or null.');
    }
    return CustomerOrder(
      orderId: _requiredString(json, 'order_id'),
      customer: _requiredString(json, 'customer'),
      priority: priority,
      crd: _optionalDate(json, 'crd'),
      materialReadyDate: _optionalDate(json, 'material_ready_date'),
      projectedShipDate: _optionalDate(json, 'projected_ship_date'),
      projectedDeliveryDate: _optionalDate(json, 'projected_delivery_date'),
      slackDays: slackValue as int?,
      risk: OrderRisk.parse(json['risk']),
      shortages: List<MaterialShortage>.unmodifiable(
        rawShortages.map((entry) => MaterialShortage.fromJson(_asMap(entry))),
      ),
    );
  }
}

class SupplyLot {
  const SupplyLot(
      {required this.lotId,
      required this.materialId,
      required this.supplierId,
      required this.eta,
      required this.remainingQuantity,
      required this.status});
  final String lotId;
  final String materialId;
  final String supplierId;
  final DateTime? eta;
  final int remainingQuantity;
  final String status;
  factory SupplyLot.fromJson(Map<String, dynamic> json) => SupplyLot(
      lotId: _requiredString(json, 'lot_id'),
      materialId: _requiredString(json, 'material_id'),
      supplierId: _requiredString(json, 'supplier_id'),
      eta: _optionalDate(json, 'eta'),
      remainingQuantity:
          _requiredInt(json, 'remaining_quantity', nonNegative: true),
      status: _requiredString(json, 'status'));
}

class OrderRequirement {
  const OrderRequirement(
      {required this.orderId,
      required this.materialId,
      required this.requiredQuantity});
  final String orderId;
  final String materialId;
  final int requiredQuantity;
  factory OrderRequirement.fromJson(Map<String, dynamic> json) =>
      OrderRequirement(
          orderId: _requiredString(json, 'order_id'),
          materialId: _requiredString(json, 'material_id'),
          requiredQuantity:
              _requiredInt(json, 'required_quantity', nonNegative: true));
}

class ManufacturingEvent {
  const ManufacturingEvent(
      {required this.eventId,
      required this.eventType,
      required this.summary,
      required this.version,
      required this.recordedAt});
  final String eventId;
  final String eventType;
  final String summary;
  final int version;
  final DateTime recordedAt;
  factory ManufacturingEvent.fromJson(Map<String, dynamic> json) =>
      ManufacturingEvent(
          eventId: _requiredString(json, 'event_id'),
          eventType: _requiredString(json, 'event_type'),
          summary: _requiredString(json, 'summary'),
          version: _requiredInt(json, 'version', nonNegative: true),
          recordedAt: _requiredDateTime(json, 'recorded_at'));
}

class RiskAlert {
  const RiskAlert(
      {required this.alertId,
      required this.orderId,
      required this.previousRisk,
      required this.newRisk,
      required this.message,
      required this.eventId,
      required this.version});
  final String alertId;
  final String orderId;
  final OrderRisk previousRisk;
  final OrderRisk newRisk;
  final String message;
  final String eventId;
  final int version;
  factory RiskAlert.fromJson(Map<String, dynamic> json) => RiskAlert(
      alertId: _requiredString(json, 'alert_id'),
      orderId: _requiredString(json, 'order_id'),
      previousRisk: OrderRisk.parse(json['previous_risk']),
      newRisk: OrderRisk.parse(json['new_risk']),
      message: _requiredString(json, 'message'),
      eventId: _requiredString(json, 'event_id'),
      version: _requiredInt(json, 'version', nonNegative: true));
}

class InventorySnapshot {
  const InventorySnapshot({
    required this.version,
    required this.asOfDate,
    required this.dataMode,
    required this.materials,
    required this.orders,
    this.supplyLots = const [],
    this.orderRequirements = const [],
    this.recentEvents = const [],
    this.alerts = const [],
  });

  final int version;
  final DateTime asOfDate;
  final String dataMode;
  final List<MaterialInventory> materials;
  final List<CustomerOrder> orders;
  final List<SupplyLot> supplyLots;
  final List<OrderRequirement> orderRequirements;
  final List<ManufacturingEvent> recentEvents;
  final List<RiskAlert> alerts;

  int get totalOrders => orders.length;
  int get onTrackOrders =>
      orders.where((order) => order.risk == OrderRisk.onTrack).length;
  int get atRiskOrders =>
      orders.where((order) => order.risk == OrderRisk.atRisk).length;
  int get criticalOrders =>
      orders.where((order) => order.risk == OrderRisk.critical).length;
  int get delayedOrders =>
      orders.where((order) => order.risk == OrderRisk.delayed).length;
  int get materialsWithShortages => orders
      .expand((order) => order.shortages)
      .map((shortage) => shortage.materialId)
      .toSet()
      .length;

  factory InventorySnapshot.fromJson(Map<String, dynamic> json) {
    final rawVersion = json['version'];
    if (rawVersion is! int || rawVersion < 1) {
      throw const FormatException('Expected a positive snapshot version.');
    }
    final rawMaterials = json['materials'];
    final rawOrders = json['orders'];
    if (rawMaterials is! List || rawOrders is! List) {
      throw const FormatException('Expected materials and orders lists.');
    }
    final dataMode = _requiredString(json, 'data_mode');
    return InventorySnapshot(
      version: rawVersion,
      asOfDate: _requiredDate(json, 'as_of_date'),
      dataMode: dataMode,
      materials: List<MaterialInventory>.unmodifiable(
        rawMaterials.map((entry) => MaterialInventory.fromJson(_asMap(entry))),
      ),
      orders: List<CustomerOrder>.unmodifiable(
        rawOrders.map((entry) => CustomerOrder.fromJson(_asMap(entry))),
      ),
      supplyLots: _requiredList(json, 'supply_lots', SupplyLot.fromJson),
      orderRequirements:
          _requiredList(json, 'order_requirements', OrderRequirement.fromJson),
      recentEvents:
          _requiredList(json, 'recent_events', ManufacturingEvent.fromJson),
      alerts: _requiredList(json, 'alerts', RiskAlert.fromJson),
    );
  }
}

List<T> _requiredList<T>(Map<String, dynamic> json, String key,
    T Function(Map<String, dynamic>) parse) {
  final value = json[key];
  if (value is! List) throw FormatException('Expected $key to be a list.');
  return List<T>.unmodifiable(value.map((entry) => parse(_asMap(entry))));
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  throw const FormatException('Expected an object in snapshot data.');
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Expected $key to be a non-empty string.');
  }
  return value;
}

int _requiredInt(Map<String, dynamic> json, String key,
    {bool nonNegative = false}) {
  final value = json[key];
  if (value is! int || (nonNegative && value < 0)) {
    throw FormatException(
        'Expected $key to be an integer${nonNegative ? ' >= 0' : ''}.');
  }
  return value;
}

DateTime _requiredDate(Map<String, dynamic> json, String key) {
  final value = json[key];
  final parsed = _parseDate(value, key);
  if (parsed == null) throw FormatException('Expected $key to be a date.');
  return parsed;
}

DateTime? _optionalDate(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) {
    throw FormatException('Expected $key to be present.');
  }
  final value = json[key];
  if (value == null) return null;
  return _parseDate(value, key);
}

DateTime? _parseDate(Object? value, String key) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw FormatException('Expected $key in YYYY-MM-DD format or null.');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null || parsed.toIso8601String().substring(0, 10) != value) {
    throw FormatException('Invalid date for $key.');
  }
  return parsed;
}

DateTime _requiredDateTime(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('Expected $key to be a timestamp.');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('Invalid timestamp for $key.');
  return parsed;
}
