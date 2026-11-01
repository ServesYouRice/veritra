package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"

	"private-messenger/server/internal/mlswire/mlswiretest"
)

// device is one simulated client: an account's single device session. The
// token is held in memory only and never printed.
type device struct {
	index     int
	token     string
	accountID string
	deviceID  string
	ip        string // sent as X-Forwarded-For; the target must trust the tool
}

type apiClient struct {
	base *url.URL
	http *http.Client
}

// clientTimeout bounds every API request, response body included.
const clientTimeout = 2 * time.Minute

func newAPIClient(base *url.URL, connections int) *apiClient {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.MaxIdleConns = connections
	transport.MaxIdleConnsPerHost = connections
	transport.MaxConnsPerHost = 0
	return &apiClient{base: base, http: &http.Client{
		Transport: transport,
		Timeout:   clientTimeout,
		// checkTarget vetted only the -target host. Following a redirect
		// would send seeding and load (with X-Forwarded-For and custom
		// headers) to whatever host the Location names, so a redirect is
		// returned as its 3xx status, which expect turns into an error. The
		// API paths are fixed, so no supported target needs one.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
}

// statusError keeps only the status code: response bodies may carry
// identifiers and are never printed.
type statusError struct{ status int }

func (e statusError) Error() string { return fmt.Sprintf("HTTP %d", e.status) }

type request struct {
	method      string
	path        string
	dev         *device
	ip          string // overrides dev.ip when set
	body        []byte
	contentType string
	headers     map[string]string
}

// do sends one request and returns the status and, when out is non-nil,
// the decoded JSON body. discard drains the body without keeping it.
func (c *apiClient) do(ctx context.Context, req request, out any) (int, int64, error) {
	target := c.base.String() + req.path
	httpReq, err := http.NewRequestWithContext(ctx, req.method, target, bytes.NewReader(req.body))
	if err != nil {
		return 0, 0, err
	}
	if req.contentType != "" {
		httpReq.Header.Set("Content-Type", req.contentType)
	}
	ip := req.ip
	if req.dev != nil {
		if req.dev.token != "" {
			httpReq.Header.Set("Authorization", "Bearer "+req.dev.token)
		}
		if ip == "" {
			ip = req.dev.ip
		}
	}
	if ip != "" {
		httpReq.Header.Set("X-Forwarded-For", ip)
	}
	for key, value := range req.headers {
		httpReq.Header.Set(key, value)
	}
	resp, err := c.http.Do(httpReq)
	if err != nil {
		return 0, 0, err
	}
	defer resp.Body.Close()
	if out == nil || resp.StatusCode >= 300 {
		// A body that breaks off (truncated, reset, timed out) is a failed
		// transfer even after a 2xx status line.
		n, err := io.Copy(io.Discard, io.LimitReader(resp.Body, 128<<20))
		return resp.StatusCode, n, err
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return resp.StatusCode, int64(len(raw)), err
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return resp.StatusCode, int64(len(raw)), errors.New("response was not the expected JSON")
	}
	return resp.StatusCode, int64(len(raw)), nil
}

func (c *apiClient) json(ctx context.Context, method, path string, dev *device, ip string, in, out any, headers map[string]string) (int, error) {
	var body []byte
	if in != nil {
		var err error
		if body, err = json.Marshal(in); err != nil {
			return 0, err
		}
	}
	status, _, err := c.do(ctx, request{method: method, path: path, dev: dev, ip: ip, body: body, contentType: "application/json", headers: headers}, out)
	return status, err
}

// expect turns an unexpected status into an error. With no codes given any
// 2xx status is accepted.
func expect(status int, err error, want ...int) error {
	if err != nil {
		return err
	}
	if len(want) == 0 && status >= 200 && status < 300 {
		return nil
	}
	for _, code := range want {
		if status == code {
			return nil
		}
	}
	return statusError{status}
}

type enrollmentReservation struct {
	ID        string `json:"id"`
	Challenge []byte `json:"challenge"`
}

type sessionResponse struct {
	Token   string `json:"token"`
	Account struct {
		ID string `json:"id"`
	} `json:"account"`
	Device struct {
		ID string `json:"id"`
	} `json:"device"`
}

// enroll reserves an enrollment, proves possession of a fresh signing key
// over a synthetic key package (structurally valid, unsigned), and creates the account through path.
func (c *apiClient) enroll(ctx context.Context, reservePath, createPath, ip string, headers map[string]string, reserveBody, createBody map[string]any) (sessionResponse, error) {
	var reservation enrollmentReservation
	if err := expect(c.json(ctx, http.MethodPost, reservePath, nil, ip, reserveBody, &reservation, headers)); err != nil {
		return sessionResponse{}, fmt.Errorf("reserve enrollment: %w", err)
	}
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return sessionResponse{}, err
	}
	keyPackage := mlswiretest.KeyPackage()
	createBody["device_key_package"] = keyPackage
	createBody["enrollment_reservation_id"] = reservation.ID
	createBody["signing_key"] = []byte(publicKey)
	createBody["challenge_signature"] = ed25519.Sign(privateKey, enrollmentProof(reservation.Challenge, publicKey, keyPackage))
	var session sessionResponse
	if err := expect(c.json(ctx, http.MethodPost, createPath, nil, ip, createBody, &session, headers)); err != nil {
		return sessionResponse{}, fmt.Errorf("create account: %w", err)
	}
	if session.Token == "" || session.Account.ID == "" || session.Device.ID == "" {
		return sessionResponse{}, errors.New("create account: response lacks a session")
	}
	return session, nil
}

// linkDevice links a second device to owner's account through the public
// device-link API, acting as both devices: owner creates a link, the new
// device reserves an enrollment and claims the link with a fresh signing key
// and key package, owner approves the claimed transcript, and the new
// device collects its session from claim-status. The transcript hash and
// the claim and approval tags are random: the server only stores and
// compares them, and the comparison people make between two screens has
// no part in a synthetic load. The new device's unauthenticated requests
// come from ip. Codes and tokens are never printed.
func (c *apiClient) linkDevice(ctx context.Context, owner *device, ip, name string) (sessionResponse, error) {
	random := func(n int) ([]byte, error) {
		buf := make([]byte, n)
		_, err := rand.Read(buf)
		return buf, err
	}
	code, err := random(32)
	if err != nil {
		return sessionResponse{}, err
	}
	var created struct {
		DeviceLink struct {
			ID   string `json:"id"`
			Code string `json:"code"`
		} `json:"device_link"`
	}
	status, err := c.json(ctx, http.MethodPost, "/api/v1/device-links", owner, "", map[string]any{"code": hex.EncodeToString(code)}, &created, nil)
	if err := expect(status, err, http.StatusCreated); err != nil {
		return sessionResponse{}, fmt.Errorf("create device link: %w", err)
	}
	if created.DeviceLink.ID == "" || created.DeviceLink.Code == "" {
		return sessionResponse{}, errors.New("create device link: response lacks the link")
	}
	var reservation enrollmentReservation
	if err := expect(c.json(ctx, http.MethodPost, "/api/v1/device-links/claim-enrollment", nil, ip, map[string]any{"code": created.DeviceLink.Code}, &reservation, nil)); err != nil {
		return sessionResponse{}, fmt.Errorf("reserve link enrollment: %w", err)
	}
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return sessionResponse{}, err
	}
	keyPackage := mlswiretest.KeyPackage()
	transcript, err := random(sha256.Size)
	if err != nil {
		return sessionResponse{}, err
	}
	claimTag, err := random(sha256.Size)
	if err != nil {
		return sessionResponse{}, err
	}
	approvalTag, err := random(sha256.Size)
	if err != nil {
		return sessionResponse{}, err
	}
	var claimed struct {
		ClaimToken string `json:"claim_token"`
	}
	status, err = c.json(ctx, http.MethodPost, "/api/v1/device-links/claim", nil, ip, map[string]any{
		"code": created.DeviceLink.Code, "device_name": name, "enrollment_reservation_id": reservation.ID,
		"device_key_package": keyPackage, "signing_key": []byte(publicKey),
		"challenge_signature": ed25519.Sign(privateKey, enrollmentProof(reservation.Challenge, publicKey, keyPackage)),
		"transcript_hash":     transcript, "claim_tag": claimTag,
	}, &claimed, nil)
	if err := expect(status, err, http.StatusAccepted); err != nil {
		return sessionResponse{}, fmt.Errorf("claim device link: %w", err)
	}
	if claimed.ClaimToken == "" {
		return sessionResponse{}, errors.New("claim device link: response lacks a claim token")
	}
	linkPath := "/api/v1/device-links/" + url.PathEscape(created.DeviceLink.ID)
	status, err = c.json(ctx, http.MethodPost, linkPath+"/approve", owner, "", map[string]any{"transcript_hash": transcript, "approval_tag": approvalTag}, nil, nil)
	if err := expect(status, err, http.StatusOK); err != nil {
		return sessionResponse{}, fmt.Errorf("approve device link: %w", err)
	}
	var session sessionResponse
	status, err = c.json(ctx, http.MethodGet, linkPath+"/claim-status", nil, ip, nil, &session, map[string]string{"X-Veritra-Claim-Token": claimed.ClaimToken})
	if err := expect(status, err, http.StatusOK); err != nil {
		return sessionResponse{}, fmt.Errorf("collect linked session: %w", err)
	}
	if session.Token == "" || session.Account.ID != owner.accountID || session.Device.ID == "" || session.Device.ID == owner.deviceID {
		return sessionResponse{}, errors.New("collect linked session: response lacks a new device session")
	}
	return session, nil
}

// enrollmentProof mirrors the server's veritra-enrollment-proof-v1 message.
func enrollmentProof(challenge, signingKey, keyPackage []byte) []byte {
	keyPackageHash := sha256.Sum256(keyPackage)
	proof := []byte("veritra-enrollment-proof-v1")
	var challengeLength [2]byte
	binary.BigEndian.PutUint16(challengeLength[:], uint16(len(challenge)))
	proof = append(proof, challengeLength[:]...)
	proof = append(proof, challenge...)
	proof = append(proof, signingKey...)
	return append(proof, keyPackageHash[:]...)
}
