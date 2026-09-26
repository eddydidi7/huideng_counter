/// Future regional backends implement this boundary. No network/sync is enabled.
/// Sync immutable count events/corrections by UUID, never last-write-wins totals.
abstract interface class RemoteDataSource {
  Future<Map<String, String>> fetchModuleLinks();
  Future<void> pushChanges(List<Map<String, Object?>> records);
  Future<List<Map<String, Object?>>> pullChanges(String? cursor);
}
