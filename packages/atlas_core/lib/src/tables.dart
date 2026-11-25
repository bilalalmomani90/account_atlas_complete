import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Sync-ready columns shared by every entity table (spec: sync designed in phase 1).
mixin SyncColumns on Table {
  TextColumn get id => text().clientDefault(() => _uuid.v7())();
  DateTimeColumn get createdAt => dateTime().clientDefault(DateTime.now)();
  DateTimeColumn get updatedAt => dateTime().clientDefault(DateTime.now)();
  TextColumn get hlc => text().nullable()(); // hybrid logical clock, set by sync engine
  DateTimeColumn get deletedAt => dateTime().nullable()(); // tombstone, never hard delete
  // manual | imported | discovered
  TextColumn get origin => text().withDefault(const Constant('manual'))();
  TextColumn get originRef => text().nullable()();
  BoolColumn get needsReview => boolean().withDefault(const Constant(false))();
  TextColumn get reviewReason => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

class Platforms extends Table with SyncColumns {
  TextColumn get name => text()();
  TextColumn get slug => text().nullable()();
  TextColumn get category => text().nullable()();
  TextColumn get baseUrl => text().nullable()();
  BoolColumn get isCustom => boolean().withDefault(const Constant(true))();
  TextColumn get apiCapability => text().withDefault(const Constant('none'))();
}

class Identities extends Table with SyncColumns {
  TextColumn get name => text()();
  TextColumn get notes => text().nullable()();
  TextColumn get color => text().nullable()();
}

class Emails extends Table with SyncColumns {
  TextColumn get address => text()();
  TextColumn get addressNormalized => text()(); // not UNIQUE: duplicates warn, never block
  TextColumn get label => text().nullable()();
}

class IdentityEmails extends Table with SyncColumns {
  TextColumn get identityId => text().references(Identities, #id)();
  TextColumn get emailId => text().references(Emails, #id)();
  BoolColumn get isPrimary => boolean().withDefault(const Constant(false))();
  @override
  List<Set<Column>> get uniqueKeys => [{identityId, emailId}];
}

class Accounts extends Table with SyncColumns {
  TextColumn get platformId => text().references(Platforms, #id)(); // mandatory
  TextColumn get displayName => text()();
  TextColumn get username => text().nullable()();
  TextColumn get profileUrl => text().nullable()();
  TextColumn get identityId => text().nullable().references(Identities, #id)();
  TextColumn get externalId => text().nullable()();
  DateTimeColumn get lastReviewedAt => dateTime().nullable()();
  TextColumn get connectionStatus => text().withDefault(const Constant('none'))();
  TextColumn get integrationId => text().nullable()();
  @override
  List<Set<Column>> get uniqueKeys => [{platformId, externalId}];
}

class AccountEmails extends Table with SyncColumns {
  TextColumn get accountId => text().references(Accounts, #id)();
  TextColumn get emailId => text().references(Emails, #id)();
  TextColumn get role => text().withDefault(const Constant('login'))();
  @override
  List<Set<Column>> get uniqueKeys => [{accountId, emailId, role}];
}

class Projects extends Table with SyncColumns {
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();
  TextColumn get category => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get links => text().withDefault(const Constant('[]'))(); // JSON list
}

class ProjectAccounts extends Table with SyncColumns {
  TextColumn get projectId => text().references(Projects, #id)();
  TextColumn get accountId => text().references(Accounts, #id)();
  TextColumn get role => text().withDefault(const Constant('owner'))();
  @override
  List<Set<Column>> get uniqueKeys => [{projectId, accountId, role}];
}

class Resources extends Table with SyncColumns {
  TextColumn get type => text()(); // database|hosting|domain|storage|api|subscription|custom
  TextColumn get name => text()();
  TextColumn get platformId => text().nullable().references(Platforms, #id)();
  TextColumn get managingAccountId => text().nullable().references(Accounts, #id)();
  TextColumn get url => text().nullable()();
  TextColumn get region => text().nullable()();
  DateTimeColumn get renewalDate => dateTime().nullable()();
}

class ProjectResources extends Table with SyncColumns {
  TextColumn get projectId => text().references(Projects, #id)();
  TextColumn get resourceId => text().references(Resources, #id)();
  TextColumn get role => text().nullable()();
  @override
  List<Set<Column>> get uniqueKeys => [{projectId, resourceId}];
}

class Connections extends Table with SyncColumns {
  TextColumn get fromType => text()();
  TextColumn get fromId => text()();
  TextColumn get toType => text()();
  TextColumn get toId => text()();
  TextColumn get kind => text()();
  TextColumn get label => text().nullable()();
}

class Notes extends Table with SyncColumns {
  TextColumn get ownerType => text()();
  TextColumn get ownerId => text()();
  TextColumn get body => text()();
}

class Attachments extends Table with SyncColumns {
  TextColumn get ownerType => text()();
  TextColumn get ownerId => text()();
  TextColumn get fileName => text()();
  TextColumn get mime => text().nullable()();
  IntColumn get size => integer().withDefault(const Constant(0))();
  TextColumn get sha256 => text().nullable()();
  TextColumn get storagePath => text().nullable()();
}

class CustomFieldDefs extends Table with SyncColumns {
  TextColumn get entityType => text()();
  TextColumn get name => text()();
  TextColumn get valueType => text().withDefault(const Constant('text'))();
  TextColumn get options => text().nullable()();
}

class CustomFieldValues extends Table with SyncColumns {
  TextColumn get defId => text().references(CustomFieldDefs, #id)();
  TextColumn get entityId => text()();
  TextColumn get valueJson => text()();
  @override
  List<Set<Column>> get uniqueKeys => [{defId, entityId}];
}

class Integrations extends Table with SyncColumns {
  TextColumn get kind => text()(); // github|supabase|firebase
  TextColumn get authType => text()();
  TextColumn get scopes => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('disconnected'))();
  DateTimeColumn get lastSyncAt => dateTime().nullable()();
  /// Pointer into the OS secure store. NEVER the secret itself.
  TextColumn get secretRef => text().nullable()();
}

class SyncHistory extends Table with SyncColumns {
  TextColumn get source => text()(); // transport or integration
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get finishedAt => dateTime().nullable()();
  TextColumn get result => text().nullable()();
  TextColumn get counts => text().nullable()();
  TextColumn get error => text().nullable()();
}

class ActivityLog extends Table with SyncColumns {
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get action => text()(); // create|update|delete|restore|sync
  TextColumn get beforeJson => text().nullable()();
  TextColumn get afterJson => text().nullable()();
  TextColumn get batchId => text().nullable()();
  BoolColumn get undoable => boolean().withDefault(const Constant(true))();
}
