import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'cabinet_selection.dart';
import 'embeddings/face_embedder.dart';
import 'embeddings/face_match_result.dart';
import 'face_detection/camera_view.dart';
import 'face_detection/face_detector_painter.dart';
import 'face_detection/face_despoofing_checker.dart';
import 'services/model_manager.dart';
import 'services/usb_serial_helper.dart';

/// Trạng thái xác thực
enum AuthState { initial, detecting, processing, success, failure }

/// Lớp quản lý xác thực khuôn mặt với hiệu suất cao và độ chính xác tốt
class OptimizedFaceAuth extends StatefulWidget {
  final Cabinet cabinet;

  const OptimizedFaceAuth({super.key, required this.cabinet});

  @override
  State createState() => _OptimizedFaceAuthState();
}

class _OptimizedFaceAuthState extends State<OptimizedFaceAuth> {
  // Camera reference
  final GlobalKey<CameraViewState> _cameraKey = GlobalKey<CameraViewState>();

  // Face Detection
  late FaceDetector _faceDetector;
  bool _isFaceDetectorInitialized = false;
  CustomPaint? _customPaint;
  bool _isBusy = false;
  bool _isAuthenticating = false;
  Timer? _scanTimer;
  String _instruction = 'Nhìn vào camera';
  AuthState _currentState = AuthState.initial;

  // Dispose flag để tránh setState sau khi dispose
  bool _isDisposed = false;

  // Security: Failure tracking and temporary lock
  int _failureCount = 0; // Đếm số lần thất bại liên tiếp
  bool _isTemporarilyLocked = false; // Trạng thái khóa tạm thời
  DateTime? _lockEndTime; // Thời gian kết thúc khóa
  Timer? _lockTimer; // Timer cho countdown dialog

  // Face Quality-based Capture
  int _consecutiveGoodFrames = 0; // Số frames tốt liên tiếp
  static const int _requiredGoodFrames = 3; // Cần 3 frames tốt để trigger
  Face? _bestFace; // Face tốt nhất trong window
  double _bestQualityScore = 0.0; // Điểm chất lượng cao nhất

  // Sử dụng AIModelManager thay vì khởi tạo riêng
  FaceEmbedder? get _faceEmbedder => AIModelManager.instance.faceEmbedder;
  FaceDeSpoofingChecker? get _spoofingChecker =>
      AIModelManager.instance.spoofingChecker;
  bool get _modelLoaded => AIModelManager.instance.isInitialized;
  UsbSerialHelper? get _usbHelper => AIModelManager.instance.usbHelper;

  @override
  void initState() {
    super.initState();
    _initFaceDetector();
    _startContinuousScan();
    // Không cần khởi tạo USB ở đây nữa, đã có ở model_manager
  }

  /// Ngưỡng kích thước khuôn mặt tối thiểu (tỷ lệ với chiều rộng ảnh)
  static const double _minFaceSize = 0.1;

  /// Đánh giá chất lượng khuôn mặt - BỎ CENTER POSITION - NÂNG LÊN 75%
  double _calculateFaceQuality(Face face, InputImage inputImage) {
    final imageSize = inputImage.metadata!.size;
    final faceBox = face.boundingBox;

    double qualityScore = 0.0;

    // 1. Size quality (35% weight) - TỐI ƯU CHO 20-40CM
    final faceRatio = faceBox.width / imageSize.width;
    double sizeScore = 0.0;

    // KHOẢNG CÁCH 20-40CM: Face Ratio 20-40%
    if (faceRatio >= 0.18 && faceRatio <= 0.4) {
      // Optimal zone cho locker authentication (20-40cm)
      sizeScore =
          1.0 - math.max(0, (0.3 - faceRatio).abs() / 0.1); // Optimal tại 30%
    }
    qualityScore += sizeScore * 0.35;

    // 2. Pose quality (giảm trọng số, nới lỏng góc) - FLEXIBLE FOR LOCKER
    double poseScore = 0.0;
    final yawAngle = face.headEulerAngleY?.abs() ?? 45.0;
    final rollAngle = face.headEulerAngleZ?.abs() ?? 45.0;
    if (yawAngle <= 32.0 && rollAngle <= 32.0) {
      poseScore = 1.0 - ((yawAngle + rollAngle) / 64.0);
    } else if (yawAngle <= 45.0 && rollAngle <= 45.0) {
      poseScore = 0.5 - ((yawAngle + rollAngle - 64.0) / 64.0);
    }
    qualityScore += poseScore * 0.18;

    // 4. Landmarks quality (20% weight) - PRACTICAL CHO LOCKER
    double landmarkScore = 0.0;
    if (face.landmarks.isNotEmpty) {
      landmarkScore = 1.0;
    } else {
      landmarkScore = 0.6; // Still acceptable cho locker usage
    }
    qualityScore += landmarkScore * 0.20;

    // 5. Stability bonus (15% weight) - QUICK AUTHENTICATION
    double stabilityScore = 0.0;
    if (_bestFace != null) {
      final prevBox = _bestFace!.boundingBox;
      final movement = math.sqrt(
        math.pow(faceBox.center.dx - prevBox.center.dx, 2) +
            math.pow(faceBox.center.dy - prevBox.center.dy, 2),
      );
      stabilityScore = math.max(
        0.0,
        1.0 - (movement / 80.0),
      ); // Quick stability
    } else {
      stabilityScore = 0.7; // Good initial score cho quick auth
    }
    qualityScore += stabilityScore * 0.15;

    return qualityScore.clamp(0.0, 1.0);
  }

  /// Khởi tạo Face Detector
  Future<void> _initFaceDetector() async {
    try {
      _faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          enableContours: false,
          enableClassification: false,
          minFaceSize: _minFaceSize,
          performanceMode: FaceDetectorMode.accurate,
          enableLandmarks: false,
        ),
      );
      if (mounted && !_isDisposed) {
        setState(() {
          _isFaceDetectorInitialized = true;
        });
      }
    } catch (e) {
      // Error initializing Face Detector
    }
  }

  /// Xử lý hình ảnh từ camera để phát hiện khuôn mặt
  Future<void> _processImage(InputImage inputImage) async {
    if (_isBusy) return;
    _isBusy = true;

    try {
      final faces = await _faceDetector.processImage(inputImage);

      if (inputImage.metadata?.size != null &&
          inputImage.metadata?.rotation != null) {
        final painter = FaceDetectorPainter(
          faces,
          inputImage.metadata!.size,
          inputImage.metadata!.rotation,
        );
        _customPaint = CustomPaint(painter: painter);
        // Cập nhật instruction dựa trên face detection với quality assessment
        if (faces.isEmpty) {
          _consecutiveGoodFrames = 0;
          _bestFace = null;
          _bestQualityScore = 0.0;
          _instruction = 'Không phát hiện khuôn mặt - Hãy nhìn vào camera';
        } else if (faces.length == 1) {
          final face = faces.first;
          final qualityScore = _calculateFaceQuality(face, inputImage);

          // Quality-based triggering - GIẢM XUỐNG 68% (không cần center position)
          if (qualityScore >= 0.68) {
            // Từ 0.75 → 0.68 (68%)
            _consecutiveGoodFrames++;

            // Track best face trong window
            if (qualityScore > _bestQualityScore) {
              _bestFace = face;
              _bestQualityScore = qualityScore;
            }

            _instruction =
                'Khuôn mặt chất lượng tốt - Vị trí linh hoạt (${_consecutiveGoodFrames}/$_requiredGoodFrames)';

            // Trigger authentication khi đạt stability requirement
            if (_consecutiveGoodFrames >= _requiredGoodFrames &&
                !_isAuthenticating &&
                _currentState == AuthState.initial &&
                !_isTemporarilyLocked) {
              print(
                "🎯 Optimal capture moment (no center required): Quality=${qualityScore.toStringAsFixed(3)}, "
                "Consecutive=${_consecutiveGoodFrames}",
              );
              _authenticateUser();
            }
          } else if (qualityScore >= 0.45) {
            // Từ 0.50 → 0.45 (45%)
            _consecutiveGoodFrames = 0; // Reset counter
            _instruction = 'Chất lượng khá - Không cần ở giữa khung hình';
          } else {
            _consecutiveGoodFrames = 0; // Reset counter

            // Specific feedback - BỎ CENTER POSITION REQUIREMENTS
            final imageSize = inputImage.metadata!.size;
            final faceRatio = face.boundingBox.width / imageSize.width;

            if (faceRatio < 0.2) {
              _instruction = 'Khuôn mặt quá nhỏ - Đến gần camera hơn';
            } else if (face.headEulerAngleY!.abs() > 37) {
              _instruction =
                  'Hãy nhìn thẳng vào camera (góc ngang: ${face.headEulerAngleY!.toInt()}°)';
            } else if (face.headEulerAngleZ!.abs() > 37) {
              _instruction =
                  'Hãy giữ đầu thẳng (góc nghiêng: ${face.headEulerAngleZ!.toInt()}°)';
            } else if (face.landmarks.isEmpty) {
              _instruction = 'Cần ánh sáng tốt hơn để phát hiện landmarks';
            } else {
              _instruction =
                  'Chất lượng chưa đủ - Cải thiện ánh sáng và vị trí';
            }
          }

          // Show temporary lock status if applicable
          if (_isTemporarilyLocked) {
            final remaining =
                _lockEndTime != null
                    ? _lockEndTime!.difference(DateTime.now()).inSeconds
                    : 0;
            if (remaining > 0) {
              _instruction =
                  'Tạm khóa do thất bại nhiều lần. Còn ${remaining}s';
            }
          }
        } else {
          _consecutiveGoodFrames = 0;
          _bestFace = null;
          _bestQualityScore = 0.0;
          _instruction =
              'Phát hiện nhiều khuôn mặt - Chỉ một người trong khung hình';
        }
      } else {
        _customPaint = null;
      }
    } catch (e) {
      _customPaint = null;
    }
    _isBusy = false;
    if (mounted && !_isDisposed) {
      setState(() {});
    }
  }

  /// Bắt đầu quá trình xác thực người dùng với parallel processing - ULTRA OPTIMIZED
  Future<void> _authenticateUser() async {
    // Check if temporarily locked
    if (_isTemporarilyLocked) {
      final remaining =
          _lockEndTime != null
              ? _lockEndTime!.difference(DateTime.now()).inSeconds
              : 0;
      if (remaining > 0) {
        setState(() {
          _instruction = 'Tạm khóa do thất bại nhiều lần. Còn ${remaining}s';
        });
        return;
      } else {
        // Lock expired, reset
        _resetLock();
      }
    }

    if (_isAuthenticating || !_modelLoaded || _isDisposed) return;

    if (!mounted || _isDisposed) return;

    setState(() {
      _isAuthenticating = true;
      _currentState = AuthState.detecting;
      _instruction = 'Đang xác thực...';
    });

    try {
      // GIẢM DELAY: 150ms → 30ms cho camera stabilization
      await Future.delayed(const Duration(milliseconds: 30));

      // Capture image với optimal timing
      final captureResult = await _captureOptimalImage();
      if (captureResult == null) {
        _handleAuthFailure('Không thể chụp ảnh chất lượng tốt');
        return;
      }

      final (capturedImage, imageBytes, bestFace) = captureResult;

      // PARALLEL LOADING: Load saved data song song với UI update
      final savedDataFuture = _loadSavedFaceData();

      // Immediate UI feedback
      setState(() {
        _currentState = AuthState.processing;
        _instruction = 'Đang xử lý AI...';
      });

      // Load saved data
      final savedEmbedding = await savedDataFuture;
      if (savedEmbedding == null) {
        _handleAuthFailure('Không tìm thấy dữ liệu khuôn mặt đã đăng ký');
        return;
      }

      // TRIPLE PARALLEL PROCESSING: 3 tasks cùng lúc
      final results = await Future.wait([
        _performSpoofingCheck(imageBytes, bestFace.boundingBox),
        _performFaceRecognition(capturedImage.path, bestFace.boundingBox),
        _validateSavedEmbedding(savedEmbedding), // Task thứ 3
      ]);

      final spoofResult = results[0] as FaceDeSpoofingResult;
      final currentEmbedding = results[1] as List<double>?;
      final savedValid = results[2] as bool;

      // Fast validation với early exit
      if (!spoofResult.isReal) {
        _handleAuthFailure(
          'Phát hiện giả mạo! Vui lòng sử dụng khuôn mặt thật.',
        );
        return;
      }

      if (currentEmbedding == null || !savedValid) {
        _handleAuthFailure('Không thể trích xuất đặc trưng khuôn mặt');
        return;
      }

      // FAST MATCHING: Bỏ validation redundant
      setState(() {
        _instruction = 'Đang so sánh...';
      });

      // Enhanced matching với pre-validated embeddings
      final matchResult = _performFastEuclideanMatching(
        savedEmbedding,
        currentEmbedding,
      );

      if (matchResult.isMatch) {
        await _handleAuthSuccess();
      } else {
        _handleAuthFailure(
          'Xác thực thất bại (MobileFaceNet)\n'
          'Distance: ${matchResult.normalizedDistance.toStringAsFixed(3)} > 0.67',
        );
      }
    } catch (e) {
      _handleAuthFailure('Lỗi xác thực: $e');
    }
  }

  // Helper methods để tách logic
  Future<(XFile, Uint8List, Face)?> _captureOptimalImage() async {
    if (_cameraKey.currentState == null || _bestFace == null) return null;

    final capturedImage = await _cameraKey.currentState!.takePicture();
    if (capturedImage == null) return null;

    final imageBytes = await capturedImage.readAsBytes();
    return (capturedImage, imageBytes, _bestFace!);
  }

  Future<List<double>?> _loadSavedFaceData() async {
    final prefs = await SharedPreferences.getInstance();
    final savedData = prefs.getString(
      'face_data_${widget.cabinet.id}_khu${widget.cabinet.boardAddress}',
    );
    if (savedData == null) return null;

    final faceData = jsonDecode(savedData);
    return List<double>.from(faceData['embedding']);
  }

  Future<bool> _validateSavedEmbedding(List<double> embedding) async {
    return _validateEmbeddingQuality(embedding);
  }

  void _handleAuthFailure(String message) {
    setState(() {
      _currentState = AuthState.failure;
      _instruction = message;
    });
    _resetAfterFailure();
  }

  Future<void> _handleAuthSuccess() async {
    _resetFailureCount();

    setState(() {
      _currentState = AuthState.success;
      _instruction = 'Đang mở tủ...';
    });

    // Gửi lệnh mở tủ qua USB Serial
    List<String> parts = widget.cabinet.id.split(' ');
    int cabinetNumber = int.parse(parts.last);
    int address = widget.cabinet.boardAddress;
    bool unlockSuccess = false;
    if (_usbHelper != null) {
      unlockSuccess = await _usbHelper!.unlockE2(address, cabinetNumber);
    }

    // Show success dialog with unlock result
    _showSuccessDialog(unlockSuccess);
  }

  void _showSuccessDialog(bool unlockSuccess) {
    if (!mounted || _isDisposed) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  unlockSuccess ? Icons.lock_open : Icons.lock,
                  size: 64,
                  color: unlockSuccess ? Colors.green : Colors.orange,
                ),
                const SizedBox(height: 16),
                Text(
                  unlockSuccess
                      ? 'Xác thực thành công!\nTủ đã mở'
                      : 'Xác thực thành công!\nTủ chưa được mở',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
    );

    // Auto close after 3 seconds like backup version
    Timer(const Duration(seconds: 3), () {
      if (mounted && Navigator.canPop(context)) {
        Navigator.of(context).pop();
        Navigator.of(context).pop(true);
      }
    });
  }

  /// Helper method: Thực hiện spoofing check (parallel task 1) - OPTIMIZED
  Future<FaceDeSpoofingResult> _performSpoofingCheck(
    Uint8List imageBytes,
    Rect faceBox,
  ) async {
    if (_spoofingChecker == null) {
      return FaceDeSpoofingResult(
        isReal: false,
        score: 1.0,
        error: 'Not available',
      );
    }

    try {
      // Add timeout để tránh hang
      return await _spoofingChecker!
          .checkSpoofing(imageBytes, faceBox)
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      return FaceDeSpoofingResult(
        isReal: false,
        score: 1.0,
        error: 'Failed: $e',
      );
    }
  }

  /// Helper method: Thực hiện face recognition (parallel task 2) - OPTIMIZED
  Future<List<double>?> _performFaceRecognition(
    String imagePath,
    Rect faceBox,
  ) async {
    try {
      if (_faceEmbedder == null) return null;

      // Add timeout để tránh hang
      final result = await _faceEmbedder!
          .getFaceEmbedding(imagePath, faceBox)
          .timeout(const Duration(seconds: 3));

      return result.success && result.embedding.isNotEmpty
          ? result.embedding
          : null;
    } catch (e) {
      return null;
    }
  }

  /// FIXED: Correct Euclidean matching với proper validation
  FaceMatchResult _performFastEuclideanMatching(
    List<double> savedEmbedding,
    List<double> currentEmbedding,
  ) {
    // Step 1: Validation (MobileFaceNet produces 192-dimensional embeddings)
    if (savedEmbedding.length != currentEmbedding.length ||
        savedEmbedding.length != 192) {
      return FaceMatchResult(
        isMatch: false,
        distance: double.infinity,
        normalizedDistance: double.infinity,
        confidence: 0.0,
        decision: 'Invalid MobileFaceNet embedding dimensions (expected 192)',
      );
    }

    // Step 2: Calculate CORRECT normalized Euclidean distance
    double normalizedDistance = _calculateCorrectEuclideanDistance(
      savedEmbedding,
      currentEmbedding,
    );

    // Step 3: Single threshold decision (DeepFace research-based)
    const double threshold = 0.67; // MobileFaceNet DeepFace threshold

    bool isMatch = normalizedDistance <= threshold;

    // Step 4: Calculate confidence score
    double confidence = 0.0;
    String decision = '';

    if (isMatch) {
      // Linear confidence calculation
      confidence = 1.0 - (normalizedDistance / threshold);
      confidence = confidence.clamp(0.0, 1.0);

      // Detailed decision based on confidence level
      if (confidence >= 0.8) {
        decision = 'Very High Confidence (MobileFaceNet)';
      } else if (confidence >= 0.6) {
        decision = 'High Confidence (MobileFaceNet)';
      } else if (confidence >= 0.4) {
        decision = 'Medium Confidence (MobileFaceNet)';
      } else if (confidence >= 0.2) {
        decision = 'Low Confidence (MobileFaceNet)';
      } else {
        decision = 'Very Low Confidence (MobileFaceNet)';
      }
    } else {
      confidence = 0.0;

      // Detailed rejection reasons for debugging
      if (normalizedDistance > threshold * 1.5) {
        decision = 'Very Different Face';
      } else if (normalizedDistance > threshold * 1.2) {
        decision = 'Different Face';
      } else {
        decision = 'Close but No Match';
      }
    }

    return FaceMatchResult(
      isMatch: isMatch,
      distance: normalizedDistance, // Use normalized as primary distance
      normalizedDistance: normalizedDistance,
      confidence: confidence,
      decision: decision,
    );
  }

  /// FIXED: Correct Euclidean distance calculation (DeepFace style)
  double _calculateCorrectEuclideanDistance(
    List<double> embedding1,
    List<double> embedding2,
  ) {
    if (embedding1.length != embedding2.length) {
      return double.infinity;
    }

    // Step 1: Normalize embeddings (critical for Euclidean distance accuracy)
    List<double> normalized1 = _normalizeEmbedding(embedding1);
    List<double> normalized2 = _normalizeEmbedding(embedding2);

    // Step 2: Calculate standard Euclidean distance
    double sumSquaredDifferences = 0.0;

    for (int i = 0; i < normalized1.length; i++) {
      final diff = normalized1[i] - normalized2[i];
      sumSquaredDifferences += diff * diff;
    }

    return math.sqrt(sumSquaredDifferences);
  }

  /// Normalize embeddings before distance calculation (DeepFace best practice)
  List<double> _normalizeEmbedding(List<double> embedding) {
    if (embedding.isEmpty) return embedding;

    // Calculate L2 norm
    double norm = 0.0;
    for (double value in embedding) {
      norm += value * value;
    }
    norm = math.sqrt(norm);

    // Avoid division by zero
    if (norm == 0.0) return embedding;

    // Normalize each component
    return embedding.map((value) => value / norm).toList();
  }

  /// Bắt đầu quét liên tục
  void _startContinuousScan() {
    _scanTimer = Timer.periodic(const Duration(milliseconds: 400), (timer) {
      if (!_isAuthenticating &&
          _currentState == AuthState.initial &&
          _modelLoaded) {
        // Ready for next authentication attempt
      }
    });
  }

  /// Widget để hiển thị camera với face detection
  Widget _buildCameraWidget() {
    if (_isFaceDetectorInitialized) {
      return FutureBuilder<List<CameraDescription>>(
        future: availableCameras(),
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            return CameraView(
              key: _cameraKey,
              cameras: snapshot.data!,
              customPaint: _customPaint,
              onImage: _processImage,
              initialDirection: CameraLensDirection.front,
            );
          } else {
            return const Center(child: CircularProgressIndicator());
          }
        },
      );
    } else {
      return const Center(child: CircularProgressIndicator());
    }
  }

  /// Lấy màu dựa vào trạng thái
  Color _getStateColor() {
    switch (_currentState) {
      case AuthState.detecting:
        return Colors.blue;
      case AuthState.processing:
        return Colors.purple;
      case AuthState.success:
        return Colors.green;
      case AuthState.failure:
        return Colors.red;
      default:
        return Colors.black54;
    }
  }

  @override
  void dispose() {
    // Đặt flag để tránh setState sau dispose
    _isDisposed = true;

    // Cancel timers first
    _scanTimer?.cancel();
    _scanTimer = null;
    _lockTimer?.cancel();
    _lockTimer = null;
    // Stop authentication if running
    _isAuthenticating = false;
    // Giải phóng các detector
    try {
      _faceDetector.close();
    } catch (e) {
      // Error disposing Face Detector
    }

    // Don't dispose models - they're managed by singleton

    try {
      if (_isFaceDetectorInitialized) {
        _faceDetector.close();
      }
    } catch (e) {
      // Error disposing FaceDetector
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Xác thực - ${widget.cabinet.id}'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // Camera view with face detection
          Expanded(
            flex: 2,
            child:
                _isFaceDetectorInitialized
                    ? Container(
                      margin: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _buildCameraWidget(), // Thêm chỉ báo trạng thái
                            Positioned(
                              top: 20,
                              right: 20,
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      _isFaceDetectorInitialized
                                          ? 'Face Detector: Đã kích hoạt'
                                          : 'Face Detector: Đang khởi tạo...',
                                      style: TextStyle(
                                        color:
                                            _isFaceDetectorInitialized
                                                ? Colors.green
                                                : Colors.orange,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _modelLoaded
                                          ? 'AI Model: Đã tải'
                                          : 'AI Model: Đang tải...',
                                      style: TextStyle(
                                        color:
                                            _modelLoaded
                                                ? Colors.green
                                                : Colors.orange,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _spoofingChecker != null
                                          ? 'Spoof Checker: Đã tải'
                                          : 'Spoof Checker: Đang tải...',
                                      style: TextStyle(
                                        color:
                                            _spoofingChecker != null
                                                ? Colors.green
                                                : Colors.orange,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // Hướng dẫn và trạng thái
                            Positioned(
                              bottom: 0,
                              left: 0,
                              right: 0,
                              child: Container(
                                padding: const EdgeInsets.all(8.0),
                                color: Colors.black54,
                                child: Text(
                                  _instruction,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                    : const Center(child: CircularProgressIndicator()),
          ),
          // Status area
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16.0),
                    decoration: BoxDecoration(
                      color: _getStateColor(),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Trạng thái: ${_currentState.name}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (_isAuthenticating)
                          const LinearProgressIndicator(
                            backgroundColor: Colors.white24,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Extract face embedding from current camera frame
  /// Reset state after authentication failure
  void _resetAfterFailure() {
    _failureCount++;

    // Reset quality tracking
    _consecutiveGoodFrames = 0;
    _bestFace = null;
    _bestQualityScore = 0.0;

    // Check if we need to temporarily lock after 3 failures
    if (_failureCount >= 3) {
      _activateTemporaryLock();
      return;
    }

    // Normal reset after failure (less than 3 times)
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && !_isDisposed) {
        setState(() {
          _currentState = AuthState.initial;
          _instruction = 'Nhìn vào camera (Thất bại: $_failureCount/3)';
          _isAuthenticating = false;
        });
      }
    });
  }

  /// Reset failure count (called on successful authentication)
  void _resetFailureCount() {
    _failureCount = 0;
  }

  /// Reset temporary lock state
  void _resetLock() {
    _isTemporarilyLocked = false;
    _lockEndTime = null;
    _lockTimer?.cancel();
    _lockTimer = null;
    _failureCount = 0;

    // Reset quality tracking
    _consecutiveGoodFrames = 0;
    _bestFace = null;
    _bestQualityScore = 0.0;
  }

  /// Activate temporary lock after 3 failures
  void _activateTemporaryLock() {
    _isTemporarilyLocked = true;
    _lockEndTime = DateTime.now().add(const Duration(seconds: 5));
    _isAuthenticating = false;

    setState(() {
      _currentState = AuthState.failure;
      _instruction = 'Quá nhiều lần thất bại. Thử lại sau 5 giây...';
    });

    // Show countdown dialog
    _showLockDialog();
  }

  /// Show countdown dialog during lock period
  void _showLockDialog() {
    if (!mounted || _isDisposed) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return _CountdownDialog(
          onComplete: () {
            if (mounted && !_isDisposed) {
              _resetLock();
              setState(() {
                _currentState = AuthState.initial;
                _instruction = 'Nhìn vào camera';
              });
            }
          },
        );
      },
    );
  }
}

/// Countdown Dialog Widget for temporary lock
class _CountdownDialog extends StatefulWidget {
  final VoidCallback onComplete;

  const _CountdownDialog({required this.onComplete});

  @override
  State<_CountdownDialog> createState() => _CountdownDialogState();
}

class _CountdownDialogState extends State<_CountdownDialog> {
  int _countdown = 5;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startCountdown();
  }

  void _startCountdown() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _countdown--;
      });

      if (_countdown <= 0) {
        timer.cancel();
        if (mounted) {
          Navigator.of(context).pop();
          widget.onComplete();
        }
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.security, color: Colors.red),
          SizedBox(width: 8),
          Text('Bảo mật'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_clock, size: 64, color: Colors.orange),
          const SizedBox(height: 16),
          const Text(
            'Quá nhiều lần xác thực thất bại!',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text('Hệ thống sẽ khóa tạm thời.', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Column(
              children: [
                Text(
                  'Thử lại sau:',
                  style: TextStyle(
                    color: Colors.red.shade700,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$_countdown',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.red.shade700,
                  ),
                ),
                Text('giây', style: TextStyle(color: Colors.red.shade700)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

bool _validateEmbeddingQuality(List<double> embedding) {
  // MobileFaceNet produces exactly 192-dimensional embeddings
  if (embedding.length != 192) {
    return false;
  }

  // Check for all zeros
  if (embedding.every((val) => val == 0.0)) {
    return false;
  }

  // Check for NaN or Infinite values
  if (embedding.any((val) => val.isNaN || val.isInfinite)) {
    return false;
  }

  // Calculate L2 norm (should be ~1.0 after normalization)
  double l2Norm = math.sqrt(
    embedding.map((val) => val * val).reduce((a, b) => a + b),
  );

  // L2 norm should be close to 1.0 for normalized embeddings
  if (l2Norm < 0.5 || l2Norm > 1.0) {
    return false;
  }

  // CRITICAL: Check variance (good embeddings MUST have sufficient variance)
  double mean = embedding.reduce((a, b) => a + b) / embedding.length;
  double variance =
      embedding
          .map((val) => (val - mean) * (val - mean))
          .reduce((a, b) => a + b) /
      embedding.length;

  if (variance < 0.0001) {
    return false;
  }

  return true;
}
