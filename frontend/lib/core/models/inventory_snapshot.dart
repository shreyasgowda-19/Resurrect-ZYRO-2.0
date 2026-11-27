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
  });

  final String materialId;
  final String name;
  final String unit;
  final int onHand;
  final int incoming;
  final int allocated;
  final int netAvailable;

  factory MaterialInventory.fromJson(Map<String, dynamic> json) =>
      MaterialInventory(
        materialId: _requiredString(json, 'material_id'),
        name: _requiredString(json, 'name'),
        unit: _requiredString(json, 'unit'),
        onHand: _requiredInt(json, 'on_hand', nonNegative: true),
        incoming: _requiredInt(json, 'incoming', nonNegative: true),
        allocated: _requiredInt(json, 'allocated', nonNegative: true),
        netAvailable: _requiredInt(json, 'net_available'),
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

class InventorySnapshot {
  const InventorySnapshot({
    required this.version,
    required this.asOfDate,
    required this.dataMode,
    required this.materials,
    required this.orders,
  });

  final int version;
  final DateTime asOfDate;
  final String dataMode;
  final List<MaterialInventory> materials;
  final List<CustomerOrder> orders;

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
    );
  }
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
