import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Cabinet {
  final String id;
  final int boardAddress;

  Cabinet({required this.id, required this.boardAddress});
}

class CabinetSelectionScreen extends StatefulWidget {
  final Function(Cabinet) onCabinetSelected;

  const CabinetSelectionScreen({super.key, required this.onCabinetSelected});

  @override
  State<CabinetSelectionScreen> createState() => _CabinetSelectionScreenState();
}

class _CabinetSelectionScreenState extends State<CabinetSelectionScreen> {
  int _selectedBoardAddress = 1;

  @override
  Widget build(BuildContext context) {
    final cabinets = List.generate(
      16,
      (i) => Cabinet(id: 'Tủ ${i + 1}', boardAddress: _selectedBoardAddress),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Chọn khu & tủ',
          style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.blueAccent,
        elevation: 4,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              children: [
                const Text(
                  'Chọn khu: ',
                  style: TextStyle(fontSize: 25, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 16),
                DropdownButton<int>(
                  value: _selectedBoardAddress,
                  items: List.generate(
                    32,
                    (i) =>
                        DropdownMenuItem(value: i + 1, child: Text('${i + 1}')),
                  ),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _selectedBoardAddress = value;
                      });
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 24),
            Expanded(
              child: GridView.builder(
                itemCount: cabinets.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  childAspectRatio: 0.75,
                ),
                itemBuilder: (context, index) {
                  final cabinet = cabinets[index];
                  return GestureDetector(
                    onTap: () => _checkAndOpenCabinet(context, cabinet),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.10),
                            blurRadius: 8,
                            offset: const Offset(2, 4),
                          ),
                        ],
                        border: Border.all(color: Colors.blueAccent, width: 1),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.lock,
                            size: 48,
                            color: Colors.blueAccent,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            cabinet.id,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: Colors.black87,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future _checkAndOpenCabinet(BuildContext context, Cabinet cabinet) async {
    final prefs = await SharedPreferences.getInstance();
    final faceData = prefs.getString(
      'face_data_${cabinet.id}_khu${cabinet.boardAddress}',
    );
    if (faceData == null) {
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Thông báo'),
            content: Text(
              '${cabinet.id} (Khu ${cabinet.boardAddress}) chưa được đăng ký khuôn mặt!',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
      return;
    }
    widget.onCabinetSelected(cabinet);
  }
}
