# zuki

**The async runtime for Zig you've never heard of** — until now.

<div align="center">

[![GitHub last commit](https://img.shields.io/github/last-commit/zuki-dev/zuki?style=flat&color=blue)](https://github.com/zuki-dev/zuki/commits)
[![GitHub tag (latest SemVer pre-release)](https://img.shields.io/github/v/tag/zuki-dev/zuki?include_prereleases&style=flat&color=orange&label=version)](https://github.com/zuki-dev/zuki/releases)
[![GitHub Repo stars](https://img.shields.io/github/stars/zuki-dev/zuki?style=flat&color=yellow)](https://github.com/zuki-dev/zuki/stargazers)
[![GitHub issues](https://img.shields.io/github/issues/zuki-dev/zuki?style=flat&color=red)](https://github.com/zuki-dev/zuki/issues)
[![License](https://img.shields.io/github/license/zuki-dev/zuki?style=flat&color=green)](LICENSE)

*Built for developers who care about performance*

</div>

---

## Why Zuki?

Most async runtimes make compromises. Zuki doesn't:

- **Lock-free data structures** — No mutexes, no blocking
- **Zero-cost abstractions** — Pay only for what you use
- **Work stealing scheduler** — Automatic load balancing
- **Rust-inspired futures** — Familiar patterns, Zig performance
- **Scalable design** — From embedded to servers

## Reality Check

**Zuki is in early development** — APIs change, bugs exist, documentation is minimal. 

The foundation is solid and performance is already impressive. Good for:
- Learning async patterns in Zig
- Contributing to runtime development  
- Exploring high-performance async

**Not ready for production.**

## Quick Example

```zig
// Create an async task
var delay = DelayFuture.from_millis(&timer, 1000);
const task = Task.from_future(&delay, 1);

// Run it on the executor
var executor = try SingleThreadedExecutor.init(allocator);
try executor.spawn(task);
try executor.run();
```

Simple. No complexity, no overhead.

## Architecture

What makes Zuki different:

- **Lock-free MPMC queues** — Multiple producers, multiple consumers, zero locks
- **Intrusive linked lists** — Zero-allocation data structures
- **Atomic operations** — Compare-and-swap for maximum throughput  
- **Work stealing** — Tasks flow where needed
- **Priority scheduling** — Important tasks get priority

## Documentation

- [Getting Started](docs/src/quick-start.md) — Start here
- [Architecture Guide](docs/) — How Zuki works
- [Roadmap](docs/src/roadmap.md) — What's planned
- [Examples](examples/) — Working code

## Contributing

Zuki needs contributors who understand performance:

- Found a bug? Open an issue
- Want to contribute? Check [CONTRIBUTING.md](CONTRIBUTING.md)
- Have ideas? Start a discussion

---

<div align="center">

**Ready to try the async runtime you've never heard of?**

[Documentation](docs/src/quick-start.md) | [Discussions](https://github.com/zuki-dev/zuki/discussions) | [GitHub](https://github.com/zuki-dev/zuki)

</div>
