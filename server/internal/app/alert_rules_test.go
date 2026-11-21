package app

import (
	"context"
	"io"
	"log/slog"
	"math"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/storage/storagetest"
)

const (
	monitoringDir = "../../../deploy/monitoring"
	// The self-host profile (Compose, systemd, any Prometheus that keeps
	// every series) and the owner's cluster profile, loaded unchanged with
	// `mimirtool rules load`.
	selfHostRulesFile = "veritra-alerts.rules.yml"
	clusterRulesFile  = "veritra-alerts.cluster.rules.yml"
	// What infra's collector forwards and the server container's memory
	// limit, copied from the infra repository.
	infraClusterFixture = "testdata/infra-cluster.txt"
)

// Rules the cluster profile leaves out, each because a series it reads is
// not forwarded off the host.
var clusterOmittedAlerts = map[string]bool{"VeritraLatencyHigh": true}

func readRepoFile(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// exportedSeries returns every series name the metrics handler writes, and
// whether its lines carry a per-route label.
func exportedSeries(t *testing.T) map[string]bool {
	t.Helper()
	dir := t.TempDir()
	storagetest.SeedMigrated(t, filepath.Join(dir, "private-messenger.db"))
	application, err := New(context.Background(), config.Config{
		Addr: ":0", DataDir: dir, DatabasePath: filepath.Join(dir, "private-messenger.db"),
		StoragePath: filepath.Join(dir, "blobs"), InstanceName: "test", EnableMetrics: true,
	}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	defer application.Close()
	application.sampleCapacity(context.Background())
	application.metrics.record("GET /api/v1/sync/events", 200, time.Millisecond)
	recorder := httptest.NewRecorder()
	application.metrics.handle(recorder, httptest.NewRequest("GET", "/metrics", nil))
	exported := map[string]bool{}
	for _, line := range strings.Split(recorder.Body.String(), "\n") {
		if series, _, ok := strings.Cut(line, " "); ok && !strings.HasPrefix(line, "#") {
			name, labels, _ := strings.Cut(series, "{")
			exported[name] = exported[name] || strings.Contains(labels, "route=")
		}
	}
	return exported
}

// Every veritra_* series an alert reads must be one the server exports, and
// every runbook link must point at an existing operations.md heading. Both
// profiles.
func TestAlertRulesReferenceExportedMetricsAndRunbooks(t *testing.T) {
	exported := exportedSeries(t)
	operations := readRepoFile(t, "../../../docs/operations.md")
	anchors := map[string]bool{}
	for _, heading := range regexp.MustCompile(`(?m)^#{2,3} (.+)$`).FindAllStringSubmatch(operations, -1) {
		slug := strings.ToLower(strings.TrimSpace(heading[1]))
		slug = regexp.MustCompile(`[^a-z0-9 -]`).ReplaceAllString(slug, "")
		anchors[strings.ReplaceAll(slug, " ", "-")] = true
	}
	for _, file := range []string{selfHostRulesFile, clusterRulesFile} {
		rules := readRepoFile(t, filepath.Join(monitoringDir, file))
		// The shipped rules must fire wherever the server's metrics are
		// scraped, so they read only its own series and `up`: no
		// kube-state-metrics, node-exporter, kubelet or cert-manager series,
		// which many collectors (the owner's cluster among them) do not have.
		for _, line := range strings.Split(rules, "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "#") {
				continue
			}
			if foreign := regexp.MustCompile(`\b(kube|node|kubelet|certmanager|container)_[a-z_]+`).FindString(line); foreign != "" {
				t.Errorf("%s reads %s, which is not one of the server's own series", file, foreign)
			}
		}
		for _, name := range regexp.MustCompile(`veritra_[a-z_]+`).FindAllString(rules, -1) {
			if _, ok := exported[name]; !ok {
				t.Errorf("%s reads %s, which the server does not export", file, name)
			}
		}
		checked := map[string]bool{}
		for _, anchor := range regexp.MustCompile(`docs/operations\.md#([a-z0-9-]+)`).FindAllStringSubmatch(rules, -1) {
			if !anchors[anchor[1]] && !checked[anchor[1]] {
				t.Errorf("%s: runbook anchor #%s is not a heading in docs/operations.md", file, anchor[1])
			}
			checked[anchor[1]] = true
		}
		for _, alert := range regexp.MustCompile(`alert: (Veritra[A-Za-z]+)`).FindAllStringSubmatch(rules, -1) {
			if !strings.Contains(operations, "`"+alert[1]+"`") {
				t.Errorf("%s: alert %s has no runbook entry in docs/operations.md", file, alert[1])
			}
		}
	}
}

type alertRule struct {
	group, name, text string
}

// parseAlertRules splits a rule file written in this repository's layout
// (group items at two spaces, rule items at six) into its rules, in order.
func parseAlertRules(t *testing.T, file string) []alertRule {
	t.Helper()
	_, body, ok := strings.Cut(readRepoFile(t, filepath.Join(monitoringDir, file)), "\ngroups:\n")
	if !ok {
		t.Fatalf("%s has no top-level groups", file)
	}
	var rules []alertRule
	group, current := "", -1
	for _, line := range strings.Split(body, "\n") {
		switch {
		case strings.HasPrefix(line, "  - name: "):
			group, current = strings.TrimPrefix(line, "  - name: "), -1
		case strings.HasPrefix(line, "      - alert: "):
			rules = append(rules, alertRule{group: group, name: strings.TrimPrefix(line, "      - alert: ")})
			current = len(rules) - 1
			rules[current].text = line + "\n"
		case current >= 0:
			rules[current].text += line + "\n"
		}
	}
	if len(rules) == 0 {
		t.Fatalf("%s has no alert rules", file)
	}
	return rules
}

// memoryThresholdMiB reads VeritraMemoryHigh's threshold, written as a
// product of numbers.
func memoryThresholdMiB(t *testing.T, file string, rules []alertRule) float64 {
	t.Helper()
	for _, rule := range rules {
		if rule.name != "VeritraMemoryHigh" {
			continue
		}
		match := regexp.MustCompile(`(?m)^ +expr: veritra_go_memory_bytes > ([0-9.]+(?: \* [0-9.]+)*)$`).FindStringSubmatch(rule.text)
		if match == nil {
			t.Fatalf("%s: VeritraMemoryHigh is not `veritra_go_memory_bytes > <product>`:\n%s", file, rule.text)
		}
		product := 1.0
		for _, factor := range strings.Split(match[1], " * ") {
			value, err := strconv.ParseFloat(factor, 64)
			if err != nil {
				t.Fatal(err)
			}
			product *= value
		}
		return product / (1 << 20)
	}
	t.Fatalf("%s has no VeritraMemoryHigh", file)
	return 0
}

func readInfraClusterFixture(t *testing.T) (keepRegex string, memoryLimitMiB float64) {
	t.Helper()
	for _, line := range strings.Split(readRepoFile(t, infraClusterFixture), "\n") {
		if key, value, ok := strings.Cut(line, ": "); ok && !strings.HasPrefix(line, "#") {
			switch key {
			case "keep_regex":
				keepRegex = value
			case "memory_limit_mib":
				limit, err := strconv.ParseFloat(value, 64)
				if err != nil {
					t.Fatal(err)
				}
				memoryLimitMiB = limit
			}
		}
	}
	if keepRegex == "" || memoryLimitMiB <= 0 {
		t.Fatalf("%s needs keep_regex and memory_limit_mib", infraClusterFixture)
	}
	return keepRegex, memoryLimitMiB
}

// The cluster profile is the self-host rules with exactly two differences:
// rules reading series that stay on the host are left out, and the memory
// threshold follows the server container's limit. Anything else is drift.
func TestClusterAlertProfileDiffersOnlyWhereItMust(t *testing.T) {
	selfHost := parseAlertRules(t, selfHostRulesFile)
	cluster := parseAlertRules(t, clusterRulesFile)
	var want []alertRule
	for _, rule := range selfHost {
		if !clusterOmittedAlerts[rule.name] {
			want = append(want, rule)
		}
	}
	if len(selfHost)-len(want) != len(clusterOmittedAlerts) {
		t.Errorf("the self-host profile no longer has every rule the cluster profile omits (%v)", clusterOmittedAlerts)
	}
	names := func(rules []alertRule) []string {
		out := make([]string, 0, len(rules))
		for _, rule := range rules {
			out = append(out, rule.group+"/"+rule.name)
		}
		return out
	}
	if strings.Join(names(want), " ") != strings.Join(names(cluster), " ") {
		t.Fatalf("cluster profile rules differ from the self-host ones:\n got  %v\n want %v", names(cluster), names(want))
	}
	withoutThreshold := func(text string) string {
		var kept []string
		for _, line := range strings.Split(text, "\n") {
			trimmed := strings.TrimSpace(line)
			if !strings.HasPrefix(trimmed, "#") && !strings.HasPrefix(trimmed, "expr: veritra_go_memory_bytes > ") {
				kept = append(kept, line)
			}
		}
		return strings.Join(kept, "\n")
	}
	for i, rule := range cluster {
		if rule.name == "VeritraMemoryHigh" {
			if withoutThreshold(rule.text) != withoutThreshold(want[i].text) {
				t.Errorf("cluster VeritraMemoryHigh differs from the self-host rule in more than its threshold:\n%s", rule.text)
			}
			continue
		}
		if rule.text != want[i].text {
			t.Errorf("cluster rule %s differs from the self-host rule; change both files together:\n got\n%s want\n%s", rule.name, rule.text, want[i].text)
		}
	}

	// Each profile warns at 80% of the memory limit its deployment sets,
	// so the alert can fire before the kernel kills the server.
	compose := readRepoFile(t, "../../../deploy/docker-compose.yml")
	_, messenger, _ := strings.Cut(compose, "\n  messenger:\n")
	composeLimit := regexp.MustCompile(`(?m)^    mem_limit: (\d+)g$`).FindStringSubmatch(messenger)
	systemdLimit := regexp.MustCompile(`(?m)^MemoryMax=(\d+)G$`).FindStringSubmatch(readRepoFile(t, "../../../deploy/systemd/private-messenger.service"))
	if composeLimit == nil || systemdLimit == nil || composeLimit[1] != systemdLimit[1] {
		t.Fatalf("Compose (%v) and systemd (%v) should set the same whole-GiB memory limit", composeLimit, systemdLimit)
	}
	selfHostLimit, _ := strconv.ParseFloat(composeLimit[1], 64)
	_, clusterLimit := readInfraClusterFixture(t)
	for _, profile := range []struct {
		file     string
		rules    []alertRule
		limitMiB float64
	}{
		{selfHostRulesFile, selfHost, selfHostLimit * 1024},
		{clusterRulesFile, cluster, clusterLimit},
	} {
		threshold := memoryThresholdMiB(t, profile.file, profile.rules)
		if threshold >= profile.limitMiB || math.Abs(threshold-0.8*profile.limitMiB) > 1e-6 {
			t.Errorf("%s: VeritraMemoryHigh fires at %.1f MiB; want 80%% of the %.0f MiB limit", profile.file, threshold, profile.limitMiB)
		}
	}
}

// Every series the cluster profile reads is forwarded by infra's collector
// (fixture copied from infra) and by the keep regex operations.md gives
// self-hosters, and neither forwards a per-route series: on an instance with
// a handful of people those read as their activity timeline.
func TestClusterAlertProfileReadsOnlyForwardedSeries(t *testing.T) {
	exported := exportedSeries(t)
	infraKeep, _ := readInfraClusterFixture(t)
	operations := readRepoFile(t, "../../../docs/operations.md")
	_, hosted, ok := strings.Cut(operations, "**Hosted metrics.**")
	docKeep := regexp.MustCompile("(?s)\n```\n([^\n]+)\n```\n").FindStringSubmatch(hosted)
	if !ok || docKeep == nil {
		t.Fatal(`docs/operations.md "Hosted metrics" has no keep regex block`)
	}
	keeps := []struct {
		source string
		keep   *regexp.Regexp
	}{
		// Prometheus anchors relabel regexes, and so does the collector.
		{infraClusterFixture, regexp.MustCompile("^(?:" + infraKeep + ")$")},
		{"docs/operations.md", regexp.MustCompile("^(?:" + docKeep[1] + ")$")},
	}
	rules := readRepoFile(t, filepath.Join(monitoringDir, clusterRulesFile))
	read := regexp.MustCompile(`veritra_[a-z_]+`).FindAllString(rules, -1)
	if len(read) == 0 {
		t.Fatal("the cluster profile reads no veritra_* series")
	}
	perRoute := 0
	for name, routed := range exported {
		if !routed {
			continue
		}
		perRoute++
		for _, k := range keeps {
			if k.keep.MatchString(name) {
				t.Errorf("%s forwards the per-route series %s", k.source, name)
			}
		}
	}
	if perRoute == 0 {
		t.Fatal("no per-route series exported; the privacy check above is vacuous")
	}
	for _, name := range read {
		for _, k := range keeps {
			if !k.keep.MatchString(name) {
				t.Errorf("%s reads %s, which %s does not forward", clusterRulesFile, name, k.source)
			}
		}
	}
	// infra's collector adds `up` itself; a Prometheus remote_write needs it
	// in the regex.
	if strings.Contains(rules, "up{") && !keeps[1].keep.MatchString("up") {
		t.Errorf("docs/operations.md keep regex drops `up`, which %s reads", clusterRulesFile)
	}
}
