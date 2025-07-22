/// Enhanced face matching result for Euclidean distance
class FaceMatchResult {
  final bool isMatch;
  final double distance;           // Raw Euclidean distance
  final double normalizedDistance; // Normalized Euclidean distance
  final double confidence;         // Confidence score (0.0 - 1.0)
  final String decision;           // Decision reasoning
  
  FaceMatchResult({
    required this.isMatch,
    required this.distance,
    required this.normalizedDistance,
    required this.confidence,
    required this.decision,
  });
  
  @override
  String toString() {
    return 'FaceMatchResult('
        'isMatch: $isMatch, '
        'distance: ${distance.toStringAsFixed(3)}, '
        'normalizedDistance: ${normalizedDistance.toStringAsFixed(3)}, '
        'confidence: ${(confidence * 100).toStringAsFixed(1)}%, '
        'decision: $decision)';
  }
}
