package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	mrand "math/rand/v2"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// profile is a synthetic dataset. The workload model is per online device:
// one sync socket; open-loop Poisson sends at -rate per minute through
// POST /messages/envelopes (the app's send path); one message in
// AttachmentEvery carries an attachment that every online recipient
// downloads, and one attachment in LargeEvery is LargeAttachmentBytes;
// every realtime event runs the app's catch-up (GET /sync/events until
// empty, coalesced while one runs, as mobile/lib/core/app_state.dart does);
// a conversation-list read and a history page about every two minutes.
// -companions adds a second client for that share of accounts (sockets,
// catch-up and reads, no sends) and -cold makes that share of devices catch
// up once from the middle of the instance's history, as after a night
// offline.
type profile struct {
	Name            string `json:"name"`
	Accounts        int    `json:"accounts"`
	DMs             int    `json:"dms"`
	Groups          int    `json:"groups"`
	GroupSize       int    `json:"group_size"`
	History         int    `json:"history_messages"`
	Attachments     int    `json:"attachments"`
	CiphertextBytes int    `json:"ciphertext_bytes"`
	AttachmentBytes int    `json:"attachment_bytes"`
	AttachmentEvery int    `json:"attachment_every"`
	LargeEvery      int    `json:"large_attachment_every"`
	LargeBytes      int    `json:"large_attachment_bytes"`
}

var profiles = map[string]profile{
	"smoke": {Name: "smoke", Accounts: 6, DMs: 3, Groups: 2, GroupSize: 3, History: 60, Attachments: 2,
		CiphertextBytes: 1024, AttachmentBytes: 16 << 10, AttachmentEvery: 5},
	"s": {Name: "s", Accounts: 50, DMs: 25, Groups: 15, GroupSize: 5, History: 20_000, Attachments: 200,
		CiphertextBytes: 1024, AttachmentBytes: 256 << 10, AttachmentEvery: 20, LargeEvery: 25, LargeBytes: 25 << 20},
	"m": {Name: "m", Accounts: 250, DMs: 125, Groups: 75, GroupSize: 5, History: 100_000, Attachments: 1_000,
		CiphertextBytes: 1024, AttachmentBytes: 256 << 10, AttachmentEvery: 20, LargeEvery: 25, LargeBytes: 25 << 20},
}

const (
	cryptoProtocol     = "mls10-openmls-v1"
	attachmentMetadata = `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576}`
	seedWorkers        = 8
	readEvery          = 2 * time.Minute
	// maxSendsInFlight caps one device's concurrent arrivals (upload plus
	// send). Arrivals over it are recorded as dropped sends, so a stalled
	// server shows as failures instead of lowering the offered load.
	maxSendsInFlight = 8
	// rateCheckEvery bounds how long a new step's rate waits to apply.
	rateCheckEvery = time.Second
	// settleGrace is how long a step's summary waits for operations that
	// started in its window: the API client's timeout plus a margin, so
	// every HTTP request ends on its own first. What is still running then
	// is counted once as unfinished.
	settleGrace = clientTimeout + 10*time.Second
	// defaultDeliveryDeadline is how long after a send's start a recipient
	// client may take to see its realtime event before the delivery counts
	// as missed (-delivery-deadline). It is well above the 2 s p99 target,
	// so a slow delivery stays a latency sample, and below settleGrace, so
	// a step's summary waits for every delivery to end.
	defaultDeliveryDeadline = 30 * time.Second
	// downloadQueue is how many attachments one client may have waiting.
	// Each client downloads in order on its own; an attachment arriving
	// when its queue is full is recorded as a dropped download, because
	// that client has fallen far behind.
	downloadQueue = 32
)

type conversation struct {
	id      string
	members []int
}

type world struct {
	client   *apiClient
	base     *url.URL
	profile  profile
	devices  []*device
	convs    []conversation
	byDevice [][]int
	rec      *recorder
	// clients holds, per online device index, the devices its simulated
	// clients use: slot 0 is the primary client, slot 1 a companion. It is
	// nil for devices that are offline during the load.
	clients [][]*device
	// deliveries measures the realtime delivery of each acknowledged send
	// to every expected recipient client.
	deliveries *deliveryTracker
	ackMu      sync.Mutex
	acked      []ackedMessage
	reconnects atomic.Int64
	// rate is the current messages per device per minute (float64 bits);
	// each load step sets it.
	rate atomic.Uint64
	// arrivals counts scheduled send arrivals, dropped ones included, for
	// the offered rate of each step.
	arrivals atomic.Int64
}

type ackedMessage struct {
	id     string
	sender int
}

// download is one attachment a client fetches after its realtime event.
// Its recorder handle was opened when the event arrived, so queueing time
// counts and the window that saw the event waits for it.
type download struct {
	dev *device
	id  string
	at  time.Time // when the event arrived
	h   *inflight
}

type runResult struct {
	StartedAt        string        `json:"started_at"`
	Profile          profile       `json:"profile"`
	Conversations    int           `json:"conversations"`
	SeedDuration     string        `json:"seed_duration"`
	Online           int           `json:"online_devices"`
	Companions       int           `json:"companion_clients"`
	Cold             int           `json:"cold_devices"`
	Warmup           string        `json:"warmup"`
	Measured         string        `json:"measured_per_step"`
	Steps            []stepResult  `json:"steps"`
	SocketReconnects int64         `json:"socket_reconnects"`
	Verify           *verifyResult `json:"verify,omitempty"`
	// RatedStep is the highest rate at which this and every lower step met
	// the targets; 0 when the first step missed.
	RatedStep float64 `json:"rated_messages_per_device_minute"`
	Verdict   verdict `json:"verdict"`
}

// stepResult is one measured window at one send rate.
type stepResult struct {
	Rate float64 `json:"messages_per_device_minute"`
	// Offered is the send rate actually generated in the window: arrivals
	// (dropped ones included) per online device per minute.
	Offered  float64            `json:"offered_messages_per_device_minute"`
	Ops      []opSummary        `json:"ops"`
	Timeline timelineSummary    `json:"timeline"`
	Server   map[string]float64 `json:"server_metrics,omitempty"`
	// ServerError says why server metrics are missing or lack the counter
	// deltas; it is a fixed message without URLs or response text.
	ServerError string  `json:"server_metrics_error,omitempty"`
	Verdict     verdict `json:"verdict"`
}

type verifyResult struct {
	Checked int `json:"checked"`
	Missing int `json:"missing"`
	Errors  int `json:"errors"`
}

func execute(ctx context.Context, target *url.URL, setupToken string, opts options, progress io.Writer) (*runResult, error) {
	rng := mrand.New(mrand.NewPCG(opts.Seed, uint64(opts.Profile.Accounts)))
	w := &world{
		client:  newAPIClient(target, 4*opts.Profile.Accounts+seedWorkers),
		base:    target,
		profile: opts.Profile,
		rec:     newRecorder(),
	}
	w.rate.Store(math.Float64bits(opts.Rates[0]))
	result := &runResult{StartedAt: time.Now().UTC().Format(time.RFC3339), Profile: opts.Profile, Online: opts.Online,
		Warmup: opts.Warmup.String(), Measured: opts.Duration.String()}
	seedStarted := time.Now()
	if err := w.seed(ctx, setupToken, rng, progress); err != nil {
		return nil, fmt.Errorf("seed: %w", err)
	}
	result.SeedDuration = time.Since(seedStarted).Round(time.Second).String()
	result.Conversations = len(w.convs)

	loadCtx, stopLoad := context.WithCancel(ctx)
	defer stopLoad()
	var running sync.WaitGroup
	w.rec = newRecorder()
	deadline := opts.DeliveryDeadline
	if deadline <= 0 {
		deadline = defaultDeliveryDeadline
	}
	w.deliveries = newDeliveryTracker(w.rec, deadline)
	// Plan every online device's clients before any of them sends, so each
	// send knows all the clients that should see it.
	type devicePlan struct {
		rng      *mrand.Rand
		coldWake chan struct{}
	}
	plans := make([]devicePlan, opts.Online)
	w.clients = make([][]*device, len(w.devices))
	var coldWakes []chan struct{}
	for i := 0; i < opts.Online; i++ {
		dev := w.devices[i]
		plan := devicePlan{rng: mrand.New(mrand.NewPCG(opts.Seed, uint64(1000+i)))}
		if plan.rng.Float64() < opts.Cold {
			plan.coldWake = make(chan struct{}, 1)
			coldWakes = append(coldWakes, plan.coldWake)
		}
		w.clients[i] = []*device{dev}
		if plan.rng.Float64() < opts.Companions {
			result.Companions++
			// The companion client shares the primary's device session.
			w.clients[i] = append(w.clients[i], dev)
		}
		plans[i] = plan
	}
	for i, plan := range plans {
		dev := w.devices[i]
		running.Add(1)
		go func() {
			defer running.Done()
			w.runDevice(loadCtx, dev, plan.coldWake, plan.rng)
		}()
	}
	running.Add(1)
	go func() {
		defer running.Done()
		w.deliveries.sweep(loadCtx, time.Second)
	}()
	result.Cold = len(coldWakes)
	stepRNG := mrand.New(mrand.NewPCG(opts.Seed, 3))
	for _, rate := range opts.Rates {
		w.rate.Store(math.Float64bits(rate))
		fmt.Fprintf(progress, "load: %d devices online at %.2f msgs/device/min, warming up for %s\n", opts.Online, rate, opts.Warmup)
		if !sleepCtx(ctx, opts.Warmup) {
			break
		}
		// Each cold device catches up once from the middle of history at a
		// random point in the first three quarters of the window.
		for _, coldWake := range coldWakes {
			coldWake := coldWake
			time.AfterFunc(time.Duration(stepRNG.Int64N(int64(opts.Duration*3/4)+1)), func() { wake(coldWake) })
		}
		before, beforeErr := scrape(ctx, opts.MetricsURL)
		fmt.Fprintf(progress, "load: measuring for %s\n", opts.Duration)
		measureFrom := time.Since(w.rec.started)
		arrivalsFrom := w.arrivals.Load()
		sleepCtx(ctx, opts.Duration)
		measureTo := time.Since(w.rec.started)
		arrivalsTo := w.arrivals.Load()
		after, afterErr := scrape(ctx, opts.MetricsURL)
		step := stepResult{Rate: rate}
		if minutes := (measureTo - measureFrom).Minutes(); minutes > 0 {
			step.Offered = float64(arrivalsTo-arrivalsFrom) / float64(opts.Online) / minutes
		}
		// Operations started in the window are summarized only once they
		// have ended, the slowest included; load goes on meanwhile.
		if forced := w.rec.settle(ctx, measureTo, settleGrace); forced > 0 {
			fmt.Fprintf(progress, "load: %d operations from the window still unfinished after %s, counted as errors\n", forced, settleGrace)
		}
		step.Ops, step.Timeline = w.rec.summarize(measureFrom, measureTo)
		if opts.MetricsURL != "" {
			step.Server, step.ServerError = serverMetrics(before, beforeErr, after, afterErr, (measureTo - measureFrom).Seconds())
		}
		step.Verdict = evaluateStep(step)
		result.Steps = append(result.Steps, step)
		if ctx.Err() != nil {
			break
		}
	}
	stopLoad()
	running.Wait()
	w.deliveries.drain()
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	result.SocketReconnects = w.reconnects.Load()
	if opts.Verify {
		result.Verify = w.verify(ctx)
	}
	finish(result)
	return result, nil
}

func sleepCtx(ctx context.Context, d time.Duration) bool {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

// deviceIP gives simulated device i its own client address, so per-address
// rate limits apply per device as they would for real phones.
func deviceIP(i int) string { return fmt.Sprintf("10.77.%d.%d", i/250, i%250+1) }

// seedIP spreads bulk seeding over many addresses; seeding is not measured.
func seedIP(rng *mrand.Rand) string {
	return fmt.Sprintf("10.78.%d.%d", rng.IntN(256), 1+rng.IntN(254))
}

func randomSecret() (string, error) {
	var raw [24]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(raw[:]), nil
}

func (w *world) seed(ctx context.Context, setupToken string, rng *mrand.Rand, progress io.Writer) error {
	p := w.profile
	password, err := randomSecret()
	if err != nil {
		return err
	}
	setupHeaders := map[string]string{"X-Veritra-Setup-Token": setupToken}
	owner, err := w.client.enroll(ctx, "/api/v1/setup/owner/enrollment", "/api/v1/setup/owner", deviceIP(0), setupHeaders,
		map[string]any{}, map[string]any{"instance_name": "Capacity test", "username": "load00000", "password": password, "device_name": "load device"})
	if err != nil {
		return fmt.Errorf("owner setup (the instance must be fresh): %w", err)
	}
	w.devices = make([]*device, p.Accounts)
	w.devices[0] = &device{index: 0, token: owner.Token, accountID: owner.Account.ID, deviceID: owner.Device.ID, ip: deviceIP(0)}
	var invite struct {
		Code string `json:"code"`
	}
	if err := expect(w.client.json(ctx, http.MethodPost, "/api/v1/invites", w.devices[0], "", map[string]any{"max_uses": p.Accounts - 1}, &invite, nil)); err != nil {
		return fmt.Errorf("create invite: %w", err)
	}
	fmt.Fprintf(progress, "seed: registering %d accounts\n", p.Accounts-1)
	if err := parallel(ctx, p.Accounts-1, 4, func(ctx context.Context, n int) error {
		i := n + 1
		session, err := w.client.enroll(ctx, "/api/v1/register/enrollment", "/api/v1/register", deviceIP(i), nil,
			map[string]any{"invite_code": invite.Code},
			map[string]any{"invite_code": invite.Code, "username": fmt.Sprintf("load%05d", i), "password": password, "device_name": "load device"})
		if err != nil {
			return err
		}
		w.devices[i] = &device{index: i, token: session.Token, accountID: session.Account.ID, deviceID: session.Device.ID, ip: deviceIP(i)}
		return nil
	}); err != nil {
		return fmt.Errorf("register: %w", err)
	}
	w.planConversations(rng)
	fmt.Fprintf(progress, "seed: creating %d conversations\n", len(w.convs))
	if err := parallel(ctx, len(w.convs), seedWorkers, func(ctx context.Context, i int) error {
		conv := &w.convs[i]
		kind := "group"
		if len(conv.members) == 2 && i < p.DMs {
			kind = "dm"
		}
		creator := w.devices[conv.members[0]]
		others := make([]string, 0, len(conv.members)-1)
		for _, member := range conv.members[1:] {
			others = append(others, w.devices[member].accountID)
		}
		var created struct {
			ID string `json:"id"`
		}
		status, err := w.client.json(ctx, http.MethodPost, "/api/v1/conversations", creator, "", map[string]any{"kind": kind, "member_account_ids": others}, &created, nil)
		if err := expect(status, err, http.StatusCreated); err != nil {
			return err
		}
		conv.id = created.ID
		return nil
	}); err != nil {
		return fmt.Errorf("conversations: %w", err)
	}
	fmt.Fprintf(progress, "seed: sending %d history messages and %d attachments\n", p.History, p.Attachments)
	seedRNGs := make([]*mrand.Rand, seedWorkers)
	for i := range seedRNGs {
		seedRNGs[i] = mrand.New(mrand.NewPCG(uint64(i), uint64(p.History)))
	}
	var rngMu sync.Mutex
	if err := parallel(ctx, p.History+p.Attachments, seedWorkers, func(ctx context.Context, n int) error {
		rngMu.Lock()
		local := seedRNGs[n%seedWorkers]
		conv := w.convs[local.IntN(len(w.convs))]
		sender := w.devices[conv.members[local.IntN(len(conv.members))]]
		ip := seedIP(local)
		rngMu.Unlock()
		var refs []string
		if n >= p.History {
			var id string
			if err := retryRateLimited(ctx, func() error {
				var err error
				id, err = w.uploadAttachment(ctx, sender, conv.id, ip, p.AttachmentBytes)
				return err
			}); err != nil {
				return err
			}
			refs = []string{id}
		}
		return retryRateLimited(ctx, func() error {
			_, err := w.sendMessage(ctx, sender, conv.id, refs, ip)
			return err
		})
	}); err != nil {
		return fmt.Errorf("history: %w", err)
	}
	return nil
}

// retryRateLimited retries a seeding write refused with 429 (the server's
// per-account write budget) after a growing pause. Seeding is not measured,
// so it simply proceeds at the rate the server admits.
func retryRateLimited(ctx context.Context, write func() error) error {
	pause := time.Second
	for attempt := 0; ; attempt++ {
		err := write()
		var refused statusError
		if !errors.As(err, &refused) || refused.status != http.StatusTooManyRequests || attempt >= 30 {
			return err
		}
		if !sleepCtx(ctx, pause) {
			return ctx.Err()
		}
		pause = min(2*pause, 15*time.Second)
	}
}

// planConversations pairs every account into at least one DM (a shuffled
// perfect matching first), adds further random pairs, then random groups.
func (w *world) planConversations(rng *mrand.Rand) {
	p := w.profile
	order := rng.Perm(p.Accounts)
	pairs := map[[2]int]bool{}
	addPair := func(a, b int) bool {
		key := [2]int{min(a, b), max(a, b)}
		if a == b || pairs[key] {
			return false
		}
		pairs[key] = true
		w.convs = append(w.convs, conversation{members: []int{a, b}})
		return true
	}
	for i := 0; i+1 < len(order) && len(w.convs) < p.DMs; i += 2 {
		addPair(order[i], order[i+1])
	}
	for attempts := 0; len(w.convs) < p.DMs && attempts < 100*p.DMs; attempts++ {
		addPair(rng.IntN(p.Accounts), rng.IntN(p.Accounts))
	}
	for g := 0; g < p.Groups; g++ {
		members := rng.Perm(p.Accounts)[:p.GroupSize]
		w.convs = append(w.convs, conversation{members: members})
	}
	w.byDevice = make([][]int, p.Accounts)
	for i, conv := range w.convs {
		for _, member := range conv.members {
			w.byDevice[member] = append(w.byDevice[member], i)
		}
	}
}

// parallel runs fn for 0..n-1 on workers goroutines and stops at the first
// error.
func parallel(ctx context.Context, n, workers int, fn func(context.Context, int) error) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var next atomic.Int64
	var firstErr error
	var once sync.Once
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				index := int(next.Add(1) - 1)
				if index >= n || ctx.Err() != nil {
					return
				}
				if err := fn(ctx, index); err != nil {
					once.Do(func() { firstErr = err; cancel() })
					return
				}
			}
		}()
	}
	wg.Wait()
	if firstErr != nil {
		return firstErr
	}
	return ctx.Err()
}

func (w *world) ciphertext(size int) []byte {
	buf := make([]byte, size)
	_, _ = rand.Read(buf)
	return buf
}

func (w *world) uploadAttachment(ctx context.Context, dev *device, conversationID, ip string, size int) (string, error) {
	var created struct {
		ID string `json:"id"`
	}
	status, _, err := w.client.do(ctx, request{
		method: http.MethodPost, path: "/api/v1/attachments?conversation_id=" + url.QueryEscape(conversationID), dev: dev, ip: ip,
		body: w.ciphertext(size), contentType: "application/octet-stream",
		headers: map[string]string{"X-Private-Messenger-Encrypted": "1", "X-Crypto-Metadata": attachmentMetadata},
	}, &created)
	if err := expect(status, err, http.StatusCreated); err != nil {
		return "", err
	}
	return created.ID, nil
}

func (w *world) sendMessage(ctx context.Context, dev *device, conversationID string, refs []string, ip string) (string, error) {
	key, err := randomSecret()
	if err != nil {
		return "", err
	}
	body := map[string]any{
		"conversation_id": conversationID, "idempotency_key": key,
		"ciphertext": w.ciphertext(w.profile.CiphertextBytes), "crypto_protocol": cryptoProtocol,
	}
	if len(refs) > 0 {
		body["attachment_refs"] = refs
	}
	var created struct {
		ID string `json:"id"`
	}
	status, err := w.client.json(ctx, http.MethodPost, "/api/v1/messages/envelopes", dev, ip, body, &created, nil)
	if err := expect(status, err, http.StatusCreated); err != nil {
		return "", err
	}
	return created.ID, nil
}

func (w *world) timed(op int, fn func() (int, error)) (int, error) {
	return w.timedFrom(op, time.Now(), fn)
}

// timedFrom measures fn from started, which may be earlier than the call:
// a send is timed from its scheduled arrival, so delay on the client side
// counts against it (no coordinated omission).
func (w *world) timedFrom(op int, started time.Time, fn func() (int, error)) (int, error) {
	h := w.rec.begin(op, started)
	status, err := fn()
	w.rec.end(h, classify(status, err), time.Since(started))
	return status, err
}

func (w *world) runDevice(ctx context.Context, dev *device, coldWake <-chan struct{}, rng *mrand.Rand) {
	var wg sync.WaitGroup
	for slot, clientDev := range w.clients[dev.index] {
		catchUp := make(chan struct{}, 1)
		var cold <-chan struct{}
		if slot == 0 {
			cold = coldWake
		}
		seed := rng.Uint64()
		client := clientSlot{dev: dev.index, slot: slot}
		downloads := make(chan download, downloadQueue)
		wg.Add(4)
		go func() {
			defer wg.Done()
			// Only the producer closes the queue, once it can send no more.
			defer close(downloads)
			w.runSocket(ctx, clientDev, client, catchUp, downloads)
		}()
		go func() { defer wg.Done(); w.runDownloads(ctx, downloads) }()
		go func() { defer wg.Done(); w.runCatchUp(ctx, clientDev, catchUp, cold) }()
		go func() { defer wg.Done(); w.runReads(ctx, clientDev, seed) }()
	}
	w.runSender(ctx, dev, rng)
	wg.Wait()
}

// sendRate is the current step's messages per device per minute.
func (w *world) sendRate() float64 { return math.Float64frombits(w.rate.Load()) }

// nextGap draws one exponential interarrival gap at rate messages a minute.
// It is never truncated: these gaps make an exact Poisson process.
func nextGap(rng *mrand.Rand, rate float64) time.Duration {
	gap := rng.ExpFloat64() * float64(time.Minute) / rate
	// Keep the conversion defined for a vanishing rate; the sender rechecks
	// the rate every second anyway.
	return time.Duration(min(gap, float64(100*365*24*time.Hour)))
}

// runSender generates the device's sends as an open loop: arrivals follow a
// Poisson process at the current rate whether or not earlier sends have
// finished, so a slow server cannot lower the load it is offered. The wait
// is checked against the rate at least every rateCheckEvery; on a change
// the remaining wait is redrawn at the new rate, which exponential gaps
// allow without bias. Each arrival runs on its own goroutine, at most
// maxSendsInFlight at once; an arrival over that cap is recorded as a
// dropped send. runSender returns only after its sends have finished.
func (w *world) runSender(ctx context.Context, dev *device, rng *mrand.Rand) {
	convs := w.byDevice[dev.index]
	if len(convs) == 0 {
		<-ctx.Done()
		return
	}
	var inFlight sync.WaitGroup
	defer inFlight.Wait()
	slots := make(chan struct{}, maxSendsInFlight)
	rate := w.sendRate()
	next := time.Now()
	if rate > 0 {
		next = next.Add(nextGap(rng, rate))
	}
	for {
		if now := time.Now(); rate <= 0 || now.Before(next) {
			wait := rateCheckEvery
			if rate > 0 {
				wait = min(wait, next.Sub(now))
			}
			if !sleepCtx(ctx, wait) {
				return
			}
			if current := w.sendRate(); current != rate {
				rate = current
				if rate > 0 {
					next = time.Now().Add(nextGap(rng, rate))
				}
			}
			continue
		}
		// The next arrival is drawn from this one's scheduled time, not from
		// when the loop got here, so a late wake-up does not stretch gaps.
		arrival := next
		next = arrival.Add(nextGap(rng, rate))
		w.arrivals.Add(1)
		// rng is not safe for concurrent use: draw everything here.
		conv := w.convs[convs[rng.IntN(len(convs))]]
		attachment := 0
		if w.profile.AttachmentEvery > 0 && rng.IntN(w.profile.AttachmentEvery) == 0 {
			attachment = w.profile.AttachmentBytes
			if w.profile.LargeEvery > 0 && rng.IntN(w.profile.LargeEvery) == 0 {
				attachment = w.profile.LargeBytes
			}
		}
		select {
		case slots <- struct{}{}:
		default:
			w.rec.record(opSend, arrival, 0, outcomeDropped)
			continue
		}
		inFlight.Add(1)
		go func() {
			defer inFlight.Done()
			defer func() { <-slots }()
			w.sendArrival(ctx, dev, conv, attachment, arrival)
		}()
	}
}

// sendArrival performs one arrival: the attachment upload first, when there
// is one, then the send that references it. The upload is timed from the
// scheduled arrival and the send from when it could start.
func (w *world) sendArrival(ctx context.Context, dev *device, conv conversation, attachment int, arrival time.Time) {
	var refs []string
	var send *inflight
	if attachment > 0 {
		upload := w.rec.begin(opUpload, arrival)
		id, err := w.uploadAttachment(ctx, dev, conv.id, "", attachment)
		if err == nil {
			refs = []string{id}
			// Register the send before the upload ends, so a step's
			// settle never sees this arrival with nothing in flight.
			send = w.rec.begin(opSend, time.Now())
		}
		w.rec.end(upload, classify(http.StatusCreated, err), time.Since(arrival))
		if err != nil {
			return
		}
	} else {
		send = w.rec.begin(opSend, arrival)
	}
	key, err := randomSecret()
	if err != nil {
		w.rec.end(send, outcomeTransportError, time.Since(send.start))
		return
	}
	body := map[string]any{"conversation_id": conv.id, "idempotency_key": key,
		"ciphertext": w.ciphertext(w.profile.CiphertextBytes), "crypto_protocol": cryptoProtocol}
	if len(refs) > 0 {
		body["attachment_refs"] = refs
	}
	w.deliveries.start(key, send.start, w.expectedRecipients(dev, conv))
	var created struct {
		ID string `json:"id"`
	}
	status, err := w.client.json(ctx, http.MethodPost, "/api/v1/messages/envelopes", dev, "", body, &created, nil)
	err = expect(status, err, http.StatusCreated)
	w.deliveries.sent(key, err == nil && created.ID != "")
	w.rec.end(send, classify(status, err), time.Since(send.start))
	if err == nil && created.ID != "" {
		w.ackMu.Lock()
		w.acked = append(w.acked, ackedMessage{id: created.ID, sender: dev.index})
		w.ackMu.Unlock()
	}
}

type realtimeEvent struct {
	Type    string `json:"type"`
	Payload struct {
		SenderDeviceID string   `json:"sender_device_id"`
		IdempotencyKey string   `json:"idempotency_key"`
		AttachmentRefs []string `json:"attachment_refs"`
	} `json:"payload"`
}

func (w *world) runSocket(ctx context.Context, dev *device, client clientSlot, catchUp chan<- struct{}, downloads chan<- download) {
	backoff := time.Second
	for ctx.Err() == nil {
		var socket *syncSocket
		_, err := w.timed(opSocket, func() (int, error) {
			var err error
			socket, err = dialSync(ctx, w.base, dev)
			return http.StatusSwitchingProtocols, err
		})
		if err != nil {
			if !sleepCtx(ctx, backoff) {
				return
			}
			backoff = min(2*backoff, 8*time.Second)
			continue
		}
		backoff = time.Second
		wake(catchUp)
		done := make(chan struct{})
		go func() {
			select {
			case <-ctx.Done():
				socket.close()
			case <-done:
			}
		}()
		for {
			payload, err := socket.next()
			if err != nil {
				break
			}
			now := time.Now()
			var event realtimeEvent
			if json.Unmarshal(payload, &event) == nil && event.Type == "message.envelope.created" && event.Payload.SenderDeviceID != dev.deviceID {
				w.deliveries.observe(event.Payload.IdempotencyKey, client, now)
				w.queueDownloads(downloads, dev, event.Payload.AttachmentRefs, now)
			}
			wake(catchUp)
		}
		close(done)
		socket.close()
		if ctx.Err() == nil {
			w.reconnects.Add(1)
			if !sleepCtx(ctx, backoff) {
				return
			}
		}
	}
}

func wake(ch chan<- struct{}) {
	select {
	case ch <- struct{}{}:
	default:
	}
}

type syncPage struct {
	Events []struct {
		ID int64 `json:"id"`
	} `json:"events"`
	Latest int64 `json:"latest_event_id"`
}

// runCatchUp pages /sync/events from the device's cursor until a page is
// empty, once per wake-up; wake-ups during a catch-up coalesce into one.
func (w *world) runCatchUp(ctx context.Context, dev *device, wake, cold <-chan struct{}) {
	var cursor int64 = -1
	for {
		op := opSync
		select {
		case <-ctx.Done():
			return
		case <-wake:
		case <-cold:
			if cursor > 0 {
				cursor /= 2
				op = opColdSync
			}
		}
		if cursor < 0 {
			var page syncPage
			status, err := w.client.json(ctx, http.MethodGet, "/api/v1/sync/events?after=0&limit=1", dev, "", nil, &page, nil)
			if expect(status, err, http.StatusOK) != nil {
				continue
			}
			cursor = page.Latest
		}
		for ctx.Err() == nil {
			var page syncPage
			_, err := w.timed(op, func() (int, error) {
				status, err := w.client.json(ctx, http.MethodGet, "/api/v1/sync/events?after="+strconv.FormatInt(cursor, 10)+"&limit=200", dev, "", nil, &page, nil)
				return status, expect(status, err, http.StatusOK)
			})
			if err != nil || len(page.Events) == 0 {
				break
			}
			cursor = page.Events[len(page.Events)-1].ID
		}
	}
}

func (w *world) runReads(ctx context.Context, dev *device, seed uint64) {
	rng := mrand.New(mrand.NewPCG(seed, 7))
	convs := w.byDevice[dev.index]
	// Spread the first read over the interval so devices do not align.
	first := time.Duration(rng.Int64N(int64(readEvery)))
	if !sleepCtx(ctx, first) {
		return
	}
	for {
		_, _ = w.timed(opConversations, func() (int, error) {
			status, _, err := w.client.do(ctx, request{method: http.MethodGet, path: "/api/v1/conversations?limit=100", dev: dev}, nil)
			return status, expect(status, err, http.StatusOK)
		})
		if len(convs) > 0 {
			conv := w.convs[convs[rng.IntN(len(convs))]]
			_, _ = w.timed(opHistory, func() (int, error) {
				status, _, err := w.client.do(ctx, request{method: http.MethodGet, path: "/api/v1/conversations/" + url.PathEscape(conv.id) + "/messages?limit=50", dev: dev}, nil)
				return status, expect(status, err, http.StatusOK)
			})
		}
		jitter := time.Duration(rng.Int64N(int64(readEvery / 5)))
		if !sleepCtx(ctx, readEvery-readEvery/10+jitter) {
			return
		}
	}
}

// queueDownloads queues every attachment of one realtime event for the
// client's downloader. Each download is registered when the event arrives;
// when the client's queue is full it is recorded as dropped at once.
func (w *world) queueDownloads(queue chan<- download, dev *device, ids []string, at time.Time) {
	for _, id := range ids {
		h := w.rec.begin(opDownload, at)
		select {
		case queue <- download{dev: dev, id: id, at: at, h: h}:
		default:
			w.rec.end(h, outcomeDropped, 0)
		}
	}
}

// runDownloads fetches one client's attachments in order, as the app does,
// and drains each body without keeping it. A download is timed from its
// event, so queueing counts. Once ctx is done every job left, and one cut
// short by the cancellation, ends as unfinished. It returns when the
// producer closes the queue, so no handle is left live.
func (w *world) runDownloads(ctx context.Context, queue <-chan download) {
	for job := range queue {
		if ctx.Err() != nil {
			w.rec.abandon(job.h)
			continue
		}
		status, _, err := w.client.do(ctx, request{method: http.MethodGet, path: "/api/v1/attachments/" + url.PathEscape(job.id), dev: job.dev}, nil)
		if ctx.Err() != nil {
			w.rec.abandon(job.h)
			continue
		}
		w.rec.end(job.h, classify(status, expect(status, err, http.StatusOK)), time.Since(job.at))
	}
}

// verify fetches every acknowledged message after the load: a committed
// message that is missing (for example after a restart) is a lost write.
func (w *world) verify(ctx context.Context) *verifyResult {
	w.ackMu.Lock()
	acked := append([]ackedMessage(nil), w.acked...)
	w.ackMu.Unlock()
	result := &verifyResult{Checked: len(acked)}
	var missing, failed atomic.Int64
	rng := mrand.New(mrand.NewPCG(99, uint64(len(acked))))
	ips := make([]string, len(acked))
	for i := range ips {
		ips[i] = seedIP(rng)
	}
	_ = parallel(ctx, len(acked), seedWorkers, func(ctx context.Context, i int) error {
		message := acked[i]
		status, _, err := w.client.do(ctx, request{method: http.MethodGet, path: "/api/v1/messages/" + url.PathEscape(message.id), dev: w.devices[message.sender], ip: ips[i]}, nil)
		switch {
		case err == nil && status == http.StatusOK:
		case err == nil && status == http.StatusNotFound:
			missing.Add(1)
		default:
			failed.Add(1)
		}
		return nil
	})
	result.Missing, result.Errors = int(missing.Load()), int(failed.Load())
	return result
}

// Fixed scrape errors: they reach the report, so they never carry the URL,
// a response body or an underlying error text.
var (
	errScrapeRequest = errors.New("metrics request failed")
	errScrapeStatus  = errors.New("metrics endpoint did not answer 200")
	errScrapeBody    = errors.New("metrics body was unreadable or too large")
)

const maxScrapeBytes = 16 << 20

// scrape reads the private /metrics text. It keeps only veritra_* series;
// none of them carries an identifier. It returns nil, nil when no URL is
// set, and an error whenever the scrape failed or may be partial: a
// missing baseline would otherwise turn lifetime counters into a window's
// deltas.
func scrape(ctx context.Context, metricsURL string) (map[string]float64, error) {
	if metricsURL == "" {
		return nil, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, metricsURL, nil)
	if err != nil {
		return nil, errScrapeRequest
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, errScrapeRequest
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
		return nil, errScrapeStatus
	}
	values := map[string]float64{}
	// One byte over the limit tells a body that was cut off by it.
	body := &io.LimitedReader{R: resp.Body, N: maxScrapeBytes + 1}
	scanner := bufio.NewScanner(body)
	scanner.Buffer(make([]byte, 64<<10), 1<<20)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "veritra_") {
			continue
		}
		cut := strings.LastIndexByte(line, ' ')
		if cut < 0 {
			continue
		}
		value, err := strconv.ParseFloat(line[cut+1:], 64)
		if err != nil {
			continue
		}
		values[line[:cut]] = value
	}
	if scanner.Err() != nil || body.N == 0 {
		return nil, errScrapeBody
	}
	return values, nil
}

var writerBuckets = []string{"0.001", "0.005", "0.01", "0.025", "0.05", "0.1", "0.25", "0.5", "1", "5"}

// serverMetrics reduces the scrapes around one window to the step's server
// signals. Counter deltas need a complete baseline: without one a key
// missing from before would read as 0 and report the lifetime counter as
// the window's figure, so they are left out and the returned message says
// why. Gauges come from the end-of-window scrape alone.
func serverMetrics(before map[string]float64, beforeErr error, after map[string]float64, afterErr error, seconds float64) (map[string]float64, string) {
	switch {
	case afterErr != nil && beforeErr != nil:
		return nil, "both scrapes failed"
	case afterErr != nil:
		return nil, "end-of-window scrape failed"
	case len(after) == 0:
		return nil, "end-of-window scrape had no veritra metrics"
	case beforeErr != nil:
		return serverGauges(after), "baseline scrape failed; counter deltas omitted"
	}
	return serverSummary(before, after, seconds), ""
}

// serverGauges holds the values read from the end-of-window scrape alone.
func serverGauges(after map[string]float64) map[string]float64 {
	return map[string]float64{
		"go_memory_bytes":        after["veritra_go_memory_bytes"],
		"go_heap_live_bytes":     after["veritra_go_heap_live_bytes"],
		"go_goroutines":          after["veritra_go_goroutines"],
		"realtime_connections":   after["veritra_realtime_connections"],
		"retention_backlog_rows": after["veritra_retention_backlog_rows"],
		"storage_database_bytes": after[`veritra_storage_bytes{component="database"}`],
		"storage_wal_bytes":      after[`veritra_storage_bytes{component="wal"}`],
		"storage_blob_bytes":     after[`veritra_storage_bytes{component="blobs"}`],
	}
}

// serverSummary reduces two complete scrapes to the capacity signals in the
// report: the gauges plus counter deltas over the window. A counter absent
// from a complete baseline did not exist yet, so it counts from zero.
func serverSummary(before, after map[string]float64, seconds float64) map[string]float64 {
	if len(after) == 0 {
		return nil
	}
	// A counter that went down was reset by a restart inside the window;
	// as Prometheus does, count from zero then.
	delta := func(key string) float64 {
		if after[key] < before[key] {
			return after[key]
		}
		return after[key] - before[key]
	}
	summary := serverGauges(after)
	for key, value := range map[string]float64{
		"realtime_dropped_events_delta":   delta("veritra_realtime_dropped_events_total"),
		"http_5xx_delta":                  delta(`veritra_http_responses_total{status_class="5xx"}`),
		"writer_waits_delta":              delta(`veritra_sqlite_pool_waits_total{pool="writer"}`),
		"writer_mean_queue":               delta(`veritra_sqlite_pool_wait_seconds_total{pool="writer"}`) / seconds,
		"reader_waits_delta":              delta(`veritra_sqlite_pool_waits_total{pool="reader"}`),
		"rate_limit_rejections_delta":     delta(`veritra_rate_limit_rejections_total{scope="general"}`) + delta(`veritra_rate_limit_rejections_total{scope="auth"}`) + delta(`veritra_rate_limit_rejections_total{scope="enrollment"}`),
		"writer_acquire_count_delta":      delta("veritra_sqlite_writer_acquire_duration_seconds_count"),
		"writer_acquire_mean_ms_in_delta": 0,
	} {
		summary[key] = value
	}
	if count := summary["writer_acquire_count_delta"]; count > 0 {
		summary["writer_acquire_mean_ms_in_delta"] = 1000 * delta("veritra_sqlite_writer_acquire_duration_seconds_sum") / count
		// p99 upper bound: the first bucket holding 99% of the window's
		// acquisitions.
		for _, le := range writerBuckets {
			if delta(`veritra_sqlite_writer_acquire_duration_seconds_bucket{le="`+le+`"}`) >= 0.99*count {
				bound, _ := strconv.ParseFloat(le, 64)
				summary["writer_acquire_p99_le_ms"] = 1000 * bound
				break
			}
		}
	}
	return summary
}
