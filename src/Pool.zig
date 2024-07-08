/// An improved version of std.Thread.Pool.
/// The main improvement is allowing a worker thread init/deinit function to be specified when starting the pool.
/// It also fixes a race condition whereby std.Thread.Pool could fail to execute some tasks submitted just before calling join().

allocator: std.mem.Allocator,
mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},
tasks: Queue = .{},
running: bool = false,
threads: []std.Thread = &.{},
thread_init: ?*Shared_Task = null,
thread_deinit: ?*Shared_Task = null,

pub const Start_Options = struct {
    num_threads: ?u32 = null,
    thread_init: ?*Shared_Task = null,
    thread_deinit: ?*Shared_Task = null,
};

pub fn shared_task(self: *Pool, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !*Shared_Task {
    const Args = @TypeOf(args);
    const Closure = struct {
        args: Args,
        allocator: std.mem.Allocator,
        shared_task: Shared_Task = .{
            .run_func = run_closure,
            .deinit_func = deinit_closure,
        },

        fn run_closure(task: *Shared_Task) void {
            const closure: *@This() = @fieldParentPtr("shared_task", task);
            @call(.auto, func, closure.args);
        }

        fn deinit_closure(task: *Shared_Task) void {
            const closure: *@This() = @fieldParentPtr("shared_task", task);
            closure.allocator.destroy(closure);
        }
    };

    const closure = try self.allocator.create(Closure);
    closure.* = .{
        .args = args,
        .allocator = self.allocator,
    };
    return &closure.shared_task;
}

pub fn start(self: *Pool, options: Start_Options) !void {
    std.debug.assert(!self.running);
    std.debug.assert(self.threads.len == 0);
    self.running = true;

    self.thread_init = options.thread_init;
    self.thread_deinit = options.thread_deinit;

    if (builtin.single_threaded or options.num_threads == 0) {
        if (self.thread_init) |task| task.run_func(task);
        return;
    }

    const num_threads = options.num_threads orelse @max(1, std.Thread.getCpuCount() catch 1);

    // kill and join any threads we spawned and free memory on error.
    self.threads = try self.allocator.alloc(std.Thread, num_threads);
    var spawned: usize = 0;
    errdefer self.join(spawned);
    for (self.threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, worker, .{ self, options.thread_init, options.thread_deinit });
        spawned += 1;
    }
}

pub fn deinit(self: *Pool) void {
    self.join(self.threads.len);
    self.* = undefined;
}

fn join(self: *Pool, threads_spawned: usize) void {
    if (builtin.single_threaded or self.threads.len == 0) {
        if (self.thread_deinit) |task| {
            task.run_func(task);
            task.deinit_func(task);
        }
        if (self.thread_init) |task| task.deinit_func(task);
        return;
    }

    self.stop();

    if (self.threads.len > 0) {
        // wake up any sleeping threads (this can be done outside the mutex)
        // then wait for all the threads we know are spawned to complete.
        self.cond.broadcast();
        for (self.threads[0..threads_spawned]) |thread| {
            thread.join();
        }

        self.allocator.free(self.threads);
    }

    if (self.thread_deinit) |task| task.deinit_func(task);
    if (self.thread_init) |task| task.deinit_func(task);
}

pub fn stop(pool: *Pool) void {
    pool.mutex.lock();
    defer pool.mutex.unlock();
    pool.running = false;
}

pub fn is_running(pool: *Pool) bool {
    pool.mutex.lock();
    defer pool.mutex.unlock();
    return pool.running;
}

pub fn submit(self: *Pool, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !void {
    if (builtin.single_threaded or self.threads.len == 0) {
        @call(.auto, func, args);
        return;
    }

    const Args = @TypeOf(args);
    const Closure = struct {
        args: Args,
        pool: *Pool,
        node: Queue.Node = .{ .data = .{ .func = run } },

        fn run(task: *Task) void {
            const node: *Queue.Node = @fieldParentPtr("data", task);
            const closure: *@This() = @fieldParentPtr("node", node);
            defer closure.deinit();
            @call(.auto, func, closure.args);
        }

        pub fn deinit(closure: *@This()) void {
            // The thread pool's allocator is protected by the mutex.
            const mutex = &closure.pool.mutex;
            mutex.lock();
            defer mutex.unlock();
            closure.pool.allocator.destroy(closure);
        }
    };

    {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.running) return error.PoolNotRunning;

        const closure = try self.allocator.create(Closure);
        closure.* = .{
            .args = args,
            .pool = self,
        };

        self.tasks.prepend(&closure.node);
    }

    // Notify waiting threads outside the lock to try and keep the critical section small.
    self.cond.signal();
}

fn worker(pool: *Pool, init_task: ?*Shared_Task, deinit_task: ?*Shared_Task) void {
    if (init_task) |task| {
        task.run_func(task);
    }

    defer if (deinit_task) |task| {
        task.run_func(task);
    };

    pool.worker_loop();
}

fn worker_loop(pool: *Pool) void {
    pool.mutex.lock();
    defer pool.mutex.unlock();

    while (true) {
        pool.drain_queue();

        if (pool.running) {
            pool.cond.wait(&pool.mutex);
        } else {
            break;
        }
    }

    // without this, there could be a race where some tasks in the queue aren't executed.
    pool.drain_queue();
}

// Assumes that pool.mutex is already locked
fn drain_queue(pool: *Pool) void {
    while (pool.tasks.popFirst()) |node| {
        pool.mutex.unlock();
        defer pool.mutex.lock();
        node.data.func(&node.data);
    }
}

const Queue = std.SinglyLinkedList(Task);
const Task = struct {
    func: Task_Func,
};
const Task_Func = *const fn (*Task) void;

const Shared_Task = struct {
    run_func: Shared_Task_Func,
    deinit_func: Shared_Task_Func,
};
const Shared_Task_Func = *const fn (*Shared_Task) void;

const Pool = @This();

const builtin = @import("builtin");
const std = @import("std");
