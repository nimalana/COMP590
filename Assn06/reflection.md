## Assignment 6 Reflection: Concurrency Models in Go and Elixir

### Process Identity and Addressing
In Elixir, the "identity" problem is essentially a non-issue because every process is born with a **PID**. In my implementation, I just had to pass the `waiting_room` PID to the Barber and Customers during their `spawn` phase. If a process needs to reply, it just uses `self()` to let the receiver know who is talking. 

Go is a completely different story. Goroutines are anonymous; there is no way to "look up" a goroutine or send it a signal by an ID. To solve this, I had to be very explicit with **channel passing**. For example, in `runCustomer` (line 103), I created a local `mailbox` channel and passed it into the `Message` struct. This channel *became* the identity. If the Barber wanted to talk to a specific customer, he had to use the `From` field (line 39) attached to that customer's message. It felt like I was manually building a phone book by passing around hardware lines, whereas in Elixir, everyone just has a unique phone number by default.

### State Management
State management felt like a "loops vs. variables" battle. In Go, the `runBarber` function (line 184) feels very procedural. I just declared `cuts`, `avgDurMs`, and `avgRating` at the top of the function. They exist as long as the goroutine is alive, and I update them inside a `for` loop. It’s very intuitive if you're used to OOP or basic imperative programming.

Elixir’s approach via **recursive receive loops** (like in `Barber.loop/4` on line 290) was a mental shift. Since data is immutable, you can’t just "change" a variable. You have to pass the "new" state as an argument to the next iteration of the function. While this felt a bit boilerplate-heavy at first, it actually felt more "natural" for the `WaitingRoom`. Managing a queue by passing a list (`[head | tail]`) into a recursive call (line 273) feels much safer and more predictable than mutating a slice in Go, where you have to worry about pointer references or accidental shared state.

### The Sleeping Barber Handshake
The handshake was the trickiest part of the logic. In Go, I used a `MsgNextCustomer` signal. The Barber sends his `trafficCh` to the Waiting Room. If the room is empty, the Waiting Room sets a boolean `barberSleeping = true` (line 167). When a new customer finally arrives, the Waiting Room checks that boolean and sends a `MsgWakeUp` to that saved channel.

In Elixir, I used a similar handshake but relied on the Barber’s PID. The Barber sends a `:none_waiting` message to himself (line 320) and transitions into a specific `sleep_loop`. The difference here is **process state transition**. In Go, the Barber is still in the same function, just blocked on a `select`. In Elixir, the Barber literally changes his "behavior" by calling a different function (`sleep_loop/4` on line 334) that only matches against specific messages like `:wakeup`. It’s a much cleaner way to represent a state machine.

### Message Types and Boilerplate
The difference in message overhead is massive. In Go, I had to define a massive `Message` struct (lines 37-51) that contains fields for every possible scenario—even if a specific message only uses one of them. I also had to define a `MsgKind` enum (line 22). This makes the code very "wordy." Every time I wanted to add a feature, like the `MsgHaircutStarting` (line 35), I had to update the struct and the enum.

Elixir’s **pattern matching** on atoms and tuples is incredibly refreshing. I didn't have to define a "Message Type" anywhere. I just typed `{:arrive, pid, id}` and Elixir figured it out. This lack of boilerplate meant I spent more time on logic and less time on structural definitions. However, the downside is that in Elixir, you have to be careful; if you typo an atom, the process just ignores the message and it sits in the mailbox forever, whereas Go would catch that at compile time.

### select vs. receive
Go’s `select` statement is a powerhouse. In `runBarber` (line 195), I used `select` to listen to both the `trafficCh` (customers) and the `controlCh` (the Shop Owner). This allowed the Barber to answer a "Get Stats" request even if he was currently waiting for a customer. It makes multiplexing feel built-in.

In Elixir, `receive` only looks at one mailbox. To get the same "multiplexing" effect, I just had to write different match arms in the same `receive` block. It achieves the same goal, but the design feels different. In Go, you are listening to different **pipes** (channels); in Elixir, you are looking for different **shapes** (patterns) in one single bucket. For the Barber, Elixir’s model felt slightly more cohesive because I didn't have to manage two separate channel variables; I just handled `:get_stats` and `:customer_ready` in the same block (line 292).

### AI Tool Usage
I used an AI tool to help bootstrap the Elixir implementation since I’m much more comfortable with Go. I prompted it with: *"Convert this Go Sleeping Barber logic to Elixir using the Actor model. Use a recursive loop for state and ensure the Barber can handle stats requests while sleeping."*

The AI was great at setting up the basic `spawn` logic and the recursive function structure. However, it initially failed on the **handshake**. It tried to have the Customer wake the Barber directly, which violated the "Waiting Room" bottleneck and caused race conditions where two customers would try to wake a barber who was already cutting hair. I had to fix this by routing all wakeup logic through the `WaitingRoom` process and explaining that the Barber should only be woken by the "room" once a seat is occupied. I also had to manually add the `System.monotonic_time` logic to get the elapsed millisecond logging right, as the AI initially used basic `DateTime` which isn't great for measuring small intervals.