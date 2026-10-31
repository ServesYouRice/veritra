// Command veritra-load seeds a fresh Veritra instance through its public HTTP
// API and drives a modelled busy-hour workload against it (card I47). It is
// the reproducible seed, load, soak and restart scenario behind the capacity
// contract in docs/operations.md and testing/evidence/T47-capacity.md.
//
// Everything it sends is synthetic: random ciphertext, generated accounts and
// a generated password. It never prints tokens, invite codes, identifiers or
// response bodies, and it refuses a public target unless -allow-remote is set.
//
// Typical run against a local container (the server must trust the tool's
// address as a proxy so each simulated device gets its own client address):
//
//	veritra-load -target http://127.0.0.1:18080 -setup-token-file token \
//	  -profile s -rate 1 -warmup 20s -duration 2m \
//	  -metrics http://127.0.0.1:19090/metrics -out result.json
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "veritra-load:", err)
		os.Exit(1)
	}
}

type options struct {
	Target         string
	SetupTokenFile string
	MetricsURL     string
	Out            string
	AllowRemote    bool
	Strict         bool
	Profile        profile
	Online         int
	Rates          []float64
	Warmup         time.Duration
	Duration       time.Duration
	Seed           uint64
	Verify         bool
	Companions     float64
	Cold           float64
	// DeliveryDeadline is when an unseen realtime delivery counts as missed.
	DeliveryDeadline time.Duration
}

func parseOptions(args []string, stderr io.Writer) (options, error) {
	fs := flag.NewFlagSet("veritra-load", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var opts options
	profileName := fs.String("profile", "s", "dataset profile: smoke, s or m")
	fs.StringVar(&opts.Target, "target", "", "server base URL, for example http://127.0.0.1:18080")
	fs.StringVar(&opts.SetupTokenFile, "setup-token-file", "", "file holding the instance's setup token (fresh instance)")
	fs.StringVar(&opts.MetricsURL, "metrics", "", "optional private /metrics URL scraped before and after the run")
	fs.StringVar(&opts.Out, "out", "", "optional path for the JSON result")
	fs.BoolVar(&opts.AllowRemote, "allow-remote", false, "allow a target that is not loopback or a private address")
	fs.BoolVar(&opts.Strict, "strict", false, "exit non-zero when a capacity target is missed")
	fs.IntVar(&opts.Online, "online", 0, "accounts online during the load (default: all)")
	rates := fs.String("rate", "1", "messages per online device per minute; a comma-separated list runs one measured step per rate")
	fs.DurationVar(&opts.Warmup, "warmup", 20*time.Second, "load before measurement starts")
	fs.DurationVar(&opts.Duration, "duration", 2*time.Minute, "measured load window")
	fs.Uint64Var(&opts.Seed, "seed", 47, "random seed for the dataset and workload")
	fs.BoolVar(&opts.Verify, "verify", true, "after the load, check that every acknowledged message is still stored")
	fs.Float64Var(&opts.Companions, "companions", 0.5, "share of online accounts with a second client (sockets, catch-up, reads)")
	fs.Float64Var(&opts.Cold, "cold", 0.2, "share of devices that catch up once from the middle of history during the window")
	fs.DurationVar(&opts.DeliveryDeadline, "delivery-deadline", defaultDeliveryDeadline, "time after a send starts by which every online recipient client must see its realtime event; later it counts as a missed delivery")
	accounts := fs.Int("accounts", 0, "override the profile's account count")
	history := fs.Int("history", -1, "override the profile's seeded message count")
	attachments := fs.Int("attachments", -1, "override the profile's seeded attachment count")
	if err := fs.Parse(args); err != nil {
		return opts, err
	}
	p, ok := profiles[*profileName]
	if !ok {
		return opts, fmt.Errorf("unknown profile %q", *profileName)
	}
	if *accounts > 0 {
		p.Accounts = *accounts
		p.DMs = min(p.DMs, *accounts/2)
		p.Groups = min(p.Groups, *accounts)
	}
	if *history >= 0 {
		p.History = *history
	}
	if *attachments >= 0 {
		p.Attachments = *attachments
	}
	opts.Profile = p
	if opts.Online <= 0 || opts.Online > p.Accounts {
		opts.Online = p.Accounts
	}
	if opts.Target == "" || opts.SetupTokenFile == "" {
		return opts, errors.New("-target and -setup-token-file are required")
	}
	for _, raw := range strings.Split(*rates, ",") {
		rate, err := strconv.ParseFloat(strings.TrimSpace(raw), 64)
		if err != nil || rate < 0 || rate > 600 {
			return opts, errors.New("-rate takes rates between 0 and 600 messages per minute")
		}
		opts.Rates = append(opts.Rates, rate)
	}
	if opts.Duration <= 0 || opts.Warmup < 0 || opts.Companions < 0 || opts.Companions > 1 || opts.Cold < 0 || opts.Cold > 1 {
		return opts, errors.New("-rate, -duration and -warmup must not be negative; -companions and -cold are shares between 0 and 1")
	}
	if opts.DeliveryDeadline <= targetDeliveryP99S*time.Second || opts.DeliveryDeadline >= settleGrace {
		return opts, fmt.Errorf("-delivery-deadline must be above the %d s delivery target and below %s", targetDeliveryP99S, settleGrace)
	}
	if p.Accounts < 2 || p.GroupSize < 2 || p.GroupSize > p.Accounts {
		return opts, errors.New("the profile needs at least two accounts and a group size between 2 and the account count")
	}
	return opts, nil
}

// checkTarget refuses public targets: this tool creates accounts and load.
func checkTarget(raw string, allowRemote bool) (*url.URL, error) {
	target, err := url.Parse(strings.TrimRight(raw, "/"))
	if err != nil || (target.Scheme != "http" && target.Scheme != "https") || target.Host == "" {
		return nil, errors.New("-target must be an http or https base URL")
	}
	if allowRemote {
		return target, nil
	}
	host := target.Hostname()
	if strings.EqualFold(host, "localhost") {
		return target, nil
	}
	ip := net.ParseIP(host)
	if ip == nil || !(ip.IsLoopback() || ip.IsPrivate()) {
		return nil, errors.New("target is not loopback or private; pass -allow-remote for a disposable test instance")
	}
	return target, nil
}

func run(ctx context.Context, args []string, stdout io.Writer) error {
	opts, err := parseOptions(args, os.Stderr)
	if err != nil {
		return err
	}
	target, err := checkTarget(opts.Target, opts.AllowRemote)
	if err != nil {
		return err
	}
	rawToken, err := os.ReadFile(opts.SetupTokenFile)
	if err != nil {
		return errors.New("cannot read the setup token file")
	}
	result, err := execute(ctx, target, strings.TrimSpace(string(rawToken)), opts, stdout)
	if err != nil {
		return err
	}
	printReport(stdout, result)
	if opts.Out != "" {
		encoded, err := json.MarshalIndent(result, "", "  ")
		if err != nil {
			return err
		}
		if err := os.WriteFile(opts.Out, append(encoded, '\n'), 0o600); err != nil {
			return err
		}
	}
	if opts.Strict && !result.Verdict.Pass {
		return errors.New("capacity targets missed")
	}
	return nil
}
