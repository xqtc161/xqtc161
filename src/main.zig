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

const TotalCount = struct { totalCount: u64 };

const LanguageNode = struct { name: []const u8 };

const LanguageEdge = struct {
    size: u64,
    node: LanguageNode,
};

const Languages = struct {
    edges: []const LanguageEdge,
};

const RepoNode = struct {
    nameWithOwner: []const u8,
    stargazerCount: u64,
    languages: Languages,
};

const Repositories = struct {
    totalCount: u64,
    nodes: []const RepoNode,
};

const ContributionsCollection = struct {
    totalCommitContributions: u64,
    totalPullRequestContributions: u64,
    totalIssueContributions: u64,
    restrictedContributionsCount: u64,
};

const User = struct {
    followers: TotalCount,
    contributionsCollection: ContributionsCollection,
    repositories: Repositories,
    repositoriesContributedTo: TotalCount,
};

const Data = struct { user: User };

const ascii = @embedFile("ascii.txt");
const tagline = "meow :3";
const gif_path: ?[]const u8 = "./cat-kitten.gif";

fn writeBar(w: *std.Io.Writer, percent: f64, width: usize) !void {
    const partials = [_][]const u8{ "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" };
    const scaled = percent / 100.0 * @as(f64, @floatFromInt(width * 8));
    const eights: usize = @intFromFloat(@round(@max(scaled, 0)));
    const full = eights / 8;
    const rem = eights % 8;
    for (0..width) |i| {
        if (i < full) {
            try w.writeAll("█");
        } else if (i == full and rem > 0) {
            try w.writeAll(partials[rem - 1]);
        } else {
            try w.writeByte(' ');
        }
    }
}

fn render(
    w: *std.Io.Writer,
    user: []const u8,
    stats: Stats,
    langs: []const Lang,
    activity: []const []const u8,
) !void {
    try w.print("```\n{s}\n\n{s}\n\n\n", .{ ascii, tagline });

    try w.print("@{s}\n\n", .{user});
    try w.print("{d} followers {d} stars\n\n", .{ stats.followers, stats.stars });

    if (langs.len > 0) {
        for (langs) |l| {
            try w.print("{s:<12} ", .{l.name});
            try writeBar(w, l.percent, 12);
            try w.print("  {d:>5.1}%\n", .{l.percent});
        }
        try w.writeAll("\n\n");
    }

    if (activity.len > 0) {
        try w.writeAll("recent activity\n\n");
        for (activity) |a| try w.print("{s}\n", .{a});
        try w.writeByte('\n');
    }

    try w.print("commits {d}  issues {d}  pull requests {d}  repos {d} contrib {d}\n", .{ stats.commits, stats.issues, stats.prs, stats.repos, stats.contributed });
    try w.print("```\n", .{});
    if (gif_path) |p| try w.print("\n![]({s})\n", .{p});
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

    var response = try client.executeTyped(Data, query, .{ .login = user });
    defer response.deinit();

    if (response.errors.len > 0) {
        for (response.errors) |err| {
            std.log.err("gql err: {s}", .{err.msg});
        }
        return error.GraphQLRequestFailed;
    }

    const data = response.data orelse return error.NoData;
    const user_node = data.user;
    const contrib = user_node.contributionsCollection;
    const repos = user_node.repositories;

    var stars: u64 = 0;
    var lang_bytes: std.StringHashMapUnmanaged(u64) = .empty;
    var activity: std.ArrayList([]const u8) = .empty;

    for (repos.nodes) |node| {
        stars += node.stargazerCount;

        for (node.languages.edges) |edge| {
            if (edge.node.name.len == 0) continue;
            const gop = try lang_bytes.getOrPut(arena, edge.node.name);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += edge.size;
        }

        if (activity.items.len < 3 and node.nameWithOwner.len > 0) {
            try activity.append(arena, node.nameWithOwner);
        }
    }

    const stats: Stats = .{
        .followers = user_node.followers.totalCount,
        .stars = stars,
        .commits = contrib.totalCommitContributions + contrib.restrictedContributionsCount,
        .prs = contrib.totalPullRequestContributions,
        .issues = contrib.totalIssueContributions,
        .repos = repos.totalCount,
        .contributed = user_node.repositoriesContributedTo.totalCount,
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

    var doc: std.Io.Writer.Allocating = .init(gpa);
    defer doc.deinit();
    try render(&doc.writer, user, stats, top, activity.items);

    var quoted: std.Io.Writer.Allocating = .init(gpa);
    defer quoted.deinit();
    try quoted.writer.print("> [!CAUTION]\n", .{});

    var doc_split = std.mem.splitScalar(u8, doc.written(), '\n');
    while (doc_split.next()) |l| {
        try quoted.writer.print("> {s}\n", .{l});
    }
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "README.md",
        .data = quoted.written(),
    });
}
