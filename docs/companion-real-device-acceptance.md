# Companion real-device pairing acceptance

This is the release gate for Kaisola issue #14. It binds one signed Mac app,
one Apple-signed iPhone device build, the complete physical-device scenario
matrix, and redacted evidence into a reproducible receipt. The receipt tool is
offline: it inspects app bundles and files but never launches Kaisola, contacts
the broker, connects to a device, or accepts credentials on its command line.

Running the local tests or creating an empty checklist **does not complete Issue #14**.
Completion requires a fresh run on a clean physical iPhone and a
signed Mac build, followed by a passing `seal` and an independent `verify` over
the unchanged artifacts.

## Safety boundary

- Use an isolated acceptance directory with mode `0700`. Do not put it in the
  repository or a shared DerivedData directory.
- Never record an Apple ID token, Firebase token, bearer credential, private
  key, recovery secret, raw device UDID, raw account-rendezvous response, or
  unredacted pairing payload in a command, log, screenshot, pasteboard audit,
  analytics capture, or operator note.
- Record the iPhone identifier only as a lowercase SHA-256 digest. Hash it in a
  local trusted process and discard the raw input; do not pass the raw value to
  this tool.
- Pairing screenshots must exclude QR contents after capture and have a UTF-8
  OCR sidecar that was reviewed for secrets. The receipt hashes the image and
  the OCR sidecar.
- Scenario logs contain only timestamps, side (`mac` or `iphone`), protocol
  event names, expected outcome, and redacted UI result. Do not capture frame
  bodies, keys, signatures, tokens, payloads, or SAS words.
- The manual code is the full signed, single-use pairing offer copied from the
  Mac and entered in the iPhone UI. The manual phrase is the separate four-word
  SAS shown after Noise XX. Compare the phrase visually and record only
  `matched-on-both`; never copy its words into evidence.
- The tool refuses symlinked evidence, path traversal, oversized evidence,
  private-key headers, bearer credentials, JWTs, and common credential fields.
  It also rejects every undeclared file in the evidence directory. Keep the
  original acceptance directory immutable after sealing.

## 1. Prepare exact builds

Use one clean source commit for both products. Set task-specific paths rather
than reusing global build locations:

```sh
issue14_commit="$(git rev-parse HEAD)"
issue14_run_root="$(mktemp -d /tmp/kaisola-issue14-acceptance.XXXXXX)"
issue14_derived_data="$(mktemp -d /tmp/kaisola-issue14-derived.XXXXXX)"
chmod 0700 "$issue14_run_root" "$issue14_derived_data"
mkdir -p "$issue14_run_root/evidence/scenarios" "$issue14_run_root/evidence/privacy"
```

Verify that `issue14_commit` is the commit used to produce both already-signed
artifacts. Do not rebuild either product from a different checkout after this
point.

Create the Mac receipt with the existing distribution preflight. This requires
a Developer ID signature, secure timestamp, exact arm64 app/helper/runtime
architecture, and the broker-free launch probe:

```sh
node scripts/native-release-preflight.cjs \
  --app /absolute/path/to/Kaisola.app \
  --require-developer-id \
  --source-commit "$issue14_commit" \
  --json-output "$issue14_run_root/mac-preflight.json"
```

Archive or build the iPhone target for a generic physical iOS destination with
normal Apple signing and the isolated DerivedData path. Locate the exported or
archive-contained `KaisolaCompanion.app`; do not use a Simulator product. Seal
its bundle identity, version/build, exact arm64 architecture, Apple signing
team and entitlements, executable hash, provisioning-profile hash, and complete
bundle digest. The receipt output must remain outside the signed `.app`:

```sh
npm run companion:device-acceptance -- inspect-ios \
  --app /absolute/path/to/KaisolaCompanion.app \
  --source-commit "$issue14_commit" \
  --output "$issue14_run_root/iphone-build.json"
```

The Mac and iPhone receipts must report the same ten-character Apple team
identifier. Save the exact model and OS version for each device. Save the app
version, build number, bundle digest, and receipt hashes; do not use a device
name or raw UDID as identity evidence.

## 2. Run the physical scenario matrix

Start from no stored Kaisola Companion identity on a clean physical iPhone.
For every positive scenario, create a new single-use offer and verify this
exact, ordered transcript on both sides using privacy-safe event-name evidence:

```text
pair.start
pair.message2
pair.message3
pair.confirmation
sas-confirm.iphone
sas-confirm.mac
paired
```

The two `sas-confirm` entries mean the same four-word SAS was displayed. For a
deterministic transcript, independently tap **They match** on the iPhone first,
then **They Match** on the Mac. Verify the stored Mac identity on the iPhone and
stored iPhone identity on the Mac after each successful flow.

Run these positive flows:

1. **QR:** create an offer on Mac, scan its QR code with the clean physical
   iPhone, compare the four-word manual phrase, confirm on both devices, and
   verify both stored identities.
2. **Manual code:** create a new offer, choose **Copy Pairing Code** on Mac,
   choose **Enter code manually** on iPhone, paste once, immediately clear the
   pasteboard, compare the four-word phrase, confirm both sides, and verify both
   stored identities.
3. **Account rendezvous:** sign both products into the same intended account,
   create a new offer on Mac, choose **Find my Mac** on iPhone, select the exact
   Mac, compare the four-word phrase, confirm both sides, and verify that the
   claimed same-account offer—not account credentials—led into the same Noise
   XX transcript and stored identities.

Reset pairing state between scenarios. Then run, in this order, **user
cancellation**, **malformed offer**, **stale offer**, **wrong account**, and
**protocol-version mismatch**. Each negative scenario must show its exact
user-visible rejection, persist no new identity on either side, and leave no
active companion channel:

| Scenario | Required observation |
| --- | --- |
| User cancellation | `cancelled-without-pairing` |
| Malformed offer | `rejected-malformed-offer` |
| Stale offer (after the two-minute expiry) | `rejected-expired-offer` |
| Wrong account rendezvous | `rejected-account-mismatch` |
| Protocol-version mismatch | `rejected-protocol-mismatch` |

Do not alter a production-signed app or hand-edit a signed offer to manufacture
version skew. Use a separately signed, clearly labelled incompatible acceptance
build from the same controlled source snapshot and record its digest as operator
evidence. If no controlled incompatible build exists, this scenario—and the
entire gate—remains blocked; do not substitute a Simulator result.

## 3. Record bounded evidence

Each of the eight scenarios needs one redacted Mac log and one redacted iPhone
log. Use these relative paths so the observation document remains portable:

```text
evidence/scenarios/qr-mac.log
evidence/scenarios/qr-iphone.log
evidence/scenarios/manualCode-mac.log
evidence/scenarios/manualCode-iphone.log
evidence/scenarios/accountRendezvous-mac.log
evidence/scenarios/accountRendezvous-iphone.log
evidence/scenarios/userCancellation-mac.log
evidence/scenarios/userCancellation-iphone.log
evidence/scenarios/malformedOffer-mac.log
evidence/scenarios/malformedOffer-iphone.log
evidence/scenarios/staleOffer-mac.log
evidence/scenarios/staleOffer-iphone.log
evidence/scenarios/wrongAccount-mac.log
evidence/scenarios/wrongAccount-iphone.log
evidence/scenarios/protocolVersionMismatch-mac.log
evidence/scenarios/protocolVersionMismatch-iphone.log
```

Paths inside `observations.json` are relative to the `evidence` directory, so
omit the leading `evidence/` there. Every scenario gets unique Mac and iPhone
logs. The machine-readable fields and observation timestamps must match
exactly. A positive log has this format (with the correct `side`):

```text
side=mac
startedAt=2026-08-09T20:00:00.000Z
completedAt=2026-08-09T20:01:00.000Z
event=pair.start
event=pair.message2
event=pair.message3
event=pair.confirmation
event=sas-confirm.iphone
event=sas-confirm.mac
event=paired
result=paired
sas=matched-on-both
storedIdentity=mac-and-iphone
rendezvous=not-used
```

Use `rendezvous=same-account-offer-claimed` for account rendezvous. A negative
log has this format, with the matrix's exact result:

```text
side=iphone
startedAt=2026-08-09T20:02:00.000Z
completedAt=2026-08-09T20:03:00.000Z
result=rejected-malformed-offer
persistedIdentity=false
activeChannel=false
userVisibleResult=true
```

Additional redacted, non-secret fields are allowed. A scenario may also
reference a separate `operator-note`, but it still requires exactly one unique
Mac log and one unique iPhone log. The sealer requires the exact positive
transcript in order on both sides and the fail-closed state on both sides for
every negative scenario.

Also create:

- `privacy/pairing.png` (or `.jpg`) plus `privacy/pairing.ocr.txt`, with OCR
  reviewed and all sensitive values absent;
- `privacy/pasteboard-audit.json`; and
- `privacy/analytics-audit.json`.

The pasteboard audit has this exact shape:

```json
{
  "schemaVersion": 1,
  "kind": "kaisola-companion-pasteboard-audit",
  "longTermKeyObserved": false,
  "privateKeyObserved": false,
  "bearerCredentialObserved": false,
  "pairingOfferClearedAfterManualEntry": true
}
```

The analytics audit has this exact shape:

```json
{
  "schemaVersion": 1,
  "kind": "kaisola-companion-analytics-audit",
  "longTermKeyObserved": false,
  "privateKeyObserved": false,
  "bearerCredentialObserved": false,
  "rawPairingOfferObserved": false
}
```

## 4. Write observations

Create `$issue14_run_root/observations.json` as UTF-8 JSON. It must have exactly
these top-level fields:

```json
{
  "schemaVersion": 1,
  "kind": "kaisola-companion-real-device-observations",
  "sourceCommit": "40 lowercase hex characters",
  "run": {
    "id": "a newly generated UUID",
    "startedAt": "canonical ISO-8601 UTC",
    "completedAt": "canonical ISO-8601 UTC"
  },
  "hardware": {
    "mac": { "modelIdentifier": "Mac model identifier", "osVersion": "major.minor.patch" },
    "iphone": {
      "modelIdentifier": "iPhone model identifier",
      "osVersion": "major.minor.patch",
      "deviceIdentifierHash": "64 lowercase SHA-256 hex characters",
      "physicalDevice": true,
      "cleanInstall": true
    }
  },
  "scenarios": {},
  "privacy": {},
  "evidence": []
}
```

`scenarios` must contain exactly `qr`, `manualCode`, `accountRendezvous`,
`userCancellation`, `malformedOffer`, `staleOffer`, `wrongAccount`, and
`protocolVersionMismatch`. Every entry has `result: "pass"`, equal `expected`
and `observed` values from the matrix, canonical start/end timestamps inside
the run, and both its `mac-log` and `iphone-log` evidence paths.

Each positive entry additionally has:

```json
{
  "transcript": [
    "pair.start",
    "pair.message2",
    "pair.message3",
    "pair.confirmation",
    "sas-confirm.iphone",
    "sas-confirm.mac",
    "paired"
  ],
  "sasConfirmation": "matched-on-both",
  "storedIdentity": "mac-and-iphone",
  "rendezvous": "not-used"
}
```

For `accountRendezvous`, use `"rendezvous":
"same-account-offer-claimed"`. Each negative entry instead adds:

```json
{
  "persistedIdentity": false,
  "activeChannel": false,
  "userVisibleResult": true
}
```

`privacy` contains exactly `logs`, `screenshots`, `pasteboard`, and `analytics`.
All four have `result: "pass"` and evidence arrays. `screenshots` also has
`ocrReviewed: true`; `pasteboard` has
`pairingOfferClearedAfterManualEntry: true`; `analytics` has
`captureReviewed: true`. The logs privacy evidence array references all sixteen
scenario logs. The screenshots array references the image and OCR sidecar.

Finally, `evidence` declares every referenced file exactly once as `{ "path":
"relative/path", "kind": "..." }`. Allowed kinds are `mac-log`, `iphone-log`,
`screenshot`, `screenshot-ocr`, `pasteboard-audit`, `analytics-audit`, and
`operator-note`. Every declaration must be referenced by a scenario or privacy
check. The validator rejects extra fields, missing cases, duplicate or absolute
paths, unreferenced declarations, and inconsistent timestamps.

## 5. Seal and independently verify

Seal only after the physical run and privacy review are complete. The output
path must not already exist; the tool publishes mode-`0600` JSON and refuses to
overwrite a prior receipt. It must also stay outside the evidence directory so
sealing cannot add an unhashed file to the evidence set:

```sh
npm run companion:device-acceptance -- seal \
  --mac-preflight "$issue14_run_root/mac-preflight.json" \
  --iphone-build "$issue14_run_root/iphone-build.json" \
  --observations "$issue14_run_root/observations.json" \
  --evidence-directory "$issue14_run_root/evidence" \
  --output "$issue14_run_root/companion-device-acceptance.json"
```

Expected terminal status:

```text
COMPANION_DEVICE_ACCEPTANCE=PASS evidence=<sha256>
```

Make the directory read-only or copy it to immutable artifact storage. A second
operator or clean process then verifies the receipt against the original build
receipts, observations, and evidence:

```sh
npm run companion:device-acceptance -- verify \
  --receipt "$issue14_run_root/companion-device-acceptance.json" \
  --mac-preflight "$issue14_run_root/mac-preflight.json" \
  --iphone-build "$issue14_run_root/iphone-build.json" \
  --observations "$issue14_run_root/observations.json" \
  --evidence-directory "$issue14_run_root/evidence"
```

Expected terminal status:

```text
COMPANION_DEVICE_ACCEPTANCE=VERIFIED evidence=<same-sha256>
```

Attach the final receipt, the two build receipts, and privacy-reviewed evidence
to the issue's controlled acceptance record. Record the exact Kaisola Mac
version/build, Companion iPhone version/build, source commit, hardware model
identifiers, OS versions, signing team, and receipt digest in the issue without
posting any excluded secret or raw device identifier.
