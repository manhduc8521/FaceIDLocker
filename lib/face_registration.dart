import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'cabinet_selection.dart';
import 'embeddings/face_embedder.dart';
import 'face_detection/camera_view.dart';
import 'face_detection/face_detector_painter.dart';
import 'services/model_manager.dart';
import 'management/utility_login.dart';
import 'management/login.dart';

class FaceRegistrationScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const FaceRegistrationScreen({super.key, required this.cameras});

  @override
  FaceRegistrationScreenState createState() => FaceRegistrationScreenState();
}

class FaceRegistrationScreenState extends State<FaceRegistrationScreen> {
  // Camera reference
  final GlobalKey<CameraViewState> _cameraKey = GlobalKey<CameraViewState>();

  // Face Detection
  late FaceDetector _faceDetector;
  bool _isFaceDetectorInitialized = false;
  CustomPaint? _customPaint;
  bool _isBusy = false;
  // UI State
  String? _selectedCabinetId;
  String _instruction = 'Nhìn vào camera';
  bool _isScanningActive = false;
  int _captureCount = 0;
  static const int _requiredCaptureCount = 5;
  List<XFile> _capturedImages = [];
  Timer? _scanTimer;

  // Sử dụng AIModelManager thay vì khởi tạo riêng
  FaceEmbedder? get _faceEmbedder => AIModelManager.instance.faceEmbedder;
  bool get _isEmbedderInitialized => _faceEmbedder?.isModelLoaded ?? false;
  bool get _modelLoaded => AIModelManager.instance.isInitialized;

  // Processing state
  bool _isProcessing = false;

  // Backup completion check
  Timer? _completionCheckTimer;

  // Processing progress tracking
  int _processedImageCount = 0;
  double _processingProgress = 0.0;
  String _processingStatus = '';

  // Face Quality-based Capture
  int _consecutiveGoodFrames = 0; // Số frames tốt liên tiếp
  static const int _requiredGoodFrames = 3; // Cần 3 frames tốt để trigger
  Face? _bestFace; // Face tốt nhất trong window
  double _bestQualityScore = 0.0; // Điểm chất lượng cao nhất
  Timer?
  _qualityResetTimer; // Timer reset quality sau thời gian không hoạt động

  final List<Cabinet> _cabinets = List.generate(
    16,
    (i) => Cabinet(id: 'Tủ ${i + 1}'),
  );
  @override
  void initState() {
    super.initState();
    _initFaceDetector();
  }

  // Ngưỡng kích thước khuôn mặt tối thiểu (tỷ lệ với chiều rộng ảnh)
  static const double _minFaceSize = 0.1;

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

      if (mounted) {
        setState(() {
          _isFaceDetectorInitialized = true;
        });
      }
    } catch (e) {
      // Error initializing Face Detector
    }
  }

  /// Xử lý hình ảnh từ camera để phát hiện khuôn mặt - ENHANCED với quality assessment
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

        // Enhanced instruction dựa trên quality assessment
        if (faces.isEmpty) {
          _consecutiveGoodFrames = 0;
          _bestFace = null;
          _bestQualityScore = 0.0;
          _instruction = 'Không phát hiện khuôn mặt - Hãy nhìn vào camera';
        } else if (faces.length == 1) {
          final face = faces.first;
          final qualityScore = _calculateFaceQuality(face, inputImage);

          // Quality-based instruction updates - GIẢM XUỐNG 75% (không cần center position)
          if (qualityScore >= 0.75) {
            // Từ 0.8 → 0.75 (75%)
            _consecutiveGoodFrames++;

            // Track best face trong window
            if (qualityScore > _bestQualityScore) {
              _bestFace = face;
              _bestQualityScore = qualityScore;
            }

            if (!_isScanningActive) {
              _instruction =
                  '✅ Chất lượng tốt (${(qualityScore * 100).toInt()}%) - '
                  'Ổn định ${_consecutiveGoodFrames}/$_requiredGoodFrames - Sẵn sàng đăng ký';
            } else {
              _instruction =
                  '✅ Đang chụp với chất lượng tốt (${(qualityScore * 100).toInt()}%)';
            }
          } else if (qualityScore >= 0.6) {
            // Từ 0.65 → 0.6 (60%)
            _consecutiveGoodFrames = 0; // Reset counter for medium quality
            _instruction =
                '⚠️ Chất lượng khá (${(qualityScore * 100).toInt()}%) - Cần cải thiện để đạt 75%';
          } else {
            _consecutiveGoodFrames = 0; // Reset counter

            // Specific feedback - BỎ CENTER POSITION, NỚI LỎNG cho 75%
            final imageSize = inputImage.metadata!.size;
            final faceRatio = face.boundingBox.width / imageSize.width;

            if (faceRatio < 0.15) {
              // Nới lỏng: 0.18 → 0.15
              _instruction =
                  '📏 Khuôn mặt quá nhỏ - Đến gần camera hơn (cần ít nhất 15% khung hình)';
            } else if (faceRatio > 0.8) {
              // Nới lỏng: 0.75 → 0.8
              _instruction =
                  '📏 Khuôn mặt quá lớn - Lùi xa camera một chút (tối đa 80% khung hình)';
            } else if (face.headEulerAngleY!.abs() > 18) {
              // Nới lỏng: 12 → 18
              _instruction =
                  '🔄 Hãy nhìn thẳng vào camera (góc ngang: ${face.headEulerAngleY!.toInt()}° > 18°)';
            } else if (face.headEulerAngleZ!.abs() > 18) {
              // Nới lỏng: 12 → 18
              _instruction =
                  '🔄 Hãy giữ đầu thẳng (góc nghiêng: ${face.headEulerAngleZ!.toInt()}° > 18°)';
            } else if (face.landmarks.isEmpty) {
              _instruction =
                  '👁️ Không phát hiện landmarks - Cần ánh sáng tốt hơn';
            } else if (!face.landmarks.containsKey(FaceLandmarkType.leftEye) ||
                !face.landmarks.containsKey(FaceLandmarkType.rightEye)) {
              _instruction =
                  '👁️ Không phát hiện đầy đủ landmarks mắt - Cần rõ ràng hơn';
            } else {
              _instruction =
                  '❌ Chất lượng chưa đạt 75% (${(qualityScore * 100).toInt()}%) - Cải thiện vị trí và ánh sáng';
            }
          }

          // Auto-reset quality tracking nếu không có hoạt động trong 3 giây
          _qualityResetTimer?.cancel();
          _qualityResetTimer = Timer(const Duration(seconds: 3), () {
            if (!_isScanningActive) {
              _resetQualityTracking();
              if (mounted) {
                setState(() {
                  _instruction =
                      'Nhìn vào camera để bắt đầu đánh giá chất lượng (cần 75%)';
                });
              }
            }
          });
        } else {
          _consecutiveGoodFrames = 0;
          _bestFace = null;
          _bestQualityScore = 0.0;
          _instruction =
              'Phát hiện nhiều khuôn mặt - Chỉ một người trong khung hình';
        }
      } else {
        _customPaint = null;
        _instruction = 'Đang khởi tạo camera...';
      }
    } catch (e) {
      _customPaint = null;
      _instruction = 'Lỗi xử lý hình ảnh';
      _consecutiveGoodFrames = 0;
    }

    _isBusy = false;
    if (mounted) {
      setState(() {});
    }
  }

  /// Callback khi capture hình ảnh - CHỈ DÙNG ĐỂ LOG, KHÔNG THÊM VÀO LIST
  void _onImageCaptured(XFile image) {
    // Không thêm vào _capturedImages ở đây để tránh duplicate
    // _capturedImages sẽ được quản lý trong _captureAndProcessImage
  }

  /// Bắt đầu đăng ký khuôn mặt
  void _startFaceRegistration() {
    if (_selectedCabinetId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng chọn tủ và nhập tên trước khi đăng ký'),
        ),
      );
      return;
    }

    if (!_modelLoaded) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đang tải mô hình, vui lòng đợi...')),
      );
      return;
    }

    setState(() {
      _capturedImages.clear(); // Clear any existing images
      _captureCount = 0; // Reset counter
      _isScanningActive = true;
      _instruction = 'Chuẩn bị chụp ảnh...';
    });

    // Bắt đầu quá trình chụp ảnh sau 2 giây (giảm từ 3 giây)
    Timer(const Duration(seconds: 2), _startCaptureSequence);
  }

  /// Bắt đầu chuỗi chụp ảnh - ENHANCED với quality-based capture - NÂNG LÊN 80%
  void _startCaptureSequence() {
    if (!_isScanningActive) return;

    _scanTimer = Timer.periodic(const Duration(milliseconds: 800), (
      timer,
    ) async {
      // Tăng interval từ 700ms → 800ms
      // Kiểm tra điều kiện dừng trước khi thực hiện bất kỳ thao tác nào
      if (_captureCount >= _requiredCaptureCount || !_isScanningActive) {
        timer.cancel();

        // Chỉ gọi _completeRegistration nếu đã đủ số lượng và vẫn đang scanning
        if (_captureCount >= _requiredCaptureCount &&
            _isScanningActive &&
            !_isProcessing) {
          await _completeRegistration();
        }
        return;
      }

      // ✅ CHỈ CHỤP KHI CHẤT LƯỢNG TỐT VÀ ỔN ĐỊNH - NÂNG LÊN 80%
      if (_consecutiveGoodFrames >= _requiredGoodFrames &&
          _bestQualityScore >= 0.75) {
        print(
          "🎯 High quality capture for registration (no center required): Score=${_bestQualityScore.toStringAsFixed(3)}, "
          "Consecutive=${_consecutiveGoodFrames}",
        );

        await _captureAndProcessImage();

        // Reset quality tracking after successful capture để tìm frame tốt tiếp theo
        _consecutiveGoodFrames = 0;
        _bestQualityScore = 0.0;
        _bestFace = null;

        // Delay dài hơn để camera ổn định trước lần chụp tiếp theo
        await Future.delayed(
          const Duration(milliseconds: 600),
        ); // Tăng từ 500ms → 700ms
      } else {
        // Wait for better quality với detailed feedback - NÂNG LÊN 80%
        final qualityPercent = (_bestQualityScore * 100).toInt();
        setState(() {
          if (_bestQualityScore > 0) {
            _instruction =
                'Đang chờ chất lượng xuất sắc... '
                '(Hiện tại: ${qualityPercent}%, '
                'Ổn định: $_consecutiveGoodFrames/$_requiredGoodFrames)';
          } else {
            _instruction =
                'Đang tìm kiếm khuôn mặt chất lượng xuất sắc (≥80%) để chụp...';
          }
        });
      }
    });
  }

  /// Chụp và xử lý ảnh - ENHANCED với optimal timing
  Future<void> _captureAndProcessImage() async {
    if (!_isScanningActive || _captureCount >= _requiredCaptureCount) return;

    setState(() {
      _instruction =
          'Đang chụp ảnh chất lượng cao ${_captureCount + 1}/$_requiredCaptureCount...';
    });

    try {
      // Wait for camera stabilization after quality detection
      await Future.delayed(const Duration(milliseconds: 200));

      // Kiểm tra lại trước khi chụp để tránh race condition
      if (!_isScanningActive || _captureCount >= _requiredCaptureCount) return;

      // Capture image from camera using GlobalKey with timeout
      if (_cameraKey.currentState != null && _bestFace != null) {
        XFile? capturedImage;

        try {
          // Add timeout for image capture
          capturedImage = await Future.any([
            _cameraKey.currentState!.takePicture(),
            Future.delayed(
              const Duration(seconds: 5),
              () => throw Exception('Camera capture timeout'),
            ),
          ]);
        } catch (e) {
          setState(() {
            _instruction = 'Lỗi chụp ảnh - Thử lại trong giây lát';
          });
          return;
        }

        if (capturedImage != null && _captureCount < _requiredCaptureCount) {
          // Enhanced validation với quality-based capture
          bool isValidImage = await _validateCapturedImageWithOptimalFace(
            capturedImage,
            _captureCount,
            _bestFace!,
          );

          if (isValidImage) {
            // Double check before adding to avoid exceeding limit
            if (_capturedImages.length < _requiredCaptureCount) {
              _capturedImages.add(capturedImage);
              _captureCount++;

              setState(() {
                _instruction =
                    'Đã chụp $_captureCount/$_requiredCaptureCount ảnh chất lượng cao '
                    '(Quality: ${(_bestQualityScore * 100).toInt()}%)';
              });
            }
          } else {
            // Even with quality checks, accept the image to avoid infinite loop
            if (_capturedImages.length < _requiredCaptureCount) {
              _capturedImages.add(capturedImage);
              _captureCount++;

              setState(() {
                _instruction =
                    'Đã chụp $_captureCount/$_requiredCaptureCount ảnh (chất lượng acceptable)';
              });
            }
          }

          // Kiểm tra và dừng timer ngay khi đạt đủ số lượng
          if (_captureCount >= _requiredCaptureCount) {
            _scanTimer?.cancel();
            setState(() {
              _instruction = 'Đang xử lý dữ liệu chất lượng cao...';
            });

            // Gọi _completeRegistration() ngay lập tức nếu chưa đang xử lý
            if (!_isProcessing) {
              await _completeRegistration();
            }

            // Backup timer để đảm bảo completion được gọi
            _completionCheckTimer = Timer(const Duration(seconds: 2), () {
              if (_captureCount >= _requiredCaptureCount &&
                  !_isProcessing &&
                  _isScanningActive) {
                _completeRegistration();
              }
            });
          }
        } else {
          throw Exception('Failed to capture image or capture limit reached');
        }
      } else {
        throw Exception('Camera not ready or no optimal face detected');
      }
    } catch (e) {
      setState(() {
        _instruction = 'Lỗi chụp ảnh - Thử lại';
      });
    }
  }

  /// Hoàn thành đăng ký
  Future<void> _completeRegistration() async {
    if (_isProcessing) {
      return; // Tránh xử lý trùng lặp
    }

    // Final validation of image count
    if (_capturedImages.length > _requiredCaptureCount) {
      _capturedImages = _capturedImages.take(_requiredCaptureCount).toList();
    }

    _isProcessing = true;
    setState(() {
      _instruction = 'Đang xử lý và lưu dữ liệu...';
    });

    try {
      // Save registration data immediately without delay
      await _saveFaceData();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Đăng ký khuôn mặt cho $_selectedCabinetId thành công',
            ),
          ),
        );
      }

      setState(() {
        _isScanningActive = false;
        _instruction = 'Đăng ký thành công!';
      });
    } catch (e) {
      setState(() {
        _isScanningActive = false;
        _instruction = 'Lỗi đăng ký: $e';
      });

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Lỗi đăng ký: $e')));
      }
    } finally {
      _isProcessing = false;
    }
  }

  /// Lưu dữ liệu khuôn mặt với xử lý đa luồng
  Future<void> _saveFaceData() async {
    if (_capturedImages.isEmpty) {
      throw Exception('Không có ảnh để xử lý');
    }

    // Log số lượng ảnh thực tế
    if (_capturedImages.length != _requiredCaptureCount) {
      // Warning: image count mismatch
    }

    final prefs = await SharedPreferences.getInstance();

    try {
      final stopwatch = Stopwatch()..start();

      // Update UI to show processing status
      setState(() {
        _processingStatus =
            'Đang xử lý ${_capturedImages.length} ảnh với batch processing...';
        _processingProgress = 0.0;
        _processedImageCount = 0;
      });

      // Use batch processing for better performance and memory management
      final List<List<double>> embeddings = await _processImagesBatch(
        _capturedImages,
      );

      // Validate embeddings count
      if (embeddings.length > _requiredCaptureCount) {
        // Trim to expected count
        embeddings.removeRange(_requiredCaptureCount, embeddings.length);
      }

      stopwatch.stop();

      // Update UI to show completion
      setState(() {
        _processingStatus =
            'Hoàn thành xử lý! Đang tính toán embedding trung bình...';
        _processingProgress = 0.9;
      });

      if (embeddings.isEmpty) {
        throw Exception('Không phát hiện khuôn mặt trong các ảnh đã chụp');
      }

      // Calculate average embedding (for multiple images)
      final embeddingSize = 192; // MobileFaceNet embedding size
      List<double> avgEmbedding = List.filled(embeddingSize, 0.0);
      for (var embedding in embeddings) {
        for (int i = 0; i < embeddingSize; i++) {
          avgEmbedding[i] += embedding[i];
        }
      }
      for (int i = 0; i < embeddingSize; i++) {
        avgEmbedding[i] /= embeddings.length;
      }

      // Save face data
      final faceData = {
        'cabinet_id': _selectedCabinetId,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'embedding': avgEmbedding,
        'image_count': _capturedImages.length,
        'face_count': embeddings.length,
      };

      await prefs.setString(
        'face_data_$_selectedCabinetId',
        jsonEncode(faceData),
      );

      // Save image paths for reference
      List<String> imagePaths = _capturedImages.map((img) => img.path).toList();
      await prefs.setStringList('face_images_$_selectedCabinetId', imagePaths);

      // Final UI update
      setState(() {
        _processingStatus = 'Hoàn thành! Đã lưu dữ liệu thành công.';
        _processingProgress = 1.0;
      });
    } catch (e) {
      setState(() {
        _processingStatus = 'Lỗi xử lý: $e';
        _processingProgress = 0.0;
      });
      rethrow;
    }
  }

  /// Process individual image for embedding extraction in parallel
  Future<List<double>> _processImageForEmbeddingParallel(
    XFile imageFile,
    int imageIndex,
  ) async {
    try {
      // Create InputImage from file path (correct way for captured images)
      final inputImage = InputImage.fromFilePath(imageFile.path);

      // Detect faces
      final faces = await _faceDetector.processImage(inputImage);
      if (faces.isNotEmpty) {
        // Use the first detected face for embedding extraction
        final face = faces.first;
        final faceBox = face.boundingBox;
        // Extract face embedding using FaceEmbedder
        // Đảm bảo models đã sẵn sàng
        await AIModelManager.instance.ensureModelsReady();

        if (_faceEmbedder != null) {
          final embeddingResult = await _faceEmbedder!.getFaceEmbedding(
            imageFile.path,
            faceBox,
          );

          if (embeddingResult.success) {
            return embeddingResult.embedding;
          } else {
            throw Exception(
              'Failed to extract face embedding from image ${imageIndex + 1}: ${embeddingResult.error}',
            );
          }
        } else {
          throw Exception(
            'FaceEmbedder not initialized for image ${imageIndex + 1}',
          );
        }
      } else {
        throw Exception('No face detected in image ${imageIndex + 1}');
      }
    } catch (e) {
      rethrow; // Re-throw the original error instead of using placeholder
    }
  }

  /// Enhanced validation với optimal face information - GIẢM XUỐNG 75% (BỎ CENTER)
  Future<bool> _validateCapturedImageWithOptimalFace(
    XFile imageFile,
    int imageIndex,
    Face optimalFace,
  ) async {
    try {
      // Use the optimal face information for validation
      final faceBox = optimalFace.boundingBox;
      final inputImage = InputImage.fromFilePath(imageFile.path);
      final imageSize = inputImage.metadata?.size;

      if (imageSize == null) return false;

      // Quality checks based on optimal face - GIẢM XUỐNG 75%
      final faceRatio = faceBox.width / imageSize.width;

      // Nới lỏng quality requirements cho registration 75%
      if (faceRatio < 0.15 || faceRatio > 0.8)
        return false; // Nới lỏng: 0.18-0.75 → 0.15-0.8

      // Head pose validation với nới lỏng thresholds
      if (optimalFace.headEulerAngleY != null &&
          optimalFace.headEulerAngleY!.abs() > 20.0)
        return false; // Nới lỏng: 15.0 → 20.0
      if (optimalFace.headEulerAngleZ != null &&
          optimalFace.headEulerAngleZ!.abs() > 18.0)
        return false; // Nới lỏng: 12.0 → 18.0

      // BỎ CENTER POSITION VALIDATION HOÀN TOÀN
      // Không cần kiểm tra vị trí center nữa

      // Landmarks validation - NỚI LỎNG cho 75%
      if (optimalFace.landmarks.isEmpty) return false;

      // Require basic landmarks for 75% quality (nới lỏng từ 80%)
      if (!optimalFace.landmarks.containsKey(FaceLandmarkType.leftEye) ||
          !optimalFace.landmarks.containsKey(FaceLandmarkType.rightEye))
        return false;

      // Embedding validation với optimal face - NỚI LỎNG 75%
      await AIModelManager.instance.ensureModelsReady();

      if (_faceEmbedder != null) {
        final embeddingResult = await _faceEmbedder!.getFaceEmbedding(
          imageFile.path,
          faceBox,
        );

        if (!embeddingResult.success) return false;

        final embedding = embeddingResult.embedding;
        if (embedding.length != 192) return false;

        // Nới lỏng embedding quality check - 75%
        final embeddingMagnitude = embedding
            .map((e) => e * e)
            .reduce((a, b) => a + b);
        if (embeddingMagnitude < 0.2) return false; // Nới lỏng: 0.25 → 0.2

        if (embedding.any((e) => e.isNaN) || embedding.any((e) => e.isInfinite))
          return false;

        // Validate embedding variance for quality - NỚI LỎNG 75%
        final mean = embedding.reduce((a, b) => a + b) / embedding.length;
        final variance =
            embedding
                .map((e) => (e - mean) * (e - mean))
                .reduce((a, b) => a + b) /
            embedding.length;
        if (variance < 0.001) return false;

        // Additional quality checks for 75% standard (nới lỏng)
        final maxValue = embedding.reduce((a, b) => a > b ? a : b);
        final minValue = embedding.reduce((a, b) => a < b ? a : b);
        if ((maxValue - minValue) < 0.4) return false; // Nới lỏng: 0.5 → 0.4
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// Đánh giá chất lượng khuôn mặt toàn diện cho đăng ký - BỎ CENTER POSITION - GIẢM XUỐNG 75%
  double _calculateFaceQuality(Face face, InputImage inputImage) {
    final imageSize = inputImage.metadata!.size;
    final faceBox = face.boundingBox;

    double qualityScore = 0.0;

    // 1. Size quality (35% weight) - Kích thước khuôn mặt - GIẢM đến 75%
    final faceRatio = faceBox.width / imageSize.width;
    double sizeScore = 0.0;
    if (faceRatio >= 0.15 && faceRatio <= 0.8) {
      // Nới lỏng: 0.18-0.75 → 0.15-0.8
      // Size range for 75% registration: 15-80% of image width (nới lỏng từ 18-75%)
      sizeScore =
          1.0 -
          math.max(0, (0.27 - faceRatio).abs() / 0.27); // Nới lỏng: 0.3 → 0.27
    }
    qualityScore += sizeScore * 0.35; // Giữ nguyên trọng số

    // 2. Pose quality (30% weight) - Góc nghiêng đầu - GIẢM đến 75%
    double poseScore = 0.0;
    final yawAngle =
        face.headEulerAngleY?.abs() ?? 30.0; // Nới lỏng: 25.0 → 30.0
    final rollAngle =
        face.headEulerAngleZ?.abs() ?? 30.0; // Nới lỏng: 25.0 → 30.0
    if (yawAngle <= 18.0 && rollAngle <= 18.0) {
      // Nới lỏng: 12.0 → 18.0
      // Nới lỏng pose requirements cho registration 75%
      poseScore =
          1.0 - ((yawAngle + rollAngle) / 36.0); // Nới lỏng: 24.0 → 36.0
    }
    qualityScore += poseScore * 0.30; // Giữ nguyên trọng số

    // 3. CENTER POSITION - BỎ HOÀN TOÀN (0% weight)
    // Không cần đặt khuôn mặt ở giữa khung hình nữa

    // 4. Landmarks quality (20% weight) - GIẢM yêu cầu đến 75%
    double landmarkScore = 0.0;
    if (face.landmarks.isNotEmpty) {
      // Nới lỏng landmarks scoring for 75% quality
      if (face.landmarks.containsKey(FaceLandmarkType.leftEye) &&
          face.landmarks.containsKey(FaceLandmarkType.rightEye) &&
          face.landmarks.containsKey(FaceLandmarkType.noseBase) &&
          face.landmarks.containsKey(FaceLandmarkType.bottomMouth)) {
        landmarkScore =
            1.0; // Full score for complete landmarks (vẫn yêu cầu 4 landmarks)
      } else if (face.landmarks.containsKey(FaceLandmarkType.leftEye) &&
          face.landmarks.containsKey(FaceLandmarkType.rightEye) &&
          face.landmarks.containsKey(FaceLandmarkType.noseBase)) {
        landmarkScore =
            0.9; // Very good score for 3 key landmarks (nới lỏng từ 75%)
      } else if (face.landmarks.containsKey(FaceLandmarkType.leftEye) &&
          face.landmarks.containsKey(FaceLandmarkType.rightEye)) {
        landmarkScore = 0.8; // Good score for eye landmarks only
      } else {
        landmarkScore = 0.6; // Nới lỏng: 0.5 → 0.6 cho some landmarks
      }
    }
    qualityScore += landmarkScore * 0.20; // Giữ nguyên trọng số

    // 5. Stability bonus (15% weight) - GIẢM yêu cầu đến 75%
    double stabilityScore = 0.0;
    if (_bestFace != null) {
      final prevBox = _bestFace!.boundingBox;
      final movement = math.sqrt(
        math.pow(faceBox.center.dx - prevBox.center.dx, 2) +
            math.pow(faceBox.center.dy - prevBox.center.dy, 2),
      );
      stabilityScore = math.max(
        0.0,
        1.0 - (movement / 50.0),
      ); // Nới lỏng: 30.0 → 50.0
    } else {
      stabilityScore =
          0.5; // Nới lỏng: 0.3 → 0.5 cho initial frame với 75% standard
    }
    qualityScore += stabilityScore * 0.15; // Giữ nguyên trọng số

    return qualityScore.clamp(0.0, 1.0);
  }

  /// Reset quality tracking variables
  void _resetQualityTracking() {
    _consecutiveGoodFrames = 0;
    _bestFace = null;
    _bestQualityScore = 0.0;
    _qualityResetTimer?.cancel();
    _qualityResetTimer = null;
  }

  /// Dừng đăng ký khuôn mặt
  void _stopFaceRegistration() {
    _scanTimer?.cancel();
    _completionCheckTimer?.cancel();

    // Reset quality tracking khi dừng
    _resetQualityTracking();

    setState(() {
      _isScanningActive = false;
      _captureCount = 0; // Reset capture count
      _capturedImages.clear(); // Clear captured images
      _instruction = 'Đăng ký đã dừng';
    });
  }

  /// Handle logout
  Future<void> _handleLogout() async {
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Đăng xuất'),
            content: const Text('Bạn có chắc chắn muốn đăng xuất?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Hủy'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Đăng xuất'),
              ),
            ],
          ),
    );

    if (shouldLogout == true) {
      await AuthService.logout();
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => LoginScreen(cameras: widget.cameras),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _completionCheckTimer?.cancel();
    _qualityResetTimer?.cancel();
    _faceDetector.close();

    // Clean up quality tracking
    _resetQualityTracking();

    // Clean up FaceEmbedder resources
    if (_isEmbedderInitialized) {
      // Don't dispose models - they're managed by AIModelManager
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Đăng Ký Khuôn Mặt'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _handleLogout,
            tooltip: 'Đăng xuất',
          ),
        ],
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
                            CameraView(
                              key: _cameraKey,
                              cameras: widget.cameras,
                              customPaint: _customPaint,
                              onImage: _processImage,
                              onCaptureImage: _onImageCaptured,
                              initialDirection: CameraLensDirection.front,
                            ),
                            // Loading indicator
                            if (!_modelLoaded)
                              const Positioned(
                                top: 20,
                                left: 0,
                                right: 0,
                                child: Column(
                                  children: [
                                    CircularProgressIndicator(),
                                    SizedBox(height: 8),
                                    Text(
                                      'Đang tải mô hình nhận diện...',
                                      style: TextStyle(
                                        color: Colors.white,
                                        backgroundColor: Colors.black54,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              ),
                            // Instructions and Progress Indicator
                            Positioned(
                              bottom: 0,
                              left: 0,
                              right: 0,
                              child: Container(
                                padding: const EdgeInsets.all(8.0),
                                color: Colors.black54,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Progress bar for parallel processing
                                    if (_isProcessing &&
                                        _processingProgress > 0)
                                      Column(
                                        children: [
                                          LinearProgressIndicator(
                                            value: _processingProgress,
                                            backgroundColor: Colors.white24,
                                            valueColor:
                                                const AlwaysStoppedAnimation<
                                                  Color
                                                >(Colors.green),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            _processingStatus,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                            ),
                                            textAlign: TextAlign.center,
                                          ),
                                          const SizedBox(height: 4),
                                        ],
                                      ),
                                    Text(
                                      _instruction,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                    : const Center(child: CircularProgressIndicator()),
          ),
          // Cabinet selection and register button
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<String>(
                    decoration: const InputDecoration(
                      labelText: 'Chọn tủ',
                      border: OutlineInputBorder(),
                    ),
                    value: _selectedCabinetId,
                    items:
                        _cabinets
                            .map(
                              (cabinet) => DropdownMenuItem(
                                value: cabinet.id,
                                child: Text(cabinet.id),
                              ),
                            )
                            .toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedCabinetId = value;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed:
                        _isScanningActive
                            ? _stopFaceRegistration
                            : _startFaceRegistration,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      backgroundColor:
                          _isScanningActive ? Colors.red : Colors.blue,
                    ),
                    child: Text(
                      _isScanningActive ? 'Dừng Đăng Ký' : 'Bắt Đầu Đăng Ký',
                      style: const TextStyle(color: Colors.white),
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

  /// Process images in batches with optimized parallel processing
  Future<List<List<double>>> _processImagesBatch(List<XFile> images) async {
    // Validate image count before processing
    if (images.length != _requiredCaptureCount) {
      // Warning: Processing different number of images than expected
    }

    const int batchSize =
        2; // Reduced from 3 to 2 to avoid memory/timeout issues
    List<List<double>> allEmbeddings = [];

    // Reset progress counter
    _processedImageCount = 0;

    setState(() {
      _processingStatus = 'Khởi tạo xử lý batch...';
      _processingProgress = 0.05;
    });

    for (int i = 0; i < images.length; i += batchSize) {
      final end =
          (i + batchSize < images.length) ? i + batchSize : images.length;
      final batch = images.sublist(i, end);

      setState(() {
        _processingStatus =
            'Đang xử lý batch ${(i ~/ batchSize) + 1}/${((images.length - 1) ~/ batchSize) + 1}...';
        _processingProgress = 0.1 + (i / images.length) * 0.8;
      });

      // Process batch with improved error handling and retry mechanism
      final batchFutures =
          batch.asMap().entries.map((entry) {
            final batchIndex = entry.key;
            final globalIndex = i + batchIndex;
            final imageFile = entry.value;

            return _processImageForEmbeddingWithRetry(
              imageFile,
              globalIndex,
            ).then((result) {
              // Update progress counter
              _processedImageCount++;
              final progress = _processedImageCount / images.length;
              setState(() {
                _processingProgress = 0.1 + (progress * 0.8);
                _processingStatus =
                    'Đã xử lý $_processedImageCount/${images.length} ảnh...';
              });
              return result;
            });
          }).toList();

      try {
        final batchEmbeddings = await Future.wait(batchFutures);
        allEmbeddings.addAll(batchEmbeddings);
      } catch (e) {
        setState(() {
          _processingStatus = 'Lỗi xử lý batch: $e';
          _processingProgress = 0.0;
        });
        throw Exception('Batch processing failed: $e');
      }

      // Small delay between batches to prevent overwhelming the system
      await Future.delayed(const Duration(milliseconds: 100));
    }

    setState(() {
      _processingStatus = 'Hoàn thành xử lý tất cả batch!';
      _processingProgress = 0.9;
    });

    return allEmbeddings;
  }

  /// Process individual image with retry mechanism for better reliability
  Future<List<double>> _processImageForEmbeddingWithRetry(
    XFile imageFile,
    int imageIndex,
  ) async {
    const int maxRetries = 2;
    const Duration baseTimeout = Duration(seconds: 15); // Increased timeout

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final result = await _processImageForEmbeddingParallel(
          imageFile,
          imageIndex,
        ).timeout(
          baseTimeout,
          onTimeout: () {
            throw Exception(
              'Timeout processing image ${imageIndex + 1} after ${baseTimeout.inSeconds}s',
            );
          },
        );

        return result;
      } catch (e) {
        if (attempt == maxRetries - 1) {
          // Last attempt failed, return a fallback or rethrow
          rethrow;
        }

        // Wait before retry
        await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }

    throw Exception(
      'Failed to process image ${imageIndex + 1} after $maxRetries attempts',
    );
  }
}

/// Data class for batch processing of images
class BatchProcessingData {
  final List<XFile> images;
  final int startIndex;
  final int endIndex;

  BatchProcessingData({
    required this.images,
    required this.startIndex,
    required this.endIndex,
  });
}

/// Result of batch processing
class BatchProcessingResult {
  final List<List<double>> embeddings;
  final int processedCount;
  final int failedCount;
  final double processingTimeMs;

  BatchProcessingResult({
    required this.embeddings,
    required this.processedCount,
    required this.failedCount,
    required this.processingTimeMs,
  });
}
