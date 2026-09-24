# Distributing the macOS app (Developer ID)

`scripts/create-archive-macos.sh` builds, Developer-ID-signs, notarizes, staples,
and packages a drag-to-Applications `.dmg` that runs on any Mac — no App Store.

## One-time Apple-side setup

The script cannot do these for you:

1. Create a **Developer ID Application** certificate: Xcode › Settings ›
   Accounts › Manage Certificates › **+** › *Developer ID Application*.
2. Create the two **manually managed Developer ID provisioning profiles** that
   `project.yml` pins by name for Release macOS builds — "ezvpn Developer ID
   app" (App ID `<prefix>`) and "ezvpn Developer ID sysex" (App ID
   `<prefix>.PacketTunnel`) — on the developer portal (Certificates,
   Identifiers & Profiles › Profiles › + › Developer ID, or via the App Store
   Connect API with an Admin key, `profileType: MAC_APP_DIRECT`). Once they
   exist, `-allowProvisioningUpdates` downloads them on any machine. They must
   be manually managed: Release macOS builds sign manually with Developer ID
   (automatic signing can only archive with a development identity, whose
   profile cannot carry the release entitlements'
   `packet-tunnel-provider-systemextension` value, and manual signing refuses
   Xcode-managed profiles).
3. Create an **App Store Connect API key** for notarization (App Store Connect ›
   Users and Access › Integrations › App Store Connect API) and download its
   `AuthKey_XXXX.p8`. Cache it as a notarytool profile once:

   ```sh
   xcrun notarytool store-credentials ezvpn-notary \
     --key AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_UUID>
   ```

## Building locally

With `DEVELOPMENT_TEAM` set in `Developer.local.xcconfig`:

```sh
xcodegen generate
scripts/create-archive-macos.sh --notary-profile ezvpn-notary
```

The result is `build/ezvpn-<version>.dmg`. Recipients drag **ezvpn** to
Applications, launch it, and approve the network extension once in System
Settings (the app requests activation on first launch). Pass `-m debugging`
instead for a local development-signed `.app` (no notarization or `.dmg`; runs
only on machines registered to your team). Run `--help` for all options.

## Building the DMG in CI (GitHub Actions)

The **Release macOS DMG (Manual)** workflow
(`.github/workflows/release-macos.yml`) runs the same script on a `macos-latest`
runner and publishes the notarized `.dmg` as a GitHub **prerelease** — the
ready-to-run download for end users, no Apple account required to install it.
Each run stamps the next version: the last `macos-v*` release (or project.yml's
`MARKETING_VERSION`, if higher) with its patch number incremented, as both the
app and extension version, with the workflow run number as the build number.
The release is tagged `macos-v<version>` and titled with the core version it
bundles. The stamp matters: sysextd only replaces an installed system extension
whose version differs, so a release reusing a version would leave the old
extension running after an upgrade. Locally, pass `--app-version X.Y.Z
--build-number N` to the script for the same effect. It is `workflow_dispatch`-only (never on push/PR)
and limited to one run at a time, so the signing identity and API key are never
exposed to untrusted code.

It supplies from **repository configuration** what the script normally reads from
your local keychain and `Developer.local.xcconfig`. Two non-sensitive values are
plaintext **Actions variables** (Settings › Secrets and variables › Actions ›
**Variables**); the rest are encrypted **secrets**:

**Variables** (`vars.*`):

| Variable | What it is | Value |
|---|---|---|
| `DEVELOPMENT_TEAM` | your Apple Developer Team ID | copy it from the portal (e.g. `5J7W998Y8H`) |
| `BUNDLE_ID_PREFIX` | a reverse-DNS prefix your team owns; **must** match the pinned App IDs / profiles (not the `com.example.ezvpn` placeholder) | the prefix you registered, e.g. `com.yourteam.ezvpn` |

**Secrets** (`secrets.*`):

| Secret | What it is | How to produce the value |
|---|---|---|
| `DEVELOPER_ID_CERT_P12` | base64 of your "Developer ID Application" cert, **exported with its private key** | Keychain Access → export the identity as `.p12`, then `base64 -i DeveloperID.p12 \| pbcopy` |
| `DEVELOPER_ID_CERT_PASSWORD` | the password you set on that `.p12` export | (as typed during export) |
| `KEYCHAIN_PASSWORD` | any random string; used only for the throwaway CI keychain | `openssl rand -base64 24` |
| `ASC_API_KEY_P8` | base64 of the App Store Connect API key (`AuthKey_XXXX.p8`) | `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `ASC_API_KEY_ID` | the key ID (the `XXXX` in the filename) | from App Store Connect |
| `ASC_API_ISSUER_ID` | the API key issuer UUID | App Store Connect › Users and Access › Integrations |

The API key must have **Admin** access so `-allowProvisioningUpdates` can
download the manually-managed `ezvpn Developer ID app` / `ezvpn Developer ID
sysex` profiles on the fresh runner (it downloads existing profiles — it does
not create them; do the [one-time setup](#one-time-apple-side-setup) first). The
same key drives notarization.

> **Security note.** These secrets are a signing identity and an Admin API key.
> Keep the workflow `workflow_dispatch`-only and restrict who can run it (e.g.
> via a protected environment); anyone who can trigger it, or push a change to
> it, can use the credentials.
