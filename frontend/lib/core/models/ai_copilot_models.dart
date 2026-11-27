enum AiResponseMode {
  gemini('gemini'),
  deterministicFallback('deterministic_fallback');

  const AiResponseMode(this.wireValue);
  final String wireValue;

  static AiResponseMode parse(Object? value) =>
      AiResponseMode.values.firstWhere((mode) => mode.wireValue == value,
          orElse: () =>
              throw FormatException('Unknown AI response mode: $value'));
}

enum AiEvidenceSource {
  inventory('inventory'),
  order('order'),
  supplier('supplier'),
  event('event'),
  alert('alert'),
  recommendation('recommendation'),
  simulation('simulation'),
  proposal('proposal'),
  purchaseOrder('purchase_order'),
  audit('audit');

  const AiEvidenceSource(this.wireValue);
  final String wireValue;

  static AiEvidenceSource parse(Object? value) =>
      AiEvidenceSource.values.firstWhere(
        (source) => source.wireValue == value,
        orElse: () =>
            throw FormatException('Unknown evidence source type: $value'),
      );
}

enum AiInsightSeverity {
  info('info'),
  warning('warning'),
  critical('critical');

  const AiInsightSeverity(this.wireValue);
  final String wireValue;

  static AiInsightSeverity parse(Object? value) =>
      AiInsightSeverity.values.firstWhere(
        (severity) => severity.wireValue == value,
        orElse: () => throw FormatException('Unknown insight severity: $value'),
      );
}

class AiEvidence {
  const AiEvidence({
    required this.evidenceId,
    required this.sourceType,
    required this.sourceId,
    required this.summary,
  });

  final String evidenceId;
  final AiEvidenceSource sourceType;
  final String sourceId;
  final String summary;

  factory AiEvidence.fromJson(Map<String, dynamic> json) => AiEvidence(
        evidenceId: _aiString(json, 'evidence_id'),
        sourceType: AiEvidenceSource.parse(json['source_type']),
        sourceId: _aiString(json, 'source_id'),
        summary: _aiString(json, 'summary'),
      );
}

class AiAnswer {
  const AiAnswer({
    required this.version,
    required this.role,
    required this.mode,
    required this.answer,
    required this.evidence,
    required this.suggestedQuestions,
    required this.warnings,
  });

  final int version;
  final String role;
  final AiResponseMode mode;
  final String answer;
  final List<AiEvidence> evidence;
  final List<String> suggestedQuestions;
  final List<String> warnings;

  factory AiAnswer.fromJson(Map<String, dynamic> json) => AiAnswer(
        version: _aiInt(json, 'version'),
        role: _aiString(json, 'role'),
        mode: AiResponseMode.parse(json['mode']),
        answer: _aiString(json, 'answer'),
        evidence: _aiEvidenceList(json, 'evidence'),
        suggestedQuestions: _aiStringList(json, 'suggested_questions'),
        warnings: _aiStringList(json, 'warnings'),
      );
}

class AiInsight {
  const AiInsight({
    required this.title,
    required this.description,
    required this.severity,
    required this.orderId,
    required this.evidence,
    required this.suggestedQuestion,
  });

  final String title;
  final String description;
  final AiInsightSeverity severity;
  final String? orderId;
  final List<AiEvidence> evidence;
  final String suggestedQuestion;

  factory AiInsight.fromJson(Map<String, dynamic> json) {
    if (!json.containsKey('order_id') ||
        (json['order_id'] != null && json['order_id'] is! String)) {
      throw const FormatException('Expected order_id to be a string or null.');
    }
    return AiInsight(
      title: _aiString(json, 'title'),
      description: _aiString(json, 'description'),
      severity: AiInsightSeverity.parse(json['severity']),
      orderId: json['order_id'] as String?,
      evidence: _aiEvidenceList(json, 'evidence'),
      suggestedQuestion: _aiString(json, 'suggested_question'),
    );
  }
}

class AiBriefing {
  const AiBriefing({
    required this.version,
    required this.role,
    required this.mode,
    required this.headline,
    required this.summary,
    required this.insights,
    required this.warnings,
  });

  final int version;
  final String role;
  final AiResponseMode mode;
  final String headline;
  final String summary;
  final List<AiInsight> insights;
  final List<String> warnings;

  factory AiBriefing.fromJson(Map<String, dynamic> json) => AiBriefing(
        version: _aiInt(json, 'version'),
        role: _aiString(json, 'role'),
        mode: AiResponseMode.parse(json['mode']),
        headline: _aiString(json, 'headline'),
        summary: _aiString(json, 'summary'),
        insights: _aiInsightList(json, 'insights'),
        warnings: _aiStringList(json, 'warnings'),
      );
}

List<AiEvidence> _aiEvidenceList(Map<String, dynamic> json, String key) =>
    _aiObjectList(json, key, AiEvidence.fromJson);

List<AiInsight> _aiInsightList(Map<String, dynamic> json, String key) =>
    _aiObjectList(json, key, AiInsight.fromJson);

List<T> _aiObjectList<T>(Map<String, dynamic> json, String key,
    T Function(Map<String, dynamic>) parse) {
  final value = json[key];
  if (value is! List) throw FormatException('Expected $key to be a list.');
  return List<T>.unmodifiable(value.map((item) => parse(_aiMap(item))));
}

List<String> _aiStringList(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List || value.any((item) => item is! String)) {
    throw FormatException('Expected $key to contain only strings.');
  }
  return List<String>.unmodifiable(value.cast<String>());
}

Map<String, dynamic> _aiMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  throw const FormatException('Expected an AI response object.');
}

String _aiString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Expected $key to be a non-empty string.');
  }
  return value;
}

int _aiInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) {
    throw FormatException('Expected $key to be a non-negative integer.');
  }
  return value;
}
