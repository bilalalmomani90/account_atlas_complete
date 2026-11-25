import 'package:drift/drift.dart';
import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(tables: [
  Platforms, Identities, Emails, IdentityEmails, Accounts, AccountEmails,
  Projects, ProjectAccounts, Resources, ProjectResources, Connections, Notes,
  Attachments, CustomFieldDefs, CustomFieldValues, Integrations, SyncHistory,
  ActivityLog,
])
class AtlasDatabase extends _$AtlasDatabase {
  AtlasDatabase(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        // Every future schema bump MUST add a step here + a migration test.
        onUpgrade: (m, from, to) async {},
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
