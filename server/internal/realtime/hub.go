package realtime

import (
	"encoding/json"
	"errors"
	"sync"
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

type Hub struct {
	mu          sync.RWMutex
	subscribers map[string]map[*Client]struct{}
	draining    bool
	total       int
}

func NewHub() *Hub {
	return &Hub{subscribers: map[string]map[*Client]struct{}{}}
}

func (h *Hub) Register(accountID, deviceID, remoteIP string) (*Client, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.draining {
		return nil, ErrHubDraining
	}
	accountCount, deviceCount, ipCount := 0, 0, 0
	for _, clients := range h.subscribers {
		for existing := range clients {
			if existing.accountID == accountID {
				accountCount++
			}
			if existing.accountID == accountID && existing.deviceID == deviceID {
				deviceCount++
			}
			if existing.remoteIP == remoteIP {
				ipCount++
			}
		}
	}
	if h.total >= maxConnections || accountCount >= maxConnectionsPerAccount ||
		deviceCount >= maxConnectionsPerDevice || ipCount >= maxConnectionsPerIP {
		return nil, ErrConnectionLimit
	}
	client := &Client{accountID: accountID, deviceID: deviceID, remoteIP: remoteIP, send: make(chan []byte, 32)}
	if h.subscribers[accountID] == nil {
		h.subscribers[accountID] = map[*Client]struct{}{}
	}
	h.subscribers[accountID][client] = struct{}{}
	h.total++
	return client, nil
}

func (h *Hub) Unregister(client *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if clients := h.subscribers[client.accountID]; clients != nil {
		if _, ok := clients[client]; ok {
			delete(clients, client)
			h.total--
		}
		if len(clients) == 0 {
			delete(h.subscribers, client.accountID)
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
			delete(clients, client)
			h.total--
			client.Close()
		}
	}
	if len(clients) == 0 {
		delete(h.subscribers, accountID)
	}
}

func (h *Hub) DisconnectAccountExceptDevice(accountID, keepDeviceID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	clients := h.subscribers[accountID]
	for client := range clients {
		if client.deviceID != keepDeviceID {
			delete(clients, client)
			h.total--
			client.Close()
		}
	}
	if len(clients) == 0 {
		delete(h.subscribers, accountID)
	}
}

func (h *Hub) DisconnectAccount(accountID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for client := range h.subscribers[accountID] {
		client.Close()
		h.total--
	}
	delete(h.subscribers, accountID)
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
	defer h.mu.RUnlock()
	for _, accountID := range accountIDs {
		for client := range h.subscribers[accountID] {
			select {
			case client.send <- payload:
			default:
			}
		}
	}
}

type Client struct {
	accountID string
	deviceID  string
	remoteIP  string
	send      chan []byte
	closeOnce sync.Once
}

func (c *Client) Send() <-chan []byte {
	return c.send
}

func (c *Client) Close() {
	c.closeOnce.Do(func() {
		close(c.send)
	})
}
