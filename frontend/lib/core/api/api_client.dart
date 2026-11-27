import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';

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

  void close() => _client.close();
}
