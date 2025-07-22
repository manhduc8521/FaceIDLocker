import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'dart:io';
import 'dart:typed_data';

enum ScreenMode { liveFeed, gallery }

class CameraView extends StatefulWidget {
  const CameraView({
    Key? key,
    required this.customPaint,
    required this.onImage,
    required this.cameras,
    this.onCaptureImage,
    this.initialDirection = CameraLensDirection.back,
  }) : super(key: key);

  final CustomPaint? customPaint;
  final Function(InputImage inputImage) onImage;
  final Function(XFile image)? onCaptureImage;
  final List<CameraDescription> cameras;
  final CameraLensDirection initialDirection;

  @override
  CameraViewState createState() => CameraViewState();
}

class CameraViewState extends State<CameraView> {
  CameraController? _controller;
  int _cameraIndex = 0;
  double zoomLevel = 0.0, minZoomLevel = 0.0, maxZoomLevel = 0.0;
  bool _isBusy = false;
  @override
  void initState() {
    super.initState();

    for (var i = 0; i < widget.cameras.length; i++) {
      if (widget.cameras[i].lensDirection == widget.initialDirection) {
        _cameraIndex = i;
      }
    }
    _startLiveFeed();
  }

  @override
  void dispose() {
    _stopLiveFeed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: _liveFeedBody());
  }

  Widget _liveFeedBody() {
    if (_controller?.value.isInitialized == false) {
      return Container();
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        CameraPreview(_controller!),
        if (widget.customPaint != null) widget.customPaint!,
      ],
    );
  }

  Future _startLiveFeed() async {
    final camera = widget.cameras[_cameraIndex];
    _controller = CameraController(
      camera,
      ResolutionPreset.veryHigh,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    _controller?.initialize().then((_) {
      if (!mounted) {
        return;
      }
      _controller?.startImageStream(_processCameraImage);
      setState(() {});
    });
  }

  Future _stopLiveFeed() async {
    try {
      if (_controller != null) {
        // Stop image stream first
        await _controller?.stopImageStream();

        // Add small delay to ensure stream is stopped
        await Future.delayed(const Duration(milliseconds: 100));

        // Dispose controller
        await _controller?.dispose();
        _controller = null;
      }
    } catch (e) {
      _controller = null; // Force null even on error
    }
  }

  Future _processCameraImage(CameraImage image) async {
    try {
      // Skip processing if busy
      if (_isBusy) return;
      _isBusy = true;

      final camera = widget.cameras[_cameraIndex];
      // Calculate rotation based on camera orientation and device orientation
      InputImageRotation rotation;
      if (Platform.isAndroid) {
        // Android camera rotation fix - front camera is mirrored
        switch (camera.sensorOrientation) {
          case 90:
            rotation =
                camera.lensDirection == CameraLensDirection.front
                    ? InputImageRotation.rotation270deg
                    : InputImageRotation.rotation90deg;
            break;
          case 180:
            rotation = InputImageRotation.rotation180deg;
            break;
          case 270:
            rotation =
                camera.lensDirection == CameraLensDirection.front
                    ? InputImageRotation.rotation90deg
                    : InputImageRotation.rotation270deg;
            break;
          default:
            rotation = InputImageRotation.rotation0deg;
        }
      } else {
        // iOS
        rotation = InputImageRotation.rotation0deg;
      }

      // Handle different image formats - prioritize NV21 for Android
      InputImageFormat? format;
      Uint8List bytes;

      if (Platform.isAndroid) {
        // For Android, prefer NV21 format and handle YUV planes properly
        switch (image.format.group) {
          case ImageFormatGroup.yuv420:
            format = InputImageFormat.nv21;
            bytes = _convertYUV420ToNV21(image);
            break;
          case ImageFormatGroup.nv21:
            format = InputImageFormat.nv21;
            bytes = _concatenatePlanes(image.planes);
            break;
          default:
            format = InputImageFormat.nv21;
            bytes = _convertYUV420ToNV21(image);
            break;
        }
      } else {
        // iOS
        switch (image.format.group) {
          case ImageFormatGroup.bgra8888:
            format = InputImageFormat.bgra8888;
            break;
          case ImageFormatGroup.yuv420:
            format = InputImageFormat.yuv420;
            break;
          default:
            format = InputImageFormat.yuv420;
            break;
        }
        bytes = _concatenatePlanes(image.planes);
      }

      final inputImage = InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: image.planes.first.bytesPerRow,
        ),
      );

      await widget.onImage(inputImage);
    } catch (e) {
      // Error processing camera image - silently continue
    } finally {
      _isBusy = false;
    }
  }

  // Helper method to concatenate image planes
  Uint8List _concatenatePlanes(List<Plane> planes) {
    final WriteBuffer allBytes = WriteBuffer();
    for (Plane plane in planes) {
      allBytes.putUint8List(plane.bytes);
    }
    return allBytes.done().buffer.asUint8List();
  }

  // Convert YUV420 to NV21 format for Android
  Uint8List _convertYUV420ToNV21(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final int uvPixelStride = image.planes[1].bytesPerPixel!;

    // Y plane
    final Uint8List yPlane = image.planes[0].bytes;

    // U and V planes
    final Uint8List uPlane = image.planes[1].bytes;
    final Uint8List vPlane = image.planes[2].bytes;

    final Uint8List nv21 = Uint8List(
      width * height + (width * height / 2).floor(),
    );

    // Copy Y plane
    nv21.setRange(0, yPlane.length, yPlane);

    // Interleave U and V planes for NV21 format
    int uvIndex = width * height;
    for (int i = 0; i < (width * height / 4).floor(); i++) {
      int srcIndex = i * uvPixelStride;
      if (srcIndex < uPlane.length &&
          srcIndex < vPlane.length &&
          uvIndex + 1 < nv21.length) {
        nv21[uvIndex++] = vPlane[srcIndex];
        nv21[uvIndex++] = uPlane[srcIndex];
      }
    }

    return nv21;
  }

  /// Capture a picture and return the file
  Future<XFile?> takePicture() async {
    if (_controller == null || !_controller!.value.isInitialized) {
      return null;
    }

    try {
      final XFile image = await _controller!.takePicture();

      // Call the callback if provided
      if (widget.onCaptureImage != null) {
        widget.onCaptureImage!(image);
      }

      return image;
    } catch (e) {
      return null;
    }
  }
}
