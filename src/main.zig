const std = @import("std");
const graphql = @import("graphql");

pub const Stats = struct {
    followers: u64,
    stars: u64,
    commits: u64,
    prs: u64,
    issues: u64,
    repos: u64,
    contributed: u64,
};

const Lang = struct { name: []const u8, percent: f64 };

const query = @embedFile("query.graphql");

fn field(v: ?std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v orelse return null) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn items(v: ?std.json.Value) []std.json.Value {
    return switch (v orelse return &.{}) {
        .array => |a| a.items,
        else => &.{},
    };
}

fn u64Of(v: ?std.json.Value) u64 {
    return switch (v orelse return 0) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        .float => |f| @intFromFloat(@max(f, 0)),
        else => 0,
    };
}

fn strOf(v: ?std.json.Value) []const u8 {
    return switch (v orelse return "") {
        .string => |s| s,
        else => "",
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const github_token = init.environ_map.get("GITHUB_TOKEN") orelse return error.MissingToken;
    const user = init.environ_map.get("GITHUB_USER") orelse return error.MissingUser;

    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{github_token});

    const headers = [_]std.http.Header{
        .{ .name = "User-Agent", .value = "readmegen" },
        .{ .name = "Authorization", .value = auth },
    };

    var client = try graphql.Client.init(
        gpa,
        io,
        "https://api.github.com/graphql",
        &headers,
    );
    defer client.deinit();

    var response = try client.execute(query, .{ .login = user });
    defer response.deinit();

    if (response.errors.len > 0) {
        for (response.errors) |err| {
            std.log.err("gql err: {s}", .{err.msg});
        }
        return error.GraphQLRequestFailed;
    }

    const data = response.data orelse return error.NoData;
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("{f}\n", .{std.json.fmt(data, .{})});
    try stdout.flush();
}
