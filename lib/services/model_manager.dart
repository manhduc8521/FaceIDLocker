import 'dart:typed_data';
import 'dart:ui';
import 'package:camera/camera.dart';
import '../embeddings/face_embedder.dart';
import '../face_detection/face_despoofing_checker.dart';
import '../services/usb_serial_helper.dart';

class AIModelManager {
  static AIModelManager? _instance;
  static AIModelManager get instance => _instance ??= AIModelManager._();

  AIModelManager._() {
    // Delay nhẹ để UI render trước, sau đó mới tải resources
    Future.delayed(const Duration(milliseconds: 100), () => _initializeAll());
  }

  // Model instances
  FaceEmbedder? _faceEmbedder;
  FaceDeSpoofingChecker? _spoofingChecker;
  
  // Camera instances
  List<CameraDescription>? _cameras;
  
  // USB Serial helper
  UsbSerialHelper? _usbHelper;
  UsbSerialHelper? get usbHelper => _usbHelper;
  
  // Loading states
  bool _isInitialized = false;
  bool _isLoading = false;
  
  // Getters
  bool get isInitialized => _isInitialized;
  bool get isLoading => _isLoading;
  FaceEmbedder? get faceEmbedder => _faceEmbedder;
  FaceDeSpoofingChecker? get spoofingChecker => _spoofingChecker;
  List<CameraDescription>? get cameras => _cameras;

  /// Khởi tạo tất cả resources (cameras trước, models sau)
  Future<void> _initializeAll() async {
    if (_isInitialized || _isLoading) return;
    
    _isLoading = true;
    
    try {
      // Khởi tạo USB trước
      _usbHelper = UsbSerialHelper();
      await _usbHelper!.connectToFT232R(baudRate: 9600);
      
      // Khởi tạo cameras trước để tránh contention
      await _initializeCameras();
      
      // Sau đó mới khởi tạo models
      await _initializeModels();
      
      _isInitialized = true;
      _isLoading = false;
      
    } catch (e) {
      print('Error initializing resources: $e');
      _isLoading = false;
    }
  }

  /// Khởi tạo cameras với error handling tốt hơn
  Future<void> _initializeCameras() async {
    try {
      // Thêm delay nhỏ để hardware ổn định
      await Future.delayed(const Duration(milliseconds: 200));
      
      _cameras = await availableCameras();
      
      // Verify cameras are accessible
      if (_cameras != null && _cameras!.isNotEmpty) {
        // Log camera info for debugging
        for (int i = 0; i < _cameras!.length; i++) {
          final camera = _cameras![i];
          print('Camera $i: ${camera.name} - ${camera.lensDirection}');
        }
      }
      
    } catch (e) {
      print('Error initializing cameras: $e');
      _cameras = [];
    }
  }

  /// Khởi tạo tất cả models
  Future<void> _initializeModels() async {
    try {
      // Khởi tạo song song để tăng tốc
      await Future.wait([
        _initializeFaceEmbedder(),
        _initializeSpoofingChecker(),
      ]);
      
    } catch (e) {
      print('Error initializing AI models: $e');
    }
  }

  /// Khởi tạo Face Embedder
  Future<void> _initializeFaceEmbedder() async {
    try {
      _faceEmbedder = FaceEmbedder();
      
      // Đợi model load xong
      int attempts = 0;
      const maxAttempts = 30; // 15 giây
      
      while (!_faceEmbedder!.isModelLoaded && attempts < maxAttempts) {
        await Future.delayed(const Duration(milliseconds: 500));
        attempts++;
      }
      
      // MODEL WARM-UP: Chạy dummy inference để loại bỏ latency lần đầu
      if (_faceEmbedder!.isModelLoaded) {
        await _warmupFaceEmbedder();
      }
      
    } catch (e) {
      // Silent fail
    }
  }

  /// Khởi tạo Spoofing Checker
  Future<void> _initializeSpoofingChecker() async {
    try {
      _spoofingChecker = FaceDeSpoofingChecker();
      
      // Đợi model load xong
      int attempts = 0;
      const maxAttempts = 30; // 15 giây
      
      while (!_spoofingChecker!.isModelLoaded && attempts < maxAttempts) {
        await Future.delayed(const Duration(milliseconds: 500));
        attempts++;
      }
      
      // MODEL WARM-UP: Chạy dummy inference để loại bỏ latency lần đầu
      if (_spoofingChecker!.isModelLoaded) {
        await _warmupSpoofingChecker();
      }
      
    } catch (e) {
      // Silent fail
    }
  }
  /// Warm-up Face Embedder với dummy data
  Future<void> _warmupFaceEmbedder() async {
    try {
      // Tạo dummy image data 112x112x3 (input size của MobileFaceNet)
      final dummyBytes = Uint8List.fromList(List.generate(112 * 112 * 3, (index) => 128));
        // Tạo dummy bounding box
      final dummyFaceBox = Rect.fromLTWH(0, 0, 112, 112);
      
      // Chạy dummy inference
      await _faceEmbedder!.getFaceEmbeddingFromBytes(dummyBytes, dummyFaceBox);
    } catch (e) {
      // Silent fail - warm-up không bắt buộc
    }
  }

  /// Warm-up Spoofing Checker với dummy data
  Future<void> _warmupSpoofingChecker() async {
    try {
      // Tạo dummy image data 256x256x4 (input size của FaceAntiSpoofing, RGBA)
      final dummyBytes = Uint8List.fromList(List.generate(256 * 256 * 4, (index) => 128));
        // Tạo dummy bounding box
      final dummyFaceBox = Rect.fromLTWH(0, 0, 256, 256);
      
      // Chạy dummy inference
      await _spoofingChecker!.checkSpoofing(dummyBytes, dummyFaceBox);
    } catch (e) {
      // Silent fail - warm-up không bắt buộc
    }
  }

  /// Đảm bảo models đã sẵn sàng trước khi sử dụng
  Future<bool> ensureModelsReady() async {
    if (_isInitialized) return true;
    
    if (!_isLoading) {
      await _initializeModels();
    }
    
    // Đợi cho đến khi loading xong
    while (_isLoading) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    
    return _isInitialized;
  }

  /// Dispose all resources
  void dispose() {
    _faceEmbedder?.dispose();
    _spoofingChecker?.dispose();
    _faceEmbedder = null;
    _spoofingChecker = null;
    _cameras = null; // Clear camera references
    _usbHelper = null; // Clear USB helper
    _isInitialized = false;
    _isLoading = false;
  }

  /// Reload models if needed
  Future<void> reloadModels() async {
    dispose();
    await _initializeModels();
  }
}
