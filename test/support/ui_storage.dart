import 'package:libranote/models/models.dart';
import 'package:libranote/services/storage_service.dart';

/// Empty local fixture for layout checks; database behavior is tested separately.
class UiStorage extends StorageService {
  @override
  Future<void> adoptOrphanDownloads() async {}
  @override
  Future<List<Book>> getBookshelf() async => [];
  @override
  Future<List<String>> getFolders() async => [];
  @override
  Future<List<Annotation>> getAllAnnotations() async => [];
  @override
  Future<List<String>> allTags() async => [];
  @override
  Future<List<ReadestNote>> getAllReadestNotes() async => [];
  @override
  Future<List<AiNote>> getAllAiNotes() async => [];
  @override
  Future<List<DocxNote>> getAllDocxNotes() async => [];
  @override
  Future<List<Map<String, Object?>>> getWhiteboardRows() async => [];
  @override
  Future<List<AiPrompt>> getAiPrompts() async => [];
  @override
  Future<List<AiConversation>> listAiConversations() async => [];
  @override
  Future<AiStats> getAiStats() async => const AiStats();
  @override
  Future<DateTime?> getFirstActivityDate() async => null;
  @override
  Future<List<UsageDay>> getUsageDays(DateTime start, DateTime end) async => [];
}
