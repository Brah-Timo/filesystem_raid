# Recovery Guide

A deep-dive into the recovery subsystem of **filesystem_raid**: how it
detects failures, selects a strategy, and rebuilds lost data.

---

## Table of Contents

1. [Recovery concepts](#recovery-concepts)
2. [Fault tolerance by RAID level](#fault-tolerance-by-raid-level)
3. [Triggering recovery](#triggering-recovery)
4. [RAID 0 — no recovery](#raid-0--no-recovery)
5. [RAID 1 — mirror rebuild](#raid-1--mirror-rebuild)
6. [RAID 5 — parity rebuild](#raid-5--parity-rebuild)
   - [Data disk failure](#data-disk-failure)
   - [Parity disk failure](#parity-disk-failure)
   - [Multiple failures](#multiple-failures)
7. [XOR vs Reed-Solomon parity](#xor-vs-reed-solomon-parity)
8. [Recovery report](#recovery-report)
9. [Testing recovery in your app](#testing-recovery-in-your-app)
10. [Recovery best practices](#recovery-best-practices)

---

## Recovery concepts

**filesystem_raid** treats recovery as a two-phase process:

1. **Detection** — `refreshStatus()` re-probes every disk directory (creates
   a tiny temp file, measures latency, reads it back, deletes it).  Any disk
   that throws an exception during probing is immediately classified as
   `DiskHealth.failed`.

2. **Rebuild** — for each failed disk, the library reads the surviving data
   from healthy disks, computes the missing chunks using the configured parity
   algorithm, and writes them back to the (now-replaced) disk.

---

## Fault tolerance by RAID level

| Level  | Tolerated failures | Notes |
|--------|--------------------|-------|
| RAID 0 | **0** | Loss of any disk = loss of all data |
| RAID 1 | **N-1** | Up to all-but-one disk can fail |
| RAID 5 | **1** | Exactly one disk per array |

Exceeding the tolerance limit throws `TooManyDiskFailuresException`.

---

## Triggering recovery

```dart
// 1. (Optional) Simulate failure for testing.
raid.simulateDiskFailure(1);

// 2. Replace the physical disk (filesystem_raid sees this as a new empty dir).
// 3. Mark the new disk as online.
await raid.simulateDiskRestore(1); // calls DiskManager.markDiskOnline()

// 4. Run recovery.
final report = await raid.recover();
print(report.summary());
```

You can also call `recover()` on a healthy array — it will return
`RecoveryStatus.notRequired` immediately without doing any I/O.

---

## RAID 0 — no recovery

```dart
// recover() on RAID 0 throws RaidNotRecoverableException immediately.
try {
  await raid.recover();
} on RaidNotRecoverableException catch (e) {
  print('Expected: ${e.message}');
}
```

RAID 0 is "write it fast, lose it completely on failure" — back up your data!

---

## RAID 1 — mirror rebuild

When a disk fails in a RAID 1 array:

1. `recover()` calls `refreshStatus()` to detect all failed disks.
2. It selects the first healthy disk as the **donor**.
3. For every filename in the registry, it reads chunk 0 from the donor and
   writes it to the rebuilt disk.

```
Healthy array:  Disk0 [file.bin]  Disk1 [file.bin]
After failure:  Disk0 [file.bin]  Disk1 [FAILED]
After restore:  Disk0 [file.bin]  Disk1 [empty new disk]

recover():
  Read file.bin from Disk0  →  Write file.bin to Disk1

Result:         Disk0 [file.bin]  Disk1 [file.bin]
```

**What is rebuilt**: entire file content (RAID 1 stores a full copy per disk).

---

## RAID 5 — parity rebuild

RAID 5 stores:

- **N-1** data chunks distributed across N disks.
- **1** parity chunk on a rotating disk (left-symmetric rotation).

### Data disk failure

When a data disk fails:

```
3-disk array, file split into 2 data chunks:

Healthy:  Disk0 [chunk0]  Disk1 [chunk1]  Disk2 [PARITY]
Failed:   Disk0 [FAILED]  Disk1 [chunk1]  Disk2 [PARITY]

Recovery:
  chunk0_recovered = chunk1 XOR PARITY
```

`ParityRecovery.recoverChunks()` calls `ParityCalculator.recoverStripe()`:

```
missing_chunk = parity XOR all_available_chunks
```

The recovered chunk is written to the rebuilt disk by
`DiskManager.rebuildChunk()`.

### Parity disk failure

When the parity disk fails:

```
Healthy:  Disk0 [chunk0]  Disk1 [chunk1]  Disk2 [FAILED]

Recovery:
  parity_recovered = chunk0 XOR chunk1
```

All data chunks are still readable; recovery re-computes parity and writes
it to the rebuilt disk.

### Multiple failures

Two or more simultaneous failures in a 3-disk RAID 5 array exceed the
tolerance limit.  `recover()` returns `RecoveryStatus.failed` and adds
error entries to `RecoveryReport.errors`.

For arrays with 4+ disks you can increase the parity shards by switching to
`ParityAlgorithm.reedSolomon` (see [XOR vs Reed-Solomon](#xor-vs-reed-solomon-parity)).

---

## XOR vs Reed-Solomon parity

### XOR (`ParityAlgorithm.xor`)

- Computed over GF(2): `P = D0 ⊕ D1 ⊕ … ⊕ Dn-1`.
- Very fast — one XOR per byte.
- Tolerates **exactly 1** missing chunk per stripe.
- Default algorithm.

### Reed-Solomon (`ParityAlgorithm.reedSolomon`)

- Systematic code over GF(2^8) using a Vandermonde encoding matrix.
- Slower but mathematically stronger.
- In the current RAID 5 implementation, `parityCount = 1`, so fault
  tolerance is still 1 disk — choose it for its stronger error-detection
  properties or to future-proof your code for higher parity counts.

```dart
const config = RaidConfig(
  type: RaidType.raid5,
  diskCount: 4,
  parityAlgorithm: ParityAlgorithm.reedSolomon,
);
```

---

## Recovery report

`FilesystemRaid.recover()` returns a `RecoveryReport`:

```dart
final report = await raid.recover();

print('Status  : ${report.status}');
print('Duration: ${report.duration.inMilliseconds} ms');
print('Disks OK: ${report.recoveredDiskIndexes}');
print('Disks KO: ${report.failedDiskIndexes}');
print('Files   : ${report.recoveredFiles.length}');
print('Bytes   : ${report.totalBytesRecovered}');
print('Rate    : ${report.successRate.toStringAsFixed(1)}%');

for (final f in report.recoveredFiles) {
  print('  ${f.filename}: disk${f.fromDiskIndex} → disk${f.toDiskIndex} '
        '(${f.bytesRecovered} bytes, verified: ${f.verified})');
}

if (report.errors.isNotEmpty) {
  for (final e in report.errors.entries) {
    print('  ERROR [${e.key}]: ${e.value}');
  }
}
```

### RecoveryStatus values

| Status | Meaning |
|--------|---------|
| `success` | All failed disks fully rebuilt |
| `partial` | Some disks rebuilt; some files had errors |
| `notRequired` | No failed disks — array was healthy |
| `failed` | Recovery impossible (RAID 0, too many failures) |

---

## Testing recovery in your app

Use the simulation helpers to test your error-handling code without destroying
real data:

```dart
import 'package:filesystem_raid/filesystem_raid.dart';
import 'package:test/test.dart';

test('RAID 5 survives one disk failure', () async {
  final raid = FilesystemRaid(
    diskPaths: ['/tmp/d0', '/tmp/d1', '/tmp/d2'],
    config: const RaidConfig(
      type: RaidType.raid5,
      diskCount: 3,
      healthCheckInterval: Duration.zero,
      writeVerification: false,
    ),
  );
  await raid.initialize();

  final original = Uint8List.fromList(List.generate(1024, (i) => i % 256));
  await raid.write('file.bin', original);

  // Simulate disk 0 failing.
  raid.simulateDiskFailure(0);

  // Data must still be readable via parity.
  final recovered = await raid.read('file.bin');
  expect(recovered, equals(original));

  // Replace disk and rebuild.
  await raid.simulateDiskRestore(0);
  final report = await raid.recover();
  expect(report.status, equals(RecoveryStatus.success));

  await raid.dispose();
});
```

---

## Recovery best practices

1. **Monitor health regularly** — set `healthCheckInterval` to something shorter
   than `Duration(hours: 24)` in production (e.g. `Duration(hours: 1)`).

2. **Act quickly on degraded arrays** — a RAID 5 array with one failed disk
   has **zero** remaining fault tolerance.  Replace and rebuild before the
   next failure.

3. **Enable write-verification** — `writeVerification: true` (default) catches
   bad writes early, before a disk failure compounds the problem.

4. **Back up your encryption key** — if `enableEncryption: true`, store the
   32-byte key in a separate secure location.  No key = no data recovery.

5. **Test recovery in staging** — use `simulateDiskFailure` / `simulateDiskRestore`
   in your CI pipeline to verify your application survives a disk event.

6. **Check `report.errors`** — a `RecoveryStatus.partial` result means some
   files were not fully rebuilt.  Inspect `report.errors` for per-file details
   and restore those files from backup.
