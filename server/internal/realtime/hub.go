package realtime

import (
	"encoding/json"
	"sync"
	"time"
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
}

func NewHub() *Hub {
	return &Hub{subscribers: map[string]map[*Client]struct{}{}}
}

func (h *Hub) Register(accountID string) *Client {
	client := &Client{accountID: accountID, send: make(chan []byte, 32)}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.subscribers[accountID] == nil {
		h.subscribers[accountID] = map[*Client]struct{}{}
	}
	h.subscribers[accountID][client] = struct{}{}
	return client
}

func (h *Hub) Unregister(client *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if clients := h.subscribers[client.accountID]; clients != nil {
		delete(clients, client)
		if len(clients) == 0 {
			delete(h.subscribers, client.accountID)
		}
	}
	close(client.send)
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
	send      chan []byte
}

func (c *Client) Send() <-chan []byte {
	return c.send
}
