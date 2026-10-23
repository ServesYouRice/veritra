package httpapi

import (
	"context"
	"net/http"
	"strconv"
)

// RequestBudget is the request-rate charge that the outer rate limiter puts
// on a request carrying a session token. The limiter cannot tell a valid
// token from a guess, so it first charges the client address's budget for
// requests without a session. Once the token resolves to a session,
// Authenticated moves the charge to that account's budget at the address,
// so people sharing one address (a household or an office behind one
// router) do not use up each other's requests. It reports false, with a
// Retry-After in seconds, when the account's budget is spent. A token that
// never resolves stays charged to the address.
type RequestBudget interface {
	Authenticated(accountID string) (ok bool, retryAfterSeconds int)
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
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	http.Error(w, "rate limited", http.StatusTooManyRequests)
	return false
}
