package httpapi

import "strings"

// RouteClass is the fixed per-address budget a route falls under in the
// outer rate limiter (docs/operations.md, "Credential abuse controls").
type RouteClass int

const (
	// OrdinaryRoute is every route without a fixed budget.
	OrdinaryRoute RouteClass = iota
	// CredentialRoute is a route that checks a password, a recovery
	// secret or a device-link claim token: 10 a minute per address.
	CredentialRoute
	// EnrollmentRoute is a route that reserves an enrollment against an
	// invite, setup or device-link code: 5 a minute per address.
	EnrollmentRoute
	// PublicRoute is a route that never looks a session token up (health,
	// readiness, setup status): it stays on the address's general budget
	// whatever Authorization header it carries.
	PublicRoute
)

// credentialRoutes, enrollmentRoutes and publicRoutes are exact routes in
// Register. The
// mux reaches their handlers only for exactly these decoded paths: it
// redirects a path that is not clean, and another spelling (a trailing
// slash, an encoded slash) matches no route or one that answers 404.
var (
	credentialRoutes = map[string]bool{
		"/api/v1/setup/owner":        true,
		"/api/v1/auth/login":         true,
		"/api/v1/auth/reauth":        true,
		"/api/v1/register":           true,
		"/api/v1/recovery":           true,
		"/api/v1/device-links/claim": true,
	}
	enrollmentRoutes = map[string]bool{
		"/api/v1/setup/owner/enrollment":        true,
		"/api/v1/register/enrollment":           true,
		"/api/v1/device-links/claim-enrollment": true,
	}
	publicRoutes = map[string]bool{
		"/livez":               true,
		"/healthz":             true,
		"/readyz":              true,
		"/api/v1/health":       true,
		"/setup":               true,
		"/api/v1/setup/status": true,
	}
)

// ClassifyRoute returns the budget for a request to urlPath (the decoded
// r.URL.Path the handlers read). Paths under /api/v1/device-links/ are
// split exactly as deviceLinkSubroute splits them, so a spelling that
// reaches the claim-status handler (a trailing slash, an encoded slash) is
// always a credential request. Any other path ending in /enrollment stays
// an enrollment request, as before.
func ClassifyRoute(urlPath string) RouteClass {
	switch {
	case credentialRoutes[urlPath]:
		return CredentialRoute
	case enrollmentRoutes[urlPath], strings.HasSuffix(urlPath, "/enrollment"):
		return EnrollmentRoute
	case publicRoutes[urlPath]:
		return PublicRoute
	}
	if strings.HasPrefix(urlPath, deviceLinkPrefix) {
		if parts := deviceLinkPathParts(urlPath); len(parts) == 2 && parts[1] == "claim-status" {
			return CredentialRoute
		}
	}
	return OrdinaryRoute
}

const deviceLinkPrefix = "/api/v1/device-links/"

// deviceLinkPathParts splits a path under /api/v1/device-links/ for
// deviceLinkSubroute: surrounding slashes are ignored.
func deviceLinkPathParts(urlPath string) []string {
	return strings.Split(strings.Trim(strings.TrimPrefix(urlPath, deviceLinkPrefix), "/"), "/")
}
