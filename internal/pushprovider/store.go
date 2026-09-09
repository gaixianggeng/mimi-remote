package pushprovider

import (
	"context"
	"database/sql"
	"time"

	_ "modernc.org/sqlite"
)

// RevocationStore 是 Provider 唯一的持久状态：被撤销的 Ticket ID 及其原到期时间。
// 不保存 Device Token、Payload、action_id 或任何会话信息；记录只保留到 Ticket
// 自然到期为止，之后由清理任务删除。
type RevocationStore struct {
	db *sql.DB
}

func OpenRevocationStore(path string) (*RevocationStore, error) {
	db, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)")
	if err != nil {
		return nil, err
	}
	// 单文件、低并发；限制连接数避免 WAL 写锁竞争。
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS revoked_tickets (
		ticket_id TEXT PRIMARY KEY,
		expires_at INTEGER NOT NULL
	)`); err != nil {
		db.Close()
		return nil, err
	}
	if _, err := db.Exec(`CREATE INDEX IF NOT EXISTS revoked_tickets_expiry
		ON revoked_tickets (expires_at)`); err != nil {
		db.Close()
		return nil, err
	}
	return &RevocationStore{db: db}, nil
}

func (s *RevocationStore) Close() error { return s.db.Close() }

func (s *RevocationStore) Revoke(ctx context.Context, ticketID string, expiresAt time.Time) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO revoked_tickets (ticket_id, expires_at) VALUES (?, ?)
		 ON CONFLICT(ticket_id) DO UPDATE SET expires_at = excluded.expires_at`,
		ticketID, expiresAt.Unix())
	return err
}

func (s *RevocationStore) Revoked(ctx context.Context, ticketID string) (bool, error) {
	var count int
	err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(1) FROM revoked_tickets WHERE ticket_id = ?`, ticketID).Scan(&count)
	if err != nil {
		return false, err
	}
	return count > 0, nil
}

// Purge 删除已经自然到期的记录。到期后的 Ticket 本身就打不开，继续保留它的 ID
// 只会让 Provider 留存多余数据。
func (s *RevocationStore) Purge(ctx context.Context, now time.Time) (int64, error) {
	result, err := s.db.ExecContext(ctx,
		`DELETE FROM revoked_tickets WHERE expires_at <= ?`, now.Unix())
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (s *RevocationStore) Count(ctx context.Context) (int, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(1) FROM revoked_tickets`).Scan(&count)
	return count, err
}
