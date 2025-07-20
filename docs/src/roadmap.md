# Roadmap

## Zuki Async Runtime Development Plan

---

This document outlines the planned features and improvements for the Zuki async runtime. The roadmap is subject to change based on community feedback and development progress.

## Current Status

**Warning: Early Development**
Zuki is currently in early development with significant limitations:
- APIs are extremely verbose and require lots of boilerplate
- Poor developer experience (DX) - creating simple async tasks takes too much code
- Manual waker management and poll method implementations required
- Single-threaded execution only
- APIs will change frequently without notice

**Do not use in production.** This is currently best suited for learning async patterns and contributing to development.

## Completed Features

**Core Foundation**
- Basic async runtime with Future/Poll pattern
- Single-threaded task executor with priority queues
- Waker system for task coordination
- Lock-free data structures (MPMC queues, ring buffers, intrusive lists)
- Timer system with delays and timeouts
- Basic documentation and examples

## Roadmap

### Short Term (Next 3-6 months)
**Goal: Usable Multi-threaded Runtime**
- Multi-threaded task executor
- Work stealing scheduler
- Thread pool management
- Performance optimizations

### Mid Term (6-12 months)  
**Goal: Better Developer Experience**
- Ergonomic API redesign (reduce boilerplate significantly)
- Simplified task creation and spawning
- Better error handling patterns
- Improved debugging and profiling tools

### Long Term (1+ years)
**Goal: Production Ready**
- Advanced scheduling (priorities, deadlines)
- I/O integration (file, network, sockets)
- Ecosystem packages (HTTP, databases)
- Full benchmarking vs other runtimes
- API stabilization (1.0 release)