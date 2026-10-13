# Code signing

GatewayLens releases are to be signed through
[SignPath Foundation](https://signpath.org/)'s free code signing for open source
projects. This page says what is signed, how to check it, what IT may need, and how
the signing is set up.

> [!NOTE]
> Applied for. Until it is in place, releases are not signed - check a download with
> the SHA-256 in its release notes, or with `build/Test-Release.ps1` below.

## What is signed

- **GatewayLens.exe**
- **GatewayLens.ps1** - the copy next to the exe in the release, and the copy inside
  the exe. The script is signed first, then the exe is built with it, then the exe
  is signed.

Both are built and signed in one GitHub Actions run, from a version tag in this
repository - [release.yml](../.github/workflows/release.yml). Before it signs,
SignPath checks that the files come from that run, on GitHub's own build machines.
Every release is approved by hand. Nothing built anywhere else is ever signed.

## Check a download

```powershell
Get-AuthenticodeSignature .\GatewayLens.exe, .\GatewayLens.ps1 | Format-List Path, Status, SignerCertificate
```

*Status* is **Valid**, and the signer is **SignPath Foundation**. Or, from a copy of
this repository at the release's tag:

```powershell
.\build\Test-Release.ps1 -Exe .\GatewayLens.exe -Script .\GatewayLens.ps1 -Publisher 'SignPath Foundation'
```

It also checks that the exe carries exactly the script released next to it.

## For IT

- **SmartScreen.** A signed file names its publisher in the warning, but a new
  release can still show *Windows protected your PC* until it has been downloaded
  enough. The reputation builds with each signed release.
- **AppLocker or App Control for Business.** Allow GatewayLens.exe by its publisher
  (SignPath Foundation, product GatewayLens) or by its hash. The exe writes the script
  to `%LOCALAPPDATA%\GatewayLens\app\<version>\GatewayLens.ps1` and runs it in
  PowerShell 7. Where scripts are enforced too, allow that script by its signature or
  its hash - otherwise PowerShell runs it in Constrained Language mode, in which
  GatewayLens cannot start.
- **Execution policy.** The exe starts PowerShell with `-ExecutionPolicy Bypass`, but
  a policy set by Group Policy wins. Under *AllSigned* the script's signature is
  checked like any other, so SignPath Foundation has to be a trusted publisher.

## How it is set up

For the maintainer - once, in this order.

1. Apply at [signpath.org/apply](https://signpath.org/apply). The README's
   [code signing policy](../README.md#code-signing-policy) is what they check, with
   two-factor sign-in on GitHub and on SignPath.
2. In SignPath, the project for GatewayLens:
   - linked to the trusted build system **GitHub.com**
   - two artifact configurations, pasted from this repository: `script` from
     [build/signpath/script.xml](../build/signpath/script.xml) and `exe` from
     [build/signpath/exe.xml](../build/signpath/exe.xml)
   - the signing policies `test-signing` and `release-signing`, with a CI user as
     submitter and yourself as approver
3. In GitHub, *Settings > Secrets and variables > Actions*:
   - secret `SIGNPATH_API_TOKEN` - the CI user's API token
   - variables `SIGNPATH_ORGANIZATION_ID`, `SIGNPATH_PROJECT_SLUG` and
     `SIGNPATH_SIGNING_POLICY_SLUG` - `test-signing` first
4. Push a version tag. Approve both requests in SignPath - the script, then the exe.
   With `test-signing` the release stays a draft: check it, then delete the draft and
   the tag.
5. Set `SIGNPATH_SIGNING_POLICY_SLUG` to `release-signing`, and release.
6. Remove the *Applied for* notes here and in the README.

Each signing request waits up to an hour for its approval; after that the run fails
and nothing is published.
