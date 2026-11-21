# Spring

A quiet macOS screenplay editor for Fountain scenes kept in an Obsidian vault.

## Build and run

```bash
swift run SpringChecks                 # core checks
scripts/bundle.sh && open build/Spring.app
```

Needs macOS 15+. Command Line Tools are enough locally; CI uses full Xcode for universal builds.

## Releases and updates

Every push to `main` replaces the `nightly` pre-release. Tags `v*` make a versioned release.
The app checks `https://pocketcoder.github.io/spring/nightly-appcast.xml` (Spring › Check for Updates…).

One-time Sparkle key setup (the private key stays in your keychain and the `SPARKLE_PRIVATE_KEY` secret):

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account spring
```

Put the printed public key in `Resources/sparkle-public-key.txt`, then:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account spring -x /tmp/spring.key && gh secret set SPARKLE_PRIVATE_KEY < /tmp/spring.key && rm /tmp/spring.key
```

## Licences

Courier Prime and Space Mono are bundled under the SIL Open Font License (`Resources/Fonts/OFL-*.txt`).
