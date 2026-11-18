package main

import (
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// 两个自定义指标。promauto 会把它们注册到默认 registry，/metrics 里就能看到。
var (
	httpRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "HTTP 请求总数，按方法、路由、状态码分类。",
	}, []string{"method", "path", "status"})

	httpDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP 请求耗时（秒）。",
		Buckets: prometheus.DefBuckets, // 5ms ~ 10s
	}, []string{"method", "path"})
)

// 这些路径被探针 / Prometheus 每隔几秒请求一次，写进日志只会刷屏，所以不记日志（指标照样统计）。
var quietPaths = map[string]bool{"/healthz": true, "/readyz": true, "/metrics": true}

// statusRecorder 包一层 ResponseWriter，记下 handler 写出的状态码。
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// Unwrap 让 http.ResponseController 能拿到底层的 ResponseWriter。
func (s *statusRecorder) Unwrap() http.ResponseWriter { return s.ResponseWriter }

// withObservability 是一个中间件：每个请求结束后更新指标，并打一行 JSON 日志。
func withObservability(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		elapsed := time.Since(start)

		route := routeOf(r)
		httpRequests.WithLabelValues(r.Method, route, strconv.Itoa(rec.status)).Inc()
		httpDuration.WithLabelValues(r.Method, route).Observe(elapsed.Seconds())

		if quietPaths[route] {
			return
		}
		slog.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", rec.status,
			"duration_ms", float64(elapsed.Microseconds())/1000,
		)
	})
}

// routeOf 返回匹配到的路由模板（比如 "/api/notes"），而不是原始 URL。
// 指标标签必须用模板：如果用原始路径，/api/notes?x=1、/random-404-path 之类的值会无限增长，
// 撑爆 Prometheus（叫"高基数"问题）。没匹配到任何路由的请求统一记为 "unmatched"。
func routeOf(r *http.Request) string {
	if r.Pattern == "" { // ServeMux 匹配成功后会把模板写进 r.Pattern
		return "unmatched"
	}
	if _, path, ok := strings.Cut(r.Pattern, " "); ok { // "GET /api/notes" -> "/api/notes"
		return path
	}
	return r.Pattern
}
