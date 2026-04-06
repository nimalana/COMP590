// main.go — Sleeping Barber: Go implementation
// COMP SCI 590  Spring 2026  Assignment 6
//
// Run with:  go run main.go

package main

import (
	"fmt"
	"math/rand"
	"time"
)

// ---------------------------------------------------------------------------
// Config — all tunable parameters in one place, no magic numbers elsewhere
// ---------------------------------------------------------------------------
const (
	TotalCustomers   = 20
	WaitingRoomCap   = 5
	ArrivalMinMs     = 500
	ArrivalMaxMs     = 2000
	HaircutMinMs     = 1000
	HaircutMaxMs     = 4000
	SatisfyThreshold = 3.0   // seconds per star lost
	GracePeriodMs    = 25000 // worst-case drain: WaitingRoomCap × HaircutMaxMs + margin
)

// ---------------------------------------------------------------------------
// Message types — explicit structs, no raw primitives on channels
// ---------------------------------------------------------------------------
type MsgKind int

const (
	MsgArrive MsgKind = iota
	MsgAdmitted
	MsgTurnedAway
	MsgNextCustomer
	MsgCustomerReady
	MsgNoneWaiting
	MsgWakeUp
	MsgRateRequest
	MsgRating
	MsgGetStats
	MsgStatsReply
	MsgShutdown
	MsgHaircutStarting // extra: lets customer record exact wait-end time
)

// Message is the single message type passed on all channels.
// From carries the reply-to / sender identity channel.
// Stats payload fields are used only in MsgStatsReply.
type Message struct {
	Kind       MsgKind
	From       chan Message // reply-to / sender identity
	CustomerID int
	Value      int   // rating or other integer payload
	ArrivalMs  int64 // customer arrival timestamp (ms)
	// Stats reply payload
	Cuts       int
	AvgDurMs   float64
	AvgRating  float64
	TurnedAway int
	QueueLen   int
}

// ---------------------------------------------------------------------------
// Logging — every line carries elapsed time and the actor's name
// ---------------------------------------------------------------------------
var startMs = time.Now().UnixMilli()

func logf(actor, format string, args ...any) {
	elapsed := time.Now().UnixMilli() - startMs
	fmt.Printf("[+%dms] [%s] %s\n", elapsed, actor, fmt.Sprintf(format, args...))
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------
func clamp(lo, hi, v int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func randDuration(minMs, maxMs int) time.Duration {
	return time.Duration(minMs+rand.Intn(maxMs-minMs+1)) * time.Millisecond
}

// ---------------------------------------------------------------------------
// Customer — one goroutine per customer.
// State: id, arrivalMs (goroutine-local variables).
//
// Message flow:
//   out: MsgArrive          → WaitingRoom  (with own mailbox as From)
//   in:  MsgAdmitted        ← WaitingRoom
//    or  MsgTurnedAway      ← WaitingRoom
//   in:  MsgHaircutStarting ← Barber       (records wait time)
//   in:  MsgRateRequest     ← Barber       (From = ratingCh)
//   out: MsgRating          → ratingCh
// ---------------------------------------------------------------------------
func runCustomer(id int, arrivalMs int64, waitingRoom chan Message) {
	name := fmt.Sprintf("Customer-%d", id)
	mailbox := make(chan Message, 4) // buffered so senders never block

	logf(name, "arrived")
	waitingRoom <- Message{
		Kind:       MsgArrive,
		From:       mailbox,
		CustomerID: id,
		ArrivalMs:  arrivalMs,
	}

	// Wait for admitted or turned_away.
	reply := <-mailbox
	switch reply.Kind {
	case MsgTurnedAway:
		logf(name, "turned away — waiting room full")
		return

	case MsgAdmitted:
		logf(name, "admitted to waiting room, waiting for barber")

		// Wait for haircut-starting signal so we can record when the wait ended.
		msg := <-mailbox
		if msg.Kind != MsgHaircutStarting {
			return
		}
		haircutStart := time.Now().UnixMilli()
		waitSecs := float64(haircutStart-arrivalMs) / 1000.0
		logf(name, "haircut starting — waited %.2fs", waitSecs)

		// Wait for rate request; msg.From is the barber's dedicated rating channel.
		msg = <-mailbox
		if msg.Kind != MsgRateRequest {
			return
		}
		score := computeRating(waitSecs)
		logf(name, "giving %d/5 stars (waited %.2fs)", score, waitSecs)
		msg.From <- Message{Kind: MsgRating, Value: score, CustomerID: id}
		// Customer exits after sending rating.
	}
}

// computeRating applies: clamp(1, 5, 5 - floor(waitSecs/threshold) + jitter)
func computeRating(waitSecs float64) int {
	jitter := rand.Intn(3) - 1 // rand.Intn(3) → 0,1,2  ⇒  -1, 0, +1
	score := 5 - int(waitSecs/SatisfyThreshold) + jitter
	return clamp(1, 5, score)
}

// ---------------------------------------------------------------------------
// WaitingRoom — single long-lived goroutine.
// State: queue, turnedAway, barberSleeping, barberTrafficCh (all goroutine-local).
//
// Sleeping/waking handshake:
//   barberSleeping = true  when MsgNoneWaiting is sent.
//   barberSleeping = false when MsgWakeUp is sent.
//   Wakeup is sent exactly once per sleep cycle.
// ---------------------------------------------------------------------------
type queueEntry struct {
	ch         chan Message
	customerID int
}

func runWaitingRoom(mailbox chan Message) {
	queue := make([]queueEntry, 0, WaitingRoomCap)
	turnedAway := 0
	barberSleeping := false
	var barberTrafficCh chan Message // stored from next_customer for wakeup

	for {
		msg := <-mailbox
		switch msg.Kind {

		case MsgArrive:
			cid, cch := msg.CustomerID, msg.From
			if len(queue) >= WaitingRoomCap {
				logf("WaitingRoom", "Customer-%d turned away (%d/%d seats full)",
					cid, len(queue), WaitingRoomCap)
				cch <- Message{Kind: MsgTurnedAway}
				turnedAway++
			} else {
				queue = append(queue, queueEntry{ch: cch, customerID: cid})
				logf("WaitingRoom", "Customer-%d admitted (%d/%d seats used)",
					cid, len(queue), WaitingRoomCap)
				cch <- Message{Kind: MsgAdmitted}
				// Wake barber exactly once per sleep cycle.
				if barberSleeping && barberTrafficCh != nil {
					logf("WaitingRoom", "Barber is sleeping — sending wakeup")
					barberTrafficCh <- Message{Kind: MsgWakeUp}
					barberSleeping = false
				}
			}

		case MsgNextCustomer:
			barberTrafficCh = msg.From // remember for wakeup
			if len(queue) == 0 {
				logf("WaitingRoom", "No customers waiting — barber will sleep")
				barberTrafficCh <- Message{Kind: MsgNoneWaiting}
				barberSleeping = true
			} else {
				entry := queue[0]
				queue = queue[1:]
				logf("WaitingRoom", "Sending Customer-%d to barber (%d still waiting)",
					entry.customerID, len(queue))
				barberTrafficCh <- Message{
					Kind:       MsgCustomerReady,
					From:       entry.ch,
					CustomerID: entry.customerID,
				}
			}

		case MsgGetStats:
			msg.From <- Message{
				Kind:       MsgStatsReply,
				TurnedAway: turnedAway,
				QueueLen:   len(queue),
			}

		case MsgShutdown:
			logf("WaitingRoom", "shutdown — %d customer(s) still queued", len(queue))
			return
		}
	}
}

// ---------------------------------------------------------------------------
// Barber — single long-lived goroutine.
// State: cuts, avgDurMs, avgRating (goroutine-local variables).
//
// Two input channels:
//   trafficCh  — WaitingRoom messages: customer_ready, none_waiting, wakeup
//   controlCh  — ShopOwner messages:   get_stats, shutdown
//
// select is used in both the main loop and the sleep loop to wait on BOTH
// channels simultaneously, so control messages are never missed.
// ---------------------------------------------------------------------------
func runBarber(trafficCh, controlCh chan Message, wr chan Message) {
	cuts := 0
	avgDurMs := 0.0
	avgRating := 0.0

	logf("Barber", "Open for business — requesting first customer")
	wr <- Message{Kind: MsgNextCustomer, From: trafficCh}

	for {
		// select lets the barber react to WR traffic OR control messages,
		// whichever arrives first.
		select {
		case msg := <-trafficCh:
			switch msg.Kind {
			case MsgCustomerReady:
				cuts, avgDurMs, avgRating =
					handleHaircut(msg.From, msg.CustomerID, cuts, avgDurMs, avgRating)
				wr <- Message{Kind: MsgNextCustomer, From: trafficCh}

			case MsgNoneWaiting:
				logf("Barber", "No customers — going to sleep")
				shutdown := barberSleepLoop(trafficCh, controlCh, cuts, avgDurMs, avgRating)
				if shutdown {
					return
				}
				logf("Barber", "Woken up! Requesting next customer")
				wr <- Message{Kind: MsgNextCustomer, From: trafficCh}

			case MsgWakeUp:
				// Wakeup in main loop means we were never truly sleeping; ignore.
				logf("Barber", "Spurious wakeup in main loop — ignored")
			}

		case msg := <-controlCh:
			switch msg.Kind {
			case MsgGetStats:
				msg.From <- Message{
					Kind:      MsgStatsReply,
					Cuts:      cuts,
					AvgDurMs:  avgDurMs,
					AvgRating: avgRating,
				}
			case MsgShutdown:
				logf("Barber", "Shutdown received — closing up")
				return
			}
		}
	}
}

// handleHaircut runs a full haircut cycle and returns updated statistics.
// A per-haircut ratingCh is used so the rating reply is isolated from other
// traffic on trafficCh.
func handleHaircut(
	customerCh chan Message,
	customerID int,
	cuts int,
	avgDurMs, avgRating float64,
) (int, float64, float64) {
	durationMs := HaircutMinMs + rand.Intn(HaircutMaxMs-HaircutMinMs+1)

	logf("Barber", "Starting haircut for Customer-%d (planned: %dms)", customerID, durationMs)

	// ratingCh is used as both the reply channel for the rate request and as
	// the From identity passed in MsgHaircutStarting so the customer can reply.
	ratingCh := make(chan Message, 1)
	customerCh <- Message{Kind: MsgHaircutStarting, From: ratingCh}

	// Simulate the haircut.
	time.Sleep(time.Duration(durationMs) * time.Millisecond)

	logf("Barber", "Finished haircut for Customer-%d — requesting rating", customerID)
	customerCh <- Message{Kind: MsgRateRequest, From: ratingCh}

	// Wait for rating on the dedicated per-haircut channel.
	ratingMsg := <-ratingCh
	score := ratingMsg.Value
	newCuts := cuts + 1
	newAvgDur := (avgDurMs*float64(cuts) + float64(durationMs)) / float64(newCuts)
	newAvgRating := (avgRating*float64(cuts) + float64(score)) / float64(newCuts)

	logf("Barber",
		"Rating from Customer-%d: %d/5. Totals → cuts=%d, avg_dur=%.2fs, avg_rating=%.2f",
		customerID, score, newCuts, newAvgDur/1000.0, newAvgRating)

	return newCuts, newAvgDur, newAvgRating
}

// barberSleepLoop blocks until wakeup or shutdown.
// Uses select to wait on trafficCh and controlCh simultaneously so get_stats
// requests are answered even while the barber is sleeping.
// Returns true if the barber should exit (shutdown received).
func barberSleepLoop(
	trafficCh, controlCh chan Message,
	cuts int, avgDurMs, avgRating float64,
) bool {
	for {
		select {
		case msg := <-trafficCh:
			if msg.Kind == MsgWakeUp {
				return false // customer arrived; resume normal operation
			}

		case msg := <-controlCh:
			switch msg.Kind {
			case MsgGetStats:
				msg.From <- Message{
					Kind:      MsgStatsReply,
					Cuts:      cuts,
					AvgDurMs:  avgDurMs,
					AvgRating: avgRating,
				}
			case MsgShutdown:
				logf("Barber", "Shutdown received while sleeping")
				return true
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Shop Owner — drives the simulation lifecycle (runs in main goroutine).
// State: customers spawned (loop counter, goroutine-local).
// ---------------------------------------------------------------------------
func runShopOwner() {
	wrMailbox := make(chan Message, WaitingRoomCap*2)
	barberTrafficCh := make(chan Message, 4) // buffered ≥ 1 prevents wakeup race
	barberControlCh := make(chan Message, 4)

	go runWaitingRoom(wrMailbox)
	go runBarber(barberTrafficCh, barberControlCh, wrMailbox)

	logf("ShopOwner", "Opening barbershop")

	for i := 1; i <= TotalCustomers; i++ {
		logf("ShopOwner", "Spawning customer %d of %d", i, TotalCustomers)
		arrivalMs := time.Now().UnixMilli()
		go runCustomer(i, arrivalMs, wrMailbox)

		if i < TotalCustomers {
			time.Sleep(randDuration(ArrivalMinMs, ArrivalMaxMs))
		}
	}

	logf("ShopOwner", "All %d customers spawned. Grace period: %dms",
		TotalCustomers, GracePeriodMs)
	time.Sleep(GracePeriodMs * time.Millisecond)

	// Collect stats from Barber and WaitingRoom before shutdown.
	// Use select to receive whichever replies first (order not guaranteed).
	barberReplyCh := make(chan Message, 1)
	wrReplyCh := make(chan Message, 1)

	barberControlCh <- Message{Kind: MsgGetStats, From: barberReplyCh}
	wrMailbox <- Message{Kind: MsgGetStats, From: wrReplyCh}

	var barberStats, wrStats Message
	gotBarber, gotWR := false, false
	for !gotBarber || !gotWR {
		select {
		case barberStats = <-barberReplyCh:
			gotBarber = true
		case wrStats = <-wrReplyCh:
			gotWR = true
		}
	}

	// Shutdown: barber first, then waiting room.
	logf("ShopOwner", "Shutdown initiated")
	barberControlCh <- Message{Kind: MsgShutdown}
	wrMailbox <- Message{Kind: MsgShutdown}

	// Brief pause so shutdown log lines appear before the report.
	time.Sleep(200 * time.Millisecond)

	printReport(barberStats, wrStats)
}

func printReport(barberStats, wrStats Message) {
	fmt.Println()
	fmt.Println("=== Barbershop Closing Report ===")
	fmt.Printf("Total customers arrived:   %d\n", TotalCustomers)
	fmt.Printf("Customers served:          %d\n", barberStats.Cuts)
	fmt.Printf("Customers turned away:     %d\n", wrStats.TurnedAway)
	fmt.Printf("Average haircut duration:  %.2fs\n", barberStats.AvgDurMs/1000.0)
	fmt.Printf("Average satisfaction:      %.1f / 5.0\n", barberStats.AvgRating)
	fmt.Println("=================================")
}

func main() {
	rand.Seed(time.Now().UnixNano()) //nolint:staticcheck — pre-1.20 compat
	runShopOwner()
}
