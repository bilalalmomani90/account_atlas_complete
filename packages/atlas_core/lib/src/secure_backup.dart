import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'exporter.dart';
import 'importer.dart';
import 'repositories.dart';

const encFormat = 'account-atlas-encrypted';
const defaultKdfIterations = 600000; // OWASP guidance for PBKDF2-HMAC-SHA256 (unverified here: re-check)
const _minIter = 1000, _maxIter = 5000000;

class BadPassword implements Exception {
  @override
  String toString() => 'wrong password or corrupted file';
}

List<int> _rand(int n) {
  final r = Random.secure();
  return List<int>.generate(n, (_) => r.nextInt(256));
}

Future<SecretKey> _key(String password, List<int> salt, int iter) =>
    Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iter, bits: 256)
        .deriveKeyFromPassword(password: password, nonce: salt);

/// Password-based authenticated encryption (PBKDF2-HMAC-SHA256 + AES-256-GCM).
/// The envelope header is bound to the ciphertext as AAD, so tampering is detected.
Future<String> encryptText(String plain, String password, {int iterations = defaultKdfIterations}) async {
  if (password.isEmpty) throw ArgumentError('empty password');
  final salt = _rand(16);
  final key = await _key(password, salt, iterations);
  final algo = AesGcm.with256bits();
  final aad = utf8.encode('$encFormat|1|$iterations');
  final box = await algo.encrypt(utf8.encode(plain), secretKey: key, nonce: algo.newNonce(), aad: aad);
  return jsonEncode({
    'format': encFormat, 'version': 1, 'kdf': 'pbkdf2-hmac-sha256', 'iterations': iterations,
    'cipher': 'aes-256-gcm',
    'salt': base64Encode(salt), 'nonce': base64Encode(box.nonce),
    'ct': base64Encode(box.cipherText), 'mac': base64Encode(box.mac.bytes),
  });
}

bool isEncrypted(String text) {
  try {
    final m = jsonDecode(text);
    return m is Map && m['format'] == encFormat;
  } catch (_) {
    return false;
  }
}

Future<String> decryptText(String envelope, String password) async {
  Map m;
  try {
    m = jsonDecode(envelope) as Map;
  } catch (_) {
    throw const FormatException('not an encrypted Account Atlas file');
  }
  if (m['format'] != encFormat || m['version'] != 1 || m['cipher'] != 'aes-256-gcm') {
    throw const FormatException('unsupported encrypted file');
  }
  final iter = m['iterations'];
  if (iter is! int || iter < _minIter || iter > _maxIter) throw const FormatException('bad kdf parameters');
  try {
    final key = await _key(password, base64Decode(m['salt'] as String), iter);
    final box = SecretBox(base64Decode(m['ct'] as String),
        nonce: base64Decode(m['nonce'] as String), mac: Mac(base64Decode(m['mac'] as String)));
    final plain = await AesGcm.with256bits().decrypt(box, secretKey: key, aad: utf8.encode('$encFormat|1|$iter'));
    return utf8.decode(plain);
  } on SecretBoxAuthenticationError {
    throw BadPassword();
  } on FormatException {
    throw const FormatException('corrupted file');
  }
}

class BackupCheck {
  BackupCheck(this.ok, this.expected, this.found);
  final bool ok;
  final Map<String, int> expected, found;
}

extension AtlasSecureBackup on AtlasRepo {
  /// Encrypted backup text. Never contains integration tokens (they are not in the DB at all).
  Future<String> exportEncrypted(String password, {int iterations = defaultKdfIterations}) async =>
      encryptText(await exportJson(), password, iterations: iterations);

  /// Decrypts [envelope] again and compares per-table counts with the live database.
  /// Call right after writing a backup: a backup that was not verified is not a backup.
  Future<BackupCheck> verifyEncrypted(String envelope, String password) async {
    final m = jsonDecode(await decryptText(envelope, password)) as Map;
    final found = {for (final e in (m['counts'] as Map).entries) e.key as String: (e.value as num).toInt()};
    final expected = <String, int>{};
    for (final t in backupTables) {
      expected[t] = (await dumpTable(t)).length;
    }
    final ok = backupTables.every((t) => found[t] == expected[t]);
    return BackupCheck(ok, expected, found);
  }

  /// Restore = normal import of the decrypted backup (safe defaults, undoable batch).
  Future<ImportPlan> planEncryptedRestore(String envelope, String password) async =>
      planBackup(await decryptText(envelope, password), source: 'encrypted-backup');
}

// ───────────────────────── app lock PIN ─────────────────────────

/// Stored in the secure store as one string: `v1:iter:salt:hash`.
Future<String> hashPin(String pin, {int iterations = 200000}) async {
  final salt = _rand(16);
  final k = await _key(pin, salt, iterations);
  return 'v1:$iterations:${base64Encode(salt)}:${base64Encode(await k.extractBytes())}';
}

Future<bool> verifyPin(String pin, String stored) async {
  final p = stored.split(':');
  if (p.length != 4 || p[0] != 'v1') return false;
  final iter = int.tryParse(p[1]);
  if (iter == null || iter < _minIter || iter > _maxIter) return false;
  final k = await (await _key(pin, base64Decode(p[2]), iter)).extractBytes();
  final want = base64Decode(p[3]);
  if (k.length != want.length) return false;
  var d = 0;
  for (var i = 0; i < k.length; i++) {
    d |= k[i] ^ want[i];
  }
  return d == 0;
}

/// Seconds to wait after [failures] consecutive wrong PINs (0 for the first 3).
int pinDelaySeconds(int failures) => failures < 3 ? 0 : min(300, 5 * (1 << (failures - 3)));
