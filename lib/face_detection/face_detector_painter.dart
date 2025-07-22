import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';

double translateX(
    double x, InputImageRotation rotation, Size size, Size absoluteImageSize) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
      return x *
          size.width /
          (Platform.isIOS ? absoluteImageSize.width : absoluteImageSize.height);
    case InputImageRotation.rotation270deg:
      return size.width -
          x *
              size.width /
              (Platform.isIOS
                  ? absoluteImageSize.width
                  : absoluteImageSize.height);
    default:
      return x * size.width / absoluteImageSize.width;
  }
}

double translateY(
    double y, InputImageRotation rotation, Size size, Size absoluteImageSize) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
    case InputImageRotation.rotation270deg:
      return y *
          size.height /
          (Platform.isIOS ? absoluteImageSize.height : absoluteImageSize.width);
    default:
      return y * size.height / absoluteImageSize.height;
  }
}

class FaceDetectorPainter extends CustomPainter {
  FaceDetectorPainter(this.faces, this.absoluteImageSize, this.rotation);

  final List<Face> faces;
  final Size absoluteImageSize;
  final InputImageRotation rotation;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = Colors.green;

    for (final Face face in faces) {
      // canvas.drawRect(
      //   Rect.fromLTRB(
      //     translateX(face.boundingBox.left, rotation, size, absoluteImageSize),
      //     translateY(face.boundingBox.top, rotation, size, absoluteImageSize),
      //     translateX(face.boundingBox.right, rotation, size, absoluteImageSize),
      //     translateY(
      //         face.boundingBox.bottom, rotation, size, absoluteImageSize),
      //   ),
      //   paint,
      // );
      double left = translateX(face.boundingBox.left, rotation, size, absoluteImageSize);
      double top = translateY(face.boundingBox.top, rotation, size, absoluteImageSize);
      double right = translateX(face.boundingBox.right, rotation, size, absoluteImageSize);
      double bottom = translateY(face.boundingBox.bottom, rotation, size, absoluteImageSize);
      canvas.drawLine(Offset(left, top), Offset(left + 70, top), paint);
      canvas.drawLine(Offset(left, top), Offset(left, top + 70), paint);
      canvas.drawLine(Offset(right, top), Offset(right - 70, top), paint);
      canvas.drawLine(Offset(right, top), Offset(right, top + 70), paint);
      canvas.drawLine(Offset(left, bottom), Offset(left + 70, bottom), paint);
      canvas.drawLine(Offset(left, bottom), Offset(left, bottom - 70), paint);
      canvas.drawLine(Offset(right, bottom), Offset(right - 70, bottom), paint);
      canvas.drawLine(Offset(right, bottom), Offset(right, bottom - 70), paint);     
    }
  }

  @override
  bool shouldRepaint(FaceDetectorPainter oldDelegate) {
    return oldDelegate.absoluteImageSize != absoluteImageSize ||
        oldDelegate.faces != faces;
  }
}
