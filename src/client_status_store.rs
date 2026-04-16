use hbb_common::log;
use sqlx::{sqlite::SqliteConnectOptions, Pool, Sqlite, SqlitePool};
use std::str::FromStr;

#[derive(Clone)]
pub struct ClientStatusStore {
    pool: Pool<Sqlite>,
}

#[derive(serde::Serialize, sqlx::FromRow)]
pub struct ClientStatusRow {
    pub peer_id: String,
    pub last_seen: i64,
    pub last_ip: Option<String>,
    pub created_at: i64,
    pub firma: Option<String>,
    pub pc_name: Option<String>,
    pub notizen: Option<String>,
    pub kennwort: Option<String>,
}

impl ClientStatusStore {
    pub async fn new(path: &str) -> Result<Self, sqlx::Error> {
        let options = SqliteConnectOptions::from_str(&format!("sqlite://{}", path))?
            .create_if_missing(true);
        let pool = SqlitePool::connect_with(options).await?;
        let store = Self { pool };
        store.init_schema().await?;
        log::info!("ClientStatusStore initialized: {}", path);
        Ok(store)
    }

    async fn init_schema(&self) -> Result<(), sqlx::Error> {
        sqlx::query("PRAGMA journal_mode = WAL;")
            .execute(&self.pool)
            .await?;
        sqlx::query("PRAGMA synchronous = NORMAL;")
            .execute(&self.pool)
            .await?;
        sqlx::query("PRAGMA busy_timeout = 5000;")
            .execute(&self.pool)
            .await?;
        sqlx::query(
            r#"CREATE TABLE IF NOT EXISTS client_status (
                peer_id    TEXT PRIMARY KEY,
                last_seen  INTEGER NOT NULL,
                last_ip    TEXT,
                created_at INTEGER NOT NULL
            )"#,
        )
        .execute(&self.pool)
        .await?;
        sqlx::query(
            "CREATE INDEX IF NOT EXISTS idx_client_status_last_seen ON client_status(last_seen)",
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Insert new client or update existing one.
    /// created_at is only set on INSERT, never overwritten on UPDATE.
    pub async fn upsert_client_seen(
        &self,
        peer_id: &str,
        last_ip: Option<&str>,
        timestamp_utc: i64,
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            r#"INSERT INTO client_status (peer_id, last_seen, last_ip, created_at)
               VALUES (?1, ?2, ?3, ?2)
               ON CONFLICT(peer_id) DO UPDATE SET
                   last_seen = excluded.last_seen,
                   last_ip   = excluded.last_ip"#,
        )
        .bind(peer_id)
        .bind(timestamp_utc)
        .bind(last_ip)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Return all clients ordered by last_seen descending.
    pub async fn get_all_clients(&self) -> Result<Vec<ClientStatusRow>, sqlx::Error> {
        let rows = sqlx::query_as::<_, ClientStatusRow>(
            "SELECT peer_id, last_seen, last_ip, created_at, firma, pc_name, notizen, kennwort
             FROM client_status ORDER BY last_seen DESC",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// Look up a single client by peer_id.
    pub async fn get_client(&self, peer_id: &str) -> Result<Option<ClientStatusRow>, sqlx::Error> {
        let row = sqlx::query_as::<_, ClientStatusRow>(
            "SELECT peer_id, last_seen, last_ip, created_at, firma, pc_name, notizen, kennwort
             FROM client_status WHERE peer_id = ?",
        )
        .bind(peer_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }
}
