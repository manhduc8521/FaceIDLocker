import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'cabinet_selection.dart';
import 'optimized_face_auth.dart';
import 'services/model_manager.dart';
import 'management/login.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  HomePageState createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  int _selectedIndex = 0;
  List<CameraDescription>? cameras;

  @override
  void initState() {
    super.initState();
    _loadCameras();
  }

  void _loadCameras() {
    // Lấy cameras từ Model Manager
    cameras = AIModelManager.instance.cameras;

    if (cameras == null || cameras!.isEmpty) {
      // Polling liên tục thay vì chỉ 1 lần
      _pollForCameras();
    }
  }

  void _pollForCameras() async {
    int attempts = 0;
    while ((cameras == null || cameras!.isEmpty) && attempts < 20 && mounted) {
      await Future.delayed(const Duration(milliseconds: 500));
      attempts++;

      if (mounted) {
        final newCameras = AIModelManager.instance.cameras;

        if (newCameras != null && newCameras.isNotEmpty) {
          setState(() {
            cameras = newCameras;
          });
          return;
        }
      }
    }
  }

  void _onItemTapped(int index) {
    if (index == 1) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (context) => LoginScreen(cameras: cameras!)),
      );
    } else {
      setState(() => _selectedIndex = index);
    }
  }

  // Khi chọn tủ, push màn hình xác thực khuôn mặt
  void _openFaceAuthScreen(BuildContext context, Cabinet cabinet) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => OptimizedFaceAuth(cabinet: cabinet),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Kiểm tra nếu cameras chưa sẵn sàng
    if (cameras == null || cameras!.isEmpty) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Đang khởi tạo camera...'),
            ],
          ),
        ),
      );
    }

    final screens = [
      CabinetSelectionScreen(
        onCabinetSelected: (cabinet) {
          _openFaceAuthScreen(context, cabinet);
        },
      ),
    ];

    return Scaffold(
      body: screens[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _selectedIndex,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.lock_open), label: 'Mở tủ'),
          BottomNavigationBarItem(icon: Icon(Icons.face), label: 'Đăng ký'),
        ],
        onTap: _onItemTapped,
      ),
    );
  }
}
