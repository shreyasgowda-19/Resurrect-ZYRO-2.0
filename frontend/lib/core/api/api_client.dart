import 'dart:convert';
import 'dart:async';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/inventory_snapshot.dart';

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

  Map<String, dynamic> _asJsonMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    throw const FormatException(
        'Expected an object for the inventory snapshot.');
  }

  void close() => _client.close();
}
