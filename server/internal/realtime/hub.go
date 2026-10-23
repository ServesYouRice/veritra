package realtime

import (
	"encoding/json"
	"errors"
	"sync"
	"sync/atomic"
	"time"
)

var (
	ErrConnectionLimit = errors.New("realtime connection limit reached")
	ErrHubDraining     = errors.New("realtime hub is draining")
)

const (
	maxConnections           = 10000
	maxConnectionsPerIP      = 20
	maxConnectionsPerAccount = 10
	maxConnectionsPerDevice  = 3
)

type Event struct {
	Version        string      `json:"version"`
	Type           string      `json:"type"`
	ID             int64       `json:"id,omitempty"`
	ConversationID string      `json:"conversation_id,omitempty"`
	Payload        interface{} `json:"payload,omitempty"`
	CreatedAt      time.Time   `json:"created_at"`
}

// Hub tracks live sockets. subscribers indexes sockets by account (which
// bounds per-account and per-device counting to at most
// maxConnectionsPerAccount entries) and perIP counts sockets per remote
// address, so Register never scans every live socket. Every removal goes
// through removeLocked so the indexes and total stay consistent.
type Hub struct {
	mu          sync.RWMutex
	subscribers map[string]map[*Client]struct{}
	perIP       map[string]int
	draining    bool
	total       int
	// Aggregate counters for the private metrics endpoint (card I47).
	dropped          atomic.Int64
	rejectedLimit    atomic.Int64
	rejectedDraining atomic.Int64
}

func NewHub() *Hub {
	return &Hub{subscribers: map[string]map[*Client]struct{}{}, perIP: map[string]int{}}
}

// ConnectionCount returns only an aggregate operational gauge. It never
// exposes account, device, or network identifiers.
func (h *Hub) ConnectionCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.total
}

func (h *Hub) Register(accountID, deviceID, remoteIP string) (*Client, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.draining {
		h.rejectedDraining.Add(1)
		return nil, ErrHubDraining
	}
	accountClients := h.subscribers[accountID]
	accountCount, deviceCount, ipCount := len(accountClients), 0, h.perIP[remoteIP]
	// At most maxConnectionsPerAccount sockets can share an account.
	for existing := range accountClients {
		if existing.deviceID == deviceID {
			deviceCount++
		}
	}
	if h.total >= maxConnections || accountCount >= maxConnectionsPerAccount ||
		deviceCount >= maxConnectionsPerDevice || ipCount >= maxConnectionsPerIP {
		h.rejectedLimit.Add(1)
		return nil, ErrConnectionLimit
	}
	client := &Client{accountID: accountID, deviceID: deviceID, remoteIP: remoteIP, send: make(chan []byte, 32)}
	if h.subscribers[accountID] == nil {
		h.subscribers[accountID] = map[*Client]struct{}{}
	}
	h.subscribers[accountID][client] = struct{}{}
	h.perIP[remoteIP]++
	h.total++
	return client, nil
}

// removeLocked drops a registered client from every index. The caller holds
// h.mu and decides whether to close the client. Deleting the current key
// while ranging over a map is safe in Go.
func (h *Hub) removeLocked(clients map[*Client]struct{}, client *Client) {
	delete(clients, client)
	h.total--
	if n := h.perIP[client.remoteIP] - 1; n > 0 {
		h.perIP[client.remoteIP] = n
	} else {
		delete(h.perIP, client.remoteIP)
	}
	if len(clients) == 0 {
		delete(h.subscribers, client.accountID)
	}
}

func (h *Hub) Unregister(client *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if clients := h.subscribers[client.accountID]; clients != nil {
		if _, ok := clients[client]; ok {
			h.removeLocked(clients, client)
		}
	}
	client.Close()
}

func (h *Hub) DisconnectDevice(accountID, deviceID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	clients := h.subscribers[accountID]
	for client := range clients {
		if client.deviceID == deviceID {
			h.removeLocked(clients, client)
			client.Close()
		}
	}
}

func (h *Hub) DisconnectAccountExceptDevice(accountID, keepDeviceID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	clients := h.subscribers[accountID]
	for client := range clients {
		if client.deviceID != keepDeviceID {
			h.removeLocked(clients, client)
			client.Close()
		}
	}
}

func (h *Hub) DisconnectAccount(accountID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	clients := h.subscribers[accountID]
	for client := range clients {
		h.removeLocked(clients, client)
		client.Close()
	}
}

// Drain rejects new registrations and closes every hijacked connection.
func (h *Hub) Drain() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.draining = true
	for accountID, clients := range h.subscribers {
		for client := range clients {
			client.Close()
		}
		delete(h.subscribers, accountID)
	}
	clear(h.perIP)
	h.total = 0
}

// Publish sends a best-effort realtime copy of an already-durable event.
// If a client's bounded buffer is full, the event is dropped for that socket;
// clients must recover missed events through the DB-backed /sync/events API
// using their last observed event id.
func (h *Hub) Publish(accountIDs []string, event Event) {
	payload, err := json.Marshal(event)
	if err != nil {
		return
	}
	h.mu.RLock()
	clients := make([]*Client, 0)
	for _, accountID := range accountIDs {
		for client := range h.subscribers[accountID] {
			clients = append(clients, client)
		}
	}
	h.mu.RUnlock()
	for _, client := range clients {
		if !client.TrySend(payload) {
			h.dropped.Add(1)
		}
	}
}

// HubStats holds aggregate counters only: events dropped because a socket's
// buffer was full (the client recovers them through /sync/events) and
// registrations refused by a connection limit or while draining.
type HubStats struct {
	DroppedEvents    int64
	RejectedLimit    int64
	RejectedDraining int64
}

func (h *Hub) Stats() HubStats {
	return HubStats{DroppedEvents: h.dropped.Load(), RejectedLimit: h.rejectedLimit.Load(), RejectedDraining: h.rejectedDraining.Load()}
}

type Client struct {
	accountID string
	deviceID  string
	remoteIP  string
	send      chan []byte
	closeOnce sync.Once
	mu        sync.RWMutex
	closed    bool
}

// TrySend queues payload without blocking. It reports false when the
// socket's buffer was full and the event was dropped; a closed client is not
// counted as a drop.
func (c *Client) TrySend(payload []byte) bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.closed {
		return true
	}
	select {
	case c.send <- payload:
		return true
	default:
		return false
	}
}

func (c *Client) Send() <-chan []byte {
	return c.send
}

func (c *Client) Close() {
	c.closeOnce.Do(func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		c.closed = true
		close(c.send)
	})
}
