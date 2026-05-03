const std = @import("std");
const HostType = @import("host_type.zig").HostType;
const RequestHost = @import("request_host.zig").RequestHost;

pub const Specificity = enum(u8) {
    fallback = 0, // "*", matches any host
    wildcard = 1, // e.g. *.example.com
    fully_qualified = 2, // e.g. example.com, or ip addresses
};

pub const HostPattern = struct {
    type: HostType,
    hostname: union(HostType) {
        /// reversed label array, NOT guaranteed to be lowercase
        domain: []const []const u8,
        /// binary representation of the ipv4 address, 4 bytes long
        ip_v4: [4]u8,
        /// binary representation of the ipv6 address, 16 bytes long
        ip_v6: [16]u8,
    },
    specificity: Specificity,
    port: ?u16,

    pub fn fromHostStr(comptime host_str: []const u8) HostPattern {
        return comptime parseHost(host_str);
    }

    pub fn match(self: *const HostPattern, request_host: *const RequestHost) bool {
        if (self.type != request_host.type) {
            return false;
        }

        if (self.port != null and self.port != request_host.port) {
            return false;
        }

        switch (self.hostname) {
            .domain => |domain_pattern| {
                if (domain_pattern.len == 1 and domain_pattern[0][0] == '*') {
                    // wildcard pattern matches any host
                    return true;
                }

                var it = std.mem.splitBackwardsScalar(u8, request_host.hostname.domain, '.');
                var i: usize = 0;

                while (it.next()) |part| : (i += 1) {
                    if (i >= domain_pattern.len) {
                        // request host has more labels than the pattern, so it cannot match
                        return false;
                    }

                    const pattern_part = domain_pattern[i];
                    if (pattern_part[0] != '*' and !std.mem.eql(u8, part, pattern_part)) {
                        return false;
                    }
                }

                return true;
            },
            .ip_v4 => |ip| {
                inline for (0..3) |i| {
                    if (ip[i] != request_host.hostname.ip_v4[i]) {
                        return false;
                    }
                }
            },
            .ip_v6 => |ip| {
                inline for (0..15) |i| {
                    if (ip[i] != request_host.hostname.ip_v6[i]) {
                        return false;
                    }
                }
            },
        }

        return true;
    }
};

const ParseHostError = error{
    InvalidHost,
};

fn parseHost(comptime host: []const u8) HostPattern {
    return comptime parseTrimmedHost(std.mem.trim(u8, host, &std.ascii.whitespace));
}

fn parseTrimmedHost(comptime host: []const u8) HostPattern {
    comptime {
        if (host.len == 0) {
            @compileError("Hostname cannot be empty");
        }

        if (host[0] == '[') {
            // ipv6
            const closing_bracket_index = std.mem.indexOfScalar(u8, host, ']') orelse {
                @compileError("Invalid IPv6 host, missing closing bracket");
            };

            const ipv6_address = host[1..closing_bracket_index];
            var port: ?u16 = null;

            if (closing_bracket_index < host.len - 1) {
                const port_str = host[closing_bracket_index + 1 ..];
                if (port_str[0] != ':') {
                    // ipv6 format allows only for a port to be specified after the closing bracket, no whitespace or any other characters are allowed
                    @compileError("Invalid port in IPv6 host string");
                }

                port = parsePort(port_str[1..]) catch {
                    @compileError("Invalid port in IPv6 host string");
                };
            }

            // std's parse will fail if the ipv6 address is invalid, so we can rely on it to validate the address for us
            // manually validating ipv6 addresses is hell so little bit of extra overhead from std's parse is worth it for the correctness guarantees it provides
            const address = std.net.Ip6Address.parse(ipv6_address, 0) catch {
                @compileError("Invalid IPv6 address");
            };

            return HostPattern{
                .type = .ip_v6,
                .hostname = .{
                    .ip_v6 = address.sa.addr,
                },
                .specificity = Specificity.fully_qualified,
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
                    @compileError("Invalid port in host string");
                };
            }

            // remove trailing dot if present, e.g. example.com. is valid and equivalent to example.com
            // but trailing dots are not allowed for ipv4 addresses, so this needs to be validated later
            hostname = std.mem.trimEnd(u8, hostname, ".");
            if (hostname.len == 0) {
                @compileError("Hostname cannot be empty");
            }

            if (!std.ascii.isAlphanumeric(hostname[0]) and hostname[0] != '*') {
                @compileError("Hostname must start with an alphanumeric character or a wildcard");
            }

            if (hostname.len != 1 and !std.ascii.isAlphanumeric(hostname[hostname.len - 1])) {
                @compileError("Hostname must end with an alphanumeric character");
            }

            var has_alpha = false;
            var has_wildcard = false;
            var has_invalid = false;
            var last_char_was_dash = false;

            var dot_count: usize = 0;
            var label_len: usize = 0;

            for (hostname) |c| {
                const is_digit = (c >= '0' and c <= '9');
                const is_alpha = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
                const is_wildcard = (c == '*');
                const is_dash = (c == '-');
                const is_dot = (c == '.');

                const is_valid = is_digit or is_alpha or is_wildcard or is_dash or is_dot;
                has_invalid |= !is_valid;
                has_alpha |= is_alpha;
                has_wildcard |= is_wildcard;

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
                @compileError("Hostname has invalid characters");
            }

            // domains with a hostname '*' are valid as catch-all
            if (has_alpha or has_wildcard) {
                // domain
                var it = std.mem.splitBackwardsScalar(u8, hostname, '.');
                var domain_parts: []const []const u8 = &[_][]const u8{};

                while (it.next()) |part| {
                    domain_parts = domain_parts ++ &[_][]const u8{part};
                }

                if (has_wildcard) {
                    var wildcard_count: usize = 0;

                    for (domain_parts) |part| {
                        if (std.mem.indexOfScalar(u8, part, '*') != null) {
                            // has wildcard
                            if (domain_parts.len != 1 and part[0] != '*') {
                                @compileError("Wildcard can only be used as a full label, e.g. *.example.com is valid, but a*.example.com or *a.example.com are not valid");
                            }

                            wildcard_count += 1;

                            if (wildcard_count > 1) {
                                @compileError("Only one wildcard is allowed in a hostname");
                            }
                        } else if (wildcard_count > 0) {
                            // if there is a wildcard, it must be the first label (last after reversing)
                            // so if we encounter a non-wildcard label after we've seen a wildcard, the hostname is invalid
                            @compileError("Wildcard must be the first label");
                        }
                    }
                }

                return HostPattern{
                    .type = HostType.domain,
                    .hostname = .{
                        .domain = domain_parts,
                    },
                    .specificity = if (has_wildcard) if (hostname.len == 1) Specificity.fallback else Specificity.wildcard else Specificity.fully_qualified,
                    .port = port,
                };
            }

            // while domain without alpha chars can technically exist, there are no TLDs that consist solely of digits
            // so to avoid ambiguity we will treat hostnames without alpha chars as ipv4 addresses

            // ipv4
            // wildcards are only allowed for domain hosts
            if (has_wildcard) {
                @compileError("Wildcards are not allowed in IPv4 hostnames");
            }

            if (dot_count != 3) {
                @compileError("Invalid IPv4 host, must contain 3 dots");
            }

            if (hostname[hostname.len - 1] == '.') {
                // trailing dot is not allowed for ipv4 addresses, must be checked against the original hostname before trimming
                @compileError("Invalid IPv4 host, cannot end with a dot");
            }

            var it = std.mem.splitScalar(u8, hostname, '.');
            var i = 0;
            var ipv4_parts: [4]u8 = undefined;

            while (it.next()) |part| : (i += 1) {
                const num = std.fmt.parseUnsigned(u8, part, 10) catch {
                    @compileError("Invalid IPv4 host, each part must be a number between 0 and 255");
                };

                if (num > 255) {
                    @compileError("Invalid IPv4 host, each part must be a number between 0 and 255");
                }
                ipv4_parts[i] = num;
            }

            return HostPattern{
                .type = HostType.ip_v4,
                .hostname = .{
                    .ip_v4 = ipv4_parts,
                },
                .specificity = Specificity.fully_qualified,
                .port = port,
            };
        }
    }
}

fn parsePort(comptime port_str: []const u8) ParseHostError!u16 {
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
