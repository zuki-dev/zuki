# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Core task polling system (`Poll(T)` type)
- Waker system for task notification
- Single-threaded executor for running tasks
- Example executor test demonstrating task scheduling and waker usage

### Changed

### Deprecated

### Removed

### Fixed
- Memory leak in SingleThreadedExecutor when tasks complete
- Fixed task cleanup in executor's deinit function

### Security

[Unreleased]: https://github.com/zuki-dev/zuki/compare/HEAD
