/// Local-only synthetic `/state` payload for widget tests and development.
/// Production code never falls back to this fixture when a request fails.
const localDemoSnapshotJson = <String, dynamic>{
  'version': 7,
  'as_of_date': '2026-12-01',
  'data_mode': 'demo',
  'materials': [
    {
      'material_id': 'MAT-001',
      'name': 'Copper',
      'unit': 'units',
      'on_hand': 600,
      'incoming': 400,
      'allocated': 1000,
      'net_available': 0,
    },
    {
      'material_id': 'MAT-002',
      'name': 'Steel',
      'unit': 'kg',
      'on_hand': 200,
      'incoming': 0,
      'allocated': 300,
      'net_available': -100,
    },
    {
      'material_id': 'MAT-003',
      'name': 'Industrial resin',
      'unit': 'litres',
      'on_hand': 75,
      'incoming': 50,
      'allocated': 80,
      'net_available': 45,
    },
  ],
  'orders': [
    {
      'order_id': 'ORD-1042',
      'customer': 'Northstar Manufacturing',
      'priority': 'high',
      'crd': '2026-12-10',
      'material_ready_date': '2026-12-05',
      'projected_ship_date': '2026-12-07',
      'projected_delivery_date': '2026-12-08',
      'slack_days': 2,
      'risk': 'on_track',
      'shortages': [],
    },
    {
      'order_id': 'ORD-1043',
      'customer': 'Apex Components',
      'priority': 'medium',
      'crd': '2026-12-12',
      'material_ready_date': null,
      'projected_ship_date': null,
      'projected_delivery_date': null,
      'slack_days': null,
      'risk': 'at_risk',
      'shortages': [
        {
          'material_id': 'MAT-002',
          'required': 300,
          'available': 200,
          'shortage': 100,
        },
      ],
    },
    {
      'order_id': 'ORD-1044',
      'customer': 'Summit Industrial',
      'priority': 'high',
      'crd': '2026-12-15',
      'material_ready_date': null,
      'projected_ship_date': null,
      'projected_delivery_date': null,
      'slack_days': null,
      'risk': 'critical',
      'shortages': [
        {
          'material_id': 'MAT-002',
          'required': 220,
          'available': 140,
          'shortage': 80,
        },
      ],
    },
    {
      'order_id': 'ORD-1045',
      'customer': 'Meridian Works',
      'priority': 'low',
      'crd': '2026-12-18',
      'material_ready_date': '2026-12-16',
      'projected_ship_date': '2026-12-19',
      'projected_delivery_date': '2026-12-22',
      'slack_days': -4,
      'risk': 'delayed',
      'shortages': [],
    },
  ],
  'supply_lots': [
    {
      'lot_id': 'LOT-7001',
      'material_id': 'MAT-001',
      'supplier_id': 'SUP-01',
      'eta': '2026-12-08',
      'remaining_quantity': 400,
      'status': 'outstanding'
    },
    {
      'lot_id': 'LOT-7002',
      'material_id': 'MAT-002',
      'supplier_id': 'SUP-02',
      'eta': '2026-12-11',
      'remaining_quantity': 100,
      'status': 'outstanding'
    },
  ],
  'order_requirements': [
    {
      'order_id': 'ORD-1042',
      'material_id': 'MAT-001',
      'required_quantity': 1000
    },
    {
      'order_id': 'ORD-1043',
      'material_id': 'MAT-002',
      'required_quantity': 300
    },
    {
      'order_id': 'ORD-1044',
      'material_id': 'MAT-002',
      'required_quantity': 220
    },
  ],
  'recent_events': [
    {
      'event_id': 'evt-demo-1',
      'event_type': 'supplier_eta_update',
      'summary': 'Supplier ETA updated for LOT-7001',
      'version': 7,
      'recorded_at': '2026-12-01T10:30:00Z'
    },
  ],
  'alerts': [
    {
      'alert_id': 'alert-demo-1',
      'order_id': 'ORD-1043',
      'previous_risk': 'on_track',
      'new_risk': 'at_risk',
      'message': 'Material readiness is at risk due to a supply shortage.',
      'event_id': 'evt-demo-1',
      'version': 7
    },
  ],
};

const localRecommendationResponse = <String, dynamic>{
  'order_id': 'ORD-1043',
  'version': 7,
  'data_mode': 'demo',
  'recommendations': [
    {
      'recommendation_id': 'REC-EXPEDITE-7-1043',
      'action_type': 'expedite_existing_lot',
      'title': 'Expedite existing steel lot',
      'explanation': 'Move the existing supplier lot forward for evaluation.',
      'material_id': 'MAT-002',
      'supplier_id': 'SUP-02',
      'lot_id': 'LOT-7002',
      'quantity': 100,
      'proposed_eta': '2026-12-09',
      'estimated_incremental_cost': null,
      'currency': null,
      'assumptions': ['Supplier can meet the proposed ETA.'],
      'evidence': ['Current ETA is 11 Dec 2026.'],
    },
    {
      'recommendation_id': 'REC-ALT-7-1043',
      'action_type': 'alternate_supplier_po',
      'title': 'Evaluate alternate steel supplier',
      'explanation':
          'Model hypothetical incoming supply from an available source.',
      'material_id': 'MAT-002',
      'supplier_id': 'SUP-03',
      'lot_id': null,
      'quantity': 100,
      'proposed_eta': '2026-12-08',
      'estimated_incremental_cost': 42.5,
      'currency': 'USD',
      'assumptions': [
        'Alternate supplier capability is synthetic for demonstration.'
      ],
      'evidence': ['Backend supplier availability record.'],
    },
  ],
};

const localSimulationResponse = <String, dynamic>{
  'order_id': 'ORD-1043',
  'recommendation_id': 'REC-EXPEDITE-7-1043',
  'version': 7,
  'hypothetical': true,
  'before': {
    'projected_ship_date': null,
    'projected_delivery_date': null,
    'slack_days': null,
    'risk': 'at_risk',
  },
  'after': {
    'projected_ship_date': '2026-12-09',
    'projected_delivery_date': '2026-12-10',
    'slack_days': 2,
    'risk': 'on_track',
  },
  'affected_orders': [
    {
      'order_id': 'ORD-1044',
      'before': {
        'projected_ship_date': null,
        'projected_delivery_date': null,
        'slack_days': null,
        'risk': 'critical',
      },
      'after': {
        'projected_ship_date': '2026-12-15',
        'projected_delivery_date': '2026-12-16',
        'slack_days': -1,
        'risk': 'at_risk',
      },
    },
  ],
  'estimated_incremental_cost': null,
  'currency': null,
  'assumptions': ['Receipt timing remains hypothetical.'],
  'warnings': ['Other orders may be affected by shared material allocation.'],
};
