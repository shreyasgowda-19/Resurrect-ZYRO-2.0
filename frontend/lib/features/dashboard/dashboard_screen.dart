import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/models/inventory_snapshot.dart';
import '../../core/models/recommendation_models.dart';

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
  final _eventsKey = GlobalKey();
  final _alertsKey = GlobalKey();
  final _historyKey = GlobalKey();
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
  Timer? _pollTimer;
  bool _requestInFlight = false;
  bool _refreshQueued = false;
  int _requestSequence = 0;
  bool _snapshotStale = false;
  DateTime? _lastRefreshAt;
  bool _submittingEvent = false;
  String? _eventMessage;
  bool _eventMessageError = false;
  Map<String, dynamic>? _pendingEvent;
  final Set<String> _seenAlertIds = {};
  final Set<String> _newAlertIds = {};
  String? _selectedLotId;
  String? _selectedMaterialId;
  String? _selectedRequirementOrderId;
  String? _selectedRequirementMaterialId;
  DateTime? _newEta;
  final _receiptQuantity = TextEditingController();
  final _adjustmentQuantity = TextEditingController();
  final _requiredQuantity = TextEditingController();
  DateTime? _newOrderDate;
  final Map<String, RecommendationResult> _recommendationsByOrder = {};
  final Map<String, String> _recommendationErrors = {};
  final Set<String> _recommendationLoads = {};
  final Map<String, int> _recommendationSequences = {};
  final Map<String, SimulationResult> _simulations = {};
  final Map<String, String> _simulationErrors = {};
  final Set<String> _simulationLoads = {};
  final Map<String, int> _simulationSequences = {};

  @override
  void initState() {
    super.initState();
    _ownsApiClient = widget.apiClient == null;
    _apiClient = widget.apiClient ?? ApiClient();
    _refresh();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && !_requestInFlight) unawaited(_loadSnapshot());
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _receiptQuantity.dispose();
    _adjustmentQuantity.dispose();
    _requiredQuantity.dispose();
    if (_ownsApiClient) _apiClient.close();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_requestInFlight) {
      _refreshQueued = true;
      return;
    }
    setState(() {
      _loading = _snapshot == null;
      _error = null;
    });
    await Future.wait([_loadSnapshot(), _checkBackend()]);
  }

  Future<void> _loadSnapshot() async {
    if (_requestInFlight) {
      _refreshQueued = true;
      return;
    }
    _requestInFlight = true;
    final sequence = ++_requestSequence;
    try {
      final token = await widget.getIdToken();
      final snapshot = await _apiClient.getState(idToken: token);
      if (!mounted || sequence != _requestSequence) return;
      final previousVersion = _snapshot?.version ?? 0;
      setState(() {
        if (_snapshot == null || snapshot.version >= _snapshot!.version) {
          _snapshot = snapshot;
          for (final alert in snapshot.alerts) {
            if (previousVersion > 0 &&
                alert.version > previousVersion &&
                !_seenAlertIds.contains(alert.alertId)) {
              _newAlertIds.add(alert.alertId);
            }
            _seenAlertIds.add(alert.alertId);
          }
        }
        _error = null;
        _loading = false;
        _snapshotStale = false;
        _lastRefreshAt = DateTime.now();
      });
    } on StateApiException catch (error) {
      if (!mounted || sequence != _requestSequence) return;
      setState(() {
        _error = error;
        _loading = false;
        _snapshotStale = _snapshot != null;
      });
    } catch (_) {
      if (!mounted || sequence != _requestSequence) return;
      setState(() {
        _error = const StateApiException(StateApiFailure.backendError);
        _loading = false;
        _snapshotStale = _snapshot != null;
      });
    } finally {
      _requestInFlight = false;
      if (mounted && _refreshQueued) {
        _refreshQueued = false;
        scheduleMicrotask(() => unawaited(_loadSnapshot()));
      }
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
      'events' => _eventsKey,
      'alerts' => _alertsKey,
      'history' => _historyKey,
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

  String _newEventId() {
    final random = Random.secure();
    return List<String>.generate(16, (_) {
      return random.nextInt(256).toRadixString(16).padLeft(2, '0');
    }).join();
  }

  Future<void> _submitEvent(String type, Map<String, dynamic> payload) async {
    final snapshot = _snapshot;
    developer.log(
      'Event submit callback entered (type=$type, role=${widget.role}, snapshotAvailable=${snapshot != null}, submitting=$_submittingEvent, stale=$_snapshotStale).',
      name: 'zyro.events',
    );
    if (widget.role != 'planner') {
      developer.log('Submission stopped: signed-in role is not planner.',
          name: 'zyro.events');
      return;
    }
    if (snapshot == null || _submittingEvent || _snapshotStale) {
      developer.log(
        'Submission stopped by state guard (snapshotAvailable=${snapshot != null}, submitting=$_submittingEvent, stale=$_snapshotStale).',
        name: 'zyro.events',
      );
      return;
    }
    try {
      final request = <String, dynamic>{
        'event_id': _newEventId(),
        'event_type': type,
        'expected_version': snapshot.version,
        'payload': Map<String, dynamic>.from(payload),
      };
      await _sendPendingEvent(request);
    } catch (error) {
      if (!mounted) return;
      developer.log(
        'Failed to prepare an event request (${error.runtimeType}); no POST was dispatched.',
        name: 'zyro.events',
      );
      setState(() {
        _eventMessage =
            'Could not generate a secure event ID. No event was sent; please try again.';
        _eventMessageError = true;
        _pendingEvent = null;
      });
    }
  }

  Future<void> _retryPendingEvent() async {
    final request = _pendingEvent;
    if (request != null && !_submittingEvent) await _sendPendingEvent(request);
  }

  Future<void> _sendPendingEvent(Map<String, dynamic> request) async {
    setState(() {
      _submittingEvent = true;
      _eventMessage = null;
    });
    try {
      developer.log('Requesting Firebase ID token for event submission.',
          name: 'zyro.events');
      final token = await widget.getIdToken();
      developer.log('Firebase ID token obtained; invoking API client.',
          name: 'zyro.events');
      final result = await _apiClient.postEvent(
        idToken: token,
        eventId: request['event_id'] as String,
        eventType: request['event_type'] as String,
        expectedVersion: request['expected_version'] as int,
        payload: Map<String, dynamic>.from(request['payload'] as Map),
      );
      if (!mounted) return;
      developer.log(
        'Event request completed (status=${result.status}, version=${result.version}).',
        name: 'zyro.events',
      );
      setState(() {
        _pendingEvent = null;
        _eventMessage = result.isDuplicate
            ? 'This event was already applied (snapshot v${result.version}).'
            : 'Event applied (snapshot v${result.version}).';
        _eventMessageError = false;
        _receiptQuantity.clear();
        _adjustmentQuantity.clear();
        _requiredQuantity.clear();
      });
      await _loadSnapshot();
    } on EventApiException catch (error) {
      if (!mounted) return;
      developer.log('Event request failed (${error.failure.name}).',
          name: 'zyro.events');
      final message = switch (error.failure) {
        EventApiFailure.unauthorized =>
          'Your session was rejected. Sign in again.',
        EventApiFailure.forbidden =>
          'Your verified role cannot submit manufacturing events.',
        EventApiFailure.notFound => error.message ??
            'The selected backend entity no longer exists. Refresh and review the form.',
        EventApiFailure.staleVersion => error.message ??
            'The snapshot changed. Refresh and review the updated data before submitting again.',
        EventApiFailure.conflict =>
          error.message ?? 'This event ID conflicts with an earlier event.',
        EventApiFailure.validation => error.message ??
            'The backend rejected this event data. Review the entered values.',
        EventApiFailure.unavailable =>
          'A required backend service is unavailable. Retry this same event when it is available.',
        EventApiFailure.timeout =>
          'The request timed out. Its result is uncertain; retry safely with the same event ID.',
        EventApiFailure.connectivity =>
          'Could not reach the backend. Its result may be uncertain; retry safely with the same event ID.',
        EventApiFailure.malformedResponse =>
          'The backend response was invalid. Refresh state before continuing.',
        EventApiFailure.backendError => error.message ??
            'The backend could not apply this event. Please retry or refresh.',
      };
      setState(() {
        _eventMessage = message;
        _eventMessageError = true;
        _pendingEvent = {
          EventApiFailure.timeout,
          EventApiFailure.connectivity,
          EventApiFailure.unavailable
        }.contains(error.failure)
            ? request
            : null;
      });
      if (error.failure == EventApiFailure.staleVersion) await _loadSnapshot();
    } catch (_) {
      if (!mounted) return;
      developer.log(
        'Event submission failed before a recognized API response; request is retained for safe retry.',
        name: 'zyro.events',
      );
      setState(() {
        _eventMessage =
            'Could not complete the request. Its result may be uncertain; retry safely with the same event ID.';
        _eventMessageError = true;
        _pendingEvent = request;
      });
    } finally {
      if (mounted) setState(() => _submittingEvent = false);
    }
  }

  String _simulationKey(String orderId, String recommendationId) =>
      '$orderId::$recommendationId';

  Future<void> _generateRecommendations(CustomerOrder order) async {
    final snapshot = _snapshot;
    if (snapshot == null || _recommendationLoads.contains(order.orderId)) {
      return;
    }
    final version = snapshot.version;
    final sequence = (_recommendationSequences[order.orderId] ?? 0) + 1;
    _recommendationSequences[order.orderId] = sequence;
    setState(() {
      _recommendationLoads.add(order.orderId);
      _recommendationErrors.remove(order.orderId);
    });
    try {
      final token = await widget.getIdToken();
      final result = await _apiClient.postRecommendations(
        idToken: token,
        orderId: order.orderId,
        expectedVersion: version,
      );
      if (!mounted || _recommendationSequences[order.orderId] != sequence) {
        return;
      }
      setState(() {
        if (_snapshot?.version == version &&
            result.version == version &&
            result.orderId == order.orderId) {
          _recommendationsByOrder[order.orderId] = result;
        } else {
          _recommendationErrors[order.orderId] =
              'The snapshot changed while recommendations were loading. Generate them again for the current version.';
        }
      });
    } on ComputationApiException catch (error) {
      if (!mounted || _recommendationSequences[order.orderId] != sequence) {
        return;
      }
      setState(() => _recommendationErrors[order.orderId] =
          _computationErrorMessage(error));
      if (error.failure == ComputationApiFailure.staleVersion) {
        await _loadSnapshot();
      }
    } catch (_) {
      if (!mounted || _recommendationSequences[order.orderId] != sequence) {
        return;
      }
      setState(() => _recommendationErrors[order.orderId] =
          'Recommendations could not be loaded. Check the connection and retry.');
    } finally {
      if (mounted && _recommendationSequences[order.orderId] == sequence) {
        setState(() => _recommendationLoads.remove(order.orderId));
      }
    }
  }

  Future<void> _simulateRecommendation(
      CustomerOrder order, InventoryRecommendation recommendation) async {
    final snapshot = _snapshot;
    final currentRecommendations = _recommendationsByOrder[order.orderId];
    if (snapshot == null ||
        currentRecommendations == null ||
        currentRecommendations.version != snapshot.version ||
        _simulationLoads.contains(
            _simulationKey(order.orderId, recommendation.recommendationId))) {
      return;
    }
    final key = _simulationKey(order.orderId, recommendation.recommendationId);
    final version = snapshot.version;
    final sequence = (_simulationSequences[key] ?? 0) + 1;
    _simulationSequences[key] = sequence;
    setState(() {
      _simulationLoads.add(key);
      _simulationErrors.remove(key);
    });
    try {
      final token = await widget.getIdToken();
      final result = await _apiClient.postSimulation(
        idToken: token,
        orderId: order.orderId,
        recommendationId: recommendation.recommendationId,
        expectedVersion: version,
      );
      if (!mounted || _simulationSequences[key] != sequence) return;
      setState(() {
        if (_snapshot?.version == version &&
            result.version == version &&
            result.orderId == order.orderId &&
            result.recommendationId == recommendation.recommendationId) {
          _simulations[key] = result;
        } else {
          _simulationErrors[key] =
              'The snapshot changed while this simulation was running. Regenerate recommendations before simulating again.';
        }
      });
    } on ComputationApiException catch (error) {
      if (!mounted || _simulationSequences[key] != sequence) return;
      setState(() => _simulationErrors[key] = _computationErrorMessage(error));
      if (error.failure == ComputationApiFailure.staleVersion) {
        await _loadSnapshot();
      }
    } catch (_) {
      if (!mounted || _simulationSequences[key] != sequence) return;
      setState(() => _simulationErrors[key] =
          'Simulation could not be completed. Check the connection and retry.');
    } finally {
      if (mounted && _simulationSequences[key] == sequence) {
        setState(() => _simulationLoads.remove(key));
      }
    }
  }

  String _computationErrorMessage(ComputationApiException error) =>
      switch (error.failure) {
        ComputationApiFailure.unauthorized =>
          'Your sign-in session was rejected. Sign in again.',
        ComputationApiFailure.forbidden =>
          'Your verified role is not authorized to run this read-only computation.',
        ComputationApiFailure.notFound =>
          error.message ?? 'The order or recommendation was not found.',
        ComputationApiFailure.staleVersion =>
          'The inventory snapshot changed. Current state is refreshing; regenerate before running another simulation.',
        ComputationApiFailure.validation => error.message ??
            'The request was invalid. Review the selected order.',
        ComputationApiFailure.unavailable =>
          'A required backend service is unavailable. Retry when it is available.',
        ComputationApiFailure.timeout =>
          'The computation timed out. You can retry it.',
        ComputationApiFailure.connectivity =>
          'Could not connect to the recommendation service. Check the network and retry.',
        ComputationApiFailure.malformedResponse =>
          'The backend returned data that does not match the T3 contract.',
        ComputationApiFailure.backendError =>
          error.message ?? 'The backend could not complete the computation.',
      };

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
            if (widget.role == 'planner')
              _navItem('events', Icons.precision_manufacturing_outlined,
                  'Manufacturing Events'),
            _navItem(
                'alerts', Icons.notifications_active_outlined, 'Risk alerts'),
            _navItem('history', Icons.history, 'Event history'),
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
                    if (_loading && _snapshot == null)
                      const _LoadingPanel()
                    else if (_error != null && _snapshot == null)
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
                      if (_snapshotStale) _staleSnapshotBanner(),
                      if (_lastRefreshAt != null) ...[
                        const SizedBox(height: 8),
                        Text(
                            'Last successful refresh: ${_formatTime(_lastRefreshAt!)}',
                            style: const TextStyle(
                                color: Color(0xFF9B9CA5), fontSize: 12)),
                        const SizedBox(height: 12),
                      ],
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
                        ...[
                          const SizedBox(height: 30),
                          _sectionHeading(_alertsKey, 'Risk alerts',
                              'Backend-reported customer risk changes caused by manufacturing events.'),
                          const SizedBox(height: 14),
                          _riskAlerts(_snapshot!),
                        ],
                        ...[
                          const SizedBox(height: 30),
                          _sectionHeading(_historyKey, 'Event history',
                              'Recently accepted events and versions supplied by the backend.'),
                          const SizedBox(height: 14),
                          _eventHistory(_snapshot!),
                        ],
                        if (widget.role == 'planner') ...[
                          const SizedBox(height: 30),
                          _sectionHeading(_eventsKey, 'Manufacturing Events',
                              'Demonstration manufacturing inputs. Changes are validated and applied by the backend.'),
                          const SizedBox(height: 14),
                          _eventPanel(_snapshot!, contentWidth),
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

  Widget _staleSnapshotBanner() => Container(
        key: const Key('stale-snapshot-banner'),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
            color: const Color(0xFF4A351C),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFFFC266))),
        child: Row(children: [
          const Icon(Icons.cloud_off_outlined, color: Color(0xFFFFC266)),
          const SizedBox(width: 10),
          const Expanded(
              child: Text(
                  'Showing the last successful snapshot. Refresh failed; these values may be stale.',
                  style: TextStyle(color: Color(0xFFFFD99A)))),
          TextButton(onPressed: _refresh, child: const Text('Retry'))
        ]),
      );

  Widget _riskAlerts(InventorySnapshot snapshot) => snapshot.alerts.isEmpty
      ? const _SectionCard(
          child:
              _InlineEmpty(message: 'No recent risk alerts from the backend.'))
      : Column(children: [
          for (final alert in snapshot.alerts)
            Card(
              key: Key('risk-alert-${alert.alertId}'),
              color: alert.newRisk == OrderRisk.critical ||
                      alert.newRisk == OrderRisk.delayed
                  ? const Color(0xFF3A252B)
                  : null,
              child: ListTile(
                  onTap: () {
                    setState(() {
                      _selectedOrderId = alert.orderId;
                      _newAlertIds.remove(alert.alertId);
                    });
                    final target = _ordersKey.currentContext;
                    if (target != null) {
                      unawaited(Scrollable.ensureVisible(target,
                          duration: const Duration(milliseconds: 180)));
                    }
                  },
                  leading: Icon(Icons.notifications_active_outlined,
                      color: _riskColor(alert.newRisk)),
                  title: Row(children: [
                    Expanded(child: Text('Risk escalation · ${alert.orderId}')),
                    if (_newAlertIds.contains(alert.alertId))
                      const Chip(label: Text('NEW'))
                  ]),
                  subtitle: Text(
                      '${alert.previousRisk.label} → ${alert.newRisk.label} · ${alert.message}\nEvent ${alert.eventId} · snapshot v${alert.version}'),
                  isThreeLine: true,
                  trailing: Icon(Icons.chevron_right,
                      color: _riskColor(alert.newRisk))),
            ),
        ]);

  Widget _eventHistory(InventorySnapshot snapshot) => snapshot
          .recentEvents.isEmpty
      ? const _SectionCard(
          child: _InlineEmpty(
              message: 'No recent manufacturing events from the backend.'))
      : _SectionCard(
          child: Column(children: [
          for (final event in snapshot.recentEvents)
            ListTile(
                key: Key('event-history-${event.eventId}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.history, color: Color(0xFF9B78FF)),
                title: Text(event.eventType.replaceAll('_', ' ')),
                subtitle: Text(
                    '${event.summary}\n${_formatTime(event.recordedAt)} · snapshot v${event.version}'),
                isThreeLine: true),
        ]));

  double _eventCardWidth(double width) =>
      width >= 760 ? (width - 14) / 2 : width;

  Widget _eventPanel(InventorySnapshot snapshot, double width) {
    final lots =
        snapshot.supplyLots.where((lot) => lot.remainingQuantity > 0).toList();
    final requirements = snapshot.orderRequirements;
    final lotIds = lots.map((lot) => lot.lotId).toSet();
    final materialIds =
        snapshot.materials.map((item) => item.materialId).toSet();
    final orderIds = snapshot.orders.map((item) => item.orderId).toSet();
    if (!lotIds.contains(_selectedLotId)) {
      _selectedLotId = lots.isEmpty ? null : lots.first.lotId;
    }
    if (!materialIds.contains(_selectedMaterialId)) {
      _selectedMaterialId = snapshot.materials.isEmpty
          ? null
          : snapshot.materials.first.materialId;
    }
    if (!orderIds.contains(_selectedRequirementOrderId)) {
      _selectedRequirementOrderId =
          snapshot.orders.isEmpty ? null : snapshot.orders.first.orderId;
    }
    final matchingRequirements = requirements
        .where((item) => item.orderId == _selectedRequirementOrderId)
        .toList();
    if (!matchingRequirements
        .any((item) => item.materialId == _selectedRequirementMaterialId)) {
      _selectedRequirementMaterialId = matchingRequirements.isEmpty
          ? null
          : matchingRequirements.first.materialId;
    }
    final lot = _findOrNull(lots, (item) => item.lotId == _selectedLotId);
    final material = _findOrNull(
        snapshot.materials, (item) => item.materialId == _selectedMaterialId);
    final requirement = _findOrNull(matchingRequirements,
        (item) => item.materialId == _selectedRequirementMaterialId);
    final order = _findOrNull(
        snapshot.orders, (item) => item.orderId == _selectedRequirementOrderId);
    final disabled = _submittingEvent || _snapshotStale;
    final cards = <Widget>[
      _eventCard(
          width,
          'Supplier ETA update',
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (lots.isEmpty)
              const _InlineEmpty(
                  message: 'No outstanding supply lots are available.')
            else ...[
              DropdownButtonFormField<String>(
                  key: const Key('eta-lot-select'),
                  initialValue: _selectedLotId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Supply lot'),
                  items: [
                    for (final item in lots)
                      DropdownMenuItem(
                          value: item.lotId, child: Text(item.lotId))
                  ],
                  onChanged: disabled
                      ? null
                      : (value) => setState(() => _selectedLotId = value)),
              if (lot != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                        'Supplier ${lot.supplierId} · Material ${lot.materialId} · Current ETA ${_displayDate(lot.eta)} · Outstanding ${lot.remainingQuantity}')),
              OutlinedButton.icon(
                  key: const Key('eta-date-button'),
                  onPressed: disabled
                      ? null
                      : () async {
                          final date = await _pickDate(_newEta);
                          if (date != null && mounted) {
                            setState(() => _newEta = date);
                          }
                        },
                  icon: const Icon(Icons.calendar_month),
                  label: Text(_newEta == null
                      ? 'Select new arrival date'
                      : 'New ETA ${_formatDate(_newEta!)}')),
              if (_newEta == null)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('Select a new arrival date to enable submission.',
                      key: Key('eta-date-validation'),
                      style: TextStyle(color: Color(0xFFB5B6BE), fontSize: 12)),
                ),
              const SizedBox(height: 8),
              FilledButton(
                  key: const Key('submit-eta-event'),
                  onPressed: disabled || lot == null || _newEta == null
                      ? null
                      : () => _submitEvent('supplier_eta_update', {
                            'lot_id': lot.lotId,
                            'new_eta': _dateWire(_newEta!)
                          }),
                  child: const Text('Submit ETA update')),
            ],
          ])),
      _eventCard(
          width,
          'Material receipt',
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (lots.isEmpty)
              const _InlineEmpty(
                  message: 'No outstanding supply lots are available.')
            else ...[
              DropdownButtonFormField<String>(
                  key: const Key('receipt-lot-select'),
                  initialValue: _selectedLotId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Supply lot'),
                  items: [
                    for (final item in lots)
                      DropdownMenuItem(
                          value: item.lotId, child: Text(item.lotId))
                  ],
                  onChanged: disabled
                      ? null
                      : (value) => setState(() => _selectedLotId = value)),
              if (lot != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                        'Outstanding quantity: ${lot.remainingQuantity} ${_findOrNull(snapshot.materials, (item) => item.materialId == lot.materialId)?.unit ?? ''}')),
              TextField(
                  key: const Key('receipt-quantity'),
                  controller: _receiptQuantity,
                  onChanged: (_) => setState(() {}),
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                      labelText: 'Quantity received',
                      errorText: _receiptQuantity.text.isEmpty ||
                              (lot != null &&
                                  _validPositive(_receiptQuantity.text,
                                      maximum: lot.remainingQuantity))
                          ? null
                          : 'Enter a positive integer up to the outstanding quantity.'),
                  enabled: !disabled),
              const SizedBox(height: 8),
              FilledButton(
                  key: const Key('submit-receipt-event'),
                  onPressed: disabled ||
                          lot == null ||
                          !_validPositive(_receiptQuantity.text,
                              maximum: lot.remainingQuantity)
                      ? null
                      : () => _submitEvent('material_receipt', {
                            'lot_id': lot.lotId,
                            'quantity': int.parse(_receiptQuantity.text)
                          }),
                  child: const Text('Submit material receipt')),
            ],
          ])),
      _eventCard(
          width,
          'Stock adjustment',
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownButtonFormField<String>(
                key: const Key('adjustment-material-select'),
                initialValue: _selectedMaterialId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Material'),
                items: [
                  for (final item in snapshot.materials)
                    DropdownMenuItem(
                        value: item.materialId,
                        child: Text('${item.materialId} · ${item.name}'))
                ],
                onChanged: disabled
                    ? null
                    : (value) => setState(() => _selectedMaterialId = value)),
            if (material != null)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                      'Physical stock: ${material.onHand} ${material.unit}')),
            TextField(
                key: const Key('adjustment-quantity'),
                controller: _adjustmentQuantity,
                onChanged: (_) => setState(() {}),
                keyboardType:
                    const TextInputType.numberWithOptions(signed: true),
                decoration: InputDecoration(
                    labelText: 'Signed quantity change',
                    errorText: _adjustmentQuantity.text.isEmpty ||
                            (material != null &&
                                _validAdjustment(
                                    _adjustmentQuantity.text, material.onHand))
                        ? null
                        : 'Enter a nonzero integer that keeps physical stock nonnegative.'),
                enabled: !disabled),
            const SizedBox(height: 8),
            FilledButton(
                key: const Key('submit-adjustment-event'),
                onPressed: disabled ||
                        material == null ||
                        !_validAdjustment(
                            _adjustmentQuantity.text, material.onHand)
                    ? null
                    : () => _submitEvent('stock_adjustment', {
                          'material_id': material.materialId,
                          'quantity_delta': int.parse(_adjustmentQuantity.text)
                        }),
                child: const Text('Submit stock adjustment')),
          ])),
      _eventCard(
          width,
          'Customer order change',
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownButtonFormField<String>(
                key: const Key('change-order-select'),
                initialValue: _selectedRequirementOrderId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Customer order'),
                items: [
                  for (final item in snapshot.orders)
                    DropdownMenuItem(
                        value: item.orderId,
                        child: Text('${item.orderId} · ${item.customer}'))
                ],
                onChanged: disabled
                    ? null
                    : (value) => setState(() {
                          _selectedRequirementOrderId = value;
                          _selectedRequirementMaterialId = null;
                        })),
            OutlinedButton.icon(
                key: const Key('order-date-button'),
                onPressed: disabled || order == null
                    ? null
                    : () async {
                        final date =
                            await _pickDate(_newOrderDate ?? order.crd);
                        if (date != null && mounted) {
                          setState(() => _newOrderDate = date);
                        }
                      },
                icon: const Icon(Icons.calendar_month),
                label: Text(_newOrderDate == null
                    ? 'Select requested delivery date'
                    : 'New CRD ${_formatDate(_newOrderDate!)}')),
            if (_newOrderDate == null)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                    'Select a requested delivery date to enable submission.',
                    key: Key('order-date-validation'),
                    style: TextStyle(color: Color(0xFFB5B6BE), fontSize: 12)),
              ),
            FilledButton(
                key: const Key('submit-order-date-event'),
                onPressed: disabled || order == null || _newOrderDate == null
                    ? null
                    : () => _submitEvent('order_change', {
                          'order_id': order.orderId,
                          'new_crd': _dateWire(_newOrderDate!)
                        }),
                child: const Text('Submit date change')),
            const Divider(height: 24),
            if (matchingRequirements.isEmpty)
              const _InlineEmpty(
                  message:
                      'No existing material requirements are available for this order.')
            else ...[
              DropdownButtonFormField<String>(
                  key: const Key('requirement-material-select'),
                  initialValue: _selectedRequirementMaterialId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      labelText: 'Existing material requirement'),
                  items: [
                    for (final item in matchingRequirements)
                      DropdownMenuItem(
                          value: item.materialId, child: Text(item.materialId))
                  ],
                  onChanged: disabled
                      ? null
                      : (value) => setState(
                          () => _selectedRequirementMaterialId = value)),
              if (requirement != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                        'Current required quantity: ${requirement.requiredQuantity}')),
              TextField(
                  key: const Key('required-quantity'),
                  controller: _requiredQuantity,
                  onChanged: (_) => setState(() {}),
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                      labelText: 'New required quantity',
                      errorText: _requiredQuantity.text.isEmpty ||
                              _validPositive(_requiredQuantity.text)
                          ? null
                          : 'Enter a positive whole number.'),
                  enabled: !disabled),
              const SizedBox(height: 8),
              FilledButton(
                  key: const Key('submit-requirement-event'),
                  onPressed: disabled ||
                          order == null ||
                          requirement == null ||
                          !_validPositive(_requiredQuantity.text)
                      ? null
                      : () => _submitEvent('order_change', {
                            'order_id': order.orderId,
                            'material_id': requirement.materialId,
                            'new_required_quantity':
                                int.parse(_requiredQuantity.text)
                          }),
                  child: const Text('Submit requirement change')),
            ],
          ])),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_eventMessage != null)
        Card(
            key: const Key('event-feedback'),
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(
                      child: Text(_eventMessage!,
                          style: TextStyle(
                              color: _eventMessageError
                                  ? const Color(0xFFFF9999)
                                  : const Color(0xFF77E0B1)))),
                  if (_pendingEvent != null)
                    TextButton(
                        key: const Key('retry-event'),
                        onPressed: _submittingEvent ? null : _retryPendingEvent,
                        child: const Text('Retry same event'))
                ]))),
      if (_snapshotStale)
        const Text(
            'Refresh and review the latest snapshot before submitting an event.'),
      Wrap(spacing: 14, runSpacing: 14, children: cards),
    ]);
  }

  Widget _eventCard(double width, String title, Widget child) => SizedBox(
      width: _eventCardWidth(width),
      child: _SectionCard(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        const Text('DEMONSTRATION MANUFACTURING INPUT',
            style: TextStyle(
                color: Color(0xFF9B9CA5), fontSize: 10, letterSpacing: 0.7)),
        const SizedBox(height: 8),
        child
      ])));

  Future<DateTime?> _pickDate(DateTime? initial) => showDatePicker(
      context: context,
      initialDate: initial ?? DateTime(2026, 12, 1),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100));
  String _dateWire(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  bool _validPositive(String value, {int? maximum}) {
    final parsed = int.tryParse(value);
    return parsed != null &&
        parsed > 0 &&
        (maximum == null || parsed <= maximum);
  }

  bool _validAdjustment(String value, int onHand) {
    final parsed = int.tryParse(value);
    return parsed != null && parsed != 0 && onHand + parsed >= 0;
  }

  String _formatTime(DateTime date) =>
      '${date.toLocal().hour.toString().padLeft(2, '0')}:${date.toLocal().minute.toString().padLeft(2, '0')}:${date.toLocal().second.toString().padLeft(2, '0')}';

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
            _DetailValue('Customer request date',
                _displayDate(selected.crd, fallback: 'Not provided')),
            _DetailValue('Current risk', selected.risk.label),
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
          const SizedBox(height: 18),
          _supplierFactsForOrder(snapshot, selected),
          const SizedBox(height: 18),
          _recommendationWorkspace(snapshot, selected),
        ]),
      ),
    );
  }

  Widget _supplierFactsForOrder(
      InventorySnapshot snapshot, CustomerOrder order) {
    final requirements = snapshot.orderRequirements
        .where((requirement) => requirement.orderId == order.orderId)
        .map((requirement) => requirement.materialId)
        .toSet();
    final materialIds = requirements.isEmpty
        ? order.shortages.map((shortage) => shortage.materialId).toSet()
        : requirements;
    final lots = snapshot.supplyLots
        .where((lot) => materialIds.contains(lot.materialId))
        .toList();
    return _SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Relevant supplier and material facts',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (lots.isEmpty)
          const Text(
              'No related supplier lots were included in the current backend snapshot.')
        else
          for (final lot in lots)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.local_shipping_outlined,
                  color: Color(0xFF9B78FF)),
              title:
                  Text('${lot.lotId} · ${lot.materialId} · ${lot.supplierId}'),
              subtitle: Text(
                  'ETA ${_displayDate(lot.eta)} · Outstanding ${lot.remainingQuantity} · ${_titleCase(lot.status)}'),
            ),
      ]),
    );
  }

  Widget _recommendationWorkspace(
      InventorySnapshot snapshot, CustomerOrder order) {
    final eligible = order.risk != OrderRisk.onTrack;
    final result = _recommendationsByOrder[order.orderId];
    final outdated = result != null && result.version != snapshot.version;
    final loading = _recommendationLoads.contains(order.orderId);
    final error = _recommendationErrors[order.orderId];
    return _SectionCard(
      key: Key('recommendation-workspace-${order.orderId}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.auto_awesome, color: Color(0xFF9B78FF)),
          const SizedBox(width: 9),
          const Expanded(
              child: Text('Recommendations',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
          if (result != null)
            _MetadataChip(
              icon: Icons.tag,
              label:
                  '${result.dataMode.toUpperCase()} · Version ${result.version}',
              color:
                  outdated ? const Color(0xFFFFC266) : const Color(0xFFB5B6BE),
            ),
        ]),
        const SizedBox(height: 8),
        Text(
          'Backend-calculated options for ${order.orderId}. Recommendations are not guaranteed recovery; all simulations are hypothetical and read-only.',
          style: const TextStyle(color: Color(0xFFB5B6BE), height: 1.4),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 18, runSpacing: 8, children: [
          _DetailValue('Customer request date',
              _displayDate(order.crd, fallback: 'Not provided')),
          _DetailValue(
              'Projected delivery', _displayDate(order.projectedDeliveryDate)),
          _DetailValue('Current risk', order.risk.label),
          _DetailValue(
              'Delivery slack',
              order.slackDays == null
                  ? 'Unavailable'
                  : '${order.slackDays} days'),
        ]),
        const SizedBox(height: 14),
        if (!eligible)
          const _InlineEmpty(
              message:
                  'Recommendations are available for at-risk, critical and delayed orders.')
        else ...[
          Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  key: Key('generate-recommendations-${order.orderId}'),
                  onPressed:
                      loading ? null : () => _generateRecommendations(order),
                  icon: loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_awesome, size: 18),
                  label: Text(loading
                      ? 'Generating…'
                      : outdated
                          ? 'Regenerate for v${snapshot.version}'
                          : result == null
                              ? 'Generate recommendations'
                              : 'Regenerate recommendations'),
                ),
                if (outdated)
                  const Text(
                    'Previous options are outdated. Generate them again before simulating.',
                    key: Key('recommendations-outdated'),
                    style: TextStyle(color: Color(0xFFFFC266)),
                  ),
              ]),
          if (error != null) ...[
            const SizedBox(height: 10),
            _InlineErrorMessage(error),
            if (!loading)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: Key('retry-recommendations-${order.orderId}'),
                  onPressed: () => _generateRecommendations(order),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ),
          ],
          if (result != null) ...[
            const SizedBox(height: 14),
            if (result.recommendations.isEmpty)
              const _InlineEmpty(
                  message:
                      'The backend returned no recommendations for this order at the current snapshot version.')
            else
              LayoutBuilder(builder: (context, constraints) {
                final cardWidth = constraints.maxWidth >= 900
                    ? (constraints.maxWidth - 14) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    for (final recommendation in result.recommendations)
                      SizedBox(
                        width: cardWidth,
                        child: _recommendationCard(
                            order, result, recommendation,
                            outdated: outdated),
                      ),
                  ],
                );
              }),
          ],
        ],
      ]),
    );
  }

  Widget _recommendationCard(
    CustomerOrder order,
    RecommendationResult result,
    InventoryRecommendation recommendation, {
    required bool outdated,
  }) {
    final key = _simulationKey(order.orderId, recommendation.recommendationId);
    final simulation = _simulations[key];
    final simulationOutdated = simulation != null &&
        (_snapshot?.version != simulation.version || outdated);
    final loading = _simulationLoads.contains(key);
    final error = _simulationErrors[key];
    return _SectionCard(
      key: Key('recommendation-card-${recommendation.recommendationId}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(recommendation.title,
            key: Key('recommendation-title-${recommendation.recommendationId}'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(
            switch (recommendation.actionType) {
              RecommendationAction.expediteExistingLot =>
                'Expedite existing lot',
              RecommendationAction.alternateSupplierPo =>
                'Alternate supplier PO',
            },
            style: const TextStyle(color: Color(0xFF9B78FF), fontSize: 12)),
        const SizedBox(height: 8),
        Text(recommendation.explanation),
        const SizedBox(height: 12),
        Wrap(spacing: 14, runSpacing: 8, children: [
          _DetailValue('Material', recommendation.materialId),
          _DetailValue('Supplier', recommendation.supplierId),
          _DetailValue('Lot', recommendation.lotId ?? 'Not applicable'),
          _DetailValue('Quantity', '${recommendation.quantity}'),
          _DetailValue('Proposed ETA', _formatDate(recommendation.proposedEta)),
          _DetailValue(
              'Estimated incremental cost',
              _costText(recommendation.estimatedIncrementalCost,
                  recommendation.currency)),
        ]),
        if (recommendation.evidence.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('Evidence', style: TextStyle(fontWeight: FontWeight.w600)),
          for (final evidence in recommendation.evidence)
            _BulletText(text: evidence),
        ],
        if (recommendation.assumptions.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('Assumptions',
              style: TextStyle(fontWeight: FontWeight.w600)),
          for (final assumption in recommendation.assumptions)
            _BulletText(text: assumption),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: Key('simulate-${recommendation.recommendationId}'),
            onPressed: outdated || simulationOutdated || loading
                ? null
                : () => _simulateRecommendation(order, recommendation),
            icon: loading
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.science_outlined, size: 18),
            label: Text(loading ? 'Simulating…' : 'Simulate what-if'),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 8),
          _InlineErrorMessage(error),
          if (!outdated && !loading)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => _simulateRecommendation(order, recommendation),
                child: const Text('Retry simulation'),
              ),
            ),
        ],
        if (simulation != null) ...[
          const SizedBox(height: 12),
          if (simulationOutdated)
            Text(
              'Outdated simulation · v${simulation.version} · current v${_snapshot?.version}',
              key:
                  Key('simulation-outdated-${recommendation.recommendationId}'),
              style: const TextStyle(color: Color(0xFFFFC266)),
            ),
          _simulationCard(simulation, recommendation.recommendationId),
        ],
      ]),
    );
  }

  Widget _simulationCard(
          SimulationResult simulation, String recommendationId) =>
      Container(
        key: Key('simulation-result-$recommendationId'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A2025),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF54D39A).withAlpha(90)),
        ),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Wrap(spacing: 8, runSpacing: 6, children: [
            Chip(label: Text('HYPOTHETICAL')),
            Text('Read-only what-if result',
                style: TextStyle(color: Color(0xFF9B9CA5))),
          ]),
          const SizedBox(height: 8),
          Text('Order ${simulation.orderId}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          _outcomeComparison(
              'Target order', simulation.before, simulation.after),
          if (simulation.affectedOrders.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Other affected orders (${simulation.affectedOrders.length})',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            for (final affected in simulation.affectedOrders) ...[
              const Divider(height: 16),
              Text(affected.orderId,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              _outcomeComparison(
                  'Collateral impact', affected.before, affected.after),
            ],
          ],
          const SizedBox(height: 8),
          _DetailValue(
              'Estimated incremental cost',
              _costText(
                  simulation.estimatedIncrementalCost, simulation.currency)),
          if (simulation.warnings.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('Warnings',
                style: TextStyle(
                    color: Color(0xFFFFC266), fontWeight: FontWeight.w700)),
            for (final warning in simulation.warnings)
              _BulletText(text: warning),
          ],
          if (simulation.assumptions.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('Assumptions',
                style: TextStyle(fontWeight: FontWeight.w700)),
            for (final assumption in simulation.assumptions)
              _BulletText(text: assumption),
          ],
        ]),
      );

  Widget _outcomeComparison(
          String heading, OrderOutcome before, OrderOutcome after) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(heading,
            style: const TextStyle(color: Color(0xFFB5B6BE), fontSize: 12)),
        const SizedBox(height: 7),
        LayoutBuilder(builder: (context, constraints) {
          final cellWidth =
              constraints.maxWidth >= 560 ? 180.0 : constraints.maxWidth;
          return Wrap(spacing: 10, runSpacing: 10, children: [
            _outcomeValue(
                'Projected ship',
                _displayDate(before.projectedShipDate),
                _displayDate(after.projectedShipDate),
                _dateChangeColor(
                    before.projectedShipDate, after.projectedShipDate),
                cellWidth),
            _outcomeValue(
                'Projected delivery',
                _displayDate(before.projectedDeliveryDate),
                _displayDate(after.projectedDeliveryDate),
                _dateChangeColor(
                    before.projectedDeliveryDate, after.projectedDeliveryDate),
                cellWidth),
            _outcomeValue(
                'Slack days',
                before.slackDays?.toString() ?? 'Unavailable',
                after.slackDays?.toString() ?? 'Unavailable',
                _slackChangeColor(before.slackDays, after.slackDays),
                cellWidth),
            SizedBox(
              width: cellWidth,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Risk',
                        style:
                            TextStyle(color: Color(0xFF9B9CA5), fontSize: 11)),
                    const SizedBox(height: 4),
                    Wrap(spacing: 6, runSpacing: 5, children: [
                      _RiskPill(risk: before.risk),
                      const Icon(Icons.arrow_forward,
                          size: 16, color: Color(0xFF9B9CA5)),
                      _RiskPill(risk: after.risk),
                    ]),
                  ]),
            ),
          ]);
        }),
      ]);

  Widget _outcomeValue(String label, String before, String after,
          Color? afterColor, double width) =>
      SizedBox(
        width: width,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: const TextStyle(color: Color(0xFF9B9CA5), fontSize: 11)),
          const SizedBox(height: 4),
          Text('Before  $before', style: const TextStyle(fontSize: 12)),
          Text('After   $after',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: afterColor)),
        ]),
      );

  Color? _dateChangeColor(DateTime? before, DateTime? after) {
    if (before == null || after == null || before == after) return null;
    return after.isBefore(before)
        ? const Color(0xFF54D39A)
        : const Color(0xFFFF7777);
  }

  Color? _slackChangeColor(int? before, int? after) {
    if (before == null || after == null || before == after) return null;
    return after > before ? const Color(0xFF54D39A) : const Color(0xFFFF7777);
  }

  String _costText(num? cost, String? currency) {
    if (cost == null) return 'Not available';
    final amount = cost is int ? '$cost' : cost.toStringAsFixed(2);
    return currency == null ? amount : '$currency $amount';
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
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(16)});

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

class _InlineErrorMessage extends StatelessWidget {
  const _InlineErrorMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF3A252B),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFFF7777).withAlpha(90)),
        ),
        child: Text(message, style: const TextStyle(color: Color(0xFFFFA0A0))),
      );
}

class _BulletText extends StatelessWidget {
  const _BulletText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('•  ', style: TextStyle(color: Color(0xFF9B78FF))),
          Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
        ]),
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

T? _findOrNull<T>(Iterable<T> values, bool Function(T) test) {
  for (final value in values) {
    if (test(value)) return value;
  }
  return null;
}
