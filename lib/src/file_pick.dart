import 'package:flutter/services.dart';

/// A locally-picked file: its display name + raw bytes.
typedef PickedFile = ({String name, Uint8List bytes});

/// Seam for picking a local file to upload. Injected into the UI so widget
/// tests can supply a fake without touching a platform channel.
abstract class FilePickerService {
  Future<PickedFile?> pick();
}

/// Real implementation over the in-app Android SAF picker (MainActivity's
/// `pi_tool/filepicker` MethodChannel). Returns null when the user cancels.
class ChannelFilePicker implements FilePickerService {
  const ChannelFilePicker();

  static const MethodChannel _channel = MethodChannel('pi_tool/filepicker');

  @override
  Future<PickedFile?> pick() async {
    final r = await _channel.invokeMapMethod<String, dynamic>('pickFile');
    if (r == null) return null;
    final bytes = r['bytes'] as Uint8List?;
    if (bytes == null) return null;
    final name = (r['name'] as String?)?.trim();
    return (name: name == null || name.isEmpty ? 'upload.bin' : name, bytes: bytes);
  }
}
