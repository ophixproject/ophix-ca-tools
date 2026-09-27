# ophix-ca-tools — Internal CA & Certificate Management

A small, dependency-free set of shell scripts (OpenSSL only — no Python, no Django, no pip
install) for standing up and running a self-signed internal Certificate Authority.

**Why this exists in the Ophix project:** every Ophix server expects a TLS certificate during
`configure_install` / `run_install`, but `ophix-certs` (the fleet certificate domain) and
`ophix-certs-ca` (the in-admin CA) are themselves Django apps that need a running, TLS-terminated
server to be useful. That's a chicken-and-egg problem the very first server in a new fleet can't
solve with `ophix-certs`. `ophix-ca-tools` is the answer: a standalone CA you can run from any
machine (your laptop, a jump box, the new server itself) before any Ophix server exists, to issue
the first cert a server needs to come up over HTTPS at all.

Typical uses:
- **Bootstrapping** — issue a cert for the very first Ophix server in a fleet, before `ophix-certs`
  has anywhere to run.
- **No-certserver fleets** — some deployments never stand up `ophix-certs` at all (small fleets,
  air-gapped environments, or an operator who just wants a lightweight internal CA). This tool is
  a complete, standalone answer for internal cert issuance in that case, with no dependency on any
  other Ophix package.
- **Emergency/offline issuance** — a CA that doesn't depend on a database, a web server, or network
  access to anything is useful when the fleet's normal cert-issuance path is down.

This tool has no dependency on any other Ophix package and no Ophix package depends on it — it is
plain OpenSSL wrapped in shell scripts, usable with or without the rest of Ophix.

### Using this with `ophix-server-base`'s `configure_install`

`ophix-manage configure_install` asks three TLS questions, and this tool's output maps onto them
directly:

| `configure_install` prompt | What to supply |
| --- | --- |
| TLS certificate (.crt / .pem) | `./ssl/<domain>/<host>/<host>.crt` from `issue_cert.sh create ...` |
| TLS private key (.key / .pem) | `./ssl/<domain>/<host>/<host>.key` from the same `issue_cert.sh` run |
| CA bundle for nginx `ssl_trusted_certificate` (optional) | the file produced by `generate_ca_bundle.sh` |

`configure_install` also copies whatever you give it for the CA bundle into
`INSTALL_DIR/ssl/certs/` and points `CA_CERT_FILE` at it — that's the same file the server later
exposes at `/api/server/ca-cert/` for Tier 1 clients to download and trust during
`quickstart`/`download ca-cert`. So one `init_ca.sh` + `issue_cert.sh` + `generate_ca_bundle.sh`
run gives you everything `configure_install` needs to bring a brand-new server up over HTTPS with
a CA its own clients will also trust — no `ophix-certs` deployment required.

Certificate lifecycle from here on (renewal via `issue_cert.sh renew`, `check_expiry.sh`,
`renew_ca.sh` for the CA itself) is entirely manual/cron-driven — this tool does not talk to any
Ophix server, by design. If a fleet later stands up `ophix-certs`, migrating off this tool is a
one-time cutover (new certs signed by `ophix-certs-ca` or an external CA instead); there's no
integration path between them since none is needed.

---

## 0️. Installation & Setup

### Clone the repository, make scripts executable

```bash
git clone git@github.com:ophixproject/ophix-ca-tools.git
cd ophix-ca-tools
chmod +x *.sh

```

Or, if you are switching branches in an existing repo:

```bash
git checkout <branch-name>
```

---

### Protect secrets from being committed

Add a `.gitignore` file (or update it) to exclude CA private keys, leaf keys, and any generated certs:

```
# Ignore private keys and sensitive files
*.key
*.csr
*.crt
.env
ssl/
*/private/
```

> This ensures that your CA private key, leaf keys, and `.env` file are **never accidentally committed** to Git.

---

### Optional: Verify

```bash
git status
```

* Only scripts and documentation should be staged for commit
* No private keys, certs, or `.env` files should appear


---

## **1️. Initialize the CA — `init_ca.sh`**

### **Purpose**

Creates a new internal Certificate Authority (CA) structure, including:

* Private key
* Self-signed CA certificate
* Directory layout: certs, private, crl, newcerts
* Index files (`index.txt`) and serial files
* `.env` file for scripts to know CA location

### **Usage**

```bash
./init_ca.sh <CertificateAuthorityName> <Country> <State> <City> <Organization> <OrgUnit>
```

**Example:**

```bash
./init_ca.sh Fleet AU Victoria Melbourne Ophix "Internal Systems"
```

### **Notes**

* `Country` must be **2-letter ISO code** (e.g., AU, US, GB)
* Script will create `.env` containing `CA_CONFIG` and defaults
* After this, the CA is ready for issuing certificates

---

## **2️. Issue or Renew Leaf Certificates — `issue_cert.sh`**

### **Purpose**

Issue or renew server (leaf) certificates signed by the CA. Supports:

* **Create** new certificate
* **Renew** existing certificate
* Optional **revoke old certificate** during renewal

### **Usage**

```bash
# Create a new certificate
./issue_cert.sh create <domain> <hostname> [ip]

# Renew a certificate
./issue_cert.sh renew [--revoke-old] <domain> <hostname> [ip]
```

**Example:**

```bash
./issue_cert.sh create example.com web01
./issue_cert.sh renew --revoke-old example.com web01
```

`ip` is optional — pass it only if the host needs an IP address in `subjectAltName` (e.g. clients
connect by IP rather than by resolvable name). When omitted, the certificate's SANs are just
`<hostname>` and `<hostname>.<domain>`.

### **Notes**

* Certificates are stored under `./ssl/<domain>/<host>/`
* `.cert_info` tracks IP (if given) and CN for comparison to avoid unnecessary regeneration
* Adding or removing the `ip` argument on a later `create`/`renew` run counts as a change — a new
  cert is issued to match the new SAN list
* Leaf cert **must not outlive the CA cert**
* `--revoke-old` will revoke previous cert in the CA index
* This system is designed for **_Internal Use Only_**. As such, issue_cert.sh creates **key**, **csr**, and **crt** rather than simply signing a csr generated elsewhere. The user is expected to know how to handle keys securely.

---

## **3️. Check certificate expiry — `check_expiry.sh`**

### **Purpose**

* Warn if CA or leaf certificates are approaching expiry
* Default warning threshold: 30 days (customizable)

### **Usage**

```bash
# Default 30-day warning
./check_expiry.sh

# Custom warning threshold
./check_expiry.sh 60   # warn if any cert expires in <60 days
```

### **What it checks**

* **CA cert** from `.env`
* All **leaf certs under ./ssl** recursively (e.g., `./ssl/domain/host/host.crt`)

### **Notes**

* Prints number of days left until expiry for each cert
* Helps plan CA renewal and leaf certificate rotations

---

## **4️. Renew the CA certificate — `renew_ca.sh`**

### **Purpose**

Renew the CA certificate when it is approaching expiry, **reusing the existing private key**:

* Generates new CA cert with extended validity
* Archives old CA cert as `*.old` for a grace period
* Prints fingerprints for verification

### **Usage**

```bash
./renew_ca.sh
```

### **Workflow / Best Practices**

1. Run **before CA expires**, ideally at least 1 year prior if leaf certs are 1 year
2. Keep old CA cert (`*.old`) during client rollout
3. Leaf certificates do **not need to be reissued** if the key stays the same
4. After verification and full distribution of new CA, old CA cert can be removed

---

## **5️. Rebuild CA index — `rebuild_index.sh`**

### **Purpose**

Rebuilds the CA index (`index.txt`) from a directory of existing certificates. Useful if:

* Index was lost or corrupted
* Migrating an old CA structure

### **Usage**

```bash
./rebuild_index.sh <certs_directory> <output_index_file>
```

**Example:**

```bash
./rebuild_index.sh ./ssl/Fastrack-CA/certs ./ssl/Fastrack-CA/index.txt
```

### **Notes**

* Reads expiration date, serial, and subject from each `.crt` file
* Creates a proper OpenSSL CA index file
* Does **not alter CA keys** or leaf certificates

---

## **6️. Recommended Certificate Lifecycle Practices**

| Item         | Recommended validity | Renewal notes                                         |
| ------------ | -------------------- | ----------------------------------------------------- |
| CA cert      | 10 years             | Renew ~1 year before expiry; reuse key if safe        |
| Leaf cert    | 1 year               | Ensure leaf cert expiry ≤ CA cert expiry              |
| Leaf renewal | Before expiry        | Use `issue_cert.sh renew`; optionally revoke old cert |
| CA rollover  | Before old CA expiry | Keep old CA cert in trust stores during grace period  |

---

## **7️. Directory Structure Overview**

```
.
├── init_ca.sh
├── issue_cert.sh
├── renew_ca.sh
├── check_expiry.sh
├── rebuild_index.sh
├── .env
└── ssl/
    └── <domain>/
        └── <host>/
            ├── <host>.key
            ├── <host>.csr
            ├── <host>.crt
            └── .cert_info
└── <CompanyName>-CA/
    ├── certs/
    │   └── ca.cert.pem
    ├── private/
    │   └── ca.key.pem
    ├── crl/
    ├── newcerts/
    ├── index.txt
    └── serial
```

---

## **8️. Quick Workflow Summary**

1. **Initialize CA**: `./init_ca.sh ...` → sets up CA + `.env`
2. **Issue leaf certs**: `./issue_cert.sh create ...`
3. **Renew leaf certs**: `./issue_cert.sh renew ...`
4. **Check expiry regularly**: `./check_expiry.sh`
5. **Renew CA when approaching expiry**: `./renew_ca.sh`
6. **Rebuild index if needed**: `./rebuild_index.sh`

---

## **9. Tips for Future You**

* Always **backup CA private key and certs** before renewal
* Do **not issue leaf certs that outlive the CA cert**
* Use `.env` for all scripts → easy to move CA directories
* Keep a **log of leaf cert renewals** (timestamps, CNs, IPs) for auditing
* Grace period for CA rollover: ~1–2 months to ensure all systems accept the new CA

---

## **10. Generate a CA Bundle — `generate_ca_bundle.sh`**

### **Purpose**

Creates a single file containing all **current valid CA certificates**.

* Useful for distributing to clients or applications that need to trust your internal CA
* Automatically handles overlapping CA certificates during a rollover (e.g., 1-year overlap)
* Default output filename combines `.env` fields `DN_O` (organization) and `DN_OU` (organizational unit)

---

### **Usage**

```bash
# Default output filename (<DN_O><DN_OU>.ca_bundle)
./generate_ca_bundle.sh

# Specify a custom filename
./generate_ca_bundle.sh my_custom_bundle.pem
```

---

### **Example**

If your `.env` contains:

```
DN_O="Ophix"
DN_OU="Internal Systems"
```

Then running:

```bash
./generate_ca_bundle.sh
```

Will generate:

```
OphixInternalSystems.ca_bundle
```

in the current directory, containing all valid CA certs.

---

### **Notes**

* Only includes **valid CA certificates** (expiration > current date)
* Useful during **CA rollover**, when both old and new CA certs are still valid
* Output is written in the **current working directory**
* Script automatically reports the name of the generated bundle

---

This should give you **everything you need to manage your internal CA for years** without needing to remember all the command flags or paths.

---
