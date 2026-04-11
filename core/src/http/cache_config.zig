pub const CacheConfig = struct {
    pub const Mode = enum {
        no_store,
        custom,

        pub fn toString(self: Mode) []const u8 {
            return switch (self) {
                .no_store => "no-store",
                .custom => "custom",
            };
        }
    };

    pub const Visibility = enum {
        none,
        public,
        private,

        pub fn toString(self: Visibility) []const u8 {
            return switch (self) {
                .none => "",
                .public => "public",
                .private => "private",
            };
        }
    };

    mode: Mode = .no_store,

    visibility: Visibility = .none,

    max_age: ?u32 = null,
    s_maxage: ?u32 = null,
    immutable: bool = false,

    no_cache: bool = false,
    must_revalidate: bool = false,

    etag: ?[]const u8 = null,
    last_modified: ?i64 = null,

    pub fn public(max_age: u32) CacheConfig {
        return CacheConfig{
            .mode = .custom,
            .visibility = .public,
            .max_age = max_age,
        };
    }

    pub fn private(max_age: u32) CacheConfig {
        return .{
            .mode = .custom,
            .visibility = .private,
            .max_age = max_age,
        };
    }

    pub fn noStore() CacheConfig {
        return .{ .mode = .no_store };
    }

    pub fn noCache() CacheConfig {
        return .{
            .mode = .custom,
            .no_cache = true,
        };
    }

    pub fn withEtag(self: CacheConfig, etag: []const u8) CacheConfig {
        var copy = self;
        copy.etag = etag;
        return copy;
    }

    pub fn withLastModified(self: CacheConfig, lastModified: i64) CacheConfig {
        var copy = self;
        copy.last_modified = lastModified;
        return copy;
    }

    pub fn mustRevalidate(self: CacheConfig) CacheConfig {
        var copy = self;
        copy.must_revalidate = true;
        return copy;
    }

    pub fn isImmutable(self: CacheConfig) CacheConfig {
        var copy = self;
        copy.immutable = true;
        return copy;
    }
};
