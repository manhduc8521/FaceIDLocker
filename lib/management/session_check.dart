import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'utility_login.dart';
import 'login.dart';
import '../face_registration.dart';

/// Widget để check session và auto-navigate
class SessionCheckWidget extends StatefulWidget {
  final List<CameraDescription> cameras;
  
  const SessionCheckWidget({super.key, required this.cameras});

  @override
  State<SessionCheckWidget> createState() => _SessionCheckWidgetState();
}

class _SessionCheckWidgetState extends State<SessionCheckWidget> {
  bool _isChecking = true;
  
  @override
  void initState() {
    super.initState();
    _checkSession();
  }
  
  Future<void> _checkSession() async {
    try {
      final isLoggedIn = await AuthService.isLoggedIn();
      
      if (mounted) {
        setState(() {
          _isChecking = false;
        });
        
        if (isLoggedIn) {
          // Auto navigate to registration
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => FaceRegistrationScreen(cameras: widget.cameras),
            ),
          );
        } else {
          // Navigate to login
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => LoginScreen(cameras: widget.cameras),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isChecking = false;
        });
        
        // Fallback to login on error
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => LoginScreen(cameras: widget.cameras),
          ),
        );
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_isChecking) ...[
              CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
              ),
              const SizedBox(height: 16),
              const Text(
                'Đang kiểm tra phiên đăng nhập...',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey,
                ),
              ),
            ] else ...[
              Icon(
                Icons.check_circle,
                color: Colors.green,
                size: 48,
              ),
              const SizedBox(height: 16),
              const Text(
                'Đang chuyển hướng...',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
