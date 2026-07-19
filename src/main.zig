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

const Lang = struct { name: []const u8, percent: u64 };

const query = @embedFile("query.graphql");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const github_token = init.environ_map.get("GITHUB_TOKEN") orelse return error.MissingToken;
    const github_user = init.environ_map.get("GITHUB_USER") orelse return error.MissingUser;
    _ = github_user; // autofix

    const auth_header = try std.fmt.allocPrint(init.arena.allocator(), "Bearer {s}", .{github_token});
    _ = auth_header; // autofix

    var client = try graphql.Client.init(
        allocator,
        io,
        "https://api.github.com",
        &.{},
    );
    defer client.deinit();

    var response = try client.execute(query, .{});
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
