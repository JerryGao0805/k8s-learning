// notes-api：示例应用的后端。
//   - 笔记存在 Postgres（/api/notes）
//   - 点击计数存在 Redis（/api/hits）
//   - 健康检查（/healthz、/readyz）给 K8s 探针用
//   - Prometheus 指标（/metrics）给监控用
//
// 所有配置都来自环境变量，在 K8s 里由 ConfigMap / Secret 注入。
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

// version 在构建镜像时用 -ldflags "-X main.version=0.1.0" 写进来；本地 go run 时是 "dev"。
var version = "dev"

// 启动时连数据库最多重试这么久。要比 Deployment 里 startupProbe 给的时间（150 秒）短，
// 这样连不上时是程序自己带着清楚的日志退出，而不是被 kubelet 杀掉。
const dbRetryWindow = 90 * time.Second

func main() {
	// 日志：JSON 格式写到 stdout。容器里只管往 stdout 写，收集交给 K8s / Loki。
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))

	if err := run(); err != nil {
		slog.Error("exiting", "error", err)
		os.Exit(1)
	}
}

func run() error {
	// 收到 SIGTERM（K8s 删除 Pod 时发送）或 Ctrl+C 时，ctx 会被取消。
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	// 在 K8s 里 hostname 就是 Pod 名，用来展示"这次请求是哪个 Pod 回答的"。
	hostname, _ := os.Hostname()

	db, err := connectPostgres(ctx)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return nil // 还没连上数据库就收到了退出信号，正常退出
		}
		return err
	}
	defer db.Close()

	// Redis 不在启动时强制连接：连不上只影响 /api/hits 和 /readyz，不影响进程启动。
	redis.SetLogger(redisLogger{})
	rdb := redis.NewClient(&redis.Options{Addr: getenv("REDIS_ADDR", "redis:6379")})
	defer rdb.Close()

	a := &app{db: db, rdb: rdb, hostname: hostname}
	srv := &http.Server{
		Addr:              ":" + getenv("PORT", "8080"),
		Handler:           withObservability(a.routes()),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		slog.Info("http server listening", "addr", srv.Addr, "version", version, "pod", hostname)
		errCh <- srv.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		return fmt.Errorf("http server: %w", err) // 比如端口被占用
	case <-ctx.Done():
	}
	stop() // 恢复默认信号处理：再按一次 Ctrl+C 就立即退出

	// 优雅退出：不再接受新连接，已在处理的请求最多再给 10 秒完成。
	slog.Info("shutdown signal received, draining", "timeout", "10s")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	slog.Info("shutdown complete")
	return nil
}

// connectPostgres 连接 Postgres 并建表，失败就按指数退避重试。
// 在 K8s 里 api 经常比 postgres 先启动好，所以刚启动时连不上是正常的。
// 每次失败都打一行日志；超过 dbRetryWindow 仍失败就返回错误让进程退出，
// K8s 会重启容器，kubectl get pods 里能看到 RESTARTS 增加，问题不会被默默藏起来。
func connectPostgres(ctx context.Context) (*pgxpool.Pool, error) {
	// 连接串留空：pgx 会像 psql 一样读取 PGHOST / PGPORT / PGUSER / PGPASSWORD / PGDATABASE。
	// pgxpool.New 只解析配置、创建连接池，并不会真正去连。
	pool, err := pgxpool.New(ctx, "")
	if err != nil {
		return nil, fmt.Errorf("postgres config: %w", err)
	}
	cfg := pool.Config().ConnConfig

	deadline := time.Now().Add(dbRetryWindow)
	backoff := time.Second
	for attempt := 1; ; attempt++ {
		err := initSchema(ctx, pool)
		if err == nil {
			slog.Info("postgres ready", "host", cfg.Host, "database", cfg.Database, "attempt", attempt)
			return pool, nil
		}
		if time.Now().After(deadline) {
			pool.Close()
			return nil, fmt.Errorf("postgres still unavailable after %d attempts: %w", attempt, err)
		}
		slog.Warn("postgres not ready, will retry",
			"host", cfg.Host, "attempt", attempt, "retry_in", backoff.String(), "error", err)

		select {
		case <-ctx.Done():
			pool.Close()
			return nil, ctx.Err()
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, 15*time.Second) // 1s, 2s, 4s, 8s, 15s, 15s ...
	}
}

// initSchema 建表（已存在就跳过）。这里同时充当"能不能连上数据库"的检查。
func initSchema(ctx context.Context, pool *pgxpool.Pool) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) // Commit 成功后再 Rollback 是空操作

	// 两个 api 副本会同时启动、同时建表。并发执行 CREATE TABLE IF NOT EXISTS 偶尔会报唯一约束冲突，
	// 所以先拿一把事务级的 advisory lock，让它们排队执行（事务结束自动释放）。
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(4242)`); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `CREATE TABLE IF NOT EXISTS notes (
		id         bigserial PRIMARY KEY,
		text       text NOT NULL,
		created_at timestamptz NOT NULL DEFAULT now()
	)`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// redisLogger 让 go-redis 库自己的日志也走 slog 输出 JSON（它默认往 stderr 打纯文本）。
type redisLogger struct{}

func (redisLogger) Printf(_ context.Context, format string, v ...any) {
	slog.Warn("go-redis", "detail", fmt.Sprintf(format, v...))
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
