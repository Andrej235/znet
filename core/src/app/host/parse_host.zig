const std = @import("std");

pub const HostType = enum {
    domain,
    ip_v4,
    ip_v6,
};

pub const Host = struct {
    type: HostType,
    host_name: []const u8,
    port: ?u16,
};

const ParseHostError = error{
    InvalidHost,
};

pub fn parseHost(host: []const u8) ParseHostError!Host {
    return parseTrimmedHost(std.mem.trim(u8, host, &std.ascii.whitespace));
}

fn parseTrimmedHost(host: []const u8) ParseHostError!Host {
    if (host.len == 0) {
        return error.InvalidHost;
    }

    if (host[0] == '[') {
        // ipv6
        const closing_bracket_index = std.mem.indexOfScalar(u8, host, ']') orelse {
            return error.InvalidHost;
        };

        const ipv6_address = host[1..closing_bracket_index];
        var port: ?u16 = null;

        if (closing_bracket_index < host.len - 1) {
            const port_str = host[closing_bracket_index + 1 ..];
            if (port_str[0] != ':') {
                // ipv6 format allows only for a port to be specified after the closing bracket, no whitespace or any other characters are allowed
                return error.InvalidHost;
            }

            port = parsePort(port_str[1..]) catch {
                return error.InvalidHost;
            };
        }

        // std's parse will fail if the ipv6 address is invalid, so we can rely on it to validate the address for us
        // manually validating ipv6 addresses is hell so little bit of extra overhead from std's parse is worth it for the correctness guarantees it provides
        _ = std.net.Ip6Address.parse(ipv6_address, 0) catch {
            return error.InvalidHost;
        };

        return Host{
            .type = .ip_v6,
            .host_name = ipv6_address,
            .port = port,
        };
    } else {
        // ipv4 or domain

        var hostname = host;
        var port: ?u16 = null;
        const last_colon_index = std.mem.lastIndexOfScalar(u8, host, ':');

        if (last_colon_index) |idx| {
            hostname = host[0..idx];
            port = parsePort(host[idx + 1 ..]) catch {
                return error.InvalidHost;
            };
        }

        // remove trailing dot if present, e.g. example.com. is valid and equivalent to example.com
        // but trailing dots are not allowed for ipv4 addresses, so this needs to be validated later
        hostname = std.mem.trimEnd(u8, hostname, ".");
        if (hostname.len == 0) {
            return error.InvalidHost;
        }

        // host must start and end with an alphanumeric character
        if (!std.ascii.isAlphanumeric(hostname[0]) or !std.ascii.isAlphanumeric(hostname[hostname.len - 1])) {
            return error.InvalidHost;
        }

        var has_alpha = false;
        var has_invalid = false;
        var last_char_was_dash = false;

        var dot_count: usize = 0;
        var label_len: usize = 0;

        for (hostname) |c| {
            const is_digit = (c >= '0' and c <= '9');
            const is_alpha = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
            const is_dash = (c == '-');
            const is_dot = (c == '.');

            const is_valid = is_digit or is_alpha or is_dash or is_dot;
            has_invalid |= !is_valid;
            has_alpha |= is_alpha;

            if (is_dot) {
                has_invalid |= label_len == 0; // empty label
                has_invalid |= last_char_was_dash; // label cannot end with a dash

                dot_count += 1;
                label_len = 0;
            } else {
                // label cannot start with a dash
                has_invalid |= label_len == 0 and is_dash;

                label_len += 1;
            }
            last_char_was_dash = is_dash;
        }

        if (has_invalid) {
            return error.InvalidHost;
        }

        if (has_alpha) {
            // domain
            return Host{
                .type = .domain,
                .host_name = hostname,
                .port = port,
            };
        }

        // while domain without alpha chars can technically exist, there are no TLDs that consist solely of digits
        // so to avoid ambiguity we will treat hostnames without alpha chars as ipv4 addresses

        // ipv4
        if (dot_count != 3) {
            return error.InvalidHost;
        }

        if (hostname[hostname.len - 1] == '.') {
            // trailing dot is not allowed for ipv4 addresses, must be checked against the original hostname before trimming
            return error.InvalidHost;
        }

        var it = std.mem.splitScalar(u8, hostname, '.');
        while (it.next()) |part| {
            const num = std.fmt.parseUnsigned(u8, part, 10) catch {
                return error.InvalidHost;
            };

            if (num > 255) {
                return error.InvalidHost;
            }
        }

        return Host{
            .type = .ip_v4,
            .host_name = hostname,
            .port = port,
        };
    }
}

fn parsePort(port_str: []const u8) ParseHostError!u16 {
    // if the port string is longer than 5 characters it will definitely exceed the max port number 65535, so we return early as parsing is more expensive
    if (port_str.len == 0 or port_str.len > 5) {
        return error.InvalidHost;
    }

    // max size of u16 is 65535 which is the max valid port number
    // so there is no need to check for overflow manually as parseUnsigned will fail if the number exceeds u16 max value
    const port = std.fmt.parseUnsigned(u16, port_str, 10) catch {
        return error.InvalidHost;
    };

    return port;
}

test "host_parsing" {
    const testing = std.testing;

    // valid hosts
    try testing.expect(testParse("example.com"));
    try testing.expect(testParse("sub.domain.example.com"));
    try testing.expect(testParse("localhost"));
    try testing.expect(testParse("a.b.c.d"));
    try testing.expect(testParse("123.com"));
    try testing.expect(testParse("example.com."));
    try testing.expect(testParse("example.com.:80"));
    try testing.expect(testParse("example.com..."));
    try testing.expect(testParse("example.com...:80"));
    try testing.expect(testParse("127.0.0.1"));
    try testing.expect(testParse("192.168.1.1"));
    try testing.expect(testParse("0.0.0.0"));
    try testing.expect(testParse("255.255.255.255"));
    try testing.expect(testParse("1.2.3.4"));
    try testing.expect(testParse("127.0.0.1:80"));
    try testing.expect(testParse("192.168.1.1:8080"));
    try testing.expect(testParse("1.2.3.4:65535"));
    try testing.expect(testParse("[::1]"));
    try testing.expect(testParse("[2001:db8::1]"));
    try testing.expect(testParse("[::]"));
    try testing.expect(testParse("[::1]:80"));
    try testing.expect(testParse("[2001:db8::1]:443"));
    try testing.expect(testParse("[::ffff:192.168.1.1]:8080"));

    // invalid hosts
    try testing.expect(!testParse(""));
    try testing.expect(!testParse("."));
    try testing.expect(!testParse("..."));
    try testing.expect(!testParse(":80"));
    try testing.expect(!testParse(".:80"));
    try testing.expect(!testParse("example.com:"));
    try testing.expect(!testParse(".example.com"));
    try testing.expect(!testParse("example.com::80"));
    try testing.expect(!testParse("example.com:80:90"));
    try testing.expect(!testParse("example..com"));
    try testing.expect(!testParse("-abc.com"));
    try testing.expect(!testParse("abc-.com"));
    try testing.expect(!testParse("abc..def.com"));
    try testing.expect(!testParse("exa mple.com"));
    try testing.expect(!testParse("127.0.0"));
    try testing.expect(!testParse("127.0.0.1.5"));
    try testing.expect(!testParse("127.0.0.256"));
    try testing.expect(!testParse("999.999.999.999"));
    try testing.expect(!testParse("127..0.1"));
    try testing.expect(!testParse("[::1"));
    try testing.expect(!testParse("::1]"));
    try testing.expect(!testParse("[::1]]"));
    try testing.expect(!testParse("[::1]extra"));
    try testing.expect(!testParse("[::1] :80"));
    try testing.expect(!testParse("[::1]:abc"));
    try testing.expect(!testParse("[::1]::"));
    try testing.expect(!testParse("[::1 ]"));
    try testing.expect(!testParse("[::1]: "));
    try testing.expect(!testParse("[::1] :8080"));
    try testing.expect(!testParse("[2001:::1]"));
    try testing.expect(!testParse("*.example.com"));
    try testing.expect(!testParse("http://example.com"));
    try testing.expect(!testParse("example.com/path"));
    try testing.expect(!testParse("user@domain.com"));
    try testing.expect(!testParse("example.com:999999"));
    try testing.expect(!testParse("example.com:-1"));
    try testing.expect(!testParse("example.com:abc"));
    try testing.expect(!testParse("example.com:"));
    try testing.expect(!testParse("example.com:08080a"));
}

fn testParse(host: []const u8) bool {
    _ = parseHost(host) catch {
        return false;
    };
    return true;
}
