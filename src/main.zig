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
    const user_node = field(data, "user") orelse return error.NoData;
    const contrib = field(user_node, "contributionsCollection");
    const repos = field(user_node, "repositories");

    var stars: u64 = 0;
    var lang_bytes: std.StringHashMapUnmanaged(u64) = .empty;
    var activity: std.ArrayList([]const u8) = .empty;

    for (items(field(repos, "nodes"))) |node| {
        stars += u64Of(field(node, "stargazerCount"));

        for (items(field(field(node, "languages"), "edges"))) |edge| {
            const name = strOf(field(field(edge, "node"), "name"));
            if (name.len == 0) continue;
            const gop = try lang_bytes.getOrPut(arena, name);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += u64Of(field(edge, "size"));
        }

        if (activity.items.len < 3) {
            const repo = strOf(field(node, "nameWithOwner"));
            if (repo.len > 0) try activity.append(arena, repo);
        }
    }

    const stats: Stats = .{
        .followers = u64Of(field(field(user_node, "followers"), "totalCount")),
        .stars = stars,
        .commits = u64Of(field(contrib, "totalCommitContributions")) +
            u64Of(field(contrib, "restrictedContributionsCount")),
        .prs = u64Of(field(contrib, "totalPullRequestContributions")),
        .issues = u64Of(field(contrib, "totalIssueContributions")),
        .repos = u64Of(field(repos, "totalCount")),
        .contributed = u64Of(field(field(user_node, "repositoriesContributedTo"), "totalCount")),
    };

    var total: u64 = 0;
    var vit = lang_bytes.valueIterator();
    while (vit.next()) |v| total += v.*;
    const denom: f64 = @floatFromInt(@max(total, 1));

    var langs: std.ArrayList(Lang) = .empty;
    var eit = lang_bytes.iterator();
    while (eit.next()) |e| {
        const bytes: f64 = @floatFromInt(e.value_ptr.*);
        try langs.append(arena, .{ .name = e.key_ptr.*, .percent = bytes / denom * 100.0 });
    }

    std.mem.sort(Lang, langs.items, {}, struct {
        fn desc(_: void, a: Lang, b: Lang) bool {
            return a.percent > b.percent;
        }
    }.desc);

    const top = langs.items[0..@min(6, langs.items.len)];

    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    const w = &out.interface;
    try w.print("@{s}\n", .{user});
    try w.print(
        "followers {d}  stars {d}  commits {d}  prs {d}  issues {d}  repos {d}  contributed {d}\n",
        .{ stats.followers, stats.stars, stats.commits, stats.prs, stats.issues, stats.repos, stats.contributed },
    );
    for (top) |l| try w.print("  {s:<12} {d:.1}%\n", .{ l.name, l.percent });
    for (activity.items) |a| try w.print("  {s}\n", .{a});
    try w.flush();
}
