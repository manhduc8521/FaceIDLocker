// Utility class for enhanced face comparison 
import 'dart:math' as math;

class FaceComparisonUtils {
  /// Tính điểm so sánh khuôn mặt kết hợp với trọng số
  /// Sử dụng cả Cosine Similarity và Euclidean Distance
  static double weightedFaceMatchScore(List<double> embedding1, List<double> embedding2) {
    // 1. Tính Cosine Similarity 
    final cosineSimilarity = calculateSimilarity(embedding1, embedding2);
    
    // 2. Tính Euclidean Distance và chuyển về similarity (0-1)
    final euclideanDistance = calculateDistance(embedding1, embedding2);
    // Chuyển khoảng cách thành độ tương đồng (1.0 - normalizeddistance) 
    // Ngưỡng khoảng cách tối đa dự kiến là 1.4 cho khuôn mặt hoàn toàn khác nhau
    final euclideanSimilarity = 1.0 - math.min(1.0, euclideanDistance / 1.4);
    
    // 3. Kết hợp các độ đo với trọng số
    // 60% trọng số cho cosine similarity, 40% cho euclidean similarity
    return (cosineSimilarity * 0.6) + (euclideanSimilarity * 0.4);
  }
  
  /// Tính độ tương đồng cosine giữa hai vector embedding
  static double calculateSimilarity(List<double> embedding1, List<double> embedding2) {
    if (embedding1.length != embedding2.length) {
      throw Exception('Kích thước vector không khớp');
    }
    
    double dotProduct = 0.0;
    double norm1 = 0.0;
    double norm2 = 0.0;
    
    for (int i = 0; i < embedding1.length; i++) {
      dotProduct += embedding1[i] * embedding2[i];
      norm1 += embedding1[i] * embedding1[i];
      norm2 += embedding2[i] * embedding2[i];
    }
    
    // Tránh chia cho 0
    if (norm1 <= 0 || norm2 <= 0) return 0.0;
    
    // Cosine similarity
    return dotProduct / (math.sqrt(norm1) * math.sqrt(norm2));
  }
  
  /// Tính khoảng cách Euclidean giữa hai vector
  static double calculateDistance(List<double> embedding1, List<double> embedding2) {
    if (embedding1.length != embedding2.length) {
      throw Exception('Kích thước vector không khớp');
    }
    
    double sumSquaredDifferences = 0.0;
    for (int i = 0; i < embedding1.length; i++) {
      final diff = embedding1[i] - embedding2[i];
      sumSquaredDifferences += diff * diff;
    }
    
    return math.sqrt(sumSquaredDifferences);
  }
  
  /// Kiểm tra xem hai khuôn mặt có khớp nhau không dựa trên ngưỡng
  static bool doFacesMatch(List<double> embedding1, List<double> embedding2, {double threshold = 0.82}) {
    final weightedScore = weightedFaceMatchScore(embedding1, embedding2);
    
    final matched = weightedScore > threshold;
    
    return matched;
  }
}
