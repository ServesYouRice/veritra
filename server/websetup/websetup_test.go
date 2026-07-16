package websetup

import (
	"strings"
	"testing"
)

func TestSetupNoticeFailsClosed(t *testing.T) {
	page, err := FS.ReadFile("index.html")
	if err != nil {
		t.Fatalf("read setup page: %v", err)
	}

	body := string(page)
	for _, required := range []string{
		"Setup Is Not Available In This Build",
		"Keep this instance private.",
		"Never use a placeholder or test key package.",
		"PRIVATE_MESSENGER_SETUP_TOKEN",
	} {
		if !strings.Contains(body, required) {
			t.Fatalf("setup page missing %q", required)
		}
	}
	if strings.Contains(body, "<form") {
		t.Fatal("setup page must not expose a form before production crypto is available")
	}
}
