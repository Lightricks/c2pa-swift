# Verification fixtures

- `es256_certs.pem` and `es256_private.key` are copied into the staged test project from
  [c2pa-swift TestShared/Resources](https://github.com/contentauth/c2pa-swift/tree/v0.1.0/TestShared/Resources).
  This key is public and used for test claims.
- `DigiCertTrustedRootG4.pem` is the self-signed DigiCert Trusted Root G4, the trust anchor of
  DigiCert’s [RFC 3161 timestamp service](https://knowledge.digicert.com/general-information/rfc3161-compliant-time-stamp-authority-server).
  It was downloaded from <https://cacerts.digicert.com/DigiCertTrustedRootG4.crt> and converted to
  PEM. Its SHA-256 fingerprint,
  `55:2F:7B:DC:F1:A7:AF:9E:6C:E6:72:01:7F:4F:12:AB:F7:72:40:C7:8E:76:1A:C2:03:D1:D9:D2:0A:C8:99:88`,
  matches the one DigiCert publishes on
  [DigiCert Trusted Root Authority Certificates](https://knowledge.digicert.com/general-information/digicert-trusted-root-authority-certificates).
  DigiCert's timestamp tokens also carry a copy of this root cross-signed by DigiCert Assured ID
  Root CA. The tests pass with the self-signed root alone, so the cross-signed copy isn't a
  fixture.
- `v0.0.16-ingredient-*.c2pa` are parent ingredient archives written with
  [FixtureGenerator](../../../FixtureGenerator) and c2pa-swift v0.0.16 (c2pa-rs 0.91.7), the
  release before the upgrade:

  ```sh
  cd UpgradeVerification/FixtureGenerator
  swift run GenerateFixtures ../../TestShared/Resources <output directory>
  ```

  The generator signs with v0.0.16 in the profile of `SigningProfile`: the same manifest and claim
  generator name, a 1024 px thumbnail and a DigiCert timestamp through an HTTP resolver limited to
  the timestamp authority, with the upstream ES256 test key. It then writes each image's archive
  with ingredient ID `parentIngredient`. Each archive holds the timestamped manifest of a
  synthetic 1600×1200 image of color blocks, and its thumbnail: a JPEG with a data hash and JPEG
  thumbnail, a transparent PNG with a PNG thumbnail, and a HEIC with a BMFF hash. They contain no
  user or production data. Regenerate them only to cover a different pre-upgrade release, since
  the point is to load archives made by an older version.
- The images that are signed are generated at runtime (see `SampleImage`), so the large inputs
  aren't part of the repository.
