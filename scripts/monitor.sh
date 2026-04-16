#!/bin/bash
# RustDesk → MySQL Sync
# Liest /api/clients, berechnet online/offline und aktualisiert rust_pcs.
# Nur UPDATE – kein INSERT (Stammdaten wie Firma/PC-Name werden manuell gepflegt).
# Wird per Cronjob aufgerufen (einmaliger Lauf, keine while-Schleife).

# --- Konfiguration ---
SERVER_URL="http://localhost:9000"
API_ENDPOINT="/api/clients"
LOG_FILE="/var/log/rustdesk_monitor.log"
ONLINE_THRESHOLD=30   # Sekunden – muss mit hbbs REG_TIMEOUT übereinstimmen

# Credentials in /root/.my.cnf (chmod 600) – nicht im Script

# --- Abhängigkeiten prüfen ---
for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Fehler: $cmd fehlt." >&2; exit 1; }
done

if command -v mysql >/dev/null 2>&1; then
    SQL_CLIENT="mysql"
elif command -v mariadb >/dev/null 2>&1; then
    SQL_CLIENT="mariadb"
else
    echo "Fehler: kein MySQL/MariaDB-Client gefunden." >&2
    exit 1
fi

# --- Hilfsfunktionen ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

execute_sql() {
    "$SQL_CLIENT" --defaults-file=/root/.my.cnf -e "$1" 2>/tmp/sql_error.log
    if [ $? -ne 0 ]; then
        log "SQL-Fehler: $(cat /tmp/sql_error.log)"
        return 1
    fi
}

mkdir -p "$(dirname "$LOG_FILE")"

# --- API abrufen ---
log "Abrufen: $SERVER_URL$API_ENDPOINT"
API_RESPONSE=$(curl -s --max-time 10 "$SERVER_URL$API_ENDPOINT")

if [ $? -ne 0 ] || [ -z "$API_RESPONSE" ]; then
    log "Fehler: API nicht erreichbar"
    exit 1
fi

echo "$API_RESPONSE" | jq . >/dev/null 2>&1 || { log "Fehler: ungültiges JSON"; exit 1; }

TOTAL=$(echo "$API_RESPONSE" | jq '. | length')
log "$TOTAL Clients aus API geladen"

NOW=$(date +%s)
updated_online=0
updated_offline=0
skipped=0

# --- Jeden bekannten Client in MySQL aktualisieren ---
echo "$API_RESPONSE" | jq -c '.[]' | while read -r client; do
    PEER_ID=$(echo "$client"  | jq -r '.peer_id')
    LAST_SEEN=$(echo "$client" | jq -r '.last_seen')

    # Online-Status berechnen
    AGE=$(( NOW - LAST_SEEN ))
    if [ "$AGE" -lt "$ONLINE_THRESHOLD" ]; then
        STATUS="online"
    else
        STATUS="offline"
    fi

    # Unix-Timestamp → MySQL DATETIME
    LAST_SEEN_DT=$(date -d "@${LAST_SEEN}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)

    PEER_ID_ESC=$(printf '%s' "$PEER_ID" | sed "s/'/\\\\'/g")

    # Nur UPDATE – Zeile muss in rust_pcs bereits existieren (Stammdaten manuell gepflegt)
    QUERY="UPDATE rust_pcs
           SET status = '${STATUS}', last_seen = '${LAST_SEEN_DT}'
           WHERE pc_id = '${PEER_ID_ESC}';"

    execute_sql "$QUERY"
done

# Zusammenfassung aus DB lesen
SUMMARY=$("$SQL_CLIENT" --defaults-file=/root/.my.cnf -sN \
    -e "SELECT
          SUM(status='online')  AS online,
          SUM(status='offline') AS offline
        FROM rust_pcs;" 2>/dev/null)
ONLINE_DB=$(echo "$SUMMARY" | awk '{print $1}')
OFFLINE_DB=$(echo "$SUMMARY" | awk '{print $2}')

log "Sync abgeschlossen – DB-Stand: ${ONLINE_DB} online, ${OFFLINE_DB} offline"
