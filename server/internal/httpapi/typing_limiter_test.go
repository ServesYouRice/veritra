package httpapi

import (
	"fmt"
	"math/rand"
	"sync"
	"testing"
	"time"
)

var typingBase = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

func TestTypingThrottleWindow(t *testing.T) {
	api := &API{}
	if !api.allowTyping("a", "c", typingBase) {
		t.Fatal("first update must be admitted")
	}
	if api.allowTyping("a", "c", typingBase.Add(1999*time.Millisecond)) {
		t.Fatal("update within 2s must be throttled")
	}
	if !api.allowTyping("a", "c2", typingBase.Add(time.Second)) {
		t.Fatal("other conversation is a separate pair")
	}
	if !api.allowTyping("b", "c", typingBase.Add(time.Second)) {
		t.Fatal("other account is a separate pair")
	}
	if !api.allowTyping("a", "c", typingBase.Add(2*time.Second)) {
		t.Fatal("update at 2s must be admitted")
	}
	// A throttled call does not extend the window.
	if api.allowTyping("a", "c", typingBase.Add(3*time.Second)) {
		t.Fatal("throttled")
	}
	if !api.allowTyping("a", "c", typingBase.Add(4*time.Second)) {
		t.Fatal("window counts from the last admitted update")
	}
}

// Entries recorded just before a generation rotation must still throttle.
func TestTypingThrottleAcrossRotation(t *testing.T) {
	api := &API{}
	api.allowTyping("x", "c", typingBase) // starts generation at 0s
	if !api.allowTyping("a", "c", typingBase.Add(1900*time.Millisecond)) {
		t.Fatal("admit")
	}
	api.allowTyping("y", "c", typingBase.Add(2*time.Second)) // rotates
	if api.allowTyping("a", "c", typingBase.Add(3800*time.Millisecond)) {
		t.Fatal("entry in previous generation must throttle")
	}
	if !api.allowTyping("a", "c", typingBase.Add(3900*time.Millisecond)) {
		t.Fatal("admit after 2s")
	}
}

// Randomised comparison with an unbounded reference map.
func TestTypingMatchesReference(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	api := &API{}
	ref := map[string]time.Time{}
	now := typingBase
	for i := 0; i < 200_000; i++ {
		now = now.Add(time.Duration(rng.Intn(40)) * time.Millisecond)
		account := fmt.Sprintf("a%d", rng.Intn(50))
		conv := fmt.Sprintf("c%d", rng.Intn(5))
		key := account + "\x00" + conv
		want := true
		if last, ok := ref[key]; ok && now.Sub(last) < typingInterval {
			want = false
		}
		if want {
			ref[key] = now
		}
		if got := api.allowTyping(account, conv, now); got != want {
			t.Fatalf("step %d: got %v want %v", i, got, want)
		}
	}
}

func TestTypingExpiryBoundsState(t *testing.T) {
	api := &API{}
	for i := 0; i < 20_000; i++ {
		api.allowTyping(fmt.Sprintf("a%d", i), "c", typingBase)
	}
	if n := api.typing.entries(); n != 20_000 {
		t.Fatalf("entries=%d", n)
	}
	api.allowTyping("late", "c", typingBase.Add(2*typingInterval))
	if n := api.typing.entries(); n != 1 {
		t.Fatalf("stale entries must expire, have %d", n)
	}
}

func TestTypingHardMemoryBound(t *testing.T) {
	api := &API{}
	for i := 0; i < typingMaxEntries; i++ {
		if !api.allowTyping(fmt.Sprintf("a%d", i), "c", typingBase) {
			t.Fatalf("pair %d refused below the bound", i)
		}
	}
	if api.allowTyping("overflow", "c", typingBase.Add(time.Second)) {
		t.Fatal("new pair past the bound must be refused")
	}
	if n := api.typing.entries(); n != typingMaxEntries {
		t.Fatalf("entries=%d, bound %d", n, typingMaxEntries)
	}
	// A held pair whose window passed is still admitted at the bound, and
	// the bound keeps counting both generations after a rotation.
	if !api.allowTyping("a0", "c", typingBase.Add(2*time.Second)) {
		t.Fatal("held pair must be admitted after its window")
	}
	if api.allowTyping("overflow", "c", typingBase.Add(2*time.Second)) {
		t.Fatal("new pair must be refused while generations are full")
	}
	if n := api.typing.entries(); n > typingMaxEntries {
		t.Fatalf("entries=%d exceed bound", n)
	}
	if !api.allowTyping("overflow", "c", typingBase.Add(2*typingInterval+2*time.Second)) {
		t.Fatal("bound must clear once old generations expire")
	}
}

func TestTypingConcurrent(t *testing.T) {
	api := &API{}
	var wg sync.WaitGroup
	admitted := make([]int, 8)
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 1000; i++ {
				if api.allowTyping("shared", "c", typingBase) {
					admitted[g]++
				}
				api.allowTyping(fmt.Sprintf("a%d-%d", g, i), "c", typingBase.Add(time.Duration(i)*time.Millisecond))
			}
		}(g)
	}
	wg.Wait()
	total := 0
	for _, n := range admitted {
		total += n
	}
	if total != 1 {
		t.Fatalf("shared pair admitted %d times at one instant", total)
	}
}
