import 'package:usb_serial/usb_serial.dart';
import 'dart:typed_data';
import 'dart:async';

class UsbSerialHelper {
  UsbPort? _port;
  StreamSubscription<Uint8List>? _subscription;
  List<int> _buffer = [];
  Completer<bool>? _responseCompleter;
  Timer? _responseTimeout;
  bool _isProcessingBuffer = false;

  /// Liệt kê các thiết bị USB
  Future<List<UsbDevice>> listDevices() async {
    return await UsbSerial.listDevices();
  }

  /// Kết nối tự động tới thiết bị FT232R dựa vào productName (chứa 'FT232' hoặc 'FTDI')
  Future<bool> connectToFT232R({int baudRate = 9600}) async {
    // Hủy subscription cũ nếu có
    await _subscription?.cancel();
    _subscription = null;
    _buffer.clear();

    List<UsbDevice> devices = await listDevices();
    if (devices.isEmpty) return false;

    UsbDevice? targetDevice;
    try {
      targetDevice = devices.firstWhere(
        (device) =>
            (device.productName?.toUpperCase().contains('FT232') ?? false) ||
            (device.productName?.toUpperCase().contains('FTDI') ?? false),
      );
    } catch (e) {
      return false;
    }

    _port = await targetDevice.create();
    if (_port == null) return false;

    bool openResult = await _port!.open();
    if (!openResult) return false;

    await _port!.setDTR(true);
    await _port!.setRTS(true);
    await _port!.setPortParameters(
      baudRate,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );

    // Thiết lập listener mới
    _setupListener();
    return true;
  }

  void _setupListener() {
    if (_port == null || _subscription != null) return;

    final stream = _port!.inputStream;
    if (stream == null) {
      print("❌ Không thể lấy inputStream");
      return;
    }

    print("🔄 Thiết lập listener...");
    _subscription = stream.listen((Uint8List data) {
      print(
        "📥 Nhận: ${data.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ')}",
      );

      if (_isProcessingBuffer) return; // Tránh xử lý chồng chéo
      _isProcessingBuffer = true;

      try {
        _buffer.addAll(data);

        // Xử lý buffer khi có đủ dữ liệu
        while (_buffer.length >= 8) {
          // Tìm điểm bắt đầu tin nhắn
          int startIdx = -1;
          for (int i = 0; i <= _buffer.length - 8; i++) {
            if (_buffer[i] == 0xAA &&
                _buffer[i + 1] == 0xA1 &&
                (_buffer[i + 2] >= 1 && _buffer[i + 2] <= 32) &&
                _buffer[i + 3] == 0xE2 &&
                _buffer[i + 4] == 0x02) {
              startIdx = i;
              break;
            }
          }

          if (startIdx == -1) {
            // Không tìm thấy header hợp lệ, xóa byte đầu tiên
            _buffer.removeAt(0);
            break;
          }

          // Kiểm tra đủ dữ liệu cho một tin nhắn hoàn chỉnh
          if (startIdx + 8 <= _buffer.length) {
            List<int> message = _buffer.sublist(startIdx, startIdx + 8);

            // Kiểm tra checksum
            int calculatedChecksum = checksum(message.sublist(0, 7));
            if (calculatedChecksum == message[7]) {
              int status = message[5];
              int channel = message[6];
              print(
                "Trạng thái: 0x${status.toRadixString(16)}, Kênh: $channel, Checksum: hợp lệ",
              );

              bool success = (status == 0x01);
              print(success ? "✅ Mở tủ thành công" : "❌ Mở tủ thất bại");

              // Hoàn thành thao tác nếu đang chờ phản hồi
              if (_responseCompleter != null &&
                  !_responseCompleter!.isCompleted) {
                _responseTimeout?.cancel();
                _responseCompleter!.complete(success);
              }
            }

            // Xóa dữ liệu đã xử lý
            _buffer.removeRange(0, startIdx + 8);
          } else {
            // Chưa đủ dữ liệu cho tin nhắn hoàn chỉnh
            break;
          }
        }

        // Kiểm soát kích thước buffer
        if (_buffer.length > 128) {
          print("🗑️ Buffer quá lớn, cắt bớt còn 64 bytes");
          _buffer = _buffer.sublist(_buffer.length - 64);
        }
      } finally {
        _isProcessingBuffer = false;
      }
    });
    print("✅ Đã thiết lập listener thành công");
  }

  int checksum(List<int> data) {
    int checksum = data[0];
    for (int i = 1; i < data.length - 1; i++) {
      checksum ^= data[i];
    }
    return checksum;
  }

  Future<bool> unlockE2(int address, int Ch) async {
    if (_port == null) return false;

    // Đảm bảo listener đã được thiết lập
    if (_subscription == null) {
      _setupListener();
    }

    // Tạo completer mới cho lệnh này
    _responseCompleter = Completer<bool>();

    // Thiết lập timeout
    _responseTimeout = Timer(const Duration(seconds: 5), () {
      if (_responseCompleter != null && !_responseCompleter!.isCompleted) {
        print("⏱️ Hết thời gian chờ phản hồi");
        _responseCompleter!.complete(false);
      }
    });

    // Chuẩn bị và gửi lệnh
    List<int> data = [0xAA, 0xA1, address, 0xE2, 0x01, Ch, 0x00];
    data[6] = checksum(data);

    print(
      "📤 Gửi lệnh: ${data.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ')}",
    );
    await sendData(data);

    // Chờ phản hồi từ listener toàn cục
    return await _responseCompleter!.future;
  }

  /// Gửi dữ liệu tới thiết bị USB
  Future<void> sendData(List<int> data) async {
    if (_port != null) {
      await _port!.write(Uint8List.fromList(data));
    }
  }

  /// Lắng nghe dữ liệu nhận về từ thiết bị USB
  Stream<Uint8List>? receiveStream() {
    return _port?.inputStream;
  }

  /// Đóng cổng USB
  Future<void> close() async {
    _subscription?.cancel();
    _subscription = null;
    _responseTimeout?.cancel();
    _responseTimeout = null;
    _responseCompleter = null;
    _buffer.clear();
    await _port?.close();
    _port = null;
  }
}
