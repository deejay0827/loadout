import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// On-disk format for an encrypted LoadOut backup. The file is layered as:
///
/// ```
/// 0..8   magic         "LOADOUT1\0"      (9 bytes, ASCII + NUL terminator)
/// 9      version       u8                (currently 1)
/// 10..25 salt          16 bytes          (PBKDF2 salt, random per-backup)
/// 26..37 nonce         12 bytes          (AES-GCM IV, random per-backup)
/// 38..53 tag           16 bytes          (GCM authentication tag)
/// 54..   ciphertext    variable          (AES-256-GCM encrypted plaintext)
/// ```
///
/// The salt + nonce are stored alongside the ciphertext (standard practice;
/// they are not secrets). The tag is required to authenticate the
/// ciphertext — flipping a single bit anywhere in the blob causes
/// [BackupCrypto.decrypt] to throw.
///
/// Keys are derived from the user-provided passphrase via PBKDF2-HMAC-SHA256
/// with 200,000 iterations. The number is comfortably above the
/// task-spec floor (10,000) and matches OWASP 2023 guidance for SHA-256
/// PBKDF2; bumping it here is a one-line change but requires a format
/// version bump if old backups must remain readable.
///
/// Threat model assumptions:
///
/// 1. The encrypted blob is treated as public — we assume any
///    cloud-storage provider it lives on (iCloud, Google Drive) MIGHT
///    leak it. Confidentiality and integrity rely entirely on the
///    passphrase the user picks.
/// 2. The user's device is trusted while the app is running. We hold the
///    derived 32-byte key in plain memory while a backup operation is in
///    flight. We DO NOT persist the key, the passphrase, or any
///    convenience cache to disk — the user has to re-enter the passphrase
///    on every backup or restore.
/// 3. The nonce is regenerated from `Random.secure()` for every encrypt
///    call. Reusing a (key, nonce) pair under GCM would be catastrophic;
///    a 16-byte salt + 12-byte fresh nonce per call gives birthday-bound
///    collision odds far below any realistic backup count.
/// 4. We do NOT include any LoadOut-side identifiers (install id, user
///    id, anything analytics-shaped) in the plaintext. The plaintext is
///    purely the JSON the user typed into the app — see [ExportService].
class BackupCrypto {
  BackupCrypto({Random? random}) : _random = random ?? Random.secure();

  /// Magic preamble + version. Lets us reject random files immediately and
  /// gate format-version changes so old blobs keep decrypting after a
  /// future format bump.
  static const List<int> _magic = <int>[
    0x4C, 0x4F, 0x41, 0x44, 0x4F, 0x55, 0x54, 0x31, 0x00,
  ]; // "LOADOUT1\0"
  static const int _formatVersion = 1;
  static const int _saltLength = 16;
  static const int _nonceLength = 12; // AES-GCM standard.
  static const int _tagLength = 16;
  static const int _keyLength = 32; // AES-256.
  static const int _pbkdfIterations = 200000;

  /// Total fixed-size header before the ciphertext starts.
  static const int _headerLength =
      9 /* magic */ + 1 /* version */ + _saltLength + _nonceLength + _tagLength;

  /// Minimum acceptable passphrase length. Mirrors the UI validator —
  /// kept here so callers that wire their own passphrase entry can't
  /// trivially bypass the rule.
  static const int minPassphraseLength = 8;

  final Random _random;

  /// Encrypt [plaintextJson] using a key derived from [passphrase].
  ///
  /// Throws [ArgumentError] if [passphrase] is too short; otherwise returns
  /// a freshly-allocated `Uint8List` shaped exactly like the format
  /// described at the top of this file. Repeated calls produce different
  /// blobs even for identical inputs (random salt + random nonce per call).
  Future<Uint8List> encrypt(String passphrase, String plaintextJson) async {
    _validatePassphrase(passphrase);

    final salt = _randomBytes(_saltLength);
    final nonce = _randomBytes(_nonceLength);

    final secretKey = await _deriveKey(passphrase: passphrase, salt: salt);
    final algo = AesGcm.with256bits();
    final secretBox = await algo.encrypt(
      utf8.encode(plaintextJson),
      secretKey: secretKey,
      nonce: nonce,
    );
    // Per PRIVACY_POLICY: keys never persist. The local reference goes
    // out of scope at the end of this method; cryptography 2.x does not
    // expose a portable sync wipe API across all SecretKey implementations,
    // so we rely on the Dart GC to reclaim the buffer.

    final cipherBytes = Uint8List.fromList(secretBox.cipherText);
    final tag = secretBox.mac.bytes;
    if (tag.length != _tagLength) {
      throw StateError(
        'Unexpected GCM tag length ${tag.length}; expected $_tagLength',
      );
    }

    final out = Uint8List(_headerLength + cipherBytes.length);
    var offset = 0;
    out.setRange(offset, offset + _magic.length, _magic);
    offset += _magic.length;
    out[offset++] = _formatVersion;
    out.setRange(offset, offset + _saltLength, salt);
    offset += _saltLength;
    out.setRange(offset, offset + _nonceLength, nonce);
    offset += _nonceLength;
    out.setRange(offset, offset + _tagLength, tag);
    offset += _tagLength;
    out.setRange(offset, offset + cipherBytes.length, cipherBytes);
    return out;
  }

  /// Decrypt [blob] using a key derived from [passphrase].
  ///
  /// Throws [BackupDecryptException] when the magic doesn't match, the
  /// format version is unrecognized, the blob is truncated, or the
  /// passphrase is wrong / data has been tampered with (any of these is
  /// indistinguishable to the GCM verifier).
  Future<String> decrypt(String passphrase, Uint8List blob) async {
    _validatePassphrase(passphrase);
    if (blob.length < _headerLength) {
      throw const BackupDecryptException(
        'File is too small to be a LoadOut backup.',
      );
    }
    for (var i = 0; i < _magic.length; i++) {
      if (blob[i] != _magic[i]) {
        throw const BackupDecryptException(
          'File magic does not match. This is not a LoadOut backup.',
        );
      }
    }
    final version = blob[_magic.length];
    if (version != _formatVersion) {
      throw BackupDecryptException(
        'Backup uses format version $version which this app cannot read. '
        'Update LoadOut and try again.',
      );
    }
    var offset = _magic.length + 1;
    final salt = blob.sublist(offset, offset + _saltLength);
    offset += _saltLength;
    final nonce = blob.sublist(offset, offset + _nonceLength);
    offset += _nonceLength;
    final tag = blob.sublist(offset, offset + _tagLength);
    offset += _tagLength;
    final cipherBytes = blob.sublist(offset);

    final secretKey = await _deriveKey(passphrase: passphrase, salt: salt);
    final algo = AesGcm.with256bits();
    try {
      final plaintext = await algo.decrypt(
        SecretBox(cipherBytes, nonce: nonce, mac: Mac(tag)),
        secretKey: secretKey,
      );
      return utf8.decode(plaintext);
    } on SecretBoxAuthenticationError {
      throw const BackupDecryptException(
        'Could not decrypt backup. The passphrase is wrong, or the file '
        'has been modified since it was created.',
      );
    }
    // [secretKey] goes out of scope here; same caveat about GC as in
    // [encrypt].
  }

  /// PBKDF2-HMAC-SHA256 key derivation. Public so callers running tests
  /// can verify deterministic outputs; production code should not need
  /// this directly.
  Future<SecretKey> _deriveKey({
    required String passphrase,
    required List<int> salt,
  }) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _pbkdfIterations,
      bits: _keyLength * 8,
    );
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  void _validatePassphrase(String passphrase) {
    if (passphrase.length < minPassphraseLength) {
      throw ArgumentError.value(
        '<redacted>',
        'passphrase',
        'Passphrase must be at least $minPassphraseLength characters.',
      );
    }
  }
}

/// Thrown by [BackupCrypto.decrypt] when the blob can't be opened. The
/// message is safe to surface in the UI — it never echoes the passphrase
/// or any internal cryptographic state.
class BackupDecryptException implements Exception {
  const BackupDecryptException(this.message);
  final String message;

  @override
  String toString() => 'BackupDecryptException: $message';
}
