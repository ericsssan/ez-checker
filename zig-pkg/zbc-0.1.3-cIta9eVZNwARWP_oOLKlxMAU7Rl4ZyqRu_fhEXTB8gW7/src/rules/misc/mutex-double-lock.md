# mutex-double-lock

**Severity:** error  
**Category:** concurrency / deadlock  
**Tier:** 1 (token walk)

## What this checks

The same mutex (or RwLock) receiver is locked twice with no intervening
`unlock()` call.

`std.Thread.Mutex` is non-reentrant.  Calling `lock()` while the same
thread already holds the lock deadlocks in ReleaseFast (busy-spins forever)
and triggers an assertion failure in Debug (`lock_count == 0`).  The same
applies to `std.Thread.RwLock.lock()` and `.lockShared()`.

## Example (fires)

```zig
fn notifyWorkers(self: *Pool) void {
    self.mutex.lock();
    enqueueWork(self);
    // BUG: forgot to unlock before re-locking in the helper path
    self.mutex.lock();   // ← deadlock
    sendNotification(self);
    self.mutex.unlock();
}
```

## Fix

Add `unlock()` before re-acquiring the lock:

```zig
fn notifyWorkers(self: *Pool) void {
    self.mutex.lock();
    enqueueWork(self);
    self.mutex.unlock();
    self.mutex.lock();
    sendNotification(self);
    self.mutex.unlock();
}
```

Or restructure to hold the lock for the entire critical section:

```zig
fn notifyWorkers(self: *Pool) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    enqueueWork(self);
    sendNotification(self);
}
```

## Real-world instance

- oven-sh/bun#28907 — `ThreadPool` sync object: a notification path
  attempted to acquire the same sync lock that was already held on the
  calling thread, deadlocking the thread pool's wakeup mechanism.
