import 'package:drift/drift.dart';

import 'phase2.dart';
import 'repositories.dart';

/// kind: account_no_email | account_no_identity | account_stale | email_unused | platform_empty |
///       resource_orphan | project_empty | renewal_soon | needs_review
class AuditIssue {
  AuditIssue(this.kind, this.entity, this.id, this.label, {this.detail});
  final String kind, entity, id, label;
  final String? detail;
}

int _sec(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

extension AtlasAudit on AtlasRepo {
  /// Read-only health check. Suggests, never changes anything by itself.
  Future<List<AuditIssue>> audit({Duration stale = const Duration(days: 365), Duration renewal = const Duration(days: 30), DateTime? now}) async {
    final n = now ?? DateTime.now();
    final out = <AuditIssue>[];

    Future<void> q(String kind, String entity, String sql, {List<Variable> vars = const [], String? Function(QueryRow)? detail}) async {
      final rows = await db.customSelect(sql, variables: vars, readsFrom: db.allTables.toSet()).get();
      for (final r in rows) {
        out.add(AuditIssue(kind, entity, r.read<String>('id'), r.read<String>('label'), detail: detail?.call(r)));
      }
    }

    await q('account_no_email', 'account',
        'SELECT a.id, a.display_name AS label FROM accounts a WHERE a.deleted_at IS NULL AND NOT EXISTS ('
        'SELECT 1 FROM account_emails ae JOIN emails e ON e.id = ae.email_id '
        'WHERE ae.account_id = a.id AND ae.deleted_at IS NULL AND e.deleted_at IS NULL) ORDER BY a.display_name');

    final hasIdentity = (await db.customSelect('SELECT COUNT(*) AS c FROM identities WHERE deleted_at IS NULL',
            readsFrom: db.allTables.toSet()).getSingle()).read<int>('c') > 0;
    if (hasIdentity) {
      await q('account_no_identity', 'account',
          'SELECT id, display_name AS label FROM accounts WHERE deleted_at IS NULL AND identity_id IS NULL ORDER BY display_name');
    }

    await q('account_stale', 'account',
        'SELECT id, display_name AS label, COALESCE(last_reviewed_at, created_at) AS t FROM accounts '
        'WHERE deleted_at IS NULL AND COALESCE(last_reviewed_at, created_at) < ? ORDER BY t',
        vars: [Variable<int>(_sec(n.subtract(stale)))],
        detail: (r) => DateTime.fromMillisecondsSinceEpoch(r.read<int>('t') * 1000).toIso8601String().split('T').first);

    await q('email_unused', 'email',
        'SELECT e.id, e.address AS label FROM emails e WHERE e.deleted_at IS NULL '
        'AND NOT EXISTS (SELECT 1 FROM account_emails ae JOIN accounts a ON a.id = ae.account_id '
        '  WHERE ae.email_id = e.id AND ae.deleted_at IS NULL AND a.deleted_at IS NULL) '
        'AND NOT EXISTS (SELECT 1 FROM identity_emails ie WHERE ie.email_id = e.id AND ie.deleted_at IS NULL) '
        'ORDER BY e.address');

    await q('platform_empty', 'platform',
        'SELECT p.id, p.name AS label FROM platforms p WHERE p.deleted_at IS NULL '
        'AND NOT EXISTS (SELECT 1 FROM accounts a WHERE a.platform_id = p.id AND a.deleted_at IS NULL) '
        'AND NOT EXISTS (SELECT 1 FROM resources r WHERE r.platform_id = p.id AND r.deleted_at IS NULL) ORDER BY p.name');

    await q('resource_orphan', 'resource',
        'SELECT r.id, r.name AS label FROM resources r WHERE r.deleted_at IS NULL AND r.platform_id IS NULL '
        'AND r.managing_account_id IS NULL '
        'AND NOT EXISTS (SELECT 1 FROM project_resources pr WHERE pr.resource_id = r.id AND pr.deleted_at IS NULL) ORDER BY r.name');

    await q('project_empty', 'project',
        'SELECT p.id, p.name AS label FROM projects p WHERE p.deleted_at IS NULL '
        'AND NOT EXISTS (SELECT 1 FROM project_accounts x WHERE x.project_id = p.id AND x.deleted_at IS NULL) '
        'AND NOT EXISTS (SELECT 1 FROM project_resources x WHERE x.project_id = p.id AND x.deleted_at IS NULL) ORDER BY p.name');

    await q('renewal_soon', 'resource',
        'SELECT id, name AS label, renewal_date AS t FROM resources WHERE deleted_at IS NULL '
        'AND renewal_date IS NOT NULL AND renewal_date < ? ORDER BY renewal_date',
        vars: [Variable<int>(_sec(n.add(renewal)))],
        detail: (r) => DateTime.fromMillisecondsSinceEpoch(r.read<int>('t') * 1000).toIso8601String().split('T').first);

    for (final (entity, table, col) in [('account', 'accounts', 'display_name'), ('resource', 'resources', 'name')]) {
      await q('needs_review', entity, 'SELECT id, $col AS label, review_reason AS d FROM $table '
          'WHERE deleted_at IS NULL AND needs_review = 1 ORDER BY $col',
          detail: (r) => r.readNullable<String>('d'));
    }
    return out;
  }

  /// "I looked at this account": resets its staleness clock. Logged and undoable.
  Future<void> markReviewed(String accountId) =>
      updateFields('account', accountId, {'last_reviewed_at': _sec(DateTime.now())});
}
