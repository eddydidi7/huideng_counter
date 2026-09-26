import '../../domain/cloud_file.dart';

abstract class CloudStorageProvider {
  Future<CloudListing> listFiles({
    bool trash = false,
    int offset = 0,
    String search = '',
    String sort = 'time',
  });
  Future<CloudFile> uploadFile(
    DriveUpload upload, {
    void Function(double)? onProgress,
  });
  Future<String> downloadFile(
    CloudFile file, {
    void Function(double)? onProgress,
  });
  Future<void> deleteFile(CloudFile file);
  Future<void> restoreFile(CloudFile file);
  // Reserved for phase 2; unavailable actions are not shown as working controls.
  Future<void> createFolder(String path) =>
      Future.error(UnsupportedError('phase_2'));
  Future<void> moveFile({required String from, required String to}) =>
      Future.error(UnsupportedError('phase_2'));
  Future<void> renameFile({required String from, required String to}) =>
      Future.error(UnsupportedError('phase_2'));
  void close();
}
