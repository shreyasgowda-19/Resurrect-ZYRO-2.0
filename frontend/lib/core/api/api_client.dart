import 'dart:convert';
import 'dart:async';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/inventory_snapshot.dart';
import '../models/proposal_models.dart';
import '../models/recommendation_models.dart';

class AuthProfile {
  const AuthProfile(
      {required this.uid, required this.email, required this.role});

  final String uid;
  final String email;
  final String role;

  factory AuthProfile.fromJson(Map<String, dynamic> json) => AuthProfile(
        uid: json['uid'] as String,
        email: json['email'] as String,
        role: json['role'] as String,
      );
}

enum AuthApiFailure { unauthorized, forbidden, connectivity, invalidResponse }

class AuthApiException implements Exception {
  const AuthApiException(this.failure);

  final AuthApiFailure failure;
}

enum StateApiFailure {
  unauthorized,
  forbidden,
  unavailable,
  connectivity,
  timeout,
  malformedResponse,
  backendError,
}

enum EventApiFailure {
  unauthorized,
  forbidden,
  notFound,
  staleVersion,
  conflict,
  validation,
  unavailable,
  timeout,
  connectivity,
  malformedResponse,
  backendError
}

class EventApiException implements Exception {
  const EventApiException(this.failure, {this.message});
  final EventApiFailure failure;
  final String? message;
}

class EventSubmission {
  const EventSubmission(
      {required this.eventId, required this.status, required this.version});
  final String eventId;
  final String status;
  final int version;
  bool get isDuplicate => status == 'duplicate';
}

enum ComputationApiFailure {
  unauthorized,
  forbidden,
  notFound,
  staleVersion,
  validation,
  unavailable,
  timeout,
  connectivity,
  malformedResponse,
  backendError,
}

class ComputationApiException implements Exception {
  const ComputationApiException(this.failure, {this.message});
  final ComputationApiFailure failure;
  final String? message;
}

enum ProposalApiFailure {
  unauthorized,
  forbidden,
  notFound,
  staleVersion,
  conflict,
  validation,
  unavailable,
  timeout,
  connectivity,
  malformedResponse,
  backendError,
}

class ProposalApiException implements Exception {
  const ProposalApiException(this.failure, {this.message});
  final ProposalApiFailure failure;
  final String? message;
}

class StateApiException implements Exception {
  const StateApiException(this.failure);

  final StateApiFailure failure;
}

class ApiClient {
  ApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _timeout = Duration(seconds: 5);

  Future<bool> checkHealth() async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/health');
    try {
      final response = await _client.get(uri).timeout(_timeout);
      if (response.statusCode != 200) return false;
      final body = jsonDecode(response.body);
      return body is Map<String, dynamic> &&
          body['status'] == 'ok' &&
          body['service'] == 'inventory-api';
    } on Exception {
      return false;
    }
  }

  Future<AuthProfile> getCurrentUser({required String idToken}) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/auth/me');
    try {
      final response = await _client.get(
        uri,
        headers: {'Authorization': 'Bearer $idToken'},
      ).timeout(_timeout);
      if (response.statusCode == 401) {
        throw const AuthApiException(AuthApiFailure.unauthorized);
      }
      if (response.statusCode == 403) {
        throw const AuthApiException(AuthApiFailure.forbidden);
      }
      if (response.statusCode != 200) {
        throw const AuthApiException(AuthApiFailure.invalidResponse);
      }
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic> ||
          body['uid'] is! String ||
          body['email'] is! String ||
          body['role'] is! String) {
        throw const AuthApiException(AuthApiFailure.invalidResponse);
      }
      return AuthProfile.fromJson(body);
    } on AuthApiException {
      rethrow;
    } on Exception {
      throw const AuthApiException(AuthApiFailure.connectivity);
    }
  }

  Future<InventorySnapshot> getState({required String idToken}) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/state');
    try {
      final response = await _client.get(
        uri,
        headers: {'Authorization': 'Bearer $idToken'},
      ).timeout(_timeout);
      if (response.statusCode == 401) {
        throw const StateApiException(StateApiFailure.unauthorized);
      }
      if (response.statusCode == 403) {
        throw const StateApiException(StateApiFailure.forbidden);
      }
      if (response.statusCode == 503) {
        throw const StateApiException(StateApiFailure.unavailable);
      }
      if (response.statusCode != 200) {
        throw const StateApiException(StateApiFailure.backendError);
      }
      try {
        final decoded = jsonDecode(response.body);
        return InventorySnapshot.fromJson(_asJsonMap(decoded));
      } on FormatException {
        throw const StateApiException(StateApiFailure.malformedResponse);
      }
    } on StateApiException {
      rethrow;
    } on TimeoutException {
      throw const StateApiException(StateApiFailure.timeout);
    } on Exception {
      throw const StateApiException(StateApiFailure.connectivity);
    }
  }

  Future<EventSubmission> postEvent(
      {required String idToken,
      required String eventId,
      required String eventType,
      required int expectedVersion,
      required Map<String, dynamic> payload}) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/events');
    try {
      developer.log(
        'Dispatching authenticated POST /events (type=$eventType, expectedVersion=$expectedVersion).',
        name: 'zyro.api',
      );
      final response = await _client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $idToken',
              'Content-Type': 'application/json'
            },
            body: jsonEncode({
              'event_id': eventId,
              'event_type': eventType,
              'expected_version': expectedVersion,
              'payload': payload
            }),
          )
          .timeout(_timeout);
      developer.log('POST /events completed with HTTP ${response.statusCode}.',
          name: 'zyro.api');
      if (response.statusCode == 200) {
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is! Map<String, dynamic> ||
              decoded['event_id'] != eventId ||
              decoded['event_id'] is! String ||
              decoded['status'] is! String ||
              decoded['version'] is! int ||
              !const ['applied', 'duplicate'].contains(decoded['status'])) {
            throw const FormatException();
          }
          return EventSubmission(
              eventId: decoded['event_id'] as String,
              status: decoded['status'] as String,
              version: decoded['version'] as int);
        } on FormatException {
          throw const EventApiException(EventApiFailure.malformedResponse);
        }
      }
      final detail = _eventErrorDetail(response.body);
      final code = detail['code'];
      final message =
          detail['message'] is String ? detail['message'] as String : null;
      if (response.statusCode == 401) {
        throw const EventApiException(EventApiFailure.unauthorized);
      }
      if (response.statusCode == 403) {
        throw const EventApiException(EventApiFailure.forbidden);
      }
      if (response.statusCode == 404) {
        throw EventApiException(EventApiFailure.notFound, message: message);
      }
      if (response.statusCode == 409) {
        throw EventApiException(
            code == 'STALE_VERSION'
                ? EventApiFailure.staleVersion
                : EventApiFailure.conflict,
            message: message);
      }
      if (response.statusCode == 422) {
        throw EventApiException(EventApiFailure.validation, message: message);
      }
      if (response.statusCode == 503) {
        throw EventApiException(EventApiFailure.unavailable, message: message);
      }
      throw EventApiException(EventApiFailure.backendError, message: message);
    } on EventApiException {
      rethrow;
    } on TimeoutException {
      throw const EventApiException(EventApiFailure.timeout);
    } on Exception {
      throw const EventApiException(EventApiFailure.connectivity);
    }
  }

  Future<RecommendationResult> postRecommendations({
    required String idToken,
    required String orderId,
    required int expectedVersion,
  }) =>
      _postComputation(
        path: '/recommendations',
        idToken: idToken,
        body: {'order_id': orderId, 'expected_version': expectedVersion},
        parse: (json) => RecommendationResult.fromJson(json),
      );

  Future<SimulationResult> postSimulation({
    required String idToken,
    required String orderId,
    required String recommendationId,
    required int expectedVersion,
  }) =>
      _postComputation(
        path: '/simulate',
        idToken: idToken,
        body: {
          'order_id': orderId,
          'recommendation_id': recommendationId,
          'expected_version': expectedVersion,
        },
        parse: (json) => SimulationResult.fromJson(json),
      );

  Future<ApprovalBoard> getProposals({required String idToken}) async {
    try {
      final response = await _client.get(
        Uri.parse('${ApiConfig.baseUrl}/proposals'),
        headers: {'Authorization': 'Bearer $idToken'},
      ).timeout(_timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          return ApprovalBoard.fromJson(_asJsonMap(jsonDecode(response.body)));
        } on FormatException {
          throw const ProposalApiException(
              ProposalApiFailure.malformedResponse);
        }
      }
      throw _proposalError(response.statusCode, response.body);
    } on ProposalApiException {
      rethrow;
    } on TimeoutException {
      throw const ProposalApiException(ProposalApiFailure.timeout);
    } on Exception {
      throw const ProposalApiException(ProposalApiFailure.connectivity);
    }
  }

  Future<ProposalSubmissionResult> postProposal({
    required String idToken,
    required String orderId,
    required String recommendationId,
    required int expectedVersion,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse('${ApiConfig.baseUrl}/proposals'),
            headers: {
              'Authorization': 'Bearer $idToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'order_id': orderId,
              'recommendation_id': recommendationId,
              'expected_version': expectedVersion,
            }),
          )
          .timeout(_timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          final result = ProposalSubmissionResult.fromJson(
              _asJsonMap(jsonDecode(response.body)));
          if (result.proposal.orderId != orderId ||
              result.proposal.recommendationId != recommendationId ||
              result.version != expectedVersion) {
            throw const FormatException(
                'Proposal response does not match the submitted request.');
          }
          return result;
        } on FormatException {
          throw const ProposalApiException(
              ProposalApiFailure.malformedResponse);
        }
      }
      throw _proposalError(response.statusCode, response.body);
    } on ProposalApiException {
      rethrow;
    } on TimeoutException {
      throw const ProposalApiException(ProposalApiFailure.timeout);
    } on Exception {
      throw const ProposalApiException(ProposalApiFailure.connectivity);
    }
  }

  Future<ProposalDecisionResult> postProposalDecision({
    required String idToken,
    required String proposalId,
    required ProposalDecisionRequest request,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse(
                '${ApiConfig.baseUrl}/proposals/${Uri.encodeComponent(proposalId)}/decision'),
            headers: {
              'Authorization': 'Bearer $idToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(request.toJson()),
          )
          .timeout(_timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          final result = ProposalDecisionResult.fromJson(
              _asJsonMap(jsonDecode(response.body)));
          if (result.proposal.proposalId != proposalId ||
              (result.purchaseOrder != null &&
                  result.purchaseOrder!.proposalId != proposalId)) {
            throw const FormatException(
                'Decision response does not match the submitted proposal.');
          }
          return result;
        } on FormatException {
          throw const ProposalApiException(
              ProposalApiFailure.malformedResponse);
        }
      }
      throw _proposalError(response.statusCode, response.body);
    } on ProposalApiException {
      rethrow;
    } on TimeoutException {
      throw const ProposalApiException(ProposalApiFailure.timeout);
    } on Exception {
      throw const ProposalApiException(ProposalApiFailure.connectivity);
    }
  }

  ProposalApiException _proposalError(int statusCode, String body) {
    final detail = _eventErrorDetail(body);
    final code = detail['code'];
    final message =
        detail['message'] is String ? detail['message'] as String : null;
    final failure = switch (statusCode) {
      401 => ProposalApiFailure.unauthorized,
      403 => ProposalApiFailure.forbidden,
      404 => ProposalApiFailure.notFound,
      409 => code == 'STALE_VERSION'
          ? ProposalApiFailure.staleVersion
          : ProposalApiFailure.conflict,
      422 => ProposalApiFailure.validation,
      503 => ProposalApiFailure.unavailable,
      _ => ProposalApiFailure.backendError,
    };
    return ProposalApiException(failure, message: message);
  }

  Future<T> _postComputation<T>({
    required String path,
    required String idToken,
    required Map<String, dynamic> body,
    required T Function(Map<String, dynamic>) parse,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse('${ApiConfig.baseUrl}$path'),
            headers: {
              'Authorization': 'Bearer $idToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
      if (response.statusCode == 200) {
        try {
          final decoded = jsonDecode(response.body);
          return parse(_asJsonMap(decoded));
        } on FormatException {
          throw const ComputationApiException(
              ComputationApiFailure.malformedResponse);
        }
      }
      final detail = _eventErrorDetail(response.body);
      final message =
          detail['message'] is String ? detail['message'] as String : null;
      final failure = switch (response.statusCode) {
        401 => ComputationApiFailure.unauthorized,
        403 => ComputationApiFailure.forbidden,
        404 => ComputationApiFailure.notFound,
        409 => ComputationApiFailure.staleVersion,
        422 => ComputationApiFailure.validation,
        503 => ComputationApiFailure.unavailable,
        _ => ComputationApiFailure.backendError,
      };
      throw ComputationApiException(failure, message: message);
    } on ComputationApiException {
      rethrow;
    } on TimeoutException {
      throw const ComputationApiException(ComputationApiFailure.timeout);
    } on Exception {
      throw const ComputationApiException(ComputationApiFailure.connectivity);
    }
  }

  Map<String, dynamic> _eventErrorDetail(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const {};
    }
    if (decoded is Map<String, dynamic> &&
        decoded['detail'] is Map<String, dynamic>) {
      return decoded['detail'] as Map<String, dynamic>;
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return const {};
  }

  Map<String, dynamic> _asJsonMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    throw const FormatException(
        'Expected an object for the inventory snapshot.');
  }

  void close() => _client.close();
}
