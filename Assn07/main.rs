fn main() {
    assert_eq!(collatz_length(1),   1,   "length of 1 should be 1");
    assert_eq!(collatz_length(6),   9,   "length of 6 should be 9");
    assert_eq!(collatz_length(27),  112, "length of 27 should be 112");
    println!("collatz_length checks passed.");

    let answer = longest_collatz(1_000_000);
    assert_eq!(answer, 837799, "longest below 1M should be 837799");
    println!("longest_collatz(1_000_000) = {}", answer);
    println!("All checks passed.");
}

fn collatz_length(n: u64) -> u64 {
    collatz_length_helper(n, 1)
}

fn collatz_length_helper(n: u64, acc: u64) -> u64 {
    match n {
        1 => acc,
        _ if n % 2 == 0 => collatz_length_helper(n / 2, acc + 1),
        _ => collatz_length_helper(3 * n + 1, acc + 1),
    }
}

fn longest_collatz(limit: u64) -> u64 {
    longest_collatz_helper(1, limit, 0, 0)
}

fn longest_collatz_helper(current: u64, limit: u64, best_start: u64, best_len: u64) -> u64 {
    if current >= limit {
        best_start
    } else {
        let len = collatz_length(current);
        if len > best_len {
            longest_collatz_helper(current + 1, limit, current, len)
        } else {
            longest_collatz_helper(current + 1, limit, best_start, best_len)
        }
    }
}
