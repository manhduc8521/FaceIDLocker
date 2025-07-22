import 'dart:io';
import 'dart:ui';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

/// Lớp FaceEmbedder: Trích xuất vector đặc trưng khuôn mặt sử dụng mô hình FaceNet
/// Được tối ưu hóa để chạy trên isolate riêng biệt
class FaceEmbedder {
  Interpreter? _faceNetInterpreter;
  IsolateInterpreter? _isolateInterpreter;
  bool _isModelLoaded = false;
  
  // Kích thước đầu vào của mô hình
  final int _inputSize = 112;
  
  // Kích thước đầu ra của mô hình (embedding)
  final int _embeddingSize = 192;
  
  /// Khởi tạo Face Embedder
  FaceEmbedder() {
    _loadModel();
  }
  
  /// Kiểm tra xem mô hình đã được tải chưa
  bool get isModelLoaded => _isModelLoaded;
  
  /// Tải mô hình MobileFaceNet
  Future<void> _loadModel() async {
    try {
      final options = InterpreterOptions()
      ..threads = 2
      ..useNnApiForAndroid = false
      ..addDelegate(XNNPackDelegate());
    
        _faceNetInterpreter = await Interpreter.fromAsset(
        'assets/MobileFaceNet.tflite',
        options: options,
      );
      
      // Tạo isolate interpreter từ main interpreter
      if (_faceNetInterpreter != null) {
        _isolateInterpreter = await IsolateInterpreter.create(
          address: _faceNetInterpreter!.address
        );
      }
      
      _isModelLoaded = true;
      // Đã tải thành công MobileFaceNet
    } catch (e) {
      // Lỗi tải mô hình MobileFaceNet
      _isModelLoaded = false;
    }
  }  /// Trích xuất đặc trưng khuôn mặt từ ảnh (được tối ưu hóa)
  Future<FaceEmbeddingResult> getFaceEmbedding(String imagePath, Rect faceBox) async {
    if (!_isModelLoaded || _isolateInterpreter == null) {
      return FaceEmbeddingResult(
        embedding: List<double>.filled(_embeddingSize, 0.0),
        success: false,
        error: 'Mô hình chưa được tải'
      );
    }
    
    try {
      // Đọc ảnh từ file
      final imageBytes = await File(imagePath).readAsBytes();
      
      // Xử lý ảnh trực tiếp
      final inputTensor = await _processImageDirectly(imageBytes, faceBox);
      
      // Chuẩn bị buffer đầu ra: batch size 2, mỗi batch có _embeddingSize phần tử
      var outputBuffer = List.generate(2, (_) => List<double>.filled(_embeddingSize, 0.0));
      
      // Chạy mô hình ML trên isolate
      await _isolateInterpreter!.run(inputTensor, outputBuffer);
      
      // L2 chuẩn hóa vector embedding của batch đầu tiên (index 0)
      final normalizedEmbedding = _l2Normalize(outputBuffer[0]);
      
      return FaceEmbeddingResult(
        embedding: normalizedEmbedding,
        success: true,
        error: null
      );
    } catch (e) {
      return FaceEmbeddingResult(
        embedding: List<double>.filled(_embeddingSize, 0.0),
        success: false,
        error: 'Lỗi trích xuất đặc trưng khuôn mặt: $e',
      );
    }
  }
    /// Trích xuất embedding từ bytes ảnh và bounding box (được tối ưu hóa)
  Future<FaceEmbeddingResult> getFaceEmbeddingFromBytes(Uint8List imageBytes, Rect faceBox) async {
    if (!_isModelLoaded || _isolateInterpreter == null) {
      return FaceEmbeddingResult(
        embedding: List<double>.filled(_embeddingSize, 0.0),
        success: false,
        error: 'Mô hình chưa được tải',
      );
    }
    
    try {
      // Xử lý ảnh trực tiếp
      final inputTensor = await _processImageDirectly(imageBytes, faceBox);
      
      // Chuẩn bị buffer đầu ra: batch size 2, mỗi batch có _embeddingSize phần tử
      var outputBuffer = List.generate(2, (_) => List<double>.filled(_embeddingSize, 0.0));
      
      // Chạy mô hình ML trên isolate
      await _isolateInterpreter!.run(inputTensor, outputBuffer);
      
      // L2 chuẩn hóa vector embedding của batch đầu tiên (index 0)
      final normalizedEmbedding = _l2Normalize(outputBuffer[0]);
      
      return FaceEmbeddingResult(
        embedding: normalizedEmbedding,
        success: true,
        error: null,
      );
    } catch (e) {
      return FaceEmbeddingResult(
        embedding: List<double>.filled(_embeddingSize, 0.0),
        success: false,
        error: 'Lỗi trích xuất đặc trưng khuôn mặt: $e',
      );
    }
  }

  /// Xử lý ảnh trực tiếp trên main thread (được tối ưu hóa)
  Future<List<List<List<List<double>>>>> _processImageDirectly(Uint8List imageBytes, Rect faceBox) async {
    // Decode ảnh
    final originalImage = img.decodeImage(imageBytes);
    if (originalImage == null) {
      throw Exception('Không thể decode ảnh');
    }
    
    // Tính toán crop bounds với margin
    const double margin = 0.1;
    final xMargin = (faceBox.width * margin).round();
    final yMargin = (faceBox.height * margin).round();
    
    final left = math.max(0, faceBox.left.round() - xMargin);
    final top = math.max(0, faceBox.top.round() - yMargin);
    final width = math.min(
      originalImage.width - left,
      faceBox.width.round() + 2 * xMargin
    );
    final height = math.min(
      originalImage.height - top,
      faceBox.height.round() + 2 * yMargin
    );
    
    // Crop và resize trong một bước
    final processedImage = img.copyResize(
      img.copyCrop(originalImage, x: left, y: top, width: width, height: height),
      width: _inputSize,
      height: _inputSize,
      interpolation: img.Interpolation.cubic
    );
    
    // Chuẩn bị input tensor batch size 2 (ảnh thứ 2 là zeros)
    var inputTensor = List.generate(
      2,
      (batchIdx) => List.generate(
        _inputSize,
        (_) => List.generate(
          _inputSize,
          (_) => List<double>.filled(3, 0.0),
        ),
      ),
    );
    
    // Thu thập pixel values để tính mean và std
    double sum = 0.0;
    List<double> pixelValues = [];
    
    for (int y = 0; y < _inputSize; y++) {
      for (int x = 0; x < _inputSize; x++) {
        final pixel = processedImage.getPixel(x, y);
        
        final r = pixel.r / 255.0;
        final g = pixel.g / 255.0;
        final b = pixel.b / 255.0;
        
        pixelValues.add(r);
        pixelValues.add(g);
        pixelValues.add(b);
        
        sum += r + g + b;
      }
    }
    
    // Tính mean
    final mean = sum / pixelValues.length;
    
    // Tính standard deviation
    double squaredSum = 0.0;
    for (final value in pixelValues) {
      squaredSum += math.pow(value - mean, 2);
    }
    var stdDev = math.sqrt(squaredSum / pixelValues.length);
    stdDev = math.max(stdDev, 1.0 / math.sqrt(pixelValues.length.toDouble()));
    
    // Fill tensor với normalized values cho ảnh đầu tiên (batch 0)
    for (int y = 0; y < _inputSize; y++) {
      for (int x = 0; x < _inputSize; x++) {
        final pixel = processedImage.getPixel(x, y);
        final r = pixel.r;
        final g = pixel.g;
        final b = pixel.b;
        inputTensor[0][y][x][0] = (r / 255.0 - mean) / stdDev;
        inputTensor[0][y][x][1] = (g / 255.0 - mean) / stdDev;
        inputTensor[0][y][x][2] = (b / 255.0 - mean) / stdDev;
      }
    }
    // batch 1 giữ nguyên là zeros
    
    return inputTensor;
  }
  
  /// Tính độ tương đồng cosine giữa hai vector embedding
  double calculateSimilarity(List<double> embedding1, List<double> embedding2) {
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
  
  /// L2 chuẩn hóa vector
  List<double> _l2Normalize(List<double> embedding) {
    double sumSquares = 0.0;
    for (var val in embedding) {
      sumSquares += val * val;
    }
    
    if (sumSquares > 0) {
      final norm = math.sqrt(sumSquares);
      for (int i = 0; i < embedding.length; i++) {
        embedding[i] = embedding[i] / norm;
      }
    }
    
    return embedding;
  }
  
  /// Tính khoảng cách Euclidean giữa hai vector
  /// Khoảng cách càng nhỏ, hai khuôn mặt càng giống nhau
  double calculateDistance(List<double> embedding1, List<double> embedding2) {
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
  
  /// Tính trung bình của nhiều vector embedding
  List<double> calculateAverageEmbedding(List<List<double>> embeddings) {
    if (embeddings.isEmpty) {
      return List<double>.filled(_embeddingSize, 0.0);
    }
    
    // Khởi tạo vector trung bình
    List<double> averageEmbedding = List<double>.filled(_embeddingSize, 0.0);
    
    // Tổng tất cả vector
    for (var embedding in embeddings) {
      for (int i = 0; i < _embeddingSize; i++) {
        averageEmbedding[i] += embedding[i];
      }
    }
    
    // Chia trung bình
    for (int i = 0; i < _embeddingSize; i++) {
      averageEmbedding[i] /= embeddings.length;
    }
    
    // Chuẩn hóa vector trung bình
    return _l2Normalize(averageEmbedding);
  }
    /// Giải phóng tài nguyên
  void dispose() {
    _faceNetInterpreter?.close();
    _isolateInterpreter = null;
    _isModelLoaded = false;
  }
}

/// Lớp chứa kết quả trích xuất đặc trưng khuôn mặt
class FaceEmbeddingResult {
  final List<double> embedding;   // Vector đặc trưng khuôn mặt
  final bool success;            // Trạng thái thành công hay thất bại
  final String? error;           // Lỗi (nếu có)
  
  FaceEmbeddingResult({
    required this.embedding,
    required this.success,
    this.error,
  });
}