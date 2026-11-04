# Automated ClearPass Certificate Deployment

Supports `HTTPS(RSA)`, `HTTPS(ECC)`, `RADIUS`, and `RadSec` certificate imports through the ClearPass REST API.

## Requirements
  - Certify The Web (or another automated ACME certificate renewal)
  - Powershell 5.1

## How to use

Pull the repo, or download the files as a ZIP to an appropriate folder on the server that will run the automation. All scripts locate their companion files using `$PSScriptRoot`. Relative `PfxPath` values are resolved against the script directory. The examples use `C:\Certificate\`.

### Configure ClearPass for API access

#### Operator Profile

1. In ClearPass Guest, configure a new Operator Profile. This can be found in Administration -> Operator Logins -> Profiles
2. Set an appropriate name - SSL Automation or similar.
3. In the Access section, configure the permissions in each section by selecting Custom from the dropdown, and changing only the following:
  - API Services -> Allow API Access - set to Allow Access
  - Platform -> Import Configuration - set to Read Only
  - Policy Manager -> Certificates - set to Read, Write, Delete
4. All other settings in the Operator Profile can remain unchanged.

#### API Access

1. In ClearPass Guest, configure an API Client. This can be found in Administration -> API Services -> API Clients
2. Set an appropriate Client ID - SSL_Automation or similar.
3. Set the Operating Mode to ClearPass REST API, select the Operator Profile that was created, set Grant Type to Client credentials, and set the Access Token Lifetime to 1 hour.
4. Copy the Client Secret and save it somewhere secure. This will not be shown again.

### Configure the server

1. On the Windows server that will manage the automation, install and use **Windows PowerShell 5.1**. PowerShell 7 is not supported and the scripts reject it. In Certify The Web, select **System PowerShell** and ensure it uses Windows PowerShell 5.1 (disable Prefer Modern PowerShell if enabled). The execution identity needs read access to the scripts, configuration, secrets and PFX files, and administrator rights for live Windows Firewall changes.
2. Set up [Certify The Web](https://certifytheweb.com) to generate certificates from your supported ACME provider. Configure password-protected PFX export tasks before the deployment script task. Export to the script directory, for example `https.pfx` and `radius.pfx`. The export passwords must match the corresponding values in `secrets.json`.
3. Add a post-request **Run a PowerShell Script** task for `Deploy-FromCertifyTheWeb.ps1`, triggered **On Success**. Set its custom arguments to `Services=HTTPS(RSA)` for the HTTPS renewal or `Services=RADIUS` for the RADIUS renewal. If one certificate serves both, export it to both configured PFX paths first, then use `Services=HTTPS(RSA),RADIUS`. The wrapper requires an explicit selection and deploys only those services; unrelated PFX exports do not need to exist. `HTTPS(ECC)` and `RadSec` can also be selected when configured.
4. Edit `config.json`. Set the ClearPass API URL, Windows listener and advertised IP, and **every** ClearPass node's actual download source IP in `AllowedSourceIPs`. Configure `Certificates` entries only for services you intend to change. Each entry names its PFX path and password environment variable. The wrapper supplies `CPPM_HTTPS_PFX_PASSWORD` and `CPPM_RADIUS_PFX_PASSWORD`; additional services can reuse these passwords or use environment variables supplied separately.
5. Copy `secrets.example.json` to `secrets.json` and replace the placeholders with your API client ID, API client secret and PFX passwords. The local secrets file and private-key files are ignored by Git. Do not commit credentials, PFX files or private keys.
6. Restrict Windows NTFS permissions on the installation directory (including `secrets.json`, PFX files, scripts and configuration) to Administrators, SYSTEM and the automation service account as needed. Remove inherited access for ordinary users. The secrets file is plaintext; Git exclusions do not protect local access. Protect script/configuration write access because deployment runs with administrator rights.
7. Allow outbound HTTPS from the automation server to ClearPass and inbound TCP on `Delivery.Port` from every allowed ClearPass download source. Ensure routing and upstream firewall rules permit those downloads. The Windows server must trust the ClearPass API TLS certificate; keep `VerifySSL` enabled.

### Test Deployment

The supplied configuration sets `Deployment.DryRun` to `true`. Trigger the renewal in Certify The Web to test certificate export, PFX loading, API authentication, node discovery, certificate reads and the planned actions. Certificate issuance and export still occur; the deployment script does not start a listener, change firewall rules or import certificates during a dry run.

A dry run does **not** validate administrator rights, listener startup, ClearPass-to-Windows connectivity or certificate import permissions. Test a live deployment on a pilot node during a maintenance window before rolling out to all nodes. Use `ClearPass.AllowedNodeUuids` to limit that pilot.

Once dry-run issues are resolved, set `Deployment.DryRun` to `false` for the pilot. Confirm the installed certificate and HTTPS/EAP health independently, then expand the node selection. `VerifyAfterImport` checks the API fingerprint when available; otherwise it requires matching subject and expiry. This API read-back does not prove which certificate a running service is presenting.

For a manual dry run from Windows PowerShell 5.1:

```powershell
& 'C:\Certificate\Deploy-FromCertifyTheWeb.ps1' -Services 'HTTPS(RSA)'
```

The deployment script also accepts `-Services @('HTTPS(RSA)', 'RADIUS')` when called directly with the required environment variables already set. Omitting `-Services` on that direct entry point processes all configured services. `-DryRun` forces a dry run regardless of configuration.

## Important security/operational caveats

- Temporary PFX delivery is **HTTP without transport encryption**. The PFX is password-protected, but interception or offline password guessing remains possible. Only use this on a trusted, controlled management network, with a strong unique PFX password. Use an alternative solution for untrusted networks.
- The Windows firewall rule restricts source IPs but is not a substitute for a network security review. The temporary HTTP server binds to the configured IP and has an unguessable path; no client authentication.
- Certificate imports may restart/reload ClearPass services. Retain a recovery path and schedule a maintenance window.
- Public CA/root changes on **RADIUS** can cause unmanaged iOS/Android/IoT clients to fail 802.1X authentication. Test existing saved Wi-Fi profiles before enabling `RADIUS` on production.
- Standalone fallback needs `StandaloneUuid` if cluster API returns no nodes. API errors are *not* interpreted as empty clusters.
- `ForceReplace` and `-Force` bypass renewal comparison. Current expiry parsing explicitly handles ClearPass month/day/year timestamps with UTC, GMT, Australian, New Zealand and common US timezone abbreviations (or numeric UTC offsets). Unknown timezones/formats are skipped unless forced.
- The download URL uses a private IP and randomly generated token. No DNS, extra TLS certificate or IIS required.
