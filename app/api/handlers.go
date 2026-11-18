package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/redis/go-redis/v9"
)

type app struct {
	db       *pgxpool.Pool
	rdb      *redis.Client
	hostname string
}

type note struct {
	ID        int64     `json:"id"`
	Text      string    `json:"text"`
	CreatedAt time.Time `json:"created_at"`
}

// routes 注册所有接口。Go 1.22+ 的路由写法："方法 路径"。
// 这里的路由模板（比如 "/api/notes"）也会被用作指标的 path 标签。
func (a *app) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/notes", a.listNotes)
	mux.HandleFunc("POST /api/notes", a.createNote)
	mux.HandleFunc("GET /api/hits", a.hits)
	mux.HandleFunc("GET /api/info", a.info)
	mux.HandleFunc("GET /healthz", healthz)
	mux.HandleFunc("GET /readyz", a.readyz)
	mux.Handle("GET /metrics", promhttp.Handler()) // 默认 registry：自带 Go 运行时和进程指标
	return mux
}

// GET /api/notes：最新的 50 条笔记
func (a *app) listNotes(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()

	rows, err := a.db.Query(ctx, `SELECT id, text, created_at FROM notes ORDER BY id DESC LIMIT 50`)
	if err != nil {
		serverError(w, r, err)
		return
	}
	notes, err := pgx.CollectRows(rows, pgx.RowToStructByPos[note])
	if err != nil {
		serverError(w, r, err)
		return
	}
	if notes == nil {
		notes = []note{} // 没有数据时返回 []，而不是 null
	}
	writeJSON(w, http.StatusOK, notes)
}

// POST /api/notes  {"text": "..."}：新建一条笔记，返回 201 和新笔记
func (a *app) createNote(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Text string `json:"text"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 8<<10) // 请求体最多 8KB
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, `invalid JSON body, expected {"text": "..."}`)
		return
	}
	text := strings.TrimSpace(req.Text)
	// 按字符（rune）计数，一个汉字算 1 个字符
	if n := utf8.RuneCountInString(text); n < 1 || n > 500 {
		writeError(w, http.StatusBadRequest, "text must be 1-500 characters")
		return
	}
	if strings.ContainsRune(text, 0) { // Postgres 的 text 类型不能存 \u0000
		writeError(w, http.StatusBadRequest, "text must not contain NUL characters")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	var n note
	err := a.db.QueryRow(ctx,
		`INSERT INTO notes (text) VALUES ($1) RETURNING id, text, created_at`, text,
	).Scan(&n.ID, &n.Text, &n.CreatedAt)
	if err != nil {
		serverError(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, n)
}

// GET /api/hits：计数器 +1，并告诉你是哪个 Pod 处理的（多刷几次能看到负载均衡）
func (a *app) hits(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	n, err := a.rdb.Incr(ctx, "hits").Result()
	if err != nil {
		serverError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"hits": n, "pod": a.hostname})
}

// GET /api/info：Pod 名和版本号。滚动更新时能看到版本一点点切换。
func (a *app) info(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"pod": a.hostname, "version": version})
}

// GET /healthz：存活探针（liveness）。只要进程还能响应 HTTP 就返回 200。
// 故意不检查数据库：数据库挂了，重启 api 也没用，反而会让所有副本一起重启。
func healthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Write([]byte("ok\n"))
}

// GET /readyz：就绪探针（readiness）。Postgres 和 Redis 都能在 1 秒内 ping 通才返回 200，
// 否则返回 503，K8s 会把这个 Pod 从 Service 的后端列表里摘掉（但不会重启它）。
func (a *app) readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), time.Second)
	defer cancel()

	// 两个 ping 并行做，共用这 1 秒
	var pgErr, redisErr error
	var wg sync.WaitGroup
	wg.Go(func() { pgErr = a.db.Ping(ctx) })
	wg.Go(func() { redisErr = a.rdb.Ping(ctx).Err() })
	wg.Wait()

	status := map[string]string{"postgres": "ok", "redis": "ok"}
	code := http.StatusOK
	if pgErr != nil {
		status["postgres"] = pgErr.Error()
		code = http.StatusServiceUnavailable
	}
	if redisErr != nil {
		status["redis"] = redisErr.Error()
		code = http.StatusServiceUnavailable
	}
	if code != http.StatusOK {
		slog.Warn("not ready", "postgres", status["postgres"], "redis", status["redis"])
	}
	writeJSON(w, code, status)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// serverError：详细错误只写日志，返回给客户端的只有笼统的提示。
func serverError(w http.ResponseWriter, r *http.Request, err error) {
	slog.Error("request failed", "method", r.Method, "path", r.URL.Path, "error", err)
	writeError(w, http.StatusInternalServerError, "internal error")
}
