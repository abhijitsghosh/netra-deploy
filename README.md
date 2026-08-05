# netra-deploy

Public distribution artefacts for **Netra** — a read-only Azure ISM PROTECTED
posture reporter & best-practice hardening scanner. Source is at
`abhijitsghosh/netra` (available to security teams on request).

## Install (Azure Cloud Shell)

```bash
curl -sL https://netra.run/install.sh | bash -s -- --region australiaeast
```

This repo also serves the landing site (`index.html`) and docs (`docs.html`) via
Cloudflare Pages at netra.run. Read-only: Netra holds the Reader role, and a
consented read-only `Policy.Read.All` Graph permission; it writes nothing.

Contents: `azuredeploy.json` (ARM template), `install.sh`, `version.json`,
`index.html`, `docs.html`, `img/` (docs screenshots).
