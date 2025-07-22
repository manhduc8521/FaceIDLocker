import 'package:flutter/material.dart';
import 'home_page.dart';
import 'services/model_manager.dart';
//import 'services/usb_serial_helper.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AIModelManager.instance;

  // Kiểm tra và in danh sách thiết bị USB
  // final usbHelper = UsbSerialHelper();
  // final devices = await usbHelper.listDevices();
  // for (var d in devices) {
  //   print('USB deviceId: \\${d.deviceId}, Name: \\${d.productName}');
  // }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      //title: 'Smart Cabinet System',
      theme: ThemeData(primarySwatch: Colors.blue),
      debugShowCheckedModeBanner: false,
      home: const HomePage(),
    );
  }
}
