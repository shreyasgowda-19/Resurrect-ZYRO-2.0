import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/models/inventory_snapshot.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.email,
    required this.role,
    required this.getIdToken,
    this.apiClient,
    this.onSignOut,
  });

  final String email;
  final String role;
  final Future<String> Function() getIdToken;
  final ApiClient? apiClient;
  final VoidCallback? onSignOut;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _overviewKey = GlobalKey();
  final _materialsKey = GlobalKey();
  final _ordersKey = GlobalKey();
  late final ApiClient _apiClient;
  late final bool _ownsApiClient;

  InventorySnapshot? _snapshot;
  StateApiException? _error;
  bool _loading = true;
  bool _checkingBackend = false;
  bool? _backendConnected;
  String _materialQuery = '';
  String _orderQuery = '';
  OrderRisk? _riskFilter;
  String? _selectedOrderId;
  String _selectedSection = 'overview';

  @override
  void initState() {
    super.initState();
    _ownsApiClient = widget.apiClient == null;
    _apiClient = widget.apiClient ?? ApiClient();
    _refresh();
  }

  @override
  void dispose() {
    if (_ownsApiClient) _apiClient.close();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await Future.wait([_loadSnapshot(), _checkBackend()]);
  }

  Future<void> _loadSnapshot() async {
    try {
      final token = await widget.getIdToken();
      final snapshot = await _apiClient.getState(idToken: token);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _selectedOrderId = null;
        _error = null;
        _loading = false;
      });
    } on StateApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = const StateApiException(StateApiFailure.backendError);
        _loading = false;
      });
    }
  }

  Future<void> _checkBackend() async {
    if (mounted) setState(() => _checkingBackend = true);
    final connected = await _apiClient.checkHealth();
    if (!mounted) return;
    setState(() {
      _checkingBackend = false;
      _backendConnected = connected;
    });
  }

  Future<void> _selectSection(String section) async {
    setState(() => _selectedSection = section);
    if (_scaffoldKey.currentState?.isDrawerOpen == true) {
      Navigator.of(context).pop();
    }
    final key = switch (section) {
      'materials' => _materialsKey,
      'orders' => _ordersKey,
      _ => _overviewKey,
    };
    await WidgetsBinding.instance.endOfFrame;
    final targetContext = key.currentContext;
    if (targetContext != null && targetContext.mounted) {
      unawaited(Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 180),
        alignment: 0.02,
      ));
    }
  }

  String _errorMessage(StateApiException error) => switch (error.failure) {
        StateApiFailure.unauthorized =>
          'Your sign-in session was rejected. Sign out and authenticate again.',
        StateApiFailure.forbidden =>
          'Your verified account is not authorized for the inventory dashboard.',
        StateApiFailure.unavailable =>
          'The backend reports that a required inventory service is unavailable.',
        StateApiFailure.connectivity =>
          'Could not connect to the inventory backend. Check the API address and network.',
        StateApiFailure.timeout =>
          'The inventory request timed out. The backend may be busy; try again.',
        StateApiFailure.malformedResponse =>
          'The backend returned inventory data that does not match the approved contract.',
        StateApiFailure.backendError =>
          'The backend could not return the inventory snapshot. Try again later.',
      };

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final desktop = width >= 980;
    final navigation = _navigation();
    return Scaffold(
      key: _scaffoldKey,
      drawer: desktop ? null : Drawer(child: navigation),
      body: SafeArea(
        child: Row(
          children: [
            if (desktop) SizedBox(width: 236, child: navigation),
            Expanded(
              child: Column(
                children: [
                  _topBar(context, desktop: desktop),
                  Expanded(child: _dashboardBody(context)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _navigation() => Container(
        color: const Color(0xFF15161A),
        padding: const EdgeInsets.fromLTRB(18, 24, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF4D8DFF), Color(0xFF9B78FF)],
                  ),
                ),
                child: const Icon(Icons.auto_awesome,
                    color: Colors.white, size: 20),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('ZYRO',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              ),
            ]),
            const SizedBox(height: 5),
            const Padding(
              padding: EdgeInsets.only(left: 48),
              child: Text('INVENTORY INTELLIGENCE',
                  style: TextStyle(
                      fontSize: 9,
                      letterSpacing: 1.1,
                      color: Color(0xFF9B9CA5))),
            ),
            const SizedBox(height: 36),
            _navItem('overview', Icons.dashboard_outlined, 'Overview'),
            _navItem('materials', Icons.inventory_2_outlined, 'Materials'),
            _navItem(
                'orders', Icons.local_shipping_outlined, 'Customer orders'),
            const Spacer(),
            const Divider(color: Color(0xFF303137)),
            Text(widget.email,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 5),
            Text('${_titleCase(widget.role)} access',
                style: const TextStyle(color: Color(0xFFB5B6BE), fontSize: 12)),
            if (widget.onSignOut != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: widget.onSignOut,
                  icon: const Icon(Icons.logout, size: 17),
                  label: const Text('Sign out'),
                ),
              ),
          ],
        ),
      );

  Widget _navItem(String key, IconData icon, String label) {
    final active = _selectedSection == key;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: active ? const Color(0xFF252631) : Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: () => _selectSection(key),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(children: [
              Icon(icon,
                  size: 19,
                  color: active
                      ? const Color(0xFF9B78FF)
                      : const Color(0xFF9B9CA5)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: active ? Colors.white : const Color(0xFFB5B6BE),
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context, {required bool desktop}) {
    final snapshot = _snapshot;
    final mode = snapshot == null
        ? 'Waiting for snapshot'
        : snapshot.dataMode.toLowerCase() == 'demo'
            ? 'DEMO DATA'
            : '${snapshot.dataMode.toUpperCase()} DATA';
    return Container(
      padding:
          EdgeInsets.fromLTRB(desktop ? 32 : 16, 18, desktop ? 32 : 16, 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF292A30))),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (!desktop) ...[
            IconButton(
              key: const Key('dashboard-menu-button'),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              icon: const Icon(Icons.menu),
              tooltip: 'Open navigation',
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Inventory dashboard',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(
                snapshot == null
                    ? 'Human-AI Collaborative Smart Inventory Intelligence'
                    : 'Snapshot v${snapshot.version} · As of ${_formatDate(snapshot.asOfDate)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: const Color(0xFF9B9CA5)),
              ),
            ]),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            key: const Key('dashboard-refresh-button'),
            onPressed: _loading ? null : _refresh,
            icon: _loading
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh, size: 18),
            label: Text(desktop ? 'Refresh snapshot' : 'Refresh'),
          ),
        ]),
        const SizedBox(height: 13),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _MetadataChip(
            icon: _backendConnected == true
                ? Icons.cloud_done_outlined
                : _backendConnected == false
                    ? Icons.cloud_off_outlined
                    : Icons.cloud_sync_outlined,
            label: _checkingBackend
                ? 'Backend checking'
                : _backendConnected == true
                    ? 'Backend connected'
                    : _backendConnected == false
                        ? 'Backend unavailable'
                        : 'Backend unchecked',
            color: _backendConnected == true
                ? const Color(0xFF54D39A)
                : _backendConnected == false
                    ? const Color(0xFFFF7777)
                    : const Color(0xFFB5B6BE),
          ),
          _MetadataChip(
            icon: snapshot?.dataMode.toLowerCase() == 'demo'
                ? Icons.science_outlined
                : Icons.storage_outlined,
            label: mode,
            color: snapshot?.dataMode.toLowerCase() == 'demo'
                ? const Color(0xFFFFC266)
                : const Color(0xFF9B9CA5),
          ),
          if (snapshot != null)
            _MetadataChip(
              icon: Icons.tag,
              label: 'Version ${snapshot.version}',
              color: const Color(0xFFB5B6BE),
            ),
          Text('${_titleCase(widget.role)} · ${widget.email}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFFB5B6BE))),
        ]),
      ]),
    );
  }

  Widget _dashboardBody(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final horizontalPadding = constraints.maxWidth < 600 ? 16.0 : 30.0;
          final contentWidth = (constraints.maxWidth - horizontalPadding * 2)
              .clamp(0.0, 1500.0)
              .toDouble();
          return SingleChildScrollView(
            key: const Key('dashboard-main-scroll'),
            padding: EdgeInsets.fromLTRB(
                horizontalPadding, 24, horizontalPadding, 40),
            child: Center(
              child: SizedBox(
                width: contentWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_loading)
                      const _LoadingPanel()
                    else if (_error != null)
                      _ErrorPanel(
                        message: _errorMessage(_error!),
                        onRetry: _refresh,
                        onSignOut:
                            _error!.failure == StateApiFailure.unauthorized ||
                                    _error!.failure == StateApiFailure.forbidden
                                ? widget.onSignOut
                                : null,
                      )
                    else if (_snapshot != null) ...[
                      if (_snapshot!.materials.isEmpty &&
                          _snapshot!.orders.isEmpty)
                        const _EmptySnapshotPanel()
                      else ...[
                        _sectionHeading(
                          _overviewKey,
                          'Overview',
                          'Customer delivery exposure and material availability from the current backend snapshot.',
                        ),
                        const SizedBox(height: 14),
                        _overviewCards(_snapshot!),
                        const SizedBox(height: 30),
                        _sectionHeading(
                          _materialsKey,
                          'Material inventory',
                          'Physical stock and expected receipts are shown separately. Net availability is provided by the backend.',
                        ),
                        const SizedBox(height: 14),
                        _materialTable(_snapshot!),
                        const SizedBox(height: 30),
                        _sectionHeading(
                          _ordersKey,
                          'Customer orders',
                          'Readiness, projected dates and risk status come directly from the backend snapshot.',
                        ),
                        const SizedBox(height: 14),
                        _orderControls(contentWidth),
                        const SizedBox(height: 12),
                        _orderTable(_snapshot!, contentWidth),
                        if (_selectedOrderId != null) ...[
                          const SizedBox(height: 18),
                          _shortageDetails(_snapshot!),
                        ],
                      ],
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      );

  Widget _sectionHeading(GlobalKey key, String title, String subtitle) =>
      Container(
        key: key,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 5),
          Text(subtitle,
              style: const TextStyle(
                  color: Color(0xFF9B9CA5), fontSize: 13, height: 1.4)),
        ]),
      );

  Widget _overviewCards(InventorySnapshot snapshot) => LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final columns = width >= 1320
              ? 6
              : width >= 850
                  ? 3
                  : width >= 500
                      ? 2
                      : 1;
          final tileHeight = width < 500 ? 92.0 : 104.0;
          final cards = <_OverviewCardData>[
            _OverviewCardData(
                'Customer orders',
                '${snapshot.totalOrders}',
                Icons.assignment_outlined,
                const Color(0xFFB5B6BE),
                'overview-total-orders'),
            _OverviewCardData(
                'On track',
                '${snapshot.onTrackOrders}',
                Icons.check_circle_outline,
                _riskColor(OrderRisk.onTrack),
                'overview-on-track'),
            _OverviewCardData(
                'At risk',
                '${snapshot.atRiskOrders}',
                Icons.warning_amber_outlined,
                _riskColor(OrderRisk.atRisk),
                'overview-at-risk'),
            _OverviewCardData(
                'Critical',
                '${snapshot.criticalOrders}',
                Icons.error_outline,
                _riskColor(OrderRisk.critical),
                'overview-critical'),
            _OverviewCardData(
                'Delayed',
                '${snapshot.delayedOrders}',
                Icons.schedule_outlined,
                _riskColor(OrderRisk.delayed),
                'overview-delayed'),
            _OverviewCardData(
                'Materials with shortages',
                '${snapshot.materialsWithShortages}',
                Icons.inventory_2_outlined,
                const Color(0xFFFF7777),
                'overview-material-shortages'),
          ];
          return GridView.builder(
            key: const Key('overview-cards-grid'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              mainAxisExtent: tileHeight,
            ),
            itemCount: cards.length,
            itemBuilder: (context, index) => _OverviewCard(data: cards[index]),
          );
        },
      );

  Widget _materialTable(InventorySnapshot snapshot) {
    final query = _materialQuery.trim().toLowerCase();
    final rows = snapshot.materials.where((material) {
      return query.isEmpty ||
          material.materialId.toLowerCase().contains(query) ||
          material.name.toLowerCase().contains(query) ||
          material.unit.toLowerCase().contains(query);
    }).toList();
    return _SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          key: const Key('material-search'),
          onChanged: (value) => setState(() => _materialQuery = value),
          decoration: const InputDecoration(
            hintText: 'Search material ID, name or unit',
            prefixIcon: Icon(Icons.search),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        if (rows.isEmpty)
          const _InlineEmpty(message: 'No materials match this search.')
        else
          SingleChildScrollView(
            key: const Key('materials-horizontal-scroll'),
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Material ID')),
                DataColumn(label: Text('Material name')),
                DataColumn(label: Text('Unit')),
                DataColumn(label: Text('On hand\n(physical)'), numeric: true),
                DataColumn(label: Text('Incoming\n(expected)'), numeric: true),
                DataColumn(label: Text('Allocated'), numeric: true),
                DataColumn(label: Text('Net available'), numeric: true),
              ],
              rows: [
                for (final material in rows)
                  DataRow(cells: [
                    DataCell(Text(material.materialId)),
                    DataCell(Text(material.name)),
                    DataCell(Text(material.unit)),
                    DataCell(Text('${material.onHand}')),
                    DataCell(Text('${material.incoming}',
                        style: const TextStyle(color: Color(0xFF9B9CA5)))),
                    DataCell(Text('${material.allocated}')),
                    DataCell(Text('${material.netAvailable}',
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: material.netAvailable < 0
                                ? const Color(0xFFFF7777)
                                : Theme.of(context).colorScheme.onSurface))),
                  ]),
              ],
            ),
          ),
      ]),
    );
  }

  Widget _orderControls(double width) => Wrap(
        spacing: 12,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: width < 600 ? width : 320,
            child: TextField(
              key: const Key('order-search'),
              onChanged: (value) => setState(() => _orderQuery = value),
              decoration: const InputDecoration(
                hintText: 'Search order or customer',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
            ),
          ),
          DropdownButton<OrderRisk?>(
            key: const Key('risk-filter-dropdown'),
            value: _riskFilter,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(12),
            dropdownColor: const Color(0xFF24252B),
            items: [
              const DropdownMenuItem<OrderRisk?>(
                  value: null, child: Text('All risk statuses')),
              for (final risk in OrderRisk.values)
                DropdownMenuItem<OrderRisk?>(
                    value: risk, child: Text(risk.label)),
            ],
            onChanged: (value) => setState(() => _riskFilter = value),
          ),
        ],
      );

  Widget _orderTable(InventorySnapshot snapshot, double width) {
    final query = _orderQuery.trim().toLowerCase();
    final rows = snapshot.orders.where((order) {
      final matchesQuery = query.isEmpty ||
          order.orderId.toLowerCase().contains(query) ||
          order.customer.toLowerCase().contains(query);
      return matchesQuery && (_riskFilter == null || order.risk == _riskFilter);
    }).toList();
    if (rows.isEmpty) {
      return const _SectionCard(
          child:
              _InlineEmpty(message: 'No customer orders match these filters.'));
    }
    if (width < 850) {
      return Column(children: [
        for (final order in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _OrderSummaryCard(
              order: order,
              selected: _selectedOrderId == order.orderId,
              onTap: () => setState(() => _selectedOrderId = order.orderId),
            ),
          ),
      ]);
    }
    return _SectionCard(
      padding: EdgeInsets.zero,
      child: SingleChildScrollView(
        key: const Key('orders-horizontal-scroll'),
        scrollDirection: Axis.horizontal,
        child: DataTable(
          showCheckboxColumn: false,
          columns: const [
            DataColumn(label: Text('Order ID')),
            DataColumn(label: Text('Customer')),
            DataColumn(label: Text('Priority')),
            DataColumn(label: Text('Customer request')),
            DataColumn(label: Text('Material ready')),
            DataColumn(label: Text('Projected ship')),
            DataColumn(label: Text('Projected delivery')),
            DataColumn(label: Text('Slack')),
            DataColumn(label: Text('Risk status')),
          ],
          rows: [
            for (final order in rows)
              DataRow(
                selected: _selectedOrderId == order.orderId,
                onSelectChanged: (_) =>
                    setState(() => _selectedOrderId = order.orderId),
                cells: [
                  DataCell(Text(order.orderId,
                      style: const TextStyle(fontWeight: FontWeight.w700))),
                  DataCell(Text(order.customer)),
                  DataCell(Text(_titleCase(order.priority.name))),
                  DataCell(
                      Text(_displayDate(order.crd, fallback: 'Not provided'))),
                  DataCell(Text(_displayDate(order.materialReadyDate))),
                  DataCell(Text(_displayDate(order.projectedShipDate))),
                  DataCell(Text(_displayDate(order.projectedDeliveryDate))),
                  DataCell(Text(order.slackDays == null
                      ? 'Unavailable'
                      : '${order.slackDays} days')),
                  DataCell(_RiskPill(risk: order.risk)),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _shortageDetails(InventorySnapshot snapshot) {
    final selected = snapshot.orders.cast<CustomerOrder?>().firstWhere(
          (order) => order?.orderId == _selectedOrderId,
          orElse: () => null,
        );
    if (selected == null) return const SizedBox.shrink();
    return Container(
      key: const Key('order-shortage-details'),
      child: _SectionCard(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.search_outlined, color: Color(0xFF9B78FF)),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Material readiness · ${selected.orderId}',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            IconButton(
                tooltip: 'Close order details',
                onPressed: () => setState(() => _selectedOrderId = null),
                icon: const Icon(Icons.close)),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 18, runSpacing: 8, children: [
            _DetailValue(
                'Material ready', _displayDate(selected.materialReadyDate)),
            _DetailValue(
                'Projected ship', _displayDate(selected.projectedShipDate)),
            _DetailValue('Projected delivery',
                _displayDate(selected.projectedDeliveryDate)),
            _DetailValue(
                'Slack days',
                selected.slackDays == null
                    ? 'Unavailable'
                    : '${selected.slackDays}'),
          ]),
          const SizedBox(height: 15),
          if (selected.shortages.isEmpty)
            const _InlineEmpty(
                message: 'No material shortages reported for this order.')
          else
            SingleChildScrollView(
              key: const Key('shortages-horizontal-scroll'),
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Material ID')),
                  DataColumn(label: Text('Required'), numeric: true),
                  DataColumn(label: Text('Available'), numeric: true),
                  DataColumn(label: Text('Shortage'), numeric: true),
                ],
                rows: [
                  for (final shortage in selected.shortages)
                    DataRow(cells: [
                      DataCell(Text(shortage.materialId)),
                      DataCell(Text('${shortage.required}')),
                      DataCell(Text('${shortage.available}')),
                      DataCell(Text('${shortage.shortage}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFFF7777)))),
                    ]),
                ],
              ),
            ),
        ]),
      ),
    );
  }
}

class _OverviewCardData {
  const _OverviewCardData(
      this.title, this.value, this.icon, this.color, this.keyName);

  final String title;
  final String value;
  final IconData icon;
  final Color color;
  final String keyName;
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({required this.data});

  final _OverviewCardData data;

  @override
  Widget build(BuildContext context) => Card(
        key: Key(data.keyName),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 15),
          child: Row(children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                  color: data.color.withAlpha(28),
                  borderRadius: BorderRadius.circular(11)),
              child: Icon(data.icon, color: data.color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(data.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Color(0xFFB5B6BE), fontSize: 12)),
                    const SizedBox(height: 4),
                    Text(data.value,
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w700)),
                  ]),
            ),
          ]),
        ),
      );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard(
      {required this.child, this.padding = const EdgeInsets.all(16)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(padding: padding, child: child),
      );
}

class _RiskPill extends StatelessWidget {
  const _RiskPill({required this.risk});

  final OrderRisk risk;

  @override
  Widget build(BuildContext context) {
    final color = _riskColor(risk);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
          color: color.withAlpha(30), borderRadius: BorderRadius.circular(20)),
      child: Text(risk.label,
          style: TextStyle(
              color: color, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

class _OrderSummaryCard extends StatelessWidget {
  const _OrderSummaryCard(
      {required this.order, required this.selected, required this.onTap});

  final CustomerOrder order;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        color: selected ? const Color(0xFF23242C) : null,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(
                        child: Text(order.orderId,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700))),
                    _RiskPill(risk: order.risk),
                  ]),
                  const SizedBox(height: 5),
                  Text(order.customer,
                      style: const TextStyle(color: Color(0xFFB5B6BE))),
                  const SizedBox(height: 12),
                  Wrap(spacing: 14, runSpacing: 8, children: [
                    _DetailValue('Priority', _titleCase(order.priority.name)),
                    _DetailValue('Request date',
                        _displayDate(order.crd, fallback: 'Not provided')),
                    _DetailValue('Material ready',
                        _displayDate(order.materialReadyDate)),
                    _DetailValue('Ship', _displayDate(order.projectedShipDate)),
                    _DetailValue(
                        'Delivery', _displayDate(order.projectedDeliveryDate)),
                    _DetailValue(
                        'Slack',
                        order.slackDays == null
                            ? 'Unavailable'
                            : '${order.slackDays} days'),
                  ]),
                  if (order.shortages.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                        '${order.shortages.length} reported material shortage(s)',
                        style: const TextStyle(
                            color: Color(0xFFFF7777),
                            fontWeight: FontWeight.w600)),
                  ],
                ]),
          ),
        ),
      );
}

class _DetailValue extends StatelessWidget {
  const _DetailValue(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: Color(0xFF8F9099), fontSize: 11)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontSize: 12)),
        ],
      );
}

class _MetadataChip extends StatelessWidget {
  const _MetadataChip(
      {required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFF303137)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _LoadingPanel extends StatelessWidget {
  const _LoadingPanel();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 96),
        child: Column(children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Loading authenticated inventory snapshot…'),
        ]),
      );
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel(
      {required this.message, required this.onRetry, this.onSignOut});

  final String message;
  final VoidCallback onRetry;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: _SectionCard(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.cloud_off_outlined,
                  color: Color(0xFFFF7777), size: 30),
              const SizedBox(height: 14),
              const Text('Inventory snapshot unavailable',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(message,
                  style:
                      const TextStyle(color: Color(0xFFB5B6BE), height: 1.45)),
              const SizedBox(height: 18),
              Wrap(spacing: 10, children: [
                FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry')),
                if (onSignOut != null)
                  TextButton.icon(
                      onPressed: onSignOut,
                      icon: const Icon(Icons.logout),
                      label: const Text('Sign out')),
              ]),
            ]),
          ),
        ),
      );
}

class _EmptySnapshotPanel extends StatelessWidget {
  const _EmptySnapshotPanel();

  @override
  Widget build(BuildContext context) => const _SectionCard(
        child: _InlineEmpty(
            message: 'The backend returned an empty inventory snapshot.'),
      );
}

class _InlineEmpty extends StatelessWidget {
  const _InlineEmpty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child:
              Text(message, style: const TextStyle(color: Color(0xFF9B9CA5))),
        ),
      );
}

Color _riskColor(OrderRisk risk) => switch (risk) {
      OrderRisk.onTrack => const Color(0xFF54D39A),
      OrderRisk.atRisk => const Color(0xFFFFC266),
      OrderRisk.critical => const Color(0xFFFF7777),
      OrderRisk.delayed => const Color(0xFFB48CFF),
    };

String _displayDate(DateTime? date, {String fallback = 'Not scheduled'}) =>
    date == null ? fallback : _formatDate(date);

String _formatDate(DateTime date) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  return '${date.day.toString().padLeft(2, '0')} ${months[date.month - 1]} ${date.year}';
}

String _titleCase(String value) => value.isEmpty
    ? value
    : '${value[0].toUpperCase()}${value.substring(1).replaceAll('_', ' ')}';
