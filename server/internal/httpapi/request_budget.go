package httpapi

import (
	"context"
	"net/http"
	"strconv"
)

// RequestBudget is the request-rate charge that the outer rate limiter puts
// on a request carrying a session token. The limiter cannot tell a valid
// token from a guess, so it admits the request on its client address's
// budget for requests with a token (every account behind the address
// together) and settles the charge once the token has been looked up:
// Authenticated charges that account's budget at the address, so people
// sharing one address (a household or an office behind one router) do not
// use up each other's requests, and Unauthenticated charges the address's
// budget for requests without a session. Each reports false, with a
// Retry-After in seconds, when that budget is spent. Only the first call
// counts; a request that makes neither is charged as one without a
// session when it ends.
type RequestBudget interface {
	Authenticated(accountID string) (ok bool, retryAfterSeconds int)
	Unauthenticated() (ok bool, retryAfterSeconds int)
}

type requestBudgetKey struct{}

// WithRequestBudget attaches budget to a request's context.
func WithRequestBudget(ctx context.Context, budget RequestBudget) context.Context {
	return context.WithValue(ctx, requestBudgetKey{}, budget)
}

// HasBearerToken reports whether the request carries a bearer token, valid
// or not. The token itself is not returned.
func HasBearerToken(r *http.Request) bool {
	return bearerToken(r) != ""
}

// admitAccount charges an authenticated request to its account's request
// budget and answers 429 when it is spent, with the same body and
// Retry-After as the address limiter.
func admitAccount(w http.ResponseWriter, r *http.Request, accountID string) bool {
	budget, ok := r.Context().Value(requestBudgetKey{}).(RequestBudget)
	if !ok {
		return true
	}
	allowed, retryAfter := budget.Authenticated(accountID)
	if allowed {
		return true
	}
	writeRateLimited(w, retryAfter)
	return false
}

// refuseUnauthenticated answers a request whose bearer token is missing or
// did not resolve to a session: 401, or 429 once its address has spent its
// budget for requests without a session.
func refuseUnauthenticated(w http.ResponseWriter, r *http.Request) {
	if budget, ok := r.Context().Value(requestBudgetKey{}).(RequestBudget); ok {
		if allowed, retryAfter := budget.Unauthenticated(); !allowed {
			writeRateLimited(w, retryAfter)
			return
		}
	}
	writeError(w, http.StatusUnauthorized, "unauthorized")
}

func writeRateLimited(w http.ResponseWriter, retryAfter int) {
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	http.Error(w, "rate limited", http.StatusTooManyRequests)
}
