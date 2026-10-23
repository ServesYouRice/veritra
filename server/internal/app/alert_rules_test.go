package app

import (
	"context"
	"io"
	"log/slog"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/config"
)

const monitoringDir = "../../../deploy/kubernetes/examples/monitoring"

func readRepoFile(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// The plain rule file and the PrometheusRule must hold the same groups.
func TestAlertRuleFilesMatch(t *testing.T) {
	plain := readRepoFile(t, filepath.Join(monitoringDir, "veritra-alerts.rules.yml"))
	operator := readRepoFile(t, filepath.Join(monitoringDir, "prometheus-rules.yaml"))
	plainGroups := plain[strings.Index(plain, "\ngroups:\n")+1:]
	spec := operator[strings.Index(operator, "\nspec:\n")+len("\nspec:\n"):]
	var dedented []string
	for _, line := range strings.Split(spec, "\n") {
		dedented = append(dedented, strings.TrimPrefix(line, "  "))
	}
	if strings.TrimSpace(strings.Join(dedented, "\n")) != strings.TrimSpace(plainGroups) {
		t.Fatal("prometheus-rules.yaml and veritra-alerts.rules.yml hold different rules")
	}
}

// Every veritra_* series an alert reads must be one the server exports, and
// every runbook link must point at an existing operations.md heading.
func TestAlertRulesReferenceExportedMetricsAndRunbooks(t *testing.T) {
	dir := t.TempDir()
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
		if name, _, ok := strings.Cut(line, " "); ok && !strings.HasPrefix(line, "#") {
			name, _, _ = strings.Cut(name, "{")
			exported[name] = true
		}
	}
	rules := readRepoFile(t, filepath.Join(monitoringDir, "veritra-alerts.rules.yml"))
	for _, name := range regexp.MustCompile(`veritra_[a-z_]+`).FindAllString(rules, -1) {
		if !exported[name] {
			t.Errorf("alert rules read %s, which the server does not export", name)
		}
	}
	operations := readRepoFile(t, "../../../docs/operations.md")
	anchors := map[string]bool{}
	for _, heading := range regexp.MustCompile(`(?m)^#{2,3} (.+)$`).FindAllStringSubmatch(operations, -1) {
		slug := strings.ToLower(strings.TrimSpace(heading[1]))
		slug = regexp.MustCompile(`[^a-z0-9 -]`).ReplaceAllString(slug, "")
		anchors[strings.ReplaceAll(slug, " ", "-")] = true
	}
	checked := map[string]bool{}
	for _, anchor := range regexp.MustCompile(`docs/operations\.md#([a-z0-9-]+)`).FindAllStringSubmatch(rules, -1) {
		if !anchors[anchor[1]] && !checked[anchor[1]] {
			t.Errorf("runbook anchor #%s is not a heading in docs/operations.md", anchor[1])
		}
		checked[anchor[1]] = true
	}
	for _, alert := range regexp.MustCompile(`alert: (Veritra[A-Za-z]+)`).FindAllStringSubmatch(rules, -1) {
		if !strings.Contains(operations, "`"+alert[1]+"`") {
			t.Errorf("alert %s has no runbook entry in docs/operations.md", alert[1])
		}
	}
}
