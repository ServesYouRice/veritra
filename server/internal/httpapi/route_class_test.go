package httpapi

import (
	"net/http/httptest"
	"testing"
)

func TestClassifyRoute(t *testing.T) {
	for target, want := range map[string]RouteClass{
		"/api/v1/setup/owner":                            CredentialRoute,
		"/api/v1/auth/login":                             CredentialRoute,
		"/api/v1/auth/reauth":                            CredentialRoute,
		"/api/v1/register":                               CredentialRoute,
		"/api/v1/recovery":                               CredentialRoute,
		"/api/v1/device-links/claim":                     CredentialRoute,
		"/api/v1/device-links/v3/claim":                  CredentialRoute,
		"/api/v1/device-links/v3/link_1/claim-status":    CredentialRoute,
		"/api/v1/device-links/v3/link_1%2Fclaim-status":  CredentialRoute,
		"/api/v1/device-links/v3/link_1/complete":        CredentialRoute,
		"/api/v1/device-links/v3/link_1%2Fcomplete":      CredentialRoute,
		"/api/v1/device-links/v3/claim-enrollment":       EnrollmentRoute,
		"/api/v1/device-links/link_1/claim-status":       CredentialRoute,
		"/api/v1/device-links/link_1/claim-status/":      CredentialRoute,
		"/api/v1/device-links/link_1%2Fclaim-status":     CredentialRoute,
		"/api/v1/device-links/link_1%2Fclaim-status%2F":  CredentialRoute,
		"/api/v1/setup/owner/enrollment":                 EnrollmentRoute,
		"/api/v1/register/enrollment":                    EnrollmentRoute,
		"/api/v1/device-links/claim-enrollment":          EnrollmentRoute,
		"/api/v1/recovery/secret":                        OrdinaryRoute,
		"/api/v1/auth/logout":                            OrdinaryRoute,
		"/api/v1/device-links":                           OrdinaryRoute,
		"/api/v1/device-links/link_1":                    OrdinaryRoute,
		"/api/v1/device-links/link_1/approve":            OrdinaryRoute,
		"/api/v1/device-links/link_1/claim-status/extra": OrdinaryRoute,
		"/api/v1/device-links/a/b/claim-status":          OrdinaryRoute,
		"/api/v1/conversations/conv_1/messages":          OrdinaryRoute,
		"/api/v1/conversations/claim-status":             OrdinaryRoute,
		"/api/v1/sync/events":                            OrdinaryRoute,
		"/livez":                                         PublicRoute,
		"/healthz":                                       PublicRoute,
		"/readyz":                                        PublicRoute,
		"/api/v1/health":                                 PublicRoute,
		"/setup":                                         PublicRoute,
		"/api/v1/setup/status":                           PublicRoute,
		"/api/v1/health/":                                OrdinaryRoute,
	} {
		// The decoded path, as the limiter and the handlers read it.
		path := httptest.NewRequest("GET", target, nil).URL.Path
		if got := ClassifyRoute(path); got != want {
			t.Errorf("ClassifyRoute(%q) = %d, want %d", target, got, want)
		}
	}
	// The claim-status test reads the parts the handler routes on.
	if parts := deviceLinkPathParts("/api/v1/device-links/link_1/claim-status/"); len(parts) != 2 || parts[0] != "link_1" || parts[1] != "claim-status" {
		t.Fatalf("parts=%q", parts)
	}
}
