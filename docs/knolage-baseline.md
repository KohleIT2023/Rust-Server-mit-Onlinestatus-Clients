# System-Dokumentation: Rustdesk-Server

**Erstellt:** 2026-04-16  
**Zuletzt aktualisiert:** 2026-04-16  
**Hostname:** `Rustdesk` / `Rustdesk.local`  
**IP-Adresse:** `192.168.0.238/24`  
**Öffentliche IP:** `78.142.96.146`  
**Betriebssystem:** Debian GNU/Linux 12 (Bookworm)  
**Kernel:** 6.8.8-2-pve (Proxmox VE Kernel)  
**Plattform:** Proxmox LXC-Container

---

## Zweck

Dieser Server ist ein **selbst gehosteter RustDesk-Relay-Server**. Er ermöglicht Remote-Desktop-Verbindungen zwischen RustDesk-Clients ohne Abhängigkeit von den öffentlichen RustDesk-Servern. Zusätzlich werden Installations-Skripte für Clients über einen HTTP-Dateiserver bereitgestellt.

---

## Laufende Dienste

| Dienst | Beschreibung | Status |
|--------|-------------|--------|
| `rustdesksignal` | RustDesk ID/Rendezvous-Server (`hbbs`) — inkl. API + Dashboard | aktiv |
| `rustdeskrelay` | RustDesk Relay-Server (`hbbr`) | aktiv |
| `rustdesk-monitor` | ~~Systemd-Dienst~~ → **deaktiviert**, ersetzt durch Cronjob | deaktiviert |
| `gohttpserver` | HTTP-Dateiserver für Client-Installationsskripte | aktiv |
| `ssh` | OpenSSH Server | aktiv |
| `postfix` | Mail (nur loopback, kein externer Relay) | aktiv |
| `cron` | Cronjobs (inkl. MySQL-Sync, jede Minute) | aktiv |

---

## RustDesk Server

### Stack & Technologie

- **Sprache:** Rust (selbst kompiliert aus Fork, Basis: `github.com/rustdesk/rustdesk-server`)
- **Basis-Commit:** `bd7bc52c` (v1.1.15)
- **Quellcode lokal:** `/usr/local/src/rustdesk-server`
- **Protokoll:** Eigenes UDP/TCP-Protokoll mit Ed25519-Schlüsselpaar
- **Datenbanken:**
  - `db_v2.sqlite3` — Peer-Registrierung (Upstream-Schema)
  - `client_status.sqlite3` — Persistente Client-Statuserfassung (eigene Erweiterung)
- **API + Dashboard:** HTTP auf Port `9000` (LAN-intern erreichbar)

### Eigene Erweiterungen gegenüber Upstream

| Erweiterung | Datei | Beschreibung |
|-------------|-------|-------------|
| `ClientStatusStore` | `src/client_status_store.rs` | SQLite-Modul: persistente Client-Erfassung |
| Hook RegisterPeer | `src/rendezvous_server.rs` | Schreibt jeden Heartbeat in `client_status.sqlite3` |
| Hook RegisterPk | `src/rendezvous_server.rs` | Schreibt Erst-Registrierungen in `client_status.sqlite3` |
| Axum HTTP-Server | `src/rendezvous_server.rs` | REST-API + Dashboard auf Port 9000 |
| `dashboard.html` | `src/dashboard.html` | Eingebettetes Web-Dashboard (`include_str!`) |

### Quellcode-Referenzen

| Komponente | Repository |
|------------|-----------|
| Server-Fork (`hbbs`, `hbbr`) | `/usr/local/src/rustdesk-server` (lokal) |
| Upstream | https://github.com/rustdesk/rustdesk-server |
| Client & Protokoll-Details | https://github.com/rustdesk/rustdesk |

Relevante Source-Pfade:
- `src/rendezvous_server.rs` — ID-Registrierung, API-Handler, Hooks
- `src/client_status_store.rs` — SQLite-Pool, upsert/get Methoden
- `src/dashboard.html` — Web-Dashboard (eingebettet)
- `src/peer.rs` — Peer-Datenbank-Operationen
- `src/relay_server.rs` — Relay-Pairing und Session-Management

### Binaries & Verzeichnis

```
/opt/rustdesk/
├── hbbs                    # Signal-/Rendezvous-Server (selbst kompiliert, 2026-04-16)
├── hbbr                    # Relay-Server
├── rustdesk-utils          # Hilfstool
├── id_ed25519              # Privater Server-Schlüssel (Ed25519)
├── id_ed25519.pub          # Öffentlicher Server-Schlüssel → Client-Konfiguration
├── db_v2.sqlite3           # SQLite-Peer-Datenbank (Upstream-Schema)
├── client_status.sqlite3   # Client-Status-DB (eigene Erweiterung, WAL-Modus)
├── monitor.sh              # MySQL-Sync-Script (One-Shot, via Cronjob)
├── rustdesk_monitor.sh     # Interaktiver Terminal-Monitor (legacy)
└── sicherung/
    ├── hbbs                # Backup-Binary
    └── hbbr                # Backup-Binary
```

### SQLite `db_v2.sqlite3` — Peer-Registrierung (Upstream)

```sql
CREATE TABLE peer (
    guid        blob PRIMARY KEY,   -- interner UUID
    id          varchar(100),       -- RustDesk-Peer-ID (z.B. "207383227")
    uuid        blob,               -- Geräte-UUID
    pk          blob,               -- Public Key des Clients (Ed25519)
    created_at  datetime,
    user        blob,
    status      tinyint,            -- NULL = normal, 1 = gebannt
    note        varchar(300),
    info        text                -- JSON: {"ip": "::ffff:1.2.3.4"}
) WITHOUT ROWID;
```

### SQLite `client_status.sqlite3` — Persistente Statuserfassung (eigene Erweiterung)

```sql
CREATE TABLE client_status (
    peer_id    TEXT PRIMARY KEY,   -- RustDesk-ID
    last_seen  INTEGER NOT NULL,   -- letzter Kontakt, UTC Unix-Timestamp
    last_ip    TEXT,               -- letzte IP-Adresse
    created_at INTEGER NOT NULL,   -- erster Kontakt (nie überschrieben)
    firma      TEXT,               -- aus MySQL rust_pcs importiert
    pc_name    TEXT,               -- aus MySQL rust_pcs importiert
    notizen    TEXT,               -- aus MySQL rust_pcs importiert
    kennwort   TEXT                -- aus MySQL rust_pcs importiert (Klartext)
);
CREATE INDEX idx_client_status_last_seen ON client_status(last_seen);
```

**Online-Status:** dynamisch berechnet — `online = (now - last_seen) < 30s`. Kein persistentes `online`-Feld.

**Stammdaten-Sync:** Die Felder `firma`, `pc_name`, `notizen`, `kennwort` werden manuell oder per Script aus der externen MySQL-DB übernommen. Beim `upsert_client_seen` (Hooks) werden diese Felder **nicht** überschrieben.

**Encoding-Hinweis:** MySQL-Daten können Latin-1-kodierte Umlaute enthalten. Beim Import nach SQLite mit Python konvertieren:
```python
try: value.decode('utf-8')
except UnicodeDecodeError: value.decode('latin-1')
```

### API & Dashboard (`hbbs`, Port 9000)

| Endpoint | Methode | Beschreibung |
|----------|---------|-------------|
| `/` | GET | Web-Dashboard (dunkel, Auto-Refresh 30s, Suchfeld) |
| `/api/online_peers` | GET | Aktuell verbundene Peers aus In-Memory-Map |
| `/api/clients` | GET | Alle bekannten Clients aus SQLite, absteigend nach `last_seen` |
| `/api/client/:peer_id` | GET | Einzelner Client inkl. berechnetem `online`-Flag |

**Dashboard-Features:** Firma, PC-Name, Status-Badge, Client-ID, IP, Zeitstempel, Passwort (klickbar → Clipboard), Notizen als Tooltip, Suchfeld.

**Zugriff:** `http://192.168.0.238:9000/`

### Systemd-Services

```
/etc/systemd/system/rustdesksignal.service
  ExecStart:        /opt/rustdesk/hbbs -k _
  WorkingDirectory: /opt/rustdesk/
  Logs:             /var/log/rustdesk/signalserver.log
                    /var/log/rustdesk/signalserver.error

/etc/systemd/system/rustdeskrelay.service
  ExecStart:        /opt/rustdesk/hbbr -k _
  Logs:             /var/log/rustdesk/relayserver.log
                    /var/log/rustdesk/relayserver.error
```

**Bekannte Log-Einträge (normal):**
- `pk updated instead of insert` — Client aktualisiert Public Key
- `IP change of <id>` — Client hat IP gewechselt
- `Client status store ready` — SQLite-Store erfolgreich initialisiert

**Bekannte Fehler (unkritisch):**
- `signalserver.error`: `GLIBC_2.39 not found` — Einträge von älteren Binaries, aktuelle laufen stabil
- `relayserver.error`: `Address already in use` — kurz nach Neustart, systemd RestartSec=10 behebt es

### Verwendete Ports

| Port | Protokoll | Prozess | Funktion |
|------|-----------|---------|----------|
| 9000 | TCP | hbbs | REST-API + Web-Dashboard (LAN) |
| 21115 | TCP | hbbs | NAT-Test |
| 21116 | TCP+UDP | hbbs | ID-Registrierung & Heartbeat |
| 21117 | TCP | hbbr | Relay-Traffic |
| 21118 | TCP | hbbs | WebSocket (hbbs) |
| 21119 | TCP | hbbr | WebSocket (hbbr) |

### Client-Konfiguration

Clients müssen folgende Einstellungen gesetzt haben:
- **ID-Server:** `192.168.0.238`
- **Relay-Server:** `192.168.0.238`
- **Key:** Inhalt von `/opt/rustdesk/id_ed25519.pub`

Die Client-Installationsskripte haben diese Werte bereits als Base64-reversed-String eingebettet.

---

## Kompilierung & Deployment

### Voraussetzungen

| Komponente | Status |
|------------|--------|
| Rust 1.86.0 + Cargo | installiert |
| build-essential | installiert |
| libssl-dev | installiert |
| libssl3 (Runtime) | installiert |
| pkg-config | installiert |

### Standard-Workflow

```bash
cd /usr/local/src/rustdesk-server

# Änderungen vornehmen, dann:
cargo build --release 2>&1 | grep "^error"  # Nur Fehler anzeigen

systemctl stop rustdesksignal
cp target/release/hbbs /opt/rustdesk/hbbs
systemctl start rustdesksignal
systemctl status rustdesksignal
```

### Wichtig beim Deployment

- Immer **erst stoppen**, dann kopieren, dann starten (nie parallel)
- `client_status.sqlite3` liegt in `/opt/rustdesk/` (WorkingDirectory des Service)
- Neue SQLite-Spalten müssen manuell per `ALTER TABLE` hinzugefügt werden — `init_schema` verwendet `CREATE TABLE IF NOT EXISTS` und ergänzt keine Spalten

### Einschränkungen

| Problem | Details |
|---------|---------|
| **Disk-Space** | Rust-Build benötigt 2–4 GB; `target/` gelegentlich mit `cargo clean` leeren |
| **RAM** | 1 GB gesamt — Rust-Linker kann OOM-Kill auslösen |

### Langfristig: Statisch kompilieren (musl)

```bash
rustup target add x86_64-unknown-linux-musl
apt install musl-tools
cargo build --release --target x86_64-unknown-linux-musl
```

---

## MySQL-Sync (`/opt/rustdesk/monitor.sh`)

Synchronisiert Client-Status aus der lokalen API in die externe MySQL-Datenbank.

**Ausführung:** Cronjob, jede Minute (`* * * * *` in root-crontab)

**Funktionsweise:**
1. Fragt `http://localhost:9000/api/clients` ab (alle je gesehenen Clients)
2. Berechnet Online-Status: `(now - last_seen) < 30s`
3. Führt `UPDATE rust_pcs SET status=..., last_seen=... WHERE pc_id=...` aus
4. Kein INSERT — Stammdaten (Firma, PC-Name) werden manuell in MySQL gepflegt

**Externe DB-Verbindung:**
- Host: `domains.basic4web.com` (= `192.67.197.210`, `web04.kohlweiss.domains`)
- Port: `3306`
- Datenbank: `admin_domains`
- Tabelle: `rust_pcs`
- Credentials: `/root/.my.cnf` (chmod 600, nicht im Script)

**MySQL `rust_pcs`-Schema (relevant):**
```sql
pc_id     varchar(255) UNIQUE,  -- RustDesk-Peer-ID
firma     varchar(255),
pc_name   varchar(255),
notizen   text,
kennwort  varchar(255),
status    enum('online','offline'),
last_seen datetime
```

**Logs:** `/var/log/rustdesk_monitor.log`

**Firewall-Regel auf domains.basic4web.com:** Port 3306 nur für `78.142.96.146` freigegeben.

---

## Lessons Learned (2026-04-16)

### 1. `io_loop` muss `&self` statt `&mut self` sein
`Arc<RendezvousServer>` kann nicht geteilt werden wenn `io_loop` einen `&mut self`-Receiver hat. Umbau auf `&self` + `Arc<RwLock<>>` für intern mutierbare Felder (`inner`, `rendezvous_servers`) war nötig um den Server-State mit dem Axum-Handler zu teilen.

### 2. sqlx `query_as!`-Makro benötigt Datenbank zur Compile-Zeit
Das Projekt nutzt eine `.env`-Datei mit `DATABASE_URL=sqlite://./db_v2.sqlite3`. Die neue `client_status`-Tabelle existiert in dieser DB nicht → `query_as!` schlägt fehl. **Lösung:** Nicht-Makro-Form `sqlx::query_as::<_, T>()` mit `#[derive(sqlx::FromRow)]` verwenden — keine Compile-Zeit-Verifizierung nötig.

### 3. `id` wird in `update_pk()` gemoved
Im `RegisterPk`-Handler wird `id` in `self.pm.update_pk(id, ...)` gemoved. Der Hook danach kann `id` nicht mehr verwenden. **Lösung:** `let peer_id_for_hook = id.clone()` vor dem `if changed`-Block anlegen.

### 4. Neue SQLite-Spalten erfordern manuelles ALTER TABLE
`ClientStatusStore::init_schema()` verwendet `CREATE TABLE IF NOT EXISTS` — bestehende Tabellen werden nicht geändert. Neue Spalten (`firma`, `pc_name` etc.) müssen manuell per `sqlite3 ... "ALTER TABLE client_status ADD COLUMN ..."` hinzugefügt werden.

### 5. MySQL Latin-1 → SQLite UTF-8 Encoding-Problem
MySQL-Daten (Umlauts: `ö`, `ü`, `ä`) werden als Latin-1-Bytes übertragen wenn der MySQL-Client keine explizite Charset-Konvertierung macht. SQLite speichert Bytes as-is. Rust's sqlx schlägt beim Lesen mit `ColumnDecode { Utf8Error }` fehl. **Lösung:** Python-Migration mit `try utf-8, fallback latin-1` vor dem ersten produktiven Einsatz.

### 6. MySQL war unsicher konfiguriert (`--skip-grant-tables`, `--skip-networking`)
Die externe MySQL-Instanz (`domains.basic4web.com`) lief mit `--skip-grant-tables` (kein Passwortschutz) und `--skip-networking` (kein TCP). Beides musste entfernt und MySQL neu gestartet werden. Port 3306 ist nur für die öffentliche IP dieses Servers freigegeben.

### 7. MySQL-Credentials nie im Script
Credentials in Shell-Skripten sind via `ps aux` für alle Benutzer sichtbar. **Immer** `/root/.my.cnf` (chmod 600) verwenden und im Script `--defaults-file=/root/.my.cnf` übergeben.

### 8. GLIBC_2.39-Fehler im Error-Log sind kosmetisch
Die Einträge in `signalserver.error` von früheren Binary-Versionen die GLIBC_2.39 benötigten, akkumulieren sich. Der aktuelle selbst kompilierte Binary läuft stabil auf Debian 12 (GLIBC 2.36). Die Fehler stammen aus `Restart=always`-Versuchen mit alten Binaries.

### 9. `systemctl stop` vor `cp` ist zwingend
Wenn das Binary läuft und kopiert wird während es geöffnet ist, startet der Service nach dem Neustart ggf. noch mit dem alten Binary (Kernel hält den alten Inode). Immer: **stop → cp → start**.

### 10. One-Shot-Cronjob besser als Systemd-While-Loop
Der ursprüngliche Monitor lief als `while true; sleep 60` in einem Systemd-Service. Nachteil: bei Crash bleibt er stehen bis systemd neu startet. **Besser:** einmaliger Script-Aufruf per Cronjob — jeder Lauf ist unabhängig, Fehler im Log isoliert.

---

## Go HTTP Server (Dateiserver)

**Pfad:** `/opt/gohttp/`  
**Port:** `8000` (HTTP)  
**Authentifizierung:** HTTP Basic Auth  
**Credentials:** gespeichert in `/etc/systemd/system/gohttpserver.service`  
**Logs:** `/var/log/gohttp/gohttpserver.log`

| Datei | Beschreibung |
|-------|-------------|
| `WindowsAgentAIOInstall.ps1` | PowerShell-Installationsskript für Windows-Clients |
| `linuxclientinstall.sh` | Bash-Installationsskript für Linux-Clients |

**Zugriff:** `http://192.168.0.238:8000`

---

## Verzeichnisstruktur (Übersicht)

```
/opt/rustdesk/              # RustDesk Server-Binaries, DBs, Scripts
/opt/gohttp/                # Go HTTP Server & Client-Installationsskripte
/usr/local/src/rustdesk-server/  # Quellcode (modifizierter Fork)
/var/log/rustdesk/          # Logs: signalserver.log, relayserver.log
/var/log/gohttp/            # Logs: gohttpserver.log
/var/log/rustdesk_monitor.log    # MySQL-Sync-Log
/root/.my.cnf               # MySQL-Credentials (chmod 600)
/root/install.sh            # Original-Installationsskript
```

---

## Systemd-Dienste verwalten

```bash
# Status prüfen
systemctl status rustdesksignal rustdeskrelay gohttpserver

# Neustart
systemctl restart rustdesksignal
systemctl restart rustdeskrelay

# Logs live verfolgen
tail -f /var/log/rustdesk/signalserver.log
tail -f /var/log/rustdesk_monitor.log

# Cronjob prüfen
crontab -l
```

---

## Installierte Software (relevant)

| Paket | Version |
|-------|---------|
| Debian | 12 (Bookworm) |
| Rust + Cargo | 1.86.0 |
| OpenSSH Server | 9.2p1 |
| Python 3 | 3.11.2 |
| SQLite3 | 3.40.1 |
| MariaDB Client | — |
| Git | 2.39.5 |
| curl / wget / jq | — |
| iptables | 1.8.9 |
| Postfix | (loopback only) |
