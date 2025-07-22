import 'dart:typed_data';
import 'dart:math' as math;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'dart:ui';

/// Kết quả kiểm tra spoofing
class FaceDeSpoofingResult {
  final bool isReal;
  final double score;
  final String? error;

  FaceDeSpoofingResult({required this.isReal, required this.score, this.error});
  
  @override
  String toString() {
    return 'FaceDeSpoofingResult(isReal: $isReal, score: $score, error: $error)';
  }
}

/// Lớp FaceDeSpoofingChecker: Kiểm tra spoofing với mô hình FaceAntiSpoofing
/// Được tối ưu hóa với cached tensors, multi-threading và INT8 precision
class FaceDeSpoofingChecker {
  Interpreter? _interpreter;
  IsolateInterpreter? _isolateInterpreter;  // Khai báo kiểu rõ ràng
  bool _isModelLoaded = false;
  final int _inputSize = 256;
  // Cache để tái sử dụng tensors - tránh allocation mỗi lần
  List<List<List<List<double>>>>? _cachedInputTensor;
  List<List<double>>? _cachedClssPred;
  List<List<double>>? _cachedLeafNodeMask;
  
  // Cache cho processed images để tránh xử lý lại ảnh giống nhau
  final Map<String, img.Image> _processedImageCache = <String, img.Image>{};

  /// Khởi tạo Face DeSpoofing Checker
  FaceDeSpoofingChecker() {
    _loadModel();
  }

  /// Kiểm tra xem mô hình đã được tải chưa
  bool get isModelLoaded => _isModelLoaded;
  /// Tải mô hình FaceAntiSpoofing với tối ưu hóa
  Future<void> _loadModel() async {
    try {      // Tối ưu options với multi-threading
      final options = InterpreterOptions()
        ..threads = 4
        ..useNnApiForAndroid = false
        ..addDelegate(XNNPackDelegate());
      
      // Tải mô hình từ assets
      _interpreter = await Interpreter.fromAsset(
        'assets/FaceAntiSpoofing.tflite',
        options: options,
      );
      
      if (_interpreter != null) {
        _isolateInterpreter = await IsolateInterpreter.create(address: _interpreter!.address);
        
        // Pre-allocate cached tensors để tránh allocation mỗi lần
        _cachedInputTensor = List.generate(1, (_) => 
          List.generate(_inputSize, (y) => 
            List.generate(_inputSize, (x) => 
              List.filled(3, 0.0))));
        
        _cachedClssPred = List.generate(1, (_) => List.filled(8, 0.0));
        _cachedLeafNodeMask = List.generate(1, (_) => List.filled(8, 0.0));
      }

      _isModelLoaded = true;
      
    } catch (e) {
      print('Error loading FaceAntiSpoofing model: $e');
      _isModelLoaded = false;    }
  }

  /// Tối ưu hóa tensor filling với raw bytes access (nhanh hơn getPixel)
  Future<void> _fillTensorFromImageOptimized(
    img.Image processedImage, 
    List<List<List<List<double>>>> inputTensor
  ) async {
    const double inv255 = 0.00392156862745098;  // 1/255 pre-calculated
      try {
      // Lấy raw bytes data để tránh function call overhead của getPixel
      final imageData = processedImage.getBytes();
      
      int byteIndex = 0;
      for (int y = 0; y < _inputSize; y++) {
        for (int x = 0; x < _inputSize; x++) {
          // Direct byte access với RGBA format (4 bytes per pixel)
          final r = imageData[byteIndex++];     // R
          final g = imageData[byteIndex++];     // G  
          final b = imageData[byteIndex++];     // B
          byteIndex++;                          // Skip A (alpha)
          
          inputTensor[0][y][x][0] = r * inv255;
          inputTensor[0][y][x][1] = g * inv255;
          inputTensor[0][y][x][2] = b * inv255;
        }
      }
    } catch (e) {
      // Fallback to slower getPixel method if raw bytes fails
      for (int y = 0; y < _inputSize; y++) {
        for (int x = 0; x < _inputSize; x++) {
          final pixel = processedImage.getPixel(x, y);
          inputTensor[0][y][x][0] = pixel.r * inv255;
          inputTensor[0][y][x][1] = pixel.g * inv255;
          inputTensor[0][y][x][2] = pixel.b * inv255;
        }
      }
    }
  }

  /// Kiểm tra spoofing từ ảnh (được tối ưu hóa)
  Future<FaceDeSpoofingResult> checkSpoofing(Uint8List imageBytes, Rect faceBox) async {
    if (!_isModelLoaded || _interpreter == null) {
      return FaceDeSpoofingResult(isReal: false, score: 0.0, error: 'Model not loaded');
    }    try {
      // Tạo cache key từ face box và image size để kiểm tra cache
      final cacheKey = '${faceBox.left}_${faceBox.top}_${faceBox.width}_${faceBox.height}_${imageBytes.length}';
      
      img.Image? processedImage = _processedImageCache[cacheKey];
      
      if (processedImage == null) {
        // Decode ảnh
        final originalImage = img.decodeImage(imageBytes);
        if (originalImage == null) {
          return FaceDeSpoofingResult(isReal: false, score: 0.0, error: 'Không thể decode ảnh');
        }
        
        // Crop khuôn mặt với bounds checking tối ưu
        final left = math.max(0, faceBox.left.round());
        final top = math.max(0, faceBox.top.round());
        final right = math.min(originalImage.width, faceBox.right.round());
        final bottom = math.min(originalImage.height, faceBox.bottom.round());
        
        final width = right - left;
        final height = bottom - top;
        
        if (width <= 0 || height <= 0) {
          return FaceDeSpoofingResult(isReal: false, score: 0.0, error: 'Invalid face crop dimensions');
        }
        
        // Crop và resize với NEAREST interpolation
        processedImage = img.copyResize(
          img.copyCrop(originalImage, x: left, y: top, width: width, height: height),
          width: _inputSize, 
          height: _inputSize, 
          interpolation: img.Interpolation.nearest
        );
        
        // Cache processed image để sử dụng lại (giới hạn cache size)
        if (_processedImageCache.length >= 5) {
          // Remove oldest entry khi cache đầy
          final firstKey = _processedImageCache.keys.first;
          _processedImageCache.remove(firstKey);
        }
        _processedImageCache[cacheKey] = processedImage;
      }
        // Sử dụng cached tensor thay vì tạo mới
      final inputTensor = _cachedInputTensor!;
      
      // Tối ưu hóa tensor filling với raw bytes access
      await _fillTensorFromImageOptimized(processedImage, inputTensor);
      
      // Sử dụng cached output tensors
      final clssPred = _cachedClssPred!;
      final leafNodeMask = _cachedLeafNodeMask!;
      
      // Reset outputs (faster than creating new arrays)      // Chạy inference trên isolate
      await _isolateInterpreter!.runForMultipleInputs(
        [inputTensor],
        {0: clssPred, 1: leafNodeMask}
      );
      
      // Tính điểm với unrolled loop cho performance tối ưu
      double score = clssPred[0][0].abs() * leafNodeMask[0][0] +
                     clssPred[0][1].abs() * leafNodeMask[0][1] +
                     clssPred[0][2].abs() * leafNodeMask[0][2] +
                     clssPred[0][3].abs() * leafNodeMask[0][3] +
                     clssPred[0][4].abs() * leafNodeMask[0][4] +
                     clssPred[0][5].abs() * leafNodeMask[0][5] +
                     clssPred[0][6].abs() * leafNodeMask[0][6] +
                     clssPred[0][7].abs() * leafNodeMask[0][7];
      
      // Theo Java: THRESHOLD = 0.2f, nếu score > threshold thì là tấn công
      const double threshold = 0.2;
      bool isReal = score <= threshold;  // <= threshold thì là thật
      
      return FaceDeSpoofingResult(isReal: isReal, score: score);
      
    } catch (e) {
      return FaceDeSpoofingResult(isReal: false, score: 0.0, error: e.toString());
    }
  }  /// Giải phóng tài nguyên
  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isolateInterpreter = null;
    
    // Clean up cached tensors
    _cachedInputTensor = null;
    _cachedClssPred = null;
    _cachedLeafNodeMask = null;
    
    // Clear image cache
    _processedImageCache.clear();
      _isModelLoaded = false;
  }

  /// Clear processed image cache để giải phóng memory
  void clearImageCache() {
    _processedImageCache.clear();
  }
  
  /// Lấy số lượng images trong cache
  int get cacheSize => _processedImageCache.length;
}