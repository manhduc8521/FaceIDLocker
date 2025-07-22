import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  static const String _loginKey = 'is_admin_logged_in';
  
  /// Kiểm tra trạng thái đăng nhập - không còn session, luôn trả về false
  static Future<bool> isLoggedIn() async {
    return false; // Luôn yêu cầu đăng nhập mới
  }
  
  /// Đăng nhập
  static Future<bool> login(String username, String password) async {
    // Validate credentials (có thể mở rộng với database)
    if (username == 'admin' && password == 'admin123') {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_loginKey, true);
      return true;
    }
    return false;
  }
  
  /// Đăng xuất - chỉ xóa trạng thái đăng nhập
  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_loginKey);
  }
}