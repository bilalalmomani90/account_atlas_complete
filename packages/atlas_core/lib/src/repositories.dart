import 'package:drift/drift.dart';
import 'database.dart';
import 'phase2.dart';

String normalizeEmail(String s) => s.trim().toLowerCase();

class AtlasRepo {
  AtlasRepo(this.db);
  final AtlasDatabase db;

  Future<String> addPlatform(String name, {String? baseUrl, String? category}) async {
    final row = await db.into(db.platforms).insertReturning(PlatformsCompanion.insert(
        name: name, baseUrl: Value(baseUrl), category: Value(category)));
    await logCreated('platform', row.id);
    return row.id;
  }

  Future<String> addAccount({
    required String platformId,
    required String displayName,
    String? username,
    String? identityId,
  }) async {
    final row = await db.into(db.accounts).insertReturning(AccountsCompanion.insert(
        platformId: platformId,
        displayName: displayName,
        username: Value(username),
        identityId: Value(identityId)));
    await logCreated('account', row.id);
    return row.id;
  }

  Future<String> addEmail(String address) async {
    final row = await db.into(db.emails).insertReturning(EmailsCompanion.insert(
        address: address.trim(), addressNormalized: normalizeEmail(address)));
    await logCreated('email', row.id);
    return row.id;
  }

  Future<void> linkAccountEmail(String accountId, String emailId, {String role = 'login'}) =>
      db.into(db.accountEmails).insert(AccountEmailsCompanion.insert(
          accountId: accountId, emailId: emailId, role: Value(role)));

  Stream<List<Platform>> watchPlatforms() => (db.select(db.platforms)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.name)]))
      .watch();

  Future<List<Account>> accountsOfPlatform(String platformId) => (db.select(db.accounts)
        ..where((t) => t.platformId.equals(platformId) & t.deletedAt.isNull()))
      .get();

  /// Accounts linked to an email address (spec: reverse search).
  Future<List<Account>> accountsForEmail(String address) async {
    final q = db.select(db.accounts).join([
      innerJoin(db.accountEmails, db.accountEmails.accountId.equalsExp(db.accounts.id)),
      innerJoin(db.emails, db.emails.id.equalsExp(db.accountEmails.emailId)),
    ])
      ..where(db.emails.addressNormalized.equals(normalizeEmail(address)) &
          db.accounts.deletedAt.isNull());
    return (await q.get()).map((r) => r.readTable(db.accounts)).toList();
  }

  /// Soft delete: tombstone only, relations stay intact.
  Future<void> softDeleteAccount(String id) => softDelete('account', id);

  Future<String> addProject(String name, {String? description}) async {
    final row = await db.into(db.projects).insertReturning(
        ProjectsCompanion.insert(name: name, description: Value(description)));
    await logCreated('project', row.id);
    return row.id;
  }

  Future<String> addResource(String type, String name, {String? platformId}) async {
    final row = await db.into(db.resources).insertReturning(ResourcesCompanion.insert(
        type: type, name: name, platformId: Value(platformId)));
    await logCreated('resource', row.id);
    return row.id;
  }

  Stream<List<Account>> watchAccounts() => (db.select(db.accounts)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.displayName)]))
      .watch();

  Stream<List<Email>> watchEmails() => (db.select(db.emails)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.addressNormalized)]))
      .watch();

  Stream<List<Project>> watchProjects() => (db.select(db.projects)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.name)]))
      .watch();

  Stream<List<Resource>> watchResources() => (db.select(db.resources)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.name)]))
      .watch();

  Stream<List<Identity>> watchIdentities() => (db.select(db.identities)
        ..where((t) => t.deletedAt.isNull()))
      .watch();

  /// Dashboard: last modified accounts.
  Stream<List<Account>> watchRecentAccounts({int limit = 5}) => (db.select(db.accounts)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
        ..limit(limit))
      .watch();

  /// Dashboard: accounts that still need info (no linked email).
  Stream<List<Account>> watchAccountsMissingEmail() {
    final linked = db.selectOnly(db.accountEmails)
      ..addColumns([db.accountEmails.accountId])
      ..where(db.accountEmails.deletedAt.isNull());
    return (db.select(db.accounts)
          ..where((t) => t.deletedAt.isNull() & t.id.isNotInQuery(linked)))
        .watch();
  }
}
