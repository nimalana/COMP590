# sleeping_barber.exs
# Sleeping Barber — Elixir / Actor-model implementation
# COMP SCI 590  Spring 2026  Assignment 6
#
# Run with:  elixir sleeping_barber.exs

# ---------------------------------------------------------------------------
# Configuration — all tunable constants live here, nowhere else.
# ---------------------------------------------------------------------------
defmodule SimConfig do
  def total_customers,        do: 20
  def waiting_room_capacity,  do: 5
  def arrival_min_ms,         do: 500
  def arrival_max_ms,         do: 2000
  def haircut_min_ms,         do: 1000
  def haircut_max_ms,         do: 4000
  def satisfaction_threshold, do: 3.0   # seconds per star lost
  # Grace period must cover the worst-case queue drain:
  # capacity (5) × max_haircut (4 s) = 20 s, plus a 5 s safety margin.
  def grace_period_ms,        do: 25_000
end

# ---------------------------------------------------------------------------
# Logging — prefixes every line with elapsed ms and the actor's name.
# @start is captured at module-compile time (≈ script start).
# ---------------------------------------------------------------------------
defmodule Log do
  @start System.monotonic_time(:millisecond)

  def log(actor, msg) do
    elapsed = System.monotonic_time(:millisecond) - @start
    IO.puts("[+#{elapsed}ms] [#{actor}] #{msg}")
  end
end

# ---------------------------------------------------------------------------
# Customer — one process per customer.
# State: arrival_time (recorded on spawn), customer id.
# Message flow:
#   out: {:arrive, self(), id}       → WaitingRoom
#   in:  :admitted  |  :turned_away  ← WaitingRoom
#   in:  {:haircut_starting, barber} ← Barber  (records wait time)
#   in:  {:rate_request, barber}     ← Barber
#   out: {:rating, score}            → Barber
# ---------------------------------------------------------------------------
defmodule Customer do
  def start(id, waiting_room_pid) do
    spawn(fn ->
      arrival_time = System.monotonic_time(:millisecond)
      Log.log("Customer-#{id}", "arrived")
      send(waiting_room_pid, {:arrive, self(), id})
      await_response(id, arrival_time)
    end)
  end

  defp await_response(id, arrival_time) do
    receive do
      :turned_away ->
        Log.log("Customer-#{id}", "turned away — waiting room full")

      :admitted ->
        Log.log("Customer-#{id}", "admitted to waiting room, waiting for barber")
        await_barber(id, arrival_time)
    end
  end

  defp await_barber(id, arrival_time) do
    receive do
      # Barber sends this right before starting the haircut so the customer
      # can record the exact moment the wait ends.
      {:haircut_starting, barber_pid} ->
        haircut_start = System.monotonic_time(:millisecond)
        wait_secs = (haircut_start - arrival_time) / 1000.0
        Log.log("Customer-#{id}", "haircut starting — waited #{Float.round(wait_secs, 2)}s")

        receive do
          {:rate_request, ^barber_pid} ->
            score = compute_rating(wait_secs)
            Log.log("Customer-#{id}",
              "giving #{score}/5 stars (waited #{Float.round(wait_secs, 2)}s)")
            send(barber_pid, {:rating, score})
            # Customer exits after rating is sent.
        end
    end
  end

  # score = clamp(1, 5,  5 - floor(wait_seconds / threshold) + jitter)
  # jitter ∈ {-1, 0, +1}
  defp compute_rating(wait_secs) do
    threshold = SimConfig.satisfaction_threshold()
    jitter    = :rand.uniform(3) - 2     # :rand.uniform(3) → 1,2,3  ⇒ -1,0,1
    score     = 5 - floor(wait_secs / threshold) + jitter
    max(1, min(5, score))
  end
end

# ---------------------------------------------------------------------------
# WaitingRoom — single long-lived process.
# Local state carried as loop parameters:
#   queue         — list of {customer_pid, customer_id}, front = head
#   turned_away   — running count of rejected customers
#   capacity      — max seats (from Config)
#   barber_sleeping — boolean; true after none_waiting is sent, false after wakeup
#   barber_pid    — pid of the Barber (stored when first next_customer arrives)
#
# Sleeping/waking handshake:
#   Set barber_sleeping = true  when :none_waiting is sent.
#   Set barber_sleeping = false when :wakeup is sent.
#   Only send :wakeup once per sleep cycle.
# ---------------------------------------------------------------------------
defmodule WaitingRoom do
  def start(capacity) do
    spawn(fn -> loop([], 0, capacity, false, nil) end)
  end

  defp loop(queue, turned_away, capacity, barber_sleeping, barber_pid) do
    receive do
      {:arrive, customer_pid, customer_id} ->
        handle_arrive(customer_pid, customer_id,
                      queue, turned_away, capacity, barber_sleeping, barber_pid)

      {:next_customer, barber} ->
        handle_next_customer(barber, queue, turned_away, capacity)

      {:get_stats, from} ->
        send(from, {:stats_reply, :waiting_room, turned_away, length(queue)})
        loop(queue, turned_away, capacity, barber_sleeping, barber_pid)

      :shutdown ->
        Log.log("WaitingRoom", "shutdown — #{length(queue)} customer(s) still queued")
    end
  end

  defp handle_arrive(customer_pid, customer_id,
                     queue, turned_away, capacity, barber_sleeping, barber_pid) do
    if length(queue) >= capacity do
      Log.log("WaitingRoom",
        "Customer-#{customer_id} turned away (#{length(queue)}/#{capacity} seats full)")
      send(customer_pid, :turned_away)
      loop(queue, turned_away + 1, capacity, barber_sleeping, barber_pid)
    else
      new_queue = queue ++ [{customer_pid, customer_id}]
      Log.log("WaitingRoom",
        "Customer-#{customer_id} admitted (#{length(new_queue)}/#{capacity} seats used)")
      send(customer_pid, :admitted)

      # Wake the barber exactly once per sleep cycle.
      if barber_sleeping and barber_pid != nil do
        Log.log("WaitingRoom", "Barber is sleeping — sending wakeup")
        send(barber_pid, :wakeup)
        loop(new_queue, turned_away, capacity, false, barber_pid)
      else
        loop(new_queue, turned_away, capacity, barber_sleeping, barber_pid)
      end
    end
  end

  defp handle_next_customer(barber, queue, turned_away, capacity) do
    case queue do
      [] ->
        Log.log("WaitingRoom", "No customers waiting — barber will sleep")
        send(barber, :none_waiting)
        # Flip barber_sleeping flag to true; remember barber pid for wakeup.
        loop([], turned_away, capacity, true, barber)

      [{customer_pid, customer_id} | rest] ->
        Log.log("WaitingRoom",
          "Sending Customer-#{customer_id} to barber (#{length(rest)} still waiting)")
        send(barber, {:customer_ready, customer_pid, customer_id})
        loop(rest, turned_away, capacity, false, barber)
    end
  end
end

# ---------------------------------------------------------------------------
# Barber — single long-lived process.
# State carried as loop parameters (no external variables):
#   wr_pid    — waiting room pid (fixed)
#   cuts      — number of completed haircuts
#   avg_dur   — running average haircut duration (ms, as float)
#   avg_rating — running average satisfaction score (float)
#
# Two receive loops:
#   loop/4       — active state: handles customer_ready, none_waiting, stats, shutdown
#   sleep_loop/4 — sleeping state: only handles wakeup, stats, shutdown
# ---------------------------------------------------------------------------
defmodule Barber do
  def start(waiting_room_pid) do
    spawn(fn ->
      Log.log("Barber", "Open for business — requesting first customer")
      send(waiting_room_pid, {:next_customer, self()})
      loop(waiting_room_pid, 0, 0.0, 0.0)
    end)
  end

  defp loop(wr_pid, cuts, avg_dur, avg_rating) do
    receive do
      {:customer_ready, customer_pid, customer_id} ->
        # Draw a random haircut duration in [haircut_min_ms, haircut_max_ms].
        duration_ms =
          SimConfig.haircut_min_ms() +
          :rand.uniform(SimConfig.haircut_max_ms() - SimConfig.haircut_min_ms() + 1) - 1

        Log.log("Barber",
          "Starting haircut for Customer-#{customer_id} (planned duration: #{duration_ms}ms)")

        # Notify the customer the haircut is beginning so they can record wait time.
        send(customer_pid, {:haircut_starting, self()})

        # Simulate the haircut.
        Process.sleep(duration_ms)

        Log.log("Barber",
          "Finished haircut for Customer-#{customer_id} — requesting rating")
        send(customer_pid, {:rate_request, self()})

        # Wait for rating — this receive is selective; shutdown/stats stay in mailbox.
        receive do
          {:rating, score} ->
            new_cuts      = cuts + 1
            new_avg_dur   = (avg_dur   * cuts + duration_ms) / new_cuts
            new_avg_rating = (avg_rating * cuts + score)      / new_cuts

            Log.log("Barber",
              "Rating from Customer-#{customer_id}: #{score}/5. " <>
              "Running totals → cuts=#{new_cuts}, " <>
              "avg_dur=#{Float.round(new_avg_dur / 1000, 2)}s, " <>
              "avg_rating=#{Float.round(new_avg_rating, 2)}")

            send(wr_pid, {:next_customer, self()})
            loop(wr_pid, new_cuts, new_avg_dur, new_avg_rating)
        end

      :none_waiting ->
        Log.log("Barber", "No customers — going to sleep")
        sleep_loop(wr_pid, cuts, avg_dur, avg_rating)

      {:get_stats, from} ->
        send(from, {:stats_reply, :barber, cuts, avg_dur, avg_rating})
        loop(wr_pid, cuts, avg_dur, avg_rating)

      :shutdown ->
        Log.log("Barber", "Shutdown received — closing up")
    end
  end

  # Sleeping state — only wakeup, get_stats, and shutdown are accepted here.
  defp sleep_loop(wr_pid, cuts, avg_dur, avg_rating) do
    receive do
      :wakeup ->
        Log.log("Barber", "Woken up! Requesting next customer")
        send(wr_pid, {:next_customer, self()})
        loop(wr_pid, cuts, avg_dur, avg_rating)

      {:get_stats, from} ->
        send(from, {:stats_reply, :barber, cuts, avg_dur, avg_rating})
        sleep_loop(wr_pid, cuts, avg_dur, avg_rating)

      :shutdown ->
        Log.log("Barber", "Shutdown received while sleeping")
    end
  end
end

# ---------------------------------------------------------------------------
# ShopOwner — drives the simulation lifecycle.
# Runs in the main (script) process; all others are spawned children.
# ---------------------------------------------------------------------------
defmodule ShopOwner do
  def run do
    Log.log("ShopOwner", "Opening barbershop")
    waiting_room = WaitingRoom.start(SimConfig.waiting_room_capacity())
    barber       = Barber.start(waiting_room)

    spawn_customers(waiting_room, 1, SimConfig.total_customers())

    Log.log("ShopOwner",
      "All #{SimConfig.total_customers()} customers spawned. " <>
      "Waiting grace period (#{SimConfig.grace_period_ms()}ms)...")
    Process.sleep(SimConfig.grace_period_ms())

    # ---- Collect statistics before sending shutdown ----
    send(barber,       {:get_stats, self()})
    send(waiting_room, {:get_stats, self()})

    {cuts, avg_dur_ms, avg_rating} =
      receive do
        {:stats_reply, :barber, c, d, r} -> {c, d, r}
      end

    turned_away =
      receive do
        {:stats_reply, :waiting_room, ta, _queue_len} -> ta
      end

    # ---- Shutdown ----
    Log.log("ShopOwner", "Shutdown initiated")
    send(barber,       :shutdown)
    send(waiting_room, :shutdown)

    # Short pause so shutdown log lines appear before the report.
    Process.sleep(200)

    print_report(cuts, avg_dur_ms, avg_rating, turned_away)
  end

  # Spawn customers one at a time; sleep a random interval between each.
  defp spawn_customers(_wr, id, total) when id > total, do: :done
  defp spawn_customers(wr, id, total) do
    Log.log("ShopOwner", "Spawning customer #{id} of #{total}")
    Customer.start(id, wr)

    if id < total do
      interval =
        SimConfig.arrival_min_ms() +
        :rand.uniform(SimConfig.arrival_max_ms() - SimConfig.arrival_min_ms() + 1) - 1
      Process.sleep(interval)
    end

    spawn_customers(wr, id + 1, total)
  end

  defp print_report(cuts, avg_dur_ms, avg_rating, turned_away) do
    total = SimConfig.total_customers()

    IO.puts("")
    IO.puts("=== Barbershop Closing Report ===")
    IO.puts("Total customers arrived:   #{total}")
    IO.puts("Customers served:          #{cuts}")
    IO.puts("Customers turned away:     #{turned_away}")
    IO.puts("Average haircut duration:  #{Float.round(avg_dur_ms / 1000, 2)}s")
    IO.puts("Average satisfaction:      #{Float.round(avg_rating, 1)} / 5.0")
    IO.puts("=================================")
  end
end

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
:rand.seed(:exsss, :os.timestamp())   # seed PRNG so each run differs
ShopOwner.run()
