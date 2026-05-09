# zNet

A lightweight, high-performance HTTP server library written entirely in Zig.

> zNet is **NOT** production ready, it started as a learning project and is currently on hold. The code is available for anyone interested in exploring or contributing, but there are no active development plans at this time.

### Features

- Asynchronous, non-blocking event driven I/O based on each platform's native APIs (e.g., epoll on Linux)
- Cross platform support for Linux, Windows (partial) with an easily extensible architecture for adding support for other platforms
- Minimal dependencies, relying only on the Zig standard library for parsing IPs, networking, allocators, and other utilities
- Support for HTTP/1.1 with keep-alive connections and pipelining
- Support for routing based on virtual hosts, URL paths, and HTTP methods, with dynamic route parameters and wildcard matching
- Path and query parameter parsing without any allocations
- Compile time action parameters validation for easier debugging and better performance
- Service based dependency injection
- Automatic request rejection based on parsing errors with standardized error messages and status codes that adhere to HTTP specifications
- Support for chunked requests
- Asynchronous logging with configurable log levels, must be explicitly enabled

### Project status

- Development is paused for the foreseeable future. The decision is due in part to recent changes in the Zig language and toolchain that diverge from the reasons this project originally chose Zig as its implementation language.

### Contributors

Basically the entire project was developed by one guy who wanted to try out Zig and learn about how HTTP servers work.

- [Andrej](https://github.com/Andrej235) - most of the core
- [Branko](https://github.com/Banecane109) - windows networking primitives

### License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
