package main

import (
	"context"
	"crypto/tls"
	"encoding/csv"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"math"
	"math/rand"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	valkey "github.com/valkey-io/valkey-go"
)

type sizeChoice struct {
	size       int
	cumulative int
}

type config struct {
	Endpoints    []string
	Duration     time.Duration
	Workers      int
	RPS          int
	Keyspace     uint64
	Preload      uint64
	PreloadOnly  bool
	UpdatePct    int
	InsertPct    int
	DeletePct    int
	HotPct       int
	HotKeys      uint64
	ValueSizes   string
	TTLSeconds   int
	Timeout      time.Duration
	RetryPolicy  string
	MaxAttempts  int
	RetryBase    time.Duration
	RetryCap     time.Duration
	SampleEvery  uint64
	Output       string
	Seed         int64
	KeyPrefix    string
	ClientName   string
	RefreshEvery time.Duration
}

type counters struct {
	logical       atomic.Uint64
	attempts      atomic.Uint64
	successes     atomic.Uint64
	errors        atomic.Uint64
	dials         atomic.Uint64
	droppedTokens atomic.Uint64
	inserts       atomic.Uint64
	updates       atomic.Uint64
	deletes       atomic.Uint64
}

type secondReport struct {
	second     int64
	logical    uint64
	attempts   uint64
	successes  uint64
	errors     uint64
	inserts    uint64
	updates    uint64
	deletes    uint64
	dialTotal  uint64
	latencyMic []int64
}

type combinedSecond struct {
	reports    int
	logical    uint64
	attempts   uint64
	successes  uint64
	errors     uint64
	inserts    uint64
	updates    uint64
	deletes    uint64
	dialTotal  uint64
	latencyMic []int64
}

type errorRecorder struct {
	mu     sync.Mutex
	counts map[string]uint64
}

func (e *errorRecorder) add(err error) {
	key := classifyError(err)
	e.mu.Lock()
	e.counts[key]++
	e.mu.Unlock()
}

func (e *errorRecorder) snapshot() map[string]uint64 {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := make(map[string]uint64, len(e.counts))
	for k, v := range e.counts {
		out[k] = v
	}
	return out
}

func classifyError(err error) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return "deadline_exceeded"
	}
	if errors.Is(err, context.Canceled) {
		return "canceled"
	}
	s := strings.ToUpper(err.Error())
	for _, class := range []string{"MOVED", "ASK", "TRYAGAIN", "CLUSTERDOWN", "READONLY", "LOADING"} {
		if strings.Contains(s, class) {
			return strings.ToLower(class)
		}
	}
	if strings.Contains(s, "CONNECTION") || strings.Contains(s, "BROKEN PIPE") || strings.Contains(s, "EOF") {
		return "connection"
	}
	return "other"
}

func main() {
	cfg := parseFlags()
	if err := validate(cfg); err != nil {
		fmt.Fprintln(os.Stderr, "configuration error:", err)
		os.Exit(2)
	}
	sizes, err := parseSizes(cfg.ValueSizes)
	if err != nil {
		fmt.Fprintln(os.Stderr, "value-size error:", err)
		os.Exit(2)
	}
	if err := os.MkdirAll(cfg.Output, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "create output directory:", err)
		os.Exit(1)
	}

	var totals counters
	dialer := net.Dialer{Timeout: 2 * time.Second, KeepAlive: time.Second}
	client, err := valkey.NewClient(valkey.ClientOption{
		InitAddress: cfg.Endpoints,
		ShuffleInit: true,
		ClientName:  cfg.ClientName,
		DisableCache: true,
		AlwaysPipelining: true,
		Dialer: dialer,
		DialCtxFn: func(ctx context.Context, addr string, d *net.Dialer, tlsConfig *tls.Config) (net.Conn, error) {
			totals.dials.Add(1)
			if tlsConfig != nil {
				td := tls.Dialer{NetDialer: d, Config: tlsConfig}
				return td.DialContext(ctx, "tcp", addr)
			}
			return d.DialContext(ctx, "tcp", addr)
		},
		ClusterOption: valkey.ClusterOption{
			ShardsRefreshInterval: cfg.RefreshEvery,
		},
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "create client:", err)
		os.Exit(1)
	}
	defer client.Close()

	if cfg.Preload > 0 {
		fmt.Fprintf(os.Stderr, "preloading %d keys with %d workers\n", cfg.Preload, cfg.Workers)
		if err := preload(client, cfg, sizes); err != nil {
			fmt.Fprintln(os.Stderr, "preload failed:", err)
			os.Exit(1)
		}
		fmt.Fprintln(os.Stderr, "preload complete")
	}
	if cfg.PreloadOnly {
		return
	}

	started := time.Now().UTC()
	ctx, cancel := context.WithTimeout(context.Background(), cfg.Duration)
	defer cancel()
	tokens := make(chan time.Time, tokenBuffer(cfg))
	reports := make(chan secondReport, cfg.Workers*4)
	var inserted atomic.Uint64
	errs := errorRecorder{counts: make(map[string]uint64)}

	if cfg.RPS > 0 {
		go produceTokens(ctx, cfg.RPS, tokens, &totals)
	}

	var wg sync.WaitGroup
	for i := 0; i < cfg.Workers; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			runWorker(ctx, workerID, client, cfg, sizes, tokens, &inserted, &totals, &errs, reports)
		}(i)
	}
	go func() {
		wg.Wait()
		close(reports)
	}()

	series := collectReports(reports)
	ended := time.Now().UTC()
	if err := writeSeries(filepath.Join(cfg.Output, "workload.csv"), started, series); err != nil {
		fmt.Fprintln(os.Stderr, "write workload series:", err)
		os.Exit(1)
	}
	if err := writeSummary(filepath.Join(cfg.Output, "summary.json"), cfg, started, ended, &totals, errs.snapshot()); err != nil {
		fmt.Fprintln(os.Stderr, "write summary:", err)
		os.Exit(1)
	}
	fmt.Printf("logical=%d attempts=%d success=%d errors=%d dials=%d dropped_tokens=%d output=%s\n",
		totals.logical.Load(), totals.attempts.Load(), totals.successes.Load(), totals.errors.Load(),
		totals.dials.Load(), totals.droppedTokens.Load(), cfg.Output)
}

func parseFlags() config {
	var cfg config
	var endpoints string
	flag.StringVar(&endpoints, "endpoints", "valkey-1:6379,valkey-2:6379,valkey-3:6379", "comma-separated cluster seed endpoints")
	flag.DurationVar(&cfg.Duration, "duration", 3*time.Minute, "timed workload duration")
	flag.IntVar(&cfg.Workers, "workers", 32, "concurrent workers")
	flag.IntVar(&cfg.RPS, "rps", 30000, "total offered logical operations/s; 0 means closed loop")
	flag.Uint64Var(&cfg.Keyspace, "keyspace", 250000, "existing entity IDs used for updates/deletes")
	flag.Uint64Var(&cfg.Preload, "preload", 0, "number of keys to load before the timed phase")
	flag.BoolVar(&cfg.PreloadOnly, "preload-only", false, "exit after preload")
	flag.IntVar(&cfg.UpdatePct, "update-pct", 85, "percentage of logical operations that update existing entities")
	flag.IntVar(&cfg.InsertPct, "insert-pct", 10, "percentage of logical operations that insert new entities")
	flag.IntVar(&cfg.DeletePct, "delete-pct", 5, "percentage of logical operations that delete entities")
	flag.IntVar(&cfg.HotPct, "hot-pct", 0, "percentage of operations targeting the hot-key subset")
	flag.Uint64Var(&cfg.HotKeys, "hot-keys", 8, "number of hot hash tags/keys")
	flag.StringVar(&cfg.ValueSizes, "value-sizes", "256:70,1024:25,4096:5", "weighted byte sizes as size:weight pairs")
	flag.IntVar(&cfg.TTLSeconds, "ttl-seconds", 0, "optional TTL for SET operations; 0 disables TTL")
	flag.DurationVar(&cfg.Timeout, "timeout", 250*time.Millisecond, "timeout for each physical attempt")
	flag.StringVar(&cfg.RetryPolicy, "retry-policy", "jitter", "none, immediate, or jitter")
	flag.IntVar(&cfg.MaxAttempts, "max-attempts", 3, "maximum physical attempts per logical operation")
	flag.DurationVar(&cfg.RetryBase, "retry-base", 10*time.Millisecond, "base delay for jittered exponential retry")
	flag.DurationVar(&cfg.RetryCap, "retry-cap", 250*time.Millisecond, "maximum retry delay")
	flag.Uint64Var(&cfg.SampleEvery, "sample-every", 10, "record one latency sample every N logical operations")
	flag.StringVar(&cfg.Output, "output", "/results/manual", "output directory")
	flag.Int64Var(&cfg.Seed, "seed", 20261006, "deterministic random seed")
	flag.StringVar(&cfg.KeyPrefix, "key-prefix", "cdc", "key prefix")
	flag.StringVar(&cfg.ClientName, "client-name", "valkey-resilience-loadgen", "Valkey client name")
	flag.DurationVar(&cfg.RefreshEvery, "topology-refresh", 2*time.Second, "periodic cluster topology refresh")
	flag.Parse()
	for _, endpoint := range strings.Split(endpoints, ",") {
		if s := strings.TrimSpace(endpoint); s != "" {
			cfg.Endpoints = append(cfg.Endpoints, s)
		}
	}
	return cfg
}

func validate(cfg config) error {
	if len(cfg.Endpoints) == 0 {
		return errors.New("at least one endpoint is required")
	}
	if cfg.Workers < 1 || cfg.Duration <= 0 || cfg.Keyspace < 1 {
		return errors.New("workers, duration, and keyspace must be positive")
	}
	if cfg.UpdatePct+cfg.InsertPct+cfg.DeletePct != 100 {
		return errors.New("update-pct + insert-pct + delete-pct must equal 100")
	}
	if cfg.HotPct < 0 || cfg.HotPct > 100 || (cfg.HotPct > 0 && cfg.HotKeys == 0) {
		return errors.New("hot-pct must be 0..100 and hot-keys must be positive when enabled")
	}
	if cfg.MaxAttempts < 1 || cfg.SampleEvery < 1 {
		return errors.New("max-attempts and sample-every must be positive")
	}
	if cfg.RetryPolicy != "none" && cfg.RetryPolicy != "immediate" && cfg.RetryPolicy != "jitter" {
		return errors.New("retry-policy must be none, immediate, or jitter")
	}
	return nil
}

func parseSizes(spec string) ([]sizeChoice, error) {
	var out []sizeChoice
	total := 0
	for _, part := range strings.Split(spec, ",") {
		fields := strings.Split(strings.TrimSpace(part), ":")
		if len(fields) != 2 {
			return nil, fmt.Errorf("invalid pair %q", part)
		}
		size, err1 := strconv.Atoi(fields[0])
		weight, err2 := strconv.Atoi(fields[1])
		if err1 != nil || err2 != nil || size < 1 || weight < 1 {
			return nil, fmt.Errorf("invalid pair %q", part)
		}
		total += weight
		out = append(out, sizeChoice{size: size, cumulative: total})
	}
	if total != 100 {
		return nil, fmt.Errorf("weights must total 100, got %d", total)
	}
	return out, nil
}

func preload(client valkey.Client, cfg config, sizes []sizeChoice) error {
	var next atomic.Uint64
	var failed atomic.Uint64
	var wg sync.WaitGroup
	for worker := 0; worker < cfg.Workers; worker++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			rng := rand.New(rand.NewSource(cfg.Seed + int64(id)*7919))
			for {
				keyID := next.Add(1)
				if keyID > cfg.Preload {
					return
				}
				key := regularKey(cfg.KeyPrefix, keyID)
				value := payload(pickSize(rng, sizes))
				ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				err := client.Do(ctx, buildSet(client, key, value, cfg.TTLSeconds)).Error()
				cancel()
				if err != nil {
					failed.Add(1)
				}
			}
		}(worker)
	}
	wg.Wait()
	if n := failed.Load(); n > 0 {
		return fmt.Errorf("%d preload operations failed", n)
	}
	return nil
}

func tokenBuffer(cfg config) int {
	if cfg.RPS <= 0 {
		return cfg.Workers
	}
	return min(max(cfg.RPS*2, cfg.Workers*4), 1_000_000)
}

func produceTokens(ctx context.Context, rps int, tokens chan<- time.Time, totals *counters) {
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	budget := float64(rps) / 100.0
	carry := 0.0
	for {
		select {
		case <-ctx.Done():
			return
		case tick := <-ticker.C:
			carry += budget
			n := int(carry)
			carry -= float64(n)
			for i := 0; i < n; i++ {
				select {
				case tokens <- tick:
				default:
					totals.droppedTokens.Add(1)
				}
			}
		}
	}
}

func runWorker(ctx context.Context, workerID int, client valkey.Client, cfg config, sizes []sizeChoice,
	tokens <-chan time.Time, inserted *atomic.Uint64, totals *counters, errs *errorRecorder, reports chan<- secondReport) {
	rng := rand.New(rand.NewSource(cfg.Seed + int64(workerID+1)*104729))
	current := secondReport{second: time.Now().Unix()}
	workerOps := uint64(0)
	flush := func() {
		current.dialTotal = totals.dials.Load()
		reports <- current
		current = secondReport{second: time.Now().Unix()}
	}
	defer flush()

	for {
		var scheduled time.Time
		if cfg.RPS > 0 {
			select {
			case <-ctx.Done():
				return
			case scheduled = <-tokens:
			}
		} else {
			select {
			case <-ctx.Done():
				return
			default:
				scheduled = time.Now()
			}
		}

		nowSecond := time.Now().Unix()
		if nowSecond != current.second {
			flush()
			current.second = nowSecond
		}
		workerOps++
		current.logical++
		totals.logical.Add(1)

		opRoll := rng.Intn(100)
		op := "update"
		var keyID uint64
		switch {
		case opRoll < cfg.UpdatePct:
			keyID = chooseExistingID(rng, cfg.Keyspace+inserted.Load())
			current.updates++
			totals.updates.Add(1)
		case opRoll < cfg.UpdatePct+cfg.InsertPct:
			keyID = cfg.Keyspace + inserted.Add(1)
			op = "insert"
			current.inserts++
			totals.inserts.Add(1)
		default:
			keyID = chooseExistingID(rng, cfg.Keyspace+inserted.Load())
			op = "delete"
			current.deletes++
			totals.deletes.Add(1)
		}
		key := chooseKey(rng, cfg, keyID)
		value := payload(pickSize(rng, sizes))
		attempts, err := executeLogical(ctx, client, cfg, rng, op, key, value)
		current.attempts += uint64(attempts)
		totals.attempts.Add(uint64(attempts))
		if err == nil {
			current.successes++
			totals.successes.Add(1)
		} else {
			current.errors++
			totals.errors.Add(1)
			errs.add(err)
		}
		if workerOps%cfg.SampleEvery == 0 {
			micros := time.Since(scheduled).Microseconds()
			if micros < 0 {
				micros = 0
			}
			current.latencyMic = append(current.latencyMic, micros)
		}
	}
}

func executeLogical(parent context.Context, client valkey.Client, cfg config, rng *rand.Rand, op, key, value string) (int, error) {
	var last error
	for attempt := 1; attempt <= cfg.MaxAttempts; attempt++ {
		ctx, cancel := context.WithTimeout(parent, cfg.Timeout)
		var command valkey.Completed
		if op == "delete" {
			command = client.B().Del().Key(key).Build()
		} else {
			command = buildSet(client, key, value, cfg.TTLSeconds)
		}
		last = client.Do(ctx, command).Error()
		cancel()
		if last == nil {
			return attempt, nil
		}
		if cfg.RetryPolicy == "none" || attempt == cfg.MaxAttempts {
			return attempt, last
		}
		delay := retryDelay(cfg, rng, attempt)
		if delay > 0 {
			select {
			case <-parent.Done():
				return attempt, parent.Err()
			case <-time.After(delay):
			}
		}
	}
	return cfg.MaxAttempts, last
}

func retryDelay(cfg config, rng *rand.Rand, attempt int) time.Duration {
	if cfg.RetryPolicy == "immediate" {
		return 0
	}
	maxDelay := float64(cfg.RetryBase) * math.Pow(2, float64(attempt-1))
	if maxDelay > float64(cfg.RetryCap) {
		maxDelay = float64(cfg.RetryCap)
	}
	if maxDelay <= 1 {
		return 0
	}
	return time.Duration(rng.Int63n(int64(maxDelay)))
}

func buildSet(client valkey.Client, key, value string, ttl int) valkey.Completed {
	b := client.B().Arbitrary("SET").Keys(key)
	if ttl > 0 {
		return b.Args(value, "EX", strconv.Itoa(ttl)).Build()
	}
	return b.Args(value).Build()
}

func chooseExistingID(rng *rand.Rand, high uint64) uint64 {
	if high < 1 {
		return 1
	}
	return uint64(rng.Int63n(int64(high))) + 1
}

func chooseKey(rng *rand.Rand, cfg config, id uint64) string {
	if cfg.HotPct > 0 && rng.Intn(100) < cfg.HotPct {
		hot := uint64(rng.Int63n(int64(cfg.HotKeys)))
		return fmt.Sprintf("%s:{hot-%d}:%d", cfg.KeyPrefix, hot, id)
	}
	return regularKey(cfg.KeyPrefix, id)
}

func regularKey(prefix string, id uint64) string {
	return fmt.Sprintf("%s:{entity-%d}:state", prefix, id)
}

func pickSize(rng *rand.Rand, choices []sizeChoice) int {
	x := rng.Intn(100) + 1
	for _, choice := range choices {
		if x <= choice.cumulative {
			return choice.size
		}
	}
	return choices[len(choices)-1].size
}

var payloadCache sync.Map

func payload(size int) string {
	if cached, ok := payloadCache.Load(size); ok {
		return cached.(string)
	}
	base := `{"source":"cdc","operation":"update","payload":"`
	end := `"}`
	if size <= len(base)+len(end) {
		v := strings.Repeat("x", size)
		payloadCache.Store(size, v)
		return v
	}
	v := base + strings.Repeat("x", size-len(base)-len(end)) + end
	payloadCache.Store(size, v)
	return v
}

func collectReports(ch <-chan secondReport) map[int64]*combinedSecond {
	series := make(map[int64]*combinedSecond)
	for report := range ch {
		item := series[report.second]
		if item == nil {
			item = &combinedSecond{}
			series[report.second] = item
		}
		item.reports++
		item.logical += report.logical
		item.attempts += report.attempts
		item.successes += report.successes
		item.errors += report.errors
		item.inserts += report.inserts
		item.updates += report.updates
		item.deletes += report.deletes
		item.dialTotal = max(item.dialTotal, report.dialTotal)
		item.latencyMic = append(item.latencyMic, report.latencyMic...)
	}
	return series
}

func writeSeries(path string, started time.Time, series map[int64]*combinedSecond) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	w := csv.NewWriter(f)
	defer w.Flush()
	header := []string{"timestamp", "elapsed_s", "logical_ops_s", "physical_attempts_s", "successes_s", "errors_s",
		"error_rate", "attempt_amplification", "connection_attempts_s", "inserts_s", "updates_s", "deletes_s",
		"latency_p50_ms", "latency_p99_ms", "latency_p999_ms", "sample_count"}
	if err := w.Write(header); err != nil {
		return err
	}
	seconds := make([]int64, 0, len(series))
	for sec := range series {
		seconds = append(seconds, sec)
	}
	sort.Slice(seconds, func(i, j int) bool { return seconds[i] < seconds[j] })
	var previousDials uint64
	for _, sec := range seconds {
		x := series[sec]
		sort.Slice(x.latencyMic, func(i, j int) bool { return x.latencyMic[i] < x.latencyMic[j] })
		errorRate := ratio(x.errors, x.logical)
		amp := ratio(x.attempts, x.logical)
		dialDelta := x.dialTotal - previousDials
		previousDials = x.dialTotal
		row := []string{
			time.Unix(sec, 0).UTC().Format(time.RFC3339),
			strconv.FormatInt(sec-started.Unix(), 10),
			strconv.FormatUint(x.logical, 10), strconv.FormatUint(x.attempts, 10),
			strconv.FormatUint(x.successes, 10), strconv.FormatUint(x.errors, 10),
			fmt.Sprintf("%.6f", errorRate), fmt.Sprintf("%.4f", amp), strconv.FormatUint(dialDelta, 10),
			strconv.FormatUint(x.inserts, 10), strconv.FormatUint(x.updates, 10), strconv.FormatUint(x.deletes, 10),
			fmt.Sprintf("%.3f", quantileMillis(x.latencyMic, 0.50)),
			fmt.Sprintf("%.3f", quantileMillis(x.latencyMic, 0.99)),
			fmt.Sprintf("%.3f", quantileMillis(x.latencyMic, 0.999)), strconv.Itoa(len(x.latencyMic)),
		}
		if err := w.Write(row); err != nil {
			return err
		}
	}
	return w.Error()
}

func quantileMillis(values []int64, q float64) float64 {
	if len(values) == 0 {
		return 0
	}
	idx := int(math.Ceil(q*float64(len(values)))) - 1
	idx = min(max(idx, 0), len(values)-1)
	return float64(values[idx]) / 1000.0
}

func ratio(numerator, denominator uint64) float64 {
	if denominator == 0 {
		return 0
	}
	return float64(numerator) / float64(denominator)
}

func writeSummary(path string, cfg config, started, ended time.Time, totals *counters, errorCounts map[string]uint64) error {
	logical := totals.logical.Load()
	duration := ended.Sub(started).Seconds()
	data := map[string]any{
		"started_at": started.Format(time.RFC3339Nano), "ended_at": ended.Format(time.RFC3339Nano),
		"duration_seconds": duration,
		"configuration": map[string]any{
			"endpoints": cfg.Endpoints, "workers": cfg.Workers, "offered_rps": cfg.RPS,
			"keyspace": cfg.Keyspace, "update_pct": cfg.UpdatePct, "insert_pct": cfg.InsertPct,
			"delete_pct": cfg.DeletePct, "hot_pct": cfg.HotPct, "hot_keys": cfg.HotKeys,
			"value_sizes": cfg.ValueSizes, "ttl_seconds": cfg.TTLSeconds,
			"timeout_ms": cfg.Timeout.Milliseconds(), "retry_policy": cfg.RetryPolicy,
			"max_attempts": cfg.MaxAttempts, "sample_every": cfg.SampleEvery, "seed": cfg.Seed,
		},
		"totals": map[string]any{
			"logical_operations": logical, "physical_attempts": totals.attempts.Load(),
			"successes": totals.successes.Load(), "errors": totals.errors.Load(),
			"connection_attempts": totals.dials.Load(), "dropped_offered_tokens": totals.droppedTokens.Load(),
			"inserts": totals.inserts.Load(), "updates": totals.updates.Load(), "deletes": totals.deletes.Load(),
			"achieved_logical_ops_per_second": float64(logical) / duration,
			"attempt_amplification": ratio(totals.attempts.Load(), logical),
		},
		"error_classes": errorCounts,
	}
	b, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o644)
}
