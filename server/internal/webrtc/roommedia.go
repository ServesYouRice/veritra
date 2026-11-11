package webrtc

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// RoomMedia is the seam to the selective forwarding unit (B6). The server
// only mints short-lived join tokens and checks the SFU's signed webhooks.
// It never touches media. A token names a random room and a random identity,
// never a conversation or account id.
type RoomMedia interface {
	// URL is the SFU address clients connect to.
	URL() string
	// JoinToken is valid for ttl and allows one identity into one room.
	JoinToken(room, identity string, now time.Time, ttl time.Duration) (string, error)
	// ParseWebhook checks the Authorization value against the body and
	// returns the event. A bad signature or body hash is an error.
	ParseWebhook(authorization string, body []byte, now time.Time) (RoomEvent, error)
}

// RoomEvent is the part of an SFU webhook the server uses.
type RoomEvent struct {
	Kind     string // "participant_left", "room_finished" or "other"
	Room     string
	Identity string
}

var ErrBadWebhook = errors.New("webhook signature is not valid")

// LiveKit implements RoomMedia for a LiveKit server (Apache-2.0), with its
// access-token and webhook formats (HS256 JWTs signed with the API secret).
type LiveKit struct {
	PublicURL string
	APIKey    string
	APISecret string
}

func (l LiveKit) URL() string { return l.PublicURL }

func b64(data []byte) string { return base64.RawURLEncoding.EncodeToString(data) }

func (l LiveKit) sign(claims map[string]any) (string, error) {
	header, _ := json.Marshal(map[string]string{"alg": "HS256", "typ": "JWT"})
	payload, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	signing := b64(header) + "." + b64(payload)
	mac := hmac.New(sha256.New, []byte(l.APISecret))
	_, _ = mac.Write([]byte(signing))
	return signing + "." + b64(mac.Sum(nil)), nil
}

func (l LiveKit) JoinToken(room, identity string, now time.Time, ttl time.Duration) (string, error) {
	if room == "" || identity == "" || l.APIKey == "" || l.APISecret == "" {
		return "", errors.New("room media is not configured")
	}
	return l.sign(map[string]any{
		"iss": l.APIKey,
		"sub": identity,
		"nbf": now.Add(-10 * time.Second).Unix(),
		"exp": now.Add(ttl).Unix(),
		"video": map[string]any{
			"room": room, "roomJoin": true,
			"canPublish": true, "canSubscribe": true, "canPublishData": false,
		},
	})
}

func (l LiveKit) ParseWebhook(authorization string, body []byte, now time.Time) (RoomEvent, error) {
	token := strings.TrimSpace(strings.TrimPrefix(authorization, "Bearer "))
	parts := strings.Split(token, ".")
	if len(parts) != 3 || l.APISecret == "" {
		return RoomEvent{}, ErrBadWebhook
	}
	mac := hmac.New(sha256.New, []byte(l.APISecret))
	_, _ = mac.Write([]byte(parts[0] + "." + parts[1]))
	got, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || subtle.ConstantTimeCompare(got, mac.Sum(nil)) != 1 {
		return RoomEvent{}, ErrBadWebhook
	}
	var header struct {
		Alg string `json:"alg"`
	}
	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil || json.Unmarshal(headerBytes, &header) != nil || header.Alg != "HS256" {
		return RoomEvent{}, ErrBadWebhook
	}
	claimBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return RoomEvent{}, ErrBadWebhook
	}
	var claims struct {
		Iss    string `json:"iss"`
		Exp    int64  `json:"exp"`
		Nbf    int64  `json:"nbf"`
		SHA256 string `json:"sha256"`
	}
	if json.Unmarshal(claimBytes, &claims) != nil || claims.Iss != l.APIKey {
		return RoomEvent{}, ErrBadWebhook
	}
	if claims.Exp == 0 || now.Unix() > claims.Exp+30 || (claims.Nbf != 0 && now.Unix() < claims.Nbf-30) {
		return RoomEvent{}, ErrBadWebhook
	}
	sum := sha256.Sum256(body)
	want := base64.StdEncoding.EncodeToString(sum[:])
	if subtle.ConstantTimeCompare([]byte(claims.SHA256), []byte(want)) != 1 {
		return RoomEvent{}, ErrBadWebhook
	}
	var event struct {
		Event string `json:"event"`
		Room  struct {
			Name string `json:"name"`
		} `json:"room"`
		Participant struct {
			Identity string `json:"identity"`
		} `json:"participant"`
	}
	if err := json.Unmarshal(body, &event); err != nil {
		return RoomEvent{}, ErrBadWebhook
	}
	out := RoomEvent{Kind: "other", Room: event.Room.Name, Identity: event.Participant.Identity}
	switch event.Event {
	case "participant_left":
		out.Kind = "participant_left"
	case "room_finished":
		out.Kind = "room_finished"
	}
	return out, nil
}
