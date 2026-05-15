const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const AppError = error{
    InvalidCommand,
    InvalidArguments,
    MissingHome,
    MissingConfig,
    ConfigExists,
    ConfigInvalid,
    SqliteError,
    AuthRequired,
    HttpError,
    RateLimited,
    IoError,
};

const default_scopes = "tweet.read users.read bookmark.read offline.access";
const x_api_base = "https://api.x.com/2";
const bookmark_tweet_fields = "id,text,author_id,created_at,conversation_id,in_reply_to_user_id,display_text_range,entities,context_annotations,attachments,referenced_tweets,public_metrics,lang,possibly_sensitive,source,note_tweet,card_uri,article";
const bookmark_expansions = "author_id,attachments.media_keys,attachments.poll_ids,referenced_tweets.id,referenced_tweets.id.author_id,referenced_tweets.id.attachments.media_keys";
const bookmark_user_fields = "id,name,username,description,created_at,verified,verified_type,profile_image_url,profile_banner_url,public_metrics,url,location,protected";
const bookmark_media_fields = "media_key,type,url,preview_image_url,width,height,alt_text,duration_ms,public_metrics,variants";
const bookmark_poll_fields = "id,options,duration_minutes,end_datetime,voting_status";
const thread_estimated_cost_micros_per_post: i64 = 1000;
const default_thread_max_results: u32 = 100;
const default_thread_max_posts: u32 = 25;
const default_thread_window_hours: u32 = 6;

const ThreadSearchMode = enum {
    auto,
    timeline,
    recent,
    all,

    fn endpointPath(self: ThreadSearchMode) []const u8 {
        return switch (self) {
            .auto, .timeline => "/users/:id/tweets",
            .recent => "/tweets/search/recent",
            .all => "/tweets/search/all",
        };
    }

    fn methodLabel(self: ThreadSearchMode) []const u8 {
        return switch (self) {
            .auto, .timeline => "user_timeline",
            .recent => "search_recent",
            .all => "search_all",
        };
    }

    fn endpointLabel(self: ThreadSearchMode) []const u8 {
        return switch (self) {
            .auto, .timeline => "users/:id/tweets",
            .recent => "search/recent",
            .all => "search/all",
        };
    }
};

const ThreadExpansionOptions = struct {
    tweet_id: ?[]const u8 = null,
    changed: bool = false,
    dry_run: bool = false,
    yes: bool = false,
    retry_partial: bool = false,
    mode: ThreadSearchMode = .auto,
    max_results: u32 = default_thread_max_results,
    max_posts: u32 = default_thread_max_posts,
    limit: ?u32 = null,
};

const ThreadExpansionPlan = struct {
    root_tweet_id: []const u8,
    root_author_id: []const u8,
    root_author_username: []const u8,
    conversation_id: []const u8,
    query: []const u8,
    start_time: []const u8,
    end_time: []const u8,
    endpoint: ThreadSearchMode,
    max_results: u32,
    max_posts: u32,
    estimated_cost_micros: i64,

    fn deinit(self: ThreadExpansionPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.root_tweet_id);
        allocator.free(self.root_author_id);
        allocator.free(self.root_author_username);
        allocator.free(self.conversation_id);
        allocator.free(self.query);
        allocator.free(self.start_time);
        allocator.free(self.end_time);
    }
};

const ThreadMembershipPost = struct {
    tweet_id: []const u8,
    raw_json: []const u8,
    created_at: []const u8,

    fn deinit(self: ThreadMembershipPost, allocator: std.mem.Allocator) void {
        allocator.free(self.tweet_id);
        allocator.free(self.raw_json);
        allocator.free(self.created_at);
    }
};

const ThreadBuildResult = struct {
    status: []const u8,
    confidence: []const u8,
    post_count: u32,
    inferred_posts: u32,
};
const config_template =
    \\{
    \\  "x": {
    \\    "client_id": "your-client-id",
    \\    "client_secret": null,
    \\    "redirect_uri": "http://127.0.0.1:8765/callback",
    \\    "scopes": ["tweet.read", "users.read", "bookmark.read", "offline.access"]
    \\  },
    \\  "storage": {
    \\    "database_path": "~/.local/share/x-bookmarks/x_bookmarks.sqlite",
    \\    "token_path": "~/.local/share/x-bookmarks/oauth-token.json",
    \\    "assets_dir": "~/.local/share/x-bookmarks/assets"
    \\  },
    \\  "sync": {
    \\    "max_results": 100,
    \\    "store_raw_pages": true,
    \\    "download_media": true,
    \\    "quote_post_depth": 1,
    \\    "require_approval": true,
    \\    "stop_at_first_complete_bookmark": true
    \\  },
    \\  "viewer": {
    \\    "export_dir": "~/.local/share/x-bookmarks/viewer-export"
    \\  },
    \\  "obsidian": {
    \\    "vault_path": null,
    \\    "root_dir": "X Bookmarks",
    \\    "export_mode": "timeline-only",
    \\    "timeline_dir": "timeline",
    \\    "index_dir": "indexes",
    \\    "data_dir": "data",
    \\    "media_policy": "images-only"
    \\  }
    \\}
    \\
;

const HttpResponse = struct {
    status: std.http.Status,
    body: []u8,
    content_type: ?[]const u8 = null,
    rate_limit_reset: ?i64 = null,
};

const TokenState = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8,
    token_type: ?[]const u8,
    scope: ?[]const u8,
    expires_at: ?i64,
    account_user_id: ?[]const u8,

    fn deinit(self: TokenState, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        if (self.refresh_token) |value| allocator.free(value);
        if (self.token_type) |value| allocator.free(value);
        if (self.scope) |value| allocator.free(value);
        if (self.account_user_id) |value| allocator.free(value);
    }
};

const Runtime = struct {
    allocator: std.mem.Allocator,
    args: []const []const u8,
    config_path_arg: ?[]const u8 = null,
    home_arg: ?[]const u8 = null,
    command_index: usize = 1,
};

const Paths = struct {
    config_path: []const u8,
    config_dir: []const u8,
    state_dir: []const u8,
};

const ObsidianExportMode = enum {
    timeline_only,
    full,

    fn parse(value: []const u8) !ObsidianExportMode {
        if (std.mem.eql(u8, value, "timeline-only")) return .timeline_only;
        if (std.mem.eql(u8, value, "full")) return .full;
        try std.fs.File.stderr().deprecatedWriter().writeAll("obsidian export mode must be timeline-only or full\n");
        return AppError.InvalidArguments;
    }

    fn configParse(value: []const u8) !ObsidianExportMode {
        if (std.mem.eql(u8, value, "timeline-only")) return .timeline_only;
        if (std.mem.eql(u8, value, "full")) return .full;
        try std.fs.File.stderr().deprecatedWriter().writeAll("config error: obsidian.export_mode must be timeline-only or full\n");
        return AppError.ConfigInvalid;
    }

    fn label(self: ObsidianExportMode) []const u8 {
        return switch (self) {
            .timeline_only => "timeline-only",
            .full => "full",
        };
    }
};

const Config = struct {
    client_id: []const u8,
    client_secret: ?[]const u8,
    redirect_uri: []const u8,
    scopes: []const []const u8,
    database_path: []const u8,
    token_path: []const u8,
    assets_dir: []const u8,
    export_dir: []const u8,
    obsidian_vault_path: ?[]const u8,
    obsidian_root_dir: []const u8,
    obsidian_export_mode: ObsidianExportMode,
    obsidian_timeline_dir: []const u8,
    obsidian_note_dir: []const u8,
    obsidian_asset_dir: []const u8,
    obsidian_index_dir: []const u8,
    obsidian_data_dir: []const u8,
    obsidian_preserve_user_notes: bool,
    media_policy: []const u8,
    max_results: u32,
    store_raw_pages: bool,
    download_media: bool,
    quote_post_depth: u32,
    require_approval: bool,
    stop_at_first_complete_bookmark: bool,
    config_path: []const u8,
    base_dir: []const u8,
    home_override: ?[]const u8,

    fn default(allocator: std.mem.Allocator, paths: Paths, home_override: ?[]const u8) !Config {
        const state_dir = paths.state_dir;
        return .{
            .client_id = try allocator.dupe(u8, "your-client-id"),
            .client_secret = null,
            .redirect_uri = try allocator.dupe(u8, "http://127.0.0.1:8765/callback"),
            .scopes = try cloneScopes(allocator, &.{ "tweet.read", "users.read", "bookmark.read", "offline.access" }),
            .database_path = try std.fs.path.join(allocator, &.{ state_dir, "x_bookmarks.sqlite" }),
            .token_path = try std.fs.path.join(allocator, &.{ state_dir, "oauth-token.json" }),
            .assets_dir = try std.fs.path.join(allocator, &.{ state_dir, "assets" }),
            .export_dir = try std.fs.path.join(allocator, &.{ state_dir, "viewer-export" }),
            .obsidian_vault_path = null,
            .obsidian_root_dir = try allocator.dupe(u8, "X Bookmarks"),
            .obsidian_export_mode = .timeline_only,
            .obsidian_timeline_dir = try allocator.dupe(u8, "timeline"),
            .obsidian_note_dir = try allocator.dupe(u8, "bookmarks"),
            .obsidian_asset_dir = try allocator.dupe(u8, "assets"),
            .obsidian_index_dir = try allocator.dupe(u8, "indexes"),
            .obsidian_data_dir = try allocator.dupe(u8, "data"),
            .obsidian_preserve_user_notes = true,
            .media_policy = try allocator.dupe(u8, "images-only"),
            .max_results = 100,
            .store_raw_pages = true,
            .download_media = true,
            .quote_post_depth = 1,
            .require_approval = true,
            .stop_at_first_complete_bookmark = true,
            .config_path = paths.config_path,
            .base_dir = paths.config_dir,
            .home_override = if (home_override != null) paths.state_dir else null,
        };
    }
};

const Db = struct {
    handle: *c.sqlite3,

    fn open(path: []const u8, allocator: std.mem.Allocator) !Db {
        try ensureParentDir(path);
        const zpath = try allocator.dupeZ(u8, path);
        defer allocator.free(zpath);
        var raw: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(zpath.ptr, &raw, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null);
        if (rc != c.SQLITE_OK) return AppError.SqliteError;
        if (c.sqlite3_busy_timeout(raw.?, 5000) != c.SQLITE_OK) {
            _ = c.sqlite3_close(raw.?);
            return AppError.SqliteError;
        }
        return .{ .handle = raw.? };
    }

    fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    fn exec(self: *Db, sql: [:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql.ptr, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg != null) {
                std.debug.print("sqlite error: {s}\n", .{std.mem.span(err_msg)});
                c.sqlite3_free(err_msg);
            }
            return AppError.SqliteError;
        }
    }

    fn prepare(self: *Db, sql: []const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) {
            std.debug.print("sqlite prepare error: {s}\n", .{std.mem.span(c.sqlite3_errmsg(self.handle))});
            return AppError.SqliteError;
        }
        return stmt.?;
    }
};

pub fn main() void {
    run() catch |err| {
        const writer = std.fs.File.stderr().deprecatedWriter();
        writer.print("error: {}\n", .{err}) catch {};
        std.process.exit(exitCode(err));
    };
}

fn run() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var rt = Runtime{ .allocator = allocator, .args = args };
    try parseGlobalArgs(&rt);

    if (rt.command_index >= args.len) {
        try printHelp();
        return;
    }

    const cmd = args[rt.command_index];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printHelp();
    } else if (std.mem.eql(u8, cmd, "config")) {
        try commandConfig(&rt);
    } else if (std.mem.eql(u8, cmd, "db")) {
        try commandDb(&rt);
    } else if (std.mem.eql(u8, cmd, "auth")) {
        try commandAuth(&rt);
    } else if (std.mem.eql(u8, cmd, "sync")) {
        try commandSync(&rt);
    } else if (std.mem.eql(u8, cmd, "export")) {
        try commandExport(&rt);
    } else if (std.mem.eql(u8, cmd, "viewer")) {
        try commandViewer(&rt);
    } else if (std.mem.eql(u8, cmd, "assets")) {
        try commandAssets(&rt);
    } else if (std.mem.eql(u8, cmd, "obsidian")) {
        try commandObsidian(&rt);
    } else if (std.mem.eql(u8, cmd, "kb")) {
        try commandKb(&rt);
    } else if (std.mem.eql(u8, cmd, "threads")) {
        try commandThreads(&rt);
    } else if (std.mem.eql(u8, cmd, "integration")) {
        try commandIntegration(&rt);
    } else if (std.mem.eql(u8, cmd, "bookmarks")) {
        try commandBookmarks(&rt);
    } else {
        std.debug.print("unknown command: {s}\n\n", .{cmd});
        try printHelp();
        return AppError.InvalidCommand;
    }
}

fn exitCode(err: anyerror) u8 {
    return switch (err) {
        AppError.InvalidCommand, AppError.InvalidArguments => 2,
        AppError.MissingHome, AppError.MissingConfig, AppError.ConfigInvalid, AppError.ConfigExists => 3,
        AppError.AuthRequired => 4,
        AppError.RateLimited => 5,
        AppError.HttpError => 6,
        AppError.SqliteError => 7,
        else => 1,
    };
}

fn parseGlobalArgs(rt: *Runtime) !void {
    var i: usize = 1;
    while (i < rt.args.len) : (i += 1) {
        const arg = rt.args[i];
        if (!std.mem.startsWith(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= rt.args.len) return AppError.InvalidArguments;
            rt.config_path_arg = rt.args[i];
        } else if (std.mem.eql(u8, arg, "--home")) {
            i += 1;
            if (i >= rt.args.len) return AppError.InvalidArguments;
            rt.home_arg = rt.args[i];
        } else {
            break;
        }
    }
    rt.command_index = i;
}

fn printHelp() !void {
    const out = std.fs.File.stdout().deprecatedWriter();
    try out.writeAll(
        \\x-bookmarks
        \\
        \\Usage:
        \\  x-bookmarks [--config PATH] [--home PATH] config init [--force] [--client-id VALUE] [--redirect-uri URI]
        \\  x-bookmarks [--config PATH] [--home PATH] config status
        \\  x-bookmarks [--config PATH] [--home PATH] db init|status
        \\  x-bookmarks [--config PATH] [--home PATH] auth login [--manual|--no-open|--code CODE|--callback-url URL]
        \\  x-bookmarks [--config PATH] [--home PATH] auth status|refresh
        \\  x-bookmarks [--config PATH] [--home PATH] sync [--full] [--yolo|--yes] [--wait-rate-limit] [--limit-pages N] [--max-results N] [--no-media|--download-media] [--expand-threads] [--thread-search-all]
        \\  x-bookmarks [--config PATH] [--home PATH] export --format jsonl
        \\  x-bookmarks [--config PATH] [--home PATH] viewer export|serve
        \\  x-bookmarks [--config PATH] [--home PATH] assets verify
        \\  x-bookmarks [--config PATH] [--home PATH] assets retry [--only-transient] [--kind KIND] [--max-attempts N] [--dry-run]
        \\  x-bookmarks [--config PATH] [--home PATH] obsidian init --vault PATH [--root-dir NAME]
        \\  x-bookmarks [--config PATH] [--home PATH] obsidian status
        \\  x-bookmarks [--config PATH] [--home PATH] obsidian export [--mode timeline-only|full] [--changed] [--dry-run] [--clean-stale] [--vault PATH]
        \\  x-bookmarks [--config PATH] [--home PATH] obsidian migrate-media [--dry-run|--remove-local-videos]
        \\  x-bookmarks [--config PATH] [--home PATH] kb init
        \\  x-bookmarks [--config PATH] [--home PATH] kb export-raw-x [--changed]
        \\  x-bookmarks [--config PATH] [--home PATH] kb status
        \\  x-bookmarks [--config PATH] [--home PATH] threads detect [--changed]
        \\  x-bookmarks [--config PATH] [--home PATH] threads expand --tweet-id TWEET_ID [--dry-run] [--user-timeline|--search-recent|--search-all|--auto] [--max-results N] [--max-posts N] [--yes]
        \\  x-bookmarks [--config PATH] [--home PATH] threads expand --changed [--dry-run] [--limit N] [--user-timeline|--search-recent|--search-all|--auto]
        \\  x-bookmarks [--config PATH] [--home PATH] threads status
        \\  x-bookmarks [--config PATH] [--home PATH] bookmarks list [--limit N]
        \\  x-bookmarks [--config PATH] [--home PATH] bookmarks stats
        \\  x-bookmarks [--config PATH] [--home PATH] integration test --live [--limit-pages N] [--max-results N] [--no-media]
        \\
    );
}

fn commandConfig(rt: *Runtime) !void {
    const sub = try requiredSubcommand(rt, "config");
    if (std.mem.eql(u8, sub, "init")) {
        try configInit(rt);
    } else if (std.mem.eql(u8, sub, "status")) {
        const paths = try resolvePaths(rt.allocator, rt.config_path_arg, rt.home_arg);
        const cfg = try loadConfig(rt.allocator, paths, rt.home_arg);
        try printConfigStatus(rt.allocator, cfg);
        try validateConfig(cfg);
    } else {
        return AppError.InvalidCommand;
    }
}

fn configInit(rt: *Runtime) !void {
    var force = false;
    var client_id: ?[]const u8 = null;
    var redirect_uri: ?[]const u8 = null;

    var i = rt.command_index + 2;
    while (i < rt.args.len) : (i += 1) {
        const arg = rt.args[i];
        if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--client-id")) {
            i += 1;
            if (i >= rt.args.len) return AppError.InvalidArguments;
            client_id = rt.args[i];
        } else if (std.mem.eql(u8, arg, "--redirect-uri")) {
            i += 1;
            if (i >= rt.args.len) return AppError.InvalidArguments;
            redirect_uri = rt.args[i];
        } else {
            return AppError.InvalidArguments;
        }
    }

    const paths = try resolvePaths(rt.allocator, rt.config_path_arg, rt.home_arg);
    if (!force and fileExists(paths.config_path)) return AppError.ConfigExists;
    try ensureParentDir(paths.config_path);

    var text = try rt.allocator.dupe(u8, config_template);
    defer rt.allocator.free(text);
    if (client_id) |v| {
        const json = try jsonStringAlloc(rt.allocator, v);
        defer rt.allocator.free(json);
        text = try replaceOwned(rt.allocator, text, "\"your-client-id\"", json);
    }
    if (redirect_uri) |v| {
        const json = try jsonStringAlloc(rt.allocator, v);
        defer rt.allocator.free(json);
        text = try replaceOwned(rt.allocator, text, "\"http://127.0.0.1:8765/callback\"", json);
    }
    if (rt.home_arg != null) {
        text = try replaceOwned(rt.allocator, text, "~/.local/share/x-bookmarks/x_bookmarks.sqlite", "x_bookmarks.sqlite");
        text = try replaceOwned(rt.allocator, text, "~/.local/share/x-bookmarks/oauth-token.json", "oauth-token.json");
        text = try replaceOwned(rt.allocator, text, "~/.local/share/x-bookmarks/assets", "assets");
        text = try replaceOwned(rt.allocator, text, "~/.local/share/x-bookmarks/viewer-export", "viewer-export");
    } else if (try envVarPresent(rt.allocator, "XDG_DATA_HOME")) {
        text = try replaceTemplateStatePaths(rt.allocator, text, paths.state_dir);
    }

    try std.fs.cwd().writeFile(.{ .sub_path = paths.config_path, .data = text });
    const out = std.fs.File.stdout().deprecatedWriter();
    try out.print("created config: {s}\n", .{paths.config_path});
}

fn commandDb(rt: *Runtime) !void {
    const sub = try requiredSubcommand(rt, "db");
    const cfg = try loadRuntimeConfig(rt);
    if (std.mem.eql(u8, sub, "init")) {
        var db = try Db.open(cfg.database_path, rt.allocator);
        defer db.close();
        try applyMigrations(&db);
        try std.fs.cwd().makePath(cfg.assets_dir);
        try std.fs.cwd().makePath(cfg.export_dir);
        try std.fs.File.stdout().deprecatedWriter().print("initialized database: {s}\n", .{cfg.database_path});
    } else if (std.mem.eql(u8, sub, "status")) {
        try dbStatus(rt.allocator, cfg);
    } else {
        return AppError.InvalidCommand;
    }
}

fn commandAuth(rt: *Runtime) !void {
    const sub = try requiredSubcommand(rt, "auth");
    const cfg = try loadRuntimeConfig(rt);
    if (std.mem.eql(u8, sub, "status")) {
        try authStatus(rt.allocator, cfg);
    } else if (std.mem.eql(u8, sub, "login")) {
        var code: ?[]const u8 = null;
        var callback_state: ?[]const u8 = null;
        var manual = false;
        var open_browser = true;
        var owned_code: ?[]const u8 = null;
        defer if (owned_code) |value| rt.allocator.free(value);
        var owned_callback_state: ?[]const u8 = null;
        defer if (owned_callback_state) |value| rt.allocator.free(value);
        var i = rt.command_index + 2;
        while (i < rt.args.len) : (i += 1) {
            if (std.mem.eql(u8, rt.args[i], "--manual")) {
                manual = true;
            } else if (std.mem.eql(u8, rt.args[i], "--no-open")) {
                open_browser = false;
            } else if (std.mem.eql(u8, rt.args[i], "--code")) {
                if (code != null) return AppError.InvalidArguments;
                i += 1;
                if (i >= rt.args.len) return AppError.InvalidArguments;
                code = rt.args[i];
            } else if (std.mem.eql(u8, rt.args[i], "--callback-url")) {
                if (code != null) return AppError.InvalidArguments;
                i += 1;
                if (i >= rt.args.len) return AppError.InvalidArguments;
                owned_code = try callbackParamFromUrl(rt.allocator, rt.args[i], "code");
                owned_callback_state = try callbackParamFromUrl(rt.allocator, rt.args[i], "state");
                code = owned_code.?;
                callback_state = owned_callback_state.?;
            } else {
                return AppError.InvalidArguments;
            }
        }
        if (manual and code != null) return AppError.InvalidArguments;
        if (code) |value| {
            try authLoginExchange(rt.allocator, cfg, value, callback_state);
        } else if (manual) {
            try authLoginStart(rt.allocator, cfg);
        } else {
            try authLoginInteractive(rt.allocator, cfg, open_browser);
        }
    } else if (std.mem.eql(u8, sub, "refresh")) {
        var token = try loadToken(rt.allocator, cfg.token_path);
        defer token.deinit(rt.allocator);
        const refreshed = try refreshToken(rt.allocator, cfg, token);
        token.deinit(rt.allocator);
        token = refreshed;
        if (token.account_user_id) |account_user_id| {
            if (account_user_id.len > 0) {
                var db = try Db.open(cfg.database_path, rt.allocator);
                defer db.close();
                try applyMigrations(&db);
                try upsertTokenObservationFromState(&db, rt.allocator, cfg, account_user_id, token);
            }
        }
        try std.fs.File.stdout().deprecatedWriter().print("refreshed token for account: {s}\n", .{token.account_user_id orelse "unknown"});
    } else {
        return AppError.InvalidCommand;
    }
}

fn authStatus(allocator: std.mem.Allocator, cfg: Config) !void {
    const out = std.fs.File.stdout().deprecatedWriter();
    try out.print("token path: {s}\n", .{cfg.token_path});
    if (!fileExists(cfg.token_path)) {
        try out.writeAll("token: missing\n");
        return;
    }
    const token = try std.fs.cwd().readFileAlloc(allocator, cfg.token_path, 1024 * 1024);
    defer allocator.free(token);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, token, .{});
    defer parsed.deinit();
    if (std.mem.eql(u8, getString(parsed.value, "status") orelse "", "pending")) {
        try out.writeAll("token: pending OAuth login\naccess token: missing\nrefresh token: missing\naccount: unknown\nexpires_at: unknown\n");
        if (getString(parsed.value, "redirect_uri")) |redirect_uri| {
            try out.print("redirect uri: {s}\n", .{redirect_uri});
        }
        return;
    }
    const access = getString(parsed.value, "access_token");
    const refresh = getString(parsed.value, "refresh_token");
    const account = getString(parsed.value, "account_user_id") orelse "unknown";
    const expires_at = getInt(parsed.value, "expires_at");
    try out.print("token: present\naccess token: {s}\nrefresh token: {s}\n", .{
        if (access != null and access.?.len > 0) "present" else "missing",
        if (refresh != null and refresh.?.len > 0) "present" else "missing",
    });
    const expires_text = if (expires_at) |value| try std.fmt.allocPrint(allocator, "{}", .{value}) else "unknown";
    defer if (expires_at != null) allocator.free(expires_text);
    try out.print("account: {s}\nexpires_at: {s}\n", .{ account, expires_text });
}

fn authLoginStart(allocator: std.mem.Allocator, cfg: Config) !void {
    const auth_url = try authLoginPrepare(allocator, cfg);
    defer allocator.free(auth_url);

    const out = std.fs.File.stdout().deprecatedWriter();
    try out.writeAll("Open this authorization URL in a browser, then exchange the returned code with X OAuth 2.0.\n");
    try out.print("{s}\n\n", .{auth_url});
    try out.print("pending PKCE state written to: {s}\n", .{cfg.token_path});
}

fn authLoginInteractive(allocator: std.mem.Allocator, cfg: Config, open_browser: bool) !void {
    const auth_url = try authLoginPrepare(allocator, cfg);
    defer allocator.free(auth_url);
    const callback = try waitForOAuthCallback(allocator, cfg.redirect_uri, auth_url, open_browser);
    defer callback.deinit(allocator);
    try authLoginExchange(allocator, cfg, callback.code, callback.state);
}

fn authLoginPrepare(allocator: std.mem.Allocator, cfg: Config) ![]const u8 {
    if (std.mem.eql(u8, cfg.client_id, "your-client-id") or cfg.client_id.len == 0) {
        std.debug.print("config is missing x.client_id\n", .{});
        return AppError.ConfigInvalid;
    }
    const verifier = try makePkceVerifier(allocator);
    defer allocator.free(verifier);
    const challenge = try makePkceChallenge(allocator, verifier);
    defer allocator.free(challenge);
    const state = try makePkceVerifier(allocator);
    defer allocator.free(state);
    const scope_joined = try joinScopes(allocator, cfg.scopes, " ");
    defer allocator.free(scope_joined);
    const auth_url = try buildAuthUrl(allocator, cfg.client_id, cfg.redirect_uri, scope_joined, state, challenge);
    errdefer allocator.free(auth_url);

    try ensureParentDir(cfg.token_path);
    const created = try timestampString(allocator);
    defer allocator.free(created);
    const pending = try std.fmt.allocPrint(
        allocator,
        "{{\n  \"status\": \"pending\",\n  \"authorization_url\": {f},\n  \"redirect_uri\": {f},\n  \"scopes\": {f},\n  \"pkce_verifier\": {f},\n  \"state\": {f},\n  \"created_at\": {f}\n}}\n",
        .{
            std.json.fmt(auth_url, .{}),
            std.json.fmt(cfg.redirect_uri, .{}),
            std.json.fmt(scope_joined, .{}),
            std.json.fmt(verifier, .{}),
            std.json.fmt(state, .{}),
            std.json.fmt(created, .{}),
        },
    );
    defer allocator.free(pending);
    try writePrivateFile(cfg.token_path, pending);

    return auth_url;
}

fn authLoginExchange(allocator: std.mem.Allocator, cfg: Config, code: []const u8, callback_state: ?[]const u8) !void {
    const pending_text = try std.fs.cwd().readFileAlloc(allocator, cfg.token_path, 1024 * 1024);
    defer allocator.free(pending_text);
    var pending = try std.json.parseFromSlice(std.json.Value, allocator, pending_text, .{});
    defer pending.deinit();
    const verifier = getString(pending.value, "pkce_verifier") orelse {
        std.debug.print("token file does not contain pending pkce_verifier; run auth login first\n", .{});
        return AppError.AuthRequired;
    };
    if (callback_state) |actual_state| {
        try validateCallbackState(pending.value, actual_state);
    }

    const payload = if (cfg.client_secret != null) try oauthPayload(allocator, &.{
        .{ "grant_type", "authorization_code" },
        .{ "redirect_uri", cfg.redirect_uri },
        .{ "code_verifier", verifier },
        .{ "code", code },
    }) else try oauthPayload(allocator, &.{
        .{ "grant_type", "authorization_code" },
        .{ "client_id", cfg.client_id },
        .{ "redirect_uri", cfg.redirect_uri },
        .{ "code_verifier", verifier },
        .{ "code", code },
    });
    defer allocator.free(payload);

    const basic_auth = try oauthBasicAuthHeader(allocator, cfg.client_id, cfg.client_secret);
    defer if (basic_auth) |value| allocator.free(value);
    var headers_buf = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Authorization", .value = "" },
    };
    var header_count: usize = 2;
    if (basic_auth) |value| {
        headers_buf[2] = .{ .name = "Authorization", .value = value };
        header_count = 3;
    }
    const response = try httpFetch(allocator, .POST, "https://api.x.com/2/oauth2/token", payload, headers_buf[0..header_count]);
    defer freeHttpResponse(allocator, response);
    if (response.status != .ok) {
        std.debug.print("token exchange failed with HTTP {}\n", .{@intFromEnum(response.status)});
        return AppError.AuthRequired;
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const access = getString(parsed.value, "access_token") orelse return AppError.AuthRequired;
    const refresh = getString(parsed.value, "refresh_token");
    const expires_in = getInt(parsed.value, "expires_in") orelse 0;
    const token_type = getString(parsed.value, "token_type") orelse "bearer";
    const scope = getString(parsed.value, "scope") orelse default_scopes;
    const expires_at = if (expires_in > 0) std.time.timestamp() + expires_in else 0;

    const account = try fetchMe(allocator, access);
    defer account.deinit(allocator);
    var db = try Db.open(cfg.database_path, allocator);
    defer db.close();
    try applyMigrations(&db);
    try upsertAccount(&db, allocator, account.user_id, account.username, account.name, account.raw_json);
    try upsertTokenObservation(&db, allocator, account.user_id, token_type, scope, expires_at, cfg.token_path);

    const refresh_json = if (refresh) |r| try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(r, .{})}) else try allocator.dupe(u8, "null");
    defer allocator.free(refresh_json);
    const updated = try timestampString(allocator);
    defer allocator.free(updated);
    const token_json = try std.fmt.allocPrint(
        allocator,
        "{{\n  \"access_token\": {f},\n  \"refresh_token\": {s},\n  \"token_type\": {f},\n  \"scope\": {f},\n  \"expires_at\": {},\n  \"account_user_id\": {f},\n  \"updated_at\": \"{s}\"\n}}\n",
        .{
            std.json.fmt(access, .{}),
            refresh_json,
            std.json.fmt(token_type, .{}),
            std.json.fmt(scope, .{}),
            expires_at,
            std.json.fmt(account.user_id, .{}),
            updated,
        },
    );
    defer allocator.free(token_json);
    try writePrivateFile(cfg.token_path, token_json);
    try std.fs.File.stdout().deprecatedWriter().print("authenticated account: @{s} ({s})\n", .{ account.username, account.user_id });
}

const OAuthCallback = struct {
    code: []const u8,
    state: []const u8,

    fn deinit(self: OAuthCallback, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.state);
    }
};

const LocalRedirect = struct {
    host: []const u8,
    port: u16,
    path: []const u8,

    fn deinit(self: LocalRedirect, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.path);
    }
};

fn waitForOAuthCallback(allocator: std.mem.Allocator, redirect_uri: []const u8, auth_url: []const u8, open_browser: bool) !OAuthCallback {
    const redirect = try parseLocalHttpRedirectUri(allocator, redirect_uri);
    defer redirect.deinit(allocator);
    const listen_host = if (std.mem.eql(u8, redirect.host, "localhost")) "127.0.0.1" else redirect.host;
    const address = try std.net.Address.parseIp4(listen_host, redirect.port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    const out = std.fs.File.stdout().deprecatedWriter();
    try out.print("listening for OAuth callback at {s}\n", .{redirect_uri});
    if (open_browser and openUrlInBrowser(allocator, auth_url)) {
        try out.writeAll("opened authorization URL in the default browser\n");
    } else {
        try out.writeAll("open this authorization URL in a browser:\n");
        try out.print("{s}\n", .{auth_url});
    }

    while (true) {
        var conn = try server.accept();
        defer conn.stream.close();
        var buf: [8192]u8 = undefined;
        const n = try conn.stream.read(&buf);
        if (n == 0) continue;
        const req = buf[0..n];
        const target = parseHttpTarget(req) orelse {
            try writeOAuthCallbackResponse(&conn.stream, .bad_request, "Invalid OAuth callback request.");
            continue;
        };
        const path = httpTargetPath(target);
        if (!std.mem.eql(u8, path, redirect.path)) {
            try writeOAuthCallbackResponse(&conn.stream, .not_found, "This local server is waiting for the X OAuth callback.");
            continue;
        }
        if (callbackParamFromUrl(allocator, target, "error")) |oauth_error| {
            defer allocator.free(oauth_error);
            try writeOAuthCallbackResponse(&conn.stream, .bad_request, "X OAuth authorization was cancelled or failed. You can close this tab.");
            std.debug.print("OAuth callback returned error: {s}\n", .{oauth_error});
            return AppError.AuthRequired;
        } else |_| {}

        const code = callbackParamFromUrl(allocator, target, "code") catch {
            try writeOAuthCallbackResponse(&conn.stream, .bad_request, "OAuth callback was missing the authorization code.");
            continue;
        };
        errdefer allocator.free(code);
        const state = callbackParamFromUrl(allocator, target, "state") catch {
            allocator.free(code);
            try writeOAuthCallbackResponse(&conn.stream, .bad_request, "OAuth callback was missing state.");
            continue;
        };
        errdefer allocator.free(state);
        try writeOAuthCallbackResponse(&conn.stream, .ok, "OAuth callback received. You can close this tab and return to the terminal.");
        return .{ .code = code, .state = state };
    }
}

fn writeOAuthCallbackResponse(stream: anytype, status: std.http.Status, message: []const u8) !void {
    const reason = switch (status) {
        .ok => "OK",
        .bad_request => "Bad Request",
        .not_found => "Not Found",
        else => "OK",
    };
    const html_prefix =
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>x-bookmarks OAuth</title></head><body><h1>x-bookmarks</h1><p>";
    const html_suffix = "</p></body></html>";
    const len = html_prefix.len + message.len + html_suffix.len;
    var header_buf: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "HTTP/1.1 {} {s}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", .{ @intFromEnum(status), reason, len });
    try stream.writeAll(header);
    try stream.writeAll(html_prefix);
    try stream.writeAll(message);
    try stream.writeAll(html_suffix);
}

fn openUrlInBrowser(allocator: std.mem.Allocator, url: []const u8) bool {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .linux => &.{ "xdg-open", url },
        .windows => &.{ "rundll32", "url.dll,FileProtocolHandler", url },
        else => return false,
    };
    const result = std.process.Child.run(.{ .allocator = allocator, .argv = argv, .max_output_bytes = 1024 }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn commandSync(rt: *Runtime) !void {
    var full = false;
    var yolo = false;
    var wait_rate_limit = false;
    var expand_threads = false;
    var thread_search_all = false;
    var limit_pages: ?u32 = null;
    var max_results_override: ?u32 = null;
    var download_media_override: ?bool = null;
    var i = rt.command_index + 1;
    while (i < rt.args.len) : (i += 1) {
        const arg = rt.args[i];
        if (std.mem.eql(u8, arg, "--full")) {
            full = true;
        } else if (std.mem.eql(u8, arg, "--yolo") or std.mem.eql(u8, arg, "--yes")) {
            yolo = true;
        } else if (std.mem.eql(u8, arg, "--wait-rate-limit")) {
            wait_rate_limit = true;
        } else if (std.mem.eql(u8, arg, "--expand-threads")) {
            expand_threads = true;
        } else if (std.mem.eql(u8, arg, "--thread-search-all")) {
            expand_threads = true;
            thread_search_all = true;
        } else if (std.mem.eql(u8, arg, "--limit-pages")) {
            i += 1;
            if (i >= rt.args.len) return AppError.InvalidArguments;
            limit_pages = try parseU32Arg(rt.args[i]);
            if (limit_pages.? == 0) return AppError.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--max-results")) {
            i += 1;
            if (i >= rt.args.len) return AppError.InvalidArguments;
            max_results_override = try parseU32Arg(rt.args[i]);
        } else if (std.mem.eql(u8, arg, "--no-media")) {
            download_media_override = false;
        } else if (std.mem.eql(u8, arg, "--download-media")) {
            download_media_override = true;
        } else {
            return AppError.InvalidArguments;
        }
    }

    var cfg = try loadRuntimeConfig(rt);
    try applySyncCliOverrides(&cfg, max_results_override, download_media_override);
    try validateConfig(cfg);
    if (!fileExists(cfg.token_path)) {
        std.debug.print("missing OAuth token file: {s}\n", .{cfg.token_path});
        return AppError.AuthRequired;
    }
    var db = try Db.open(cfg.database_path, rt.allocator);
    defer db.close();
    try applyMigrations(&db);
    var token = try loadToken(rt.allocator, cfg.token_path);
    defer token.deinit(rt.allocator);
    try refreshTokenIfNeeded(rt.allocator, cfg, &token);
    var discovered_account_user_id: ?[]const u8 = null;
    defer if (discovered_account_user_id) |value| rt.allocator.free(value);
    const account_user_id = nonEmptyOptional(token.account_user_id) orelse blk: {
        const me = try fetchMe(rt.allocator, token.access_token);
        defer me.deinit(rt.allocator);
        try upsertAccount(&db, rt.allocator, me.user_id, me.username, me.name, me.raw_json);
        discovered_account_user_id = try rt.allocator.dupe(u8, me.user_id);
        break :blk discovered_account_user_id.?;
    };
    try upsertTokenObservationFromState(&db, rt.allocator, cfg, account_user_id, token);

    if (cfg.require_approval and !yolo) {
        const discovery = try discoverSyncWork(&db, rt.allocator, cfg, token.access_token, account_user_id, full, limit_pages, wait_rate_limit);
        try std.fs.File.stdout().deprecatedWriter().print(
            "Found {} new bookmarks and up to {} media assets across {} page(s). Download and write now? [y/N] ",
            .{ discovery.new_bookmarks, discovery.media_assets, discovery.pages },
        );
        var answer_buf: [8]u8 = undefined;
        const n = try std.fs.File.stdin().read(&answer_buf);
        const answer = std.mem.trim(u8, answer_buf[0..n], " \t\r\n");
        if (!(std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes"))) {
            try std.fs.File.stdout().deprecatedWriter().writeAll("sync cancelled\n");
            return;
        }
    }

    const request_json = try syncRequestJson(rt.allocator, cfg, full, yolo, limit_pages);
    defer rt.allocator.free(request_json);
    const run_id = try createSyncRun(&db, account_user_id, if (full) "full" else "incremental", request_json, rt.allocator);
    var retried_auth = false;
    const result = while (true) {
        break runBookmarkSync(&db, rt.allocator, cfg, token.access_token, account_user_id, run_id, full, limit_pages, wait_rate_limit) catch |err| {
            if (err == AppError.AuthRequired and !retried_auth and token.refresh_token != null) {
                const refreshed = try refreshToken(rt.allocator, cfg, token);
                token.deinit(rt.allocator);
                token = refreshed;
                retried_auth = true;
                continue;
            }
            const e = try std.fmt.allocPrint(rt.allocator, "{{\"error\":\"{}\"}}", .{err});
            defer rt.allocator.free(e);
            try markRunBookmarksIncomplete(&db, account_user_id, run_id);
            try finishSyncRun(&db, run_id, "failed", 0, 0, 0, false, null, e, rt.allocator);
            return err;
        };
    };
    defer if (result.early_stop_tweet_id) |value| rt.allocator.free(value);
    if (shouldDeactivateMissingAfterSync(full, limit_pages)) {
        try markBookmarksInactiveNotSeen(&db, account_user_id, run_id);
    } else if (full and limit_pages != null) {
        try recordSyncWarning(&db, rt.allocator, run_id, "full_sync_limited_no_deactivation", "{\"reason\":\"limit_pages\"}");
    }
    try refreshBookmarkCompletenessForRun(&db, rt.allocator, account_user_id, run_id, result.folder_state_accounted);
    try finishSyncRun(&db, run_id, "succeeded", result.pages, result.tweets, result.new_bookmarks, result.early_stop_used, result.early_stop_tweet_id, null, rt.allocator);
    if (result.ordering_warning) {
        try std.fs.File.stderr().deprecatedWriter().writeAll("warning: bookmark ordering shifted unexpectedly; consider `x-bookmarks sync --full`\n");
    }
    if (result.cap_warning) {
        try std.fs.File.stderr().deprecatedWriter().writeAll("warning: API returned at least 800 bookmarks and no next page; results may be capped by X API access behavior\n");
    }
    try std.fs.File.stdout().deprecatedWriter().print("sync succeeded: pages={} tweets={} new_bookmarks={} early_stop={}\n", .{ result.pages, result.tweets, result.new_bookmarks, result.early_stop_used });
    if (expand_threads) {
        const opts = ThreadExpansionOptions{
            .changed = true,
            .dry_run = !yolo,
            .yes = yolo,
            .mode = if (thread_search_all) .all else .auto,
            .max_results = default_thread_max_results,
        };
        if (!yolo) {
            try std.fs.File.stdout().deprecatedWriter().writeAll("sync thread expansion requires --yes/--yolo to fetch; showing dry run instead\n");
        }
        _ = try expandThreads(&db, rt.allocator, cfg, if (yolo) token.access_token else null, opts);
    }
}

fn commandExport(rt: *Runtime) !void {
    var format: []const u8 = "jsonl";
    var i = rt.command_index + 1;
    while (i < rt.args.len) : (i += 1) {
        if (std.mem.eql(u8, rt.args[i], "--format")) {
            i += 1;
            if (i >= rt.args.len) return AppError.InvalidArguments;
            format = rt.args[i];
        } else {
            return AppError.InvalidArguments;
        }
    }
    if (!std.mem.eql(u8, format, "jsonl")) return AppError.InvalidArguments;
    const cfg = try loadRuntimeConfig(rt);
    var db = try Db.open(cfg.database_path, rt.allocator);
    defer db.close();
    try applyMigrations(&db);
    try validateCompleteBookmarksForExport(&db, rt.allocator);
    try exportJsonl(&db, rt.allocator, std.fs.File.stdout().deprecatedWriter());
}

fn commandViewer(rt: *Runtime) !void {
    const sub = try requiredSubcommand(rt, "viewer");
    const cfg = try loadRuntimeConfig(rt);
    if (std.mem.eql(u8, sub, "export")) {
        var db = try Db.open(cfg.database_path, rt.allocator);
        defer db.close();
        try applyMigrations(&db);
        try viewerExport(&db, rt.allocator, cfg);
    } else if (std.mem.eql(u8, sub, "serve")) {
        try validateViewerExportFiles(rt.allocator, cfg.export_dir);
        try serveDirectory(rt.allocator, cfg.export_dir, 8766);
    } else {
        return AppError.InvalidCommand;
    }
}

fn commandObsidian(rt: *Runtime) !void {
    const sub = try requiredSubcommand(rt, "obsidian");
    if (std.mem.eql(u8, sub, "init")) {
        try obsidianInitCommand(rt);
        return;
    }

    const cfg = try loadRuntimeConfig(rt);
    var db = try Db.open(cfg.database_path, rt.allocator);
    defer db.close();
    try applyMigrations(&db);

    if (std.mem.eql(u8, sub, "status")) {
        try obsidianStatus(&db, rt.allocator, cfg, null);
    } else if (std.mem.eql(u8, sub, "export")) {
        var opts = ObsidianExportOptions{};
        var i = rt.command_index + 2;
        while (i < rt.args.len) : (i += 1) {
            const arg = rt.args[i];
            if (std.mem.eql(u8, arg, "--changed")) {
                opts.changed_only = true;
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                opts.dry_run = true;
            } else if (std.mem.eql(u8, arg, "--clean-stale")) {
                opts.clean_stale = true;
            } else if (std.mem.eql(u8, arg, "--mode")) {
                i += 1;
                if (i >= rt.args.len) return AppError.InvalidArguments;
                opts.mode_override = try ObsidianExportMode.parse(rt.args[i]);
            } else if (std.mem.eql(u8, arg, "--vault")) {
                i += 1;
                if (i >= rt.args.len) return AppError.InvalidArguments;
                opts.vault_override = rt.args[i];
            } else {
                return AppError.InvalidArguments;
            }
        }
        try obsidianExport(&db, rt.allocator, cfg, opts);
    } else if (std.mem.eql(u8, sub, "migrate-media")) {
        var dry_run = false;
        var remove = false;
        var i = rt.command_index + 2;
        while (i < rt.args.len) : (i += 1) {
            if (std.mem.eql(u8, rt.args[i], "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, rt.args[i], "--remove-local-videos")) {
                remove = true;
            } else {
                return AppError.InvalidArguments;
            }
        }
        if (dry_run == remove) return AppError.InvalidArguments;
        try obsidianMigrateMedia(&db, rt.allocator, cfg, dry_run);
    } else {
        return AppError.InvalidCommand;
    }
}

fn obsidianInitCommand(rt: *Runtime) !void {
    var vault: ?[]const u8 = null;
    var root_dir: ?[]const u8 = null;
    var i = rt.command_index + 2;
    while (i < rt.args.len) : (i += 1) {
        if (std.mem.eql(u8, rt.args[i], "--vault")) {
            i += 1;
            if (i >= rt.args.len) return AppError.InvalidArguments;
            vault = rt.args[i];
        } else if (std.mem.eql(u8, rt.args[i], "--root-dir")) {
            i += 1;
            if (i >= rt.args.len) return AppError.InvalidArguments;
            root_dir = rt.args[i];
        } else {
            return AppError.InvalidArguments;
        }
    }
    const vault_path = vault orelse return AppError.InvalidArguments;
    if (!std.fs.path.isAbsolute(vault_path)) {
        try std.fs.File.stderr().deprecatedWriter().writeAll("obsidian init requires an absolute --vault path\n");
        return AppError.ConfigInvalid;
    }
    if (root_dir) |r| if (!validManagedRelativePath(r)) return AppError.ConfigInvalid;

    const paths = try resolvePaths(rt.allocator, rt.config_path_arg, rt.home_arg);
    if (!fileExists(paths.config_path)) {
        std.debug.print("missing config: {s}\nrun `x-bookmarks config init` first\n", .{paths.config_path});
        return AppError.MissingConfig;
    }
    var cfg = try loadConfig(rt.allocator, paths, rt.home_arg);
    cfg.obsidian_vault_path = try rt.allocator.dupe(u8, vault_path);
    if (root_dir) |r| cfg.obsidian_root_dir = try rt.allocator.dupe(u8, r);
    try validateConfig(cfg);

    var resolved = try resolveObsidianPaths(rt.allocator, cfg, null);
    defer resolved.deinit(rt.allocator);
    try makeObsidianTimelineDirs(resolved);
    const readme_path = try std.fs.path.join(rt.allocator, &.{ resolved.root, "README.md" });
    defer rt.allocator.free(readme_path);
    if (!fileExists(readme_path)) {
        try std.fs.cwd().writeFile(.{ .sub_path = readme_path, .data = "# X Bookmarks\n\nThis directory is managed by x-bookmarks. The default export writes generated timeline notes for viewing bookmarked X posts in Obsidian.\n" });
    }
    try writeObsidianConfig(rt.allocator, paths.config_path, vault_path, cfg.obsidian_root_dir);
    try std.fs.File.stdout().deprecatedWriter().print("initialized Obsidian export root: {s}\n", .{resolved.root});
}

fn commandKb(rt: *Runtime) !void {
    const sub = try requiredSubcommand(rt, "kb");
    const cfg = try loadRuntimeConfig(rt);
    if (std.mem.eql(u8, sub, "init")) {
        if (rt.command_index + 2 != rt.args.len) return AppError.InvalidArguments;
        var paths = try resolveObsidianPaths(rt.allocator, cfg, null);
        defer paths.deinit(rt.allocator);
        try kbInit(rt.allocator, paths);
    } else if (std.mem.eql(u8, sub, "export-raw-x")) {
        var changed_only = false;
        var i = rt.command_index + 2;
        while (i < rt.args.len) : (i += 1) {
            if (std.mem.eql(u8, rt.args[i], "--changed")) {
                changed_only = true;
            } else {
                return AppError.InvalidArguments;
            }
        }
        var db = try Db.open(cfg.database_path, rt.allocator);
        defer db.close();
        try applyMigrations(&db);
        var paths = try resolveObsidianPaths(rt.allocator, cfg, null);
        defer paths.deinit(rt.allocator);
        const stats = try kbExportRawX(&db, rt.allocator, paths, changed_only);
        try std.fs.File.stdout().deprecatedWriter().print("kb raw X export: total={} written={} skipped={} processed={}\n", .{ stats.total, stats.written, stats.skipped_unchanged, stats.skipped_processed });
    } else if (std.mem.eql(u8, sub, "status")) {
        if (rt.command_index + 2 != rt.args.len) return AppError.InvalidArguments;
        var db = try Db.open(cfg.database_path, rt.allocator);
        defer db.close();
        try applyMigrations(&db);
        var paths = try resolveObsidianPaths(rt.allocator, cfg, null);
        defer paths.deinit(rt.allocator);
        try kbStatus(&db, rt.allocator, paths);
    } else {
        return AppError.InvalidCommand;
    }
}

fn commandThreads(rt: *Runtime) !void {
    const sub = try requiredSubcommand(rt, "threads");
    const cfg = try loadRuntimeConfig(rt);
    var db = try Db.open(cfg.database_path, rt.allocator);
    defer db.close();
    try applyMigrations(&db);

    if (std.mem.eql(u8, sub, "detect")) {
        var changed_only = false;
        var i = rt.command_index + 2;
        while (i < rt.args.len) : (i += 1) {
            if (std.mem.eql(u8, rt.args[i], "--changed")) {
                changed_only = true;
            } else {
                return AppError.InvalidArguments;
            }
        }
        const count = try detectThreadCandidates(&db, rt.allocator, changed_only);
        try std.fs.File.stdout().deprecatedWriter().print("thread candidates detected: {}\n", .{count});
    } else if (std.mem.eql(u8, sub, "status")) {
        if (rt.command_index + 2 != rt.args.len) return AppError.InvalidArguments;
        try printThreadStatus(&db);
    } else if (std.mem.eql(u8, sub, "expand")) {
        var opts = ThreadExpansionOptions{};
        var i = rt.command_index + 2;
        while (i < rt.args.len) : (i += 1) {
            const arg = rt.args[i];
            if (std.mem.eql(u8, arg, "--tweet-id")) {
                i += 1;
                if (i >= rt.args.len) return AppError.InvalidArguments;
                opts.tweet_id = rt.args[i];
            } else if (std.mem.eql(u8, arg, "--changed")) {
                opts.changed = true;
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                opts.dry_run = true;
            } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "--yolo")) {
                opts.yes = true;
            } else if (std.mem.eql(u8, arg, "--retry-partial")) {
                opts.retry_partial = true;
            } else if (std.mem.eql(u8, arg, "--user-timeline")) {
                opts.mode = .timeline;
            } else if (std.mem.eql(u8, arg, "--search-recent")) {
                opts.mode = .recent;
            } else if (std.mem.eql(u8, arg, "--search-all")) {
                opts.mode = .all;
            } else if (std.mem.eql(u8, arg, "--auto")) {
                opts.mode = .auto;
            } else if (std.mem.eql(u8, arg, "--max-results")) {
                i += 1;
                if (i >= rt.args.len) return AppError.InvalidArguments;
                opts.max_results = try parseU32Arg(rt.args[i]);
            } else if (std.mem.eql(u8, arg, "--max-posts")) {
                i += 1;
                if (i >= rt.args.len) return AppError.InvalidArguments;
                opts.max_posts = try parseU32Arg(rt.args[i]);
            } else if (std.mem.eql(u8, arg, "--limit")) {
                i += 1;
                if (i >= rt.args.len) return AppError.InvalidArguments;
                opts.limit = try parseU32Arg(rt.args[i]);
            } else {
                return AppError.InvalidArguments;
            }
        }
        if ((opts.tweet_id == null) == !opts.changed) return AppError.InvalidArguments;
        if (opts.max_results == 0 or opts.max_results > 100) return AppError.InvalidArguments;
        if (opts.max_posts == 0 or opts.max_posts > 100) return AppError.InvalidArguments;
        var token: ?TokenState = null;
        defer if (token) |t| t.deinit(rt.allocator);
        if (!opts.dry_run) {
            if (!opts.yes) {
                try std.fs.File.stderr().deprecatedWriter().writeAll("thread expansion fetches X API results; rerun with --dry-run or --yes\n");
                return AppError.InvalidArguments;
            }
            if (!fileExists(cfg.token_path)) return AppError.AuthRequired;
            token = try loadToken(rt.allocator, cfg.token_path);
            try refreshTokenIfNeeded(rt.allocator, cfg, &token.?);
        }
        const expanded = try expandThreads(&db, rt.allocator, cfg, if (token) |t| t.access_token else null, opts);
        try std.fs.File.stdout().deprecatedWriter().print("thread expansion processed: {}\n", .{expanded});
    } else {
        return AppError.InvalidCommand;
    }
}

fn commandAssets(rt: *Runtime) !void {
    const sub = try requiredSubcommand(rt, "assets");
    const cfg = try loadRuntimeConfig(rt);
    var db = try Db.open(cfg.database_path, rt.allocator);
    defer db.close();
    try applyMigrations(&db);
    if (std.mem.eql(u8, sub, "verify")) {
        try assetsVerify(&db, rt.allocator);
    } else if (std.mem.eql(u8, sub, "retry")) {
        try assetsRetryCommand(&db, rt.allocator, cfg, rt);
    } else {
        return AppError.InvalidCommand;
    }
}

const AssetRetryOptions = struct {
    only_transient: bool = false,
    kind: ?[]const u8 = null,
    max_attempts: u32 = 3,
    dry_run: bool = false,
};

const ObsidianExportOptions = struct {
    mode_override: ?ObsidianExportMode = null,
    changed_only: bool = false,
    dry_run: bool = false,
    clean_stale: bool = false,
    vault_override: ?[]const u8 = null,
};

const ObsidianPaths = struct {
    vault: []const u8,
    root: []const u8,
    notes: []const u8,
    assets: []const u8,
    images: []const u8,
    previews: []const u8,
    avatars: []const u8,
    indexes: []const u8,
    timeline: []const u8,
    data: []const u8,

    fn deinit(self: ObsidianPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.vault);
        allocator.free(self.root);
        allocator.free(self.notes);
        allocator.free(self.assets);
        allocator.free(self.images);
        allocator.free(self.previews);
        allocator.free(self.avatars);
        allocator.free(self.indexes);
        allocator.free(self.timeline);
        allocator.free(self.data);
    }
};

fn assetsRetryCommand(db: *Db, allocator: std.mem.Allocator, cfg: Config, rt: *Runtime) !void {
    var opts = AssetRetryOptions{};
    var i = rt.command_index + 2;
    while (i < rt.args.len) : (i += 1) {
        const arg = rt.args[i];
        if (std.mem.eql(u8, arg, "--only-transient")) {
            opts.only_transient = true;
        } else if (std.mem.eql(u8, arg, "--kind")) {
            i += 1;
            if (i >= rt.args.len) return AppError.InvalidArguments;
            opts.kind = rt.args[i];
        } else if (std.mem.eql(u8, arg, "--max-attempts")) {
            i += 1;
            if (i >= rt.args.len) return AppError.InvalidArguments;
            opts.max_attempts = try parseU32Arg(rt.args[i]);
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else {
            return AppError.InvalidArguments;
        }
    }
    try assetsRetry(db, allocator, cfg, opts);
}

fn commandIntegration(rt: *Runtime) !void {
    const sub = try requiredSubcommand(rt, "integration");
    if (!std.mem.eql(u8, sub, "test")) return AppError.InvalidCommand;

    var live = false;
    var limit_pages: u32 = 1;
    var max_results: ?u32 = 1;
    var download_media: ?bool = null;
    var i = rt.command_index + 2;
    while (i < rt.args.len) : (i += 1) {
        if (std.mem.eql(u8, rt.args[i], "--live")) {
            live = true;
        } else if (std.mem.eql(u8, rt.args[i], "--limit-pages")) {
            i += 1;
            if (i >= rt.args.len) return AppError.InvalidArguments;
            limit_pages = try parseU32Arg(rt.args[i]);
            if (limit_pages == 0) return AppError.InvalidArguments;
        } else if (std.mem.eql(u8, rt.args[i], "--max-results")) {
            i += 1;
            if (i >= rt.args.len) return AppError.InvalidArguments;
            max_results = try parseU32Arg(rt.args[i]);
        } else if (std.mem.eql(u8, rt.args[i], "--no-media")) {
            download_media = false;
        } else {
            return AppError.InvalidArguments;
        }
    }

    if (!live) {
        try std.fs.File.stdout().deprecatedWriter().writeAll("integration test skipped: pass --live to use real X API credentials\n");
        return;
    }

    const cfg = try loadRuntimeConfig(rt);
    try validateConfig(cfg);
    var token = try loadToken(rt.allocator, cfg.token_path);
    defer token.deinit(rt.allocator);
    try refreshTokenIfNeeded(rt.allocator, cfg, &token);
    const account = try fetchMe(rt.allocator, token.access_token);
    defer account.deinit(rt.allocator);

    const integration_name = try uniqueRunDirectoryName(rt.allocator, "live");
    defer rt.allocator.free(integration_name);
    const integration_dir = try std.fs.path.join(rt.allocator, &.{ ".zig-cache", "integration", integration_name });
    defer rt.allocator.free(integration_dir);
    try std.fs.cwd().makePath(integration_dir);

    var test_cfg = cfg;
    test_cfg.database_path = try std.fs.path.join(rt.allocator, &.{ integration_dir, "x_bookmarks.sqlite" });
    defer rt.allocator.free(test_cfg.database_path);
    test_cfg.assets_dir = try std.fs.path.join(rt.allocator, &.{ integration_dir, "assets" });
    defer rt.allocator.free(test_cfg.assets_dir);
    test_cfg.export_dir = try std.fs.path.join(rt.allocator, &.{ integration_dir, "viewer-export" });
    defer rt.allocator.free(test_cfg.export_dir);
    test_cfg.require_approval = false;
    try applySyncCliOverrides(&test_cfg, max_results, download_media);

    var db = try Db.open(test_cfg.database_path, rt.allocator);
    defer db.close();
    try applyMigrations(&db);
    try upsertAccount(&db, rt.allocator, account.user_id, account.username, account.name, account.raw_json);

    const request_json = try syncRequestJson(rt.allocator, test_cfg, false, true, limit_pages);
    defer rt.allocator.free(request_json);
    const run_id = try createSyncRun(&db, account.user_id, "integration", request_json, rt.allocator);
    const result = try runBookmarkSync(&db, rt.allocator, test_cfg, token.access_token, account.user_id, run_id, false, limit_pages, false);
    defer if (result.early_stop_tweet_id) |value| rt.allocator.free(value);
    try refreshBookmarkCompletenessForRun(&db, rt.allocator, account.user_id, run_id, result.folder_state_accounted);
    try finishSyncRun(&db, run_id, "succeeded", result.pages, result.tweets, result.new_bookmarks, result.early_stop_used, result.early_stop_tweet_id, null, rt.allocator);
    try viewerExport(&db, rt.allocator, test_cfg);
    try validateViewerExportFiles(rt.allocator, test_cfg.export_dir);
    try assetsVerify(&db, rt.allocator);

    try std.fs.File.stdout().deprecatedWriter().print(
        "integration test passed: account=@{s} pages={} tweets={} db={s} viewer={s}\n",
        .{ account.username, result.pages, result.tweets, test_cfg.database_path, test_cfg.export_dir },
    );
}

fn validateViewerExportFiles(allocator: std.mem.Allocator, export_dir: []const u8) !void {
    const required = [_][]const u8{
        "index.html",
        "data/bookmarks.json",
        "data/tweets.json",
        "data/folders.json",
        "data/folder-items.json",
        "data/media-assets.json",
        "data/tweet-media.json",
        "data/missing-references.json",
        "data/sync-warnings.json",
        "data/sync-summary.json",
    };
    for (required) |rel| {
        const path = try std.fs.path.join(allocator, &.{ export_dir, rel });
        defer allocator.free(path);
        if (!fileExists(path)) {
            if (!builtin.is_test) std.debug.print("viewer export missing required file: {s}\n", .{path});
            return AppError.IoError;
        }
    }
    try validateViewerAssetReferences(allocator, export_dir);
}

fn validateViewerAssetReferences(allocator: std.mem.Allocator, export_dir: []const u8) !void {
    const index_path = try std.fs.path.join(allocator, &.{ export_dir, "index.html" });
    defer allocator.free(index_path);
    const index = try std.fs.cwd().readFileAlloc(allocator, index_path, 1024 * 1024);
    defer allocator.free(index);

    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, index, offset, "assets/")) |start| {
        var end = start;
        while (end < index.len and !isAssetRefTerminator(index[end])) : (end += 1) {}
        if (end > start) {
            const rel = index[start..end];
            const path = try std.fs.path.join(allocator, &.{ export_dir, rel });
            defer allocator.free(path);
            if (!fileExists(path)) {
                if (!builtin.is_test) std.debug.print("viewer export missing referenced asset: {s}\n", .{path});
                return AppError.IoError;
            }
        }
        offset = end;
    }
}

fn isAssetRefTerminator(ch: u8) bool {
    return ch == '"' or ch == '\'' or ch == '<' or ch == '>' or ch == ')' or std.ascii.isWhitespace(ch);
}

fn commandBookmarks(rt: *Runtime) !void {
    const sub = try requiredSubcommand(rt, "bookmarks");
    const cfg = try loadRuntimeConfig(rt);
    var db = try Db.open(cfg.database_path, rt.allocator);
    defer db.close();
    try applyMigrations(&db);
    if (std.mem.eql(u8, sub, "stats")) {
        try printBookmarkStats(&db);
    } else if (std.mem.eql(u8, sub, "list")) {
        var limit: u32 = 50;
        var i = rt.command_index + 2;
        while (i < rt.args.len) : (i += 1) {
            if (std.mem.eql(u8, rt.args[i], "--limit")) {
                i += 1;
                if (i >= rt.args.len) return AppError.InvalidArguments;
                limit = try parseU32Arg(rt.args[i]);
            } else {
                return AppError.InvalidArguments;
            }
        }
        try listBookmarks(&db, limit);
    } else {
        return AppError.InvalidCommand;
    }
}

fn printBookmarkStats(db: *Db) !void {
    const out = std.fs.File.stdout().deprecatedWriter();
    try out.print("bookmarks: {}\n", .{try scalarCount(db, "SELECT count(*) FROM bookmark_items WHERE active = 1")});
    try out.print("complete: {}\n", .{try scalarCount(db, "SELECT count(*) FROM bookmark_items WHERE active = 1 AND complete_for_offline_render = 1")});
    try out.print("incomplete: {}\n", .{try scalarCount(db, "SELECT count(*) FROM bookmark_items WHERE active = 1 AND complete_for_offline_render = 0")});
    try out.print("tweets: {}\n", .{try scalarCount(db, "SELECT count(*) FROM tweets")});
    try out.print("media assets: {}\n", .{try scalarCount(db, "SELECT count(*) FROM media_assets")});
    try out.print("folders: {}\n", .{try scalarCount(db, "SELECT count(*) FROM bookmark_folders")});
    try out.print("missing references: {}\n", .{try scalarCount(db, "SELECT count(*) FROM missing_references")});
}

fn listBookmarks(db: *Db, limit: u32) !void {
    const stmt = try db.prepare(
        \\SELECT b.tweet_id, b.complete_for_offline_render, coalesce(u.username, ''), coalesce(t.text, ''), t.canonical_uri
        \\FROM bookmark_items b
        \\JOIN tweets t ON t.tweet_id = b.tweet_id
        \\LEFT JOIN users u ON u.user_id = t.author_id
        \\WHERE b.active = 1
        \\ORDER BY b.import_position IS NULL, b.import_position, b.last_seen_at DESC, b.tweet_id DESC
        \\LIMIT ?
    );
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, @intCast(limit));
    const out = std.fs.File.stdout().deprecatedWriter();
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        const text = colText(stmt, 3);
        const preview = if (text.len > 100) text[0..100] else text;
        try out.print("{s}\t{s}\t@{s}\t{s}\t{s}\n", .{
            colText(stmt, 0),
            if (c.sqlite3_column_int(stmt, 1) != 0) "complete" else "incomplete",
            colText(stmt, 2),
            preview,
            colText(stmt, 4),
        });
    }
}

fn shouldDeactivateMissingAfterSync(full: bool, limit_pages: ?u32) bool {
    return full and limit_pages == null;
}

fn requiredSubcommand(rt: *Runtime, parent: []const u8) ![]const u8 {
    _ = parent;
    const idx = rt.command_index + 1;
    if (idx >= rt.args.len) return AppError.InvalidCommand;
    return rt.args[idx];
}

fn parseU32Arg(value: []const u8) !u32 {
    return std.fmt.parseInt(u32, value, 10) catch AppError.InvalidArguments;
}

fn resolvePaths(allocator: std.mem.Allocator, explicit_config: ?[]const u8, home_override: ?[]const u8) !Paths {
    if (home_override) |h| {
        const home_abs = try absolutize(allocator, h);
        const config_path = if (explicit_config) |p| try absolutize(allocator, p) else try std.fs.path.join(allocator, &.{ home_abs, "config.json" });
        return .{
            .config_path = config_path,
            .config_dir = try dirnameDup(allocator, config_path),
            .state_dir = home_abs,
        };
    }

    const config_base = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try homeRelativePath(allocator, ".config"),
        else => return err,
    };
    defer allocator.free(config_base);
    const data_base = std.process.getEnvVarOwned(allocator, "XDG_DATA_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try homeRelativePath(allocator, ".local/share"),
        else => return err,
    };
    defer allocator.free(data_base);

    const config_path = if (explicit_config) |p| try absolutize(allocator, p) else try std.fs.path.join(allocator, &.{ config_base, "x-bookmarks", "config.json" });
    return .{
        .config_path = config_path,
        .config_dir = try dirnameDup(allocator, config_path),
        .state_dir = try std.fs.path.join(allocator, &.{ data_base, "x-bookmarks" }),
    };
}

fn homeRelativePath(allocator: std.mem.Allocator, suffix: []const u8) ![]const u8 {
    const home = try getHome(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, suffix });
}

fn loadRuntimeConfig(rt: *Runtime) !Config {
    const paths = try resolvePaths(rt.allocator, rt.config_path_arg, rt.home_arg);
    if (!fileExists(paths.config_path)) {
        std.debug.print("missing config: {s}\nrun `x-bookmarks config init` first\n", .{paths.config_path});
        return AppError.MissingConfig;
    }
    return loadConfig(rt.allocator, paths, rt.home_arg);
}

fn loadConfig(allocator: std.mem.Allocator, paths: Paths, home_override: ?[]const u8) !Config {
    var cfg = try Config.default(allocator, paths, home_override);
    if (!fileExists(paths.config_path)) return cfg;

    const text = try std.fs.cwd().readFileAlloc(allocator, paths.config_path, 4 * 1024 * 1024);
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return AppError.ConfigInvalid;

    if (getObject(root, "x")) |x| {
        if (getString(x, "client_id")) |v| cfg.client_id = try allocator.dupe(u8, v);
        if (getNullableString(x, "client_secret")) |v| cfg.client_secret = if (v) |s| try allocator.dupe(u8, s) else null;
        if (getString(x, "redirect_uri")) |v| cfg.redirect_uri = try allocator.dupe(u8, v);
        if (getArray(x, "scopes")) |arr| cfg.scopes = try parseScopes(allocator, arr);
    }
    if (getObject(root, "storage")) |storage| {
        if (getString(storage, "database_path")) |v| cfg.database_path = try resolveConfiguredPath(allocator, cfg, v);
        if (getString(storage, "token_path")) |v| cfg.token_path = try resolveConfiguredPath(allocator, cfg, v);
        if (getString(storage, "assets_dir")) |v| cfg.assets_dir = try resolveConfiguredPath(allocator, cfg, v);
    }
    if (getObject(root, "viewer")) |viewer| {
        if (getString(viewer, "export_dir")) |v| cfg.export_dir = try resolveConfiguredPath(allocator, cfg, v);
    }
    if (getObject(root, "obsidian")) |obsidian| {
        if (getNullableString(obsidian, "vault_path")) |v| cfg.obsidian_vault_path = if (v) |s| try resolveConfiguredPath(allocator, cfg, s) else null;
        if (getString(obsidian, "root_dir")) |v| cfg.obsidian_root_dir = try allocator.dupe(u8, v);
        if (getString(obsidian, "export_mode")) |v| cfg.obsidian_export_mode = try ObsidianExportMode.configParse(v);
        if (getString(obsidian, "timeline_dir")) |v| cfg.obsidian_timeline_dir = try allocator.dupe(u8, v);
        if (getString(obsidian, "note_dir")) |v| cfg.obsidian_note_dir = try allocator.dupe(u8, v);
        if (getString(obsidian, "asset_dir")) |v| cfg.obsidian_asset_dir = try allocator.dupe(u8, v);
        if (getString(obsidian, "index_dir")) |v| cfg.obsidian_index_dir = try allocator.dupe(u8, v);
        if (getString(obsidian, "data_dir")) |v| cfg.obsidian_data_dir = try allocator.dupe(u8, v);
        if (getBool(obsidian, "preserve_user_notes")) |v| cfg.obsidian_preserve_user_notes = v;
        if (getString(obsidian, "media_policy")) |v| cfg.media_policy = try allocator.dupe(u8, v);
    }
    if (getObject(root, "sync")) |sync| {
        if (getInt(sync, "max_results")) |v| cfg.max_results = try parseConfigU32(v);
        if (getBool(sync, "store_raw_pages")) |v| cfg.store_raw_pages = v;
        if (getBool(sync, "download_media")) |v| cfg.download_media = v;
        if (getInt(sync, "quote_post_depth")) |v| cfg.quote_post_depth = try parseConfigU32(v);
        if (getBool(sync, "require_approval")) |v| cfg.require_approval = v;
        if (getBool(sync, "stop_at_first_complete_bookmark")) |v| cfg.stop_at_first_complete_bookmark = v;
    }
    return cfg;
}

fn parseConfigU32(value: i64) !u32 {
    if (value < 0 or value > std.math.maxInt(u32)) return AppError.ConfigInvalid;
    return @intCast(value);
}

fn envVarPresent(allocator: std.mem.Allocator, name: []const u8) !bool {
    const value = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return err,
    };
    allocator.free(value);
    return true;
}

fn replaceTemplateStatePaths(allocator: std.mem.Allocator, text: []u8, state_dir: []const u8) ![]u8 {
    var out = text;
    const db_path = try std.fs.path.join(allocator, &.{ state_dir, "x_bookmarks.sqlite" });
    defer allocator.free(db_path);
    const token_path = try std.fs.path.join(allocator, &.{ state_dir, "oauth-token.json" });
    defer allocator.free(token_path);
    const assets_dir = try std.fs.path.join(allocator, &.{ state_dir, "assets" });
    defer allocator.free(assets_dir);
    const export_dir = try std.fs.path.join(allocator, &.{ state_dir, "viewer-export" });
    defer allocator.free(export_dir);

    out = try replaceJsonStringLiteral(allocator, out, "~/.local/share/x-bookmarks/x_bookmarks.sqlite", db_path);
    out = try replaceJsonStringLiteral(allocator, out, "~/.local/share/x-bookmarks/oauth-token.json", token_path);
    out = try replaceJsonStringLiteral(allocator, out, "~/.local/share/x-bookmarks/assets", assets_dir);
    out = try replaceJsonStringLiteral(allocator, out, "~/.local/share/x-bookmarks/viewer-export", export_dir);
    return out;
}

fn replaceJsonStringLiteral(allocator: std.mem.Allocator, original: []u8, needle_raw: []const u8, replacement_raw: []const u8) ![]u8 {
    const needle = try jsonStringAlloc(allocator, needle_raw);
    defer allocator.free(needle);
    const replacement = try jsonStringAlloc(allocator, replacement_raw);
    defer allocator.free(replacement);
    return replaceOwned(allocator, original, needle, replacement);
}

fn applySyncCliOverrides(cfg: *Config, max_results: ?u32, download_media: ?bool) !void {
    if (max_results) |value| {
        if (value < 1 or value > 100) return AppError.InvalidArguments;
        cfg.max_results = value;
    }
    if (download_media) |value| cfg.download_media = value;
}

fn resolveConfiguredPath(allocator: std.mem.Allocator, cfg: Config, p: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, p, "~/")) {
        const home = try getHome(allocator);
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, p[2..] });
    }
    if (std.fs.path.isAbsolute(p)) return allocator.dupe(u8, p);
    if (cfg.home_override) |h| return std.fs.path.join(allocator, &.{ h, p });
    return std.fs.path.join(allocator, &.{ cfg.base_dir, p });
}

fn printConfigStatus(allocator: std.mem.Allocator, cfg: Config) !void {
    const scopes = try joinScopes(allocator, cfg.scopes, " ");
    defer allocator.free(scopes);
    const out = std.fs.File.stdout().deprecatedWriter();
    try out.print(
        \\config path: {s}
        \\database path: {s}
        \\token path: {s}
        \\assets dir: {s}
        \\viewer export dir: {s}
        \\obsidian vault: {s}
        \\obsidian root dir: {s}
        \\obsidian export mode: {s}
        \\obsidian timeline dir: {s}
        \\media policy: {s}
        \\redirect uri: {s}
        \\scopes: {s}
        \\client id: {s}
        \\token file: {s}
        \\max results: {}
        \\download media: {}
        \\require approval: {}
        \\stop at first complete bookmark: {}
        \\
    , .{
        cfg.config_path,
        cfg.database_path,
        cfg.token_path,
        cfg.assets_dir,
        cfg.export_dir,
        cfg.obsidian_vault_path orelse "not configured",
        cfg.obsidian_root_dir,
        cfg.obsidian_export_mode.label(),
        cfg.obsidian_timeline_dir,
        cfg.media_policy,
        cfg.redirect_uri,
        scopes,
        if (cfg.client_id.len > 0 and !std.mem.eql(u8, cfg.client_id, "your-client-id")) "configured" else "missing",
        if (fileExists(cfg.token_path)) "present" else "missing",
        cfg.max_results,
        cfg.download_media,
        cfg.require_approval,
        cfg.stop_at_first_complete_bookmark,
    });
}

fn validateConfig(cfg: Config) !void {
    var valid = true;
    if (cfg.client_id.len == 0 or std.mem.eql(u8, cfg.client_id, "your-client-id")) {
        try configError("config error: x.client_id is required\n");
        valid = false;
    }
    if (cfg.redirect_uri.len == 0) {
        try configError("config error: x.redirect_uri is required\n");
        valid = false;
    }
    if (!hasScope(cfg.scopes, "tweet.read") or !hasScope(cfg.scopes, "users.read") or !hasScope(cfg.scopes, "bookmark.read") or !hasScope(cfg.scopes, "offline.access")) {
        try configError("config error: scopes must include tweet.read, users.read, bookmark.read, and offline.access\n");
        valid = false;
    }
    if (cfg.max_results < 1 or cfg.max_results > 100) {
        try configError("config error: sync.max_results must be between 1 and 100\n");
        valid = false;
    }
    if (cfg.quote_post_depth != 1) {
        try configError("config error: sync.quote_post_depth must be 1 in this version\n");
        valid = false;
    }
    if (cfg.database_path.len == 0 or cfg.token_path.len == 0 or cfg.assets_dir.len == 0 or cfg.export_dir.len == 0) {
        try configError("config error: storage and viewer paths must be non-empty\n");
        valid = false;
    }
    if (!validMediaPolicy(cfg.media_policy)) {
        try configError("config error: obsidian.media_policy must be images-only, all-local, or metadata-only\n");
        valid = false;
    }
    if (!validManagedRelativePath(cfg.obsidian_root_dir) or !validManagedRelativePath(cfg.obsidian_timeline_dir) or !validManagedRelativePath(cfg.obsidian_note_dir) or !validManagedRelativePath(cfg.obsidian_asset_dir) or !validManagedRelativePath(cfg.obsidian_index_dir) or !validManagedRelativePath(cfg.obsidian_data_dir)) {
        try configError("config error: obsidian managed directories must be relative paths without traversal\n");
        valid = false;
    }
    if (!valid) return AppError.ConfigInvalid;
}

fn validMediaPolicy(policy: []const u8) bool {
    return std.mem.eql(u8, policy, "images-only") or std.mem.eql(u8, policy, "all-local") or std.mem.eql(u8, policy, "metadata-only");
}

fn validManagedRelativePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    var parts = std.mem.splitAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn configError(message: []const u8) !void {
    if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().writeAll(message);
}

fn hasScope(scopes: []const []const u8, needle: []const u8) bool {
    for (scopes) |scope| {
        if (std.mem.eql(u8, scope, needle)) return true;
    }
    return false;
}

fn applyMigrations(db: *Db) !void {
    try db.exec(
        \\PRAGMA journal_mode=WAL;
        \\PRAGMA foreign_keys=ON;
        \\CREATE TABLE IF NOT EXISTS schema_migrations (
        \\  version TEXT PRIMARY KEY,
        \\  applied_at TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS accounts (
        \\  user_id TEXT PRIMARY KEY,
        \\  username TEXT,
        \\  name TEXT,
        \\  raw_json TEXT NOT NULL,
        \\  created_at TEXT,
        \\  updated_at TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS oauth_token_observations (
        \\  account_user_id TEXT PRIMARY KEY,
        \\  token_type TEXT,
        \\  scope TEXT,
        \\  expires_at TEXT,
        \\  token_file_path TEXT,
        \\  created_at TEXT NOT NULL,
        \\  updated_at TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS sync_runs (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  account_user_id TEXT NOT NULL,
        \\  mode TEXT NOT NULL,
        \\  status TEXT NOT NULL,
        \\  started_at TEXT NOT NULL,
        \\  finished_at TEXT,
        \\  request_params_json TEXT NOT NULL,
        \\  pages_requested INTEGER NOT NULL DEFAULT 0,
        \\  tweets_seen INTEGER NOT NULL DEFAULT 0,
        \\  new_bookmarks INTEGER NOT NULL DEFAULT 0,
        \\  early_stop_used INTEGER NOT NULL DEFAULT 0,
        \\  early_stop_tweet_id TEXT,
        \\  error_json TEXT
        \\);
        \\CREATE TABLE IF NOT EXISTS tweets (
        \\  tweet_id TEXT PRIMARY KEY,
        \\  author_id TEXT,
        \\  conversation_id TEXT,
        \\  canonical_uri TEXT NOT NULL,
        \\  twitter_uri TEXT NOT NULL,
        \\  created_at TEXT,
        \\  text TEXT,
        \\  lang TEXT,
        \\  possibly_sensitive INTEGER,
        \\  raw_json TEXT NOT NULL,
        \\  first_seen_at TEXT NOT NULL,
        \\  last_seen_at TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS users (
        \\  user_id TEXT PRIMARY KEY,
        \\  username TEXT,
        \\  name TEXT,
        \\  description TEXT,
        \\  profile_image_url TEXT,
        \\  raw_json TEXT NOT NULL,
        \\  first_seen_at TEXT NOT NULL,
        \\  last_seen_at TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS media (
        \\  media_key TEXT PRIMARY KEY,
        \\  type TEXT,
        \\  url TEXT,
        \\  preview_image_url TEXT,
        \\  raw_json TEXT NOT NULL,
        \\  first_seen_at TEXT NOT NULL,
        \\  last_seen_at TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS media_assets (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  media_key TEXT,
        \\  asset_kind TEXT NOT NULL,
        \\  source_url TEXT NOT NULL,
        \\  local_path TEXT NOT NULL,
        \\  content_type TEXT,
        \\  byte_size INTEGER,
        \\  sha256 TEXT,
        \\  width INTEGER,
        \\  height INTEGER,
        \\  status TEXT NOT NULL,
        \\  error_json TEXT,
        \\  first_seen_at TEXT NOT NULL,
        \\  last_checked_at TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS tweet_media (
        \\  tweet_id TEXT NOT NULL,
        \\  media_key TEXT NOT NULL,
        \\  position INTEGER,
        \\  PRIMARY KEY (tweet_id, media_key)
        \\);
        \\CREATE TABLE IF NOT EXISTS bookmark_items (
        \\  account_user_id TEXT NOT NULL,
        \\  tweet_id TEXT NOT NULL,
        \\  active INTEGER NOT NULL DEFAULT 1,
        \\  complete_for_offline_render INTEGER NOT NULL DEFAULT 0,
        \\  first_seen_run_id INTEGER NOT NULL,
        \\  last_seen_run_id INTEGER NOT NULL,
        \\  first_seen_at TEXT NOT NULL,
        \\  last_seen_at TEXT NOT NULL,
        \\  import_position INTEGER,
        \\  PRIMARY KEY (account_user_id, tweet_id)
        \\);
        \\CREATE TABLE IF NOT EXISTS bookmark_folders (
        \\  account_user_id TEXT NOT NULL,
        \\  folder_id TEXT NOT NULL,
        \\  name TEXT,
        \\  raw_json TEXT NOT NULL,
        \\  first_seen_at TEXT NOT NULL,
        \\  last_seen_at TEXT NOT NULL,
        \\  PRIMARY KEY (account_user_id, folder_id)
        \\);
        \\CREATE TABLE IF NOT EXISTS bookmark_folder_items (
        \\  account_user_id TEXT NOT NULL,
        \\  folder_id TEXT NOT NULL,
        \\  tweet_id TEXT NOT NULL,
        \\  first_seen_at TEXT NOT NULL,
        \\  last_seen_at TEXT NOT NULL,
        \\  PRIMARY KEY (account_user_id, folder_id, tweet_id)
        \\);
        \\CREATE TABLE IF NOT EXISTS raw_pages (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  sync_run_id INTEGER NOT NULL,
        \\  page_number INTEGER NOT NULL,
        \\  pagination_token TEXT,
        \\  next_token TEXT,
        \\  result_count INTEGER,
        \\  response_json TEXT NOT NULL,
        \\  fetched_at TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS sync_warnings (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  sync_run_id INTEGER NOT NULL,
        \\  warning_type TEXT NOT NULL,
        \\  context_json TEXT NOT NULL,
        \\  created_at TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS missing_references (
        \\  tweet_id TEXT NOT NULL,
        \\  referenced_tweet_id TEXT NOT NULL,
        \\  reference_type TEXT NOT NULL,
        \\  status TEXT NOT NULL,
        \\  raw_json TEXT NOT NULL,
        \\  first_seen_at TEXT NOT NULL,
        \\  last_seen_at TEXT NOT NULL,
        \\  PRIMARY KEY (tweet_id, referenced_tweet_id, reference_type)
        \\);
        \\CREATE TABLE IF NOT EXISTS thread_expansions (
        \\  root_tweet_id TEXT PRIMARY KEY,
        \\  root_author_id TEXT NOT NULL,
        \\  root_author_username TEXT,
        \\  conversation_id TEXT NOT NULL,
        \\  status TEXT NOT NULL,
        \\  method TEXT,
        \\  confidence TEXT,
        \\  post_count INTEGER NOT NULL DEFAULT 0,
        \\  fetched_at TEXT,
        \\  api_endpoint TEXT,
        \\  query TEXT,
        \\  max_results INTEGER,
        \\  result_count INTEGER,
        \\  estimated_cost_micros INTEGER,
        \\  error_json TEXT,
        \\  first_seen_at TEXT NOT NULL,
        \\  last_seen_at TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS thread_posts (
        \\  root_tweet_id TEXT NOT NULL,
        \\  tweet_id TEXT NOT NULL,
        \\  position INTEGER NOT NULL,
        \\  include_reason TEXT NOT NULL,
        \\  confidence TEXT NOT NULL,
        \\  PRIMARY KEY (root_tweet_id, tweet_id)
        \\);
        \\CREATE TABLE IF NOT EXISTS thread_candidates (
        \\  tweet_id TEXT PRIMARY KEY,
        \\  detected_at TEXT NOT NULL,
        \\  reason_json TEXT NOT NULL,
        \\  status TEXT NOT NULL
        \\);
        \\CREATE INDEX IF NOT EXISTS idx_bookmark_items_last_seen ON bookmark_items(account_user_id, last_seen_run_id);
        \\CREATE INDEX IF NOT EXISTS idx_media_assets_status ON media_assets(status);
        \\CREATE INDEX IF NOT EXISTS idx_thread_expansions_status ON thread_expansions(status);
        \\CREATE INDEX IF NOT EXISTS idx_thread_posts_root_position ON thread_posts(root_tweet_id, position);
        \\INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES ('001_initial', datetime('now'));
    );
    try ensureMediaAssetPolicyColumns(db);
    try backfillMediaAssetPolicyColumns(db);
}

fn ensureMediaAssetPolicyColumns(db: *Db) !void {
    if (!try tableColumnExists(db, "media_assets", "retrieval_policy")) try db.exec("ALTER TABLE media_assets ADD COLUMN retrieval_policy TEXT;");
    if (!try tableColumnExists(db, "media_assets", "retry_class")) try db.exec("ALTER TABLE media_assets ADD COLUMN retry_class TEXT;");
    if (!try tableColumnExists(db, "media_assets", "attempts")) try db.exec("ALTER TABLE media_assets ADD COLUMN attempts INTEGER DEFAULT 0;");
    if (!try tableColumnExists(db, "media_assets", "last_error_at")) try db.exec("ALTER TABLE media_assets ADD COLUMN last_error_at TEXT;");
    if (!try tableColumnExists(db, "media_assets", "removed_at")) try db.exec("ALTER TABLE media_assets ADD COLUMN removed_at TEXT;");
    if (!try tableColumnExists(db, "media_assets", "removal_reason")) try db.exec("ALTER TABLE media_assets ADD COLUMN removal_reason TEXT;");
}

fn tableColumnExists(db: *Db, table_name: []const u8, column_name: []const u8) !bool {
    const sql = try std.fmt.allocPrint(std.heap.page_allocator, "PRAGMA table_info({s})", .{table_name});
    defer std.heap.page_allocator.free(sql);
    const stmt = try db.prepare(sql);
    defer _ = c.sqlite3_finalize(stmt);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return false;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        if (std.mem.eql(u8, colText(stmt, 1), column_name)) return true;
    }
}

fn backfillMediaAssetPolicyColumns(db: *Db) !void {
    try db.exec(
        \\UPDATE media_assets
        \\SET retrieval_policy = CASE
        \\  WHEN asset_kind IN ('image', 'preview_image', 'author_avatar') THEN 'images-only'
        \\  WHEN asset_kind IN ('video_variant', 'animated_gif_variant') AND status = 'downloaded' THEN 'all-local'
        \\  WHEN asset_kind IN ('video_variant', 'animated_gif_variant') THEN 'images-only'
        \\  ELSE retrieval_policy
        \\END
        \\WHERE retrieval_policy IS NULL;
        \\UPDATE media_assets
        \\SET retry_class = CASE
        \\  WHEN status = 'downloaded' THEN NULL
        \\  WHEN status IN ('skipped', 'remote_only') THEN 'policy'
        \\  WHEN status = 'removed' THEN 'policy'
        \\  WHEN status = 'failed' AND (error_json LIKE '%503%' OR error_json LIKE '%502%' OR error_json LIKE '%500%' OR error_json LIKE '%504%' OR error_json LIKE '%UnknownHostName%' OR error_json LIKE '%timeout%' OR error_json LIKE '%Timeout%' OR error_json LIKE '%connection reset%') THEN 'transient'
        \\  WHEN status = 'failed' AND (error_json LIKE '%403%' OR error_json LIKE '%404%') THEN 'permanent'
        \\  WHEN status = 'failed' THEN 'unknown'
        \\  ELSE retry_class
        \\END
        \\WHERE retry_class IS NULL OR retry_class = '';
    );
}

fn dbStatus(allocator: std.mem.Allocator, cfg: Config) !void {
    const out = std.fs.File.stdout().deprecatedWriter();
    try out.print("database path: {s}\n", .{cfg.database_path});
    if (!fileExists(cfg.database_path)) {
        try out.writeAll("database: missing\n");
        return;
    }
    var db = try Db.open(cfg.database_path, allocator);
    defer db.close();
    try applyMigrations(&db);
    try printCount(&db, "schema_migrations");
    try printCount(&db, "accounts");
    try printCount(&db, "sync_runs");
    try printCount(&db, "bookmark_items");
    try printCount(&db, "tweets");
    try printCount(&db, "users");
    try printCount(&db, "media");
    try printCount(&db, "media_assets");
    try printCount(&db, "bookmark_folders");
    try printCount(&db, "sync_warnings");
}

fn printCount(db: *Db, table: []const u8) !void {
    var sql_buf: [128]u8 = undefined;
    const sql = try std.fmt.bufPrint(&sql_buf, "SELECT count(*) FROM {s}", .{table});
    const stmt = try db.prepare(sql);
    defer _ = c.sqlite3_finalize(stmt);
    const rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_ROW) return AppError.SqliteError;
    const count = c.sqlite3_column_int64(stmt, 0);
    try std.fs.File.stdout().deprecatedWriter().print("{s}: {}\n", .{ table, count });
}

fn createSyncRun(db: *Db, account_user_id: []const u8, mode: []const u8, request_json: []const u8, allocator: std.mem.Allocator) !i64 {
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const stmt = try db.prepare("INSERT INTO sync_runs(account_user_id, mode, status, started_at, request_params_json) VALUES (?, ?, 'running', ?, ?)");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, account_user_id);
    try bindText(stmt, 2, mode);
    try bindText(stmt, 3, now);
    try bindText(stmt, 4, request_json);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
    return c.sqlite3_last_insert_rowid(db.handle);
}

fn finishSyncRun(db: *Db, run_id: i64, status: []const u8, pages: u32, tweets: u32, new_bookmarks: u32, early: bool, early_tweet_id: ?[]const u8, error_json: ?[]const u8, allocator: std.mem.Allocator) !void {
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const stmt = try db.prepare(
        "UPDATE sync_runs SET status=?, finished_at=?, pages_requested=?, tweets_seen=?, new_bookmarks=?, early_stop_used=?, early_stop_tweet_id=?, error_json=? WHERE id=?",
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, status);
    try bindText(stmt, 2, now);
    _ = c.sqlite3_bind_int(stmt, 3, @intCast(pages));
    _ = c.sqlite3_bind_int(stmt, 4, @intCast(tweets));
    _ = c.sqlite3_bind_int(stmt, 5, @intCast(new_bookmarks));
    _ = c.sqlite3_bind_int(stmt, 6, if (early) 1 else 0);
    if (early_tweet_id) |id| try bindText(stmt, 7, id) else _ = c.sqlite3_bind_null(stmt, 7);
    if (error_json) |e| try bindText(stmt, 8, e) else _ = c.sqlite3_bind_null(stmt, 8);
    _ = c.sqlite3_bind_int64(stmt, 9, run_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn beginTransaction(db: *Db) !void {
    try db.exec("BEGIN IMMEDIATE;");
}

fn commitTransaction(db: *Db) !void {
    try db.exec("COMMIT;");
}

fn rollbackTransaction(db: *Db) !void {
    db.exec("ROLLBACK;") catch {};
}

const AccountInfo = struct {
    user_id: []const u8,
    username: []const u8,
    name: []const u8,
    raw_json: []u8,

    fn deinit(self: AccountInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.user_id);
        allocator.free(self.username);
        allocator.free(self.name);
        allocator.free(self.raw_json);
    }
};

const SyncResult = struct {
    pages: u32 = 0,
    tweets: u32 = 0,
    new_bookmarks: u32 = 0,
    early_stop_used: bool = false,
    early_stop_tweet_id: ?[]const u8 = null,
    ordering_warning: bool = false,
    cap_warning: bool = false,
    folder_state_accounted: bool = true,
};

const SyncDiscovery = struct {
    pages: u32 = 0,
    tweets_seen: u32 = 0,
    new_bookmarks: u32 = 0,
    media_assets: u32 = 0,
    early_stop_used: bool = false,
};

const ExistingAsset = struct {
    media_key: []const u8,
    asset_kind: []const u8,
    local_path: []const u8,
    content_type: []const u8,
    byte_size: i64,
    sha256: []const u8,

    fn deinit(self: ExistingAsset, allocator: std.mem.Allocator) void {
        allocator.free(self.media_key);
        allocator.free(self.asset_kind);
        allocator.free(self.local_path);
        allocator.free(self.content_type);
        allocator.free(self.sha256);
    }
};

fn httpFetch(allocator: std.mem.Allocator, method: std.http.Method, url: []const u8, payload: ?[]const u8, headers: []const std.http.Header) !HttpResponse {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();

    const uri = try std.Uri.parse(url);
    const redirect_behavior: std.http.Client.Request.RedirectBehavior = if (payload == null) @enumFromInt(3) else .unhandled;
    var req = try client.request(method, uri, .{
        .redirect_behavior = redirect_behavior,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = headers,
    });
    defer req.deinit();

    if (payload) |body| {
        req.transfer_encoding = .{ .content_length = body.len };
        var request_body = try req.sendBodyUnflushed(&.{});
        try request_body.writer.writeAll(body);
        try request_body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    const redirect_buffer = try allocator.alloc(u8, 8 * 1024);
    defer allocator.free(redirect_buffer);
    var response = try req.receiveHead(redirect_buffer);
    var rate_limit_reset: ?i64 = null;
    var content_type: ?[]const u8 = null;
    var header_it = response.head.iterateHeaders();
    while (header_it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-rate-limit-reset")) {
            rate_limit_reset = std.fmt.parseInt(i64, header.value, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
            content_type = try allocator.dupe(u8, header.value);
        }
    }

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer.len > 0) allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(&body_writer.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };

    return .{ .status = response.head.status, .body = try body_writer.toOwnedSlice(), .content_type = content_type, .rate_limit_reset = rate_limit_reset };
}

fn freeHttpResponse(allocator: std.mem.Allocator, response: HttpResponse) void {
    allocator.free(response.body);
    if (response.content_type) |value| allocator.free(value);
}

const FormPair = struct { []const u8, []const u8 };

fn oauthPayload(allocator: std.mem.Allocator, pairs: []const FormPair) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var first = true;
    for (pairs) |pair| {
        if (!first) try out.append(allocator, '&');
        first = false;
        const k = try urlEncode(allocator, pair[0]);
        defer allocator.free(k);
        const v = try urlEncode(allocator, pair[1]);
        defer allocator.free(v);
        try out.appendSlice(allocator, k);
        try out.append(allocator, '=');
        try out.appendSlice(allocator, v);
    }
    return out.toOwnedSlice(allocator);
}

fn oauthBasicAuthHeader(allocator: std.mem.Allocator, client_id: []const u8, client_secret: ?[]const u8) !?[]const u8 {
    const secret = client_secret orelse return null;
    const raw = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ client_id, secret });
    defer allocator.free(raw);
    const encoded_len = std.base64.standard.Encoder.calcSize(raw.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, raw);
    return try std.fmt.allocPrint(allocator, "Basic {s}", .{encoded});
}

fn loadToken(allocator: std.mem.Allocator, token_path: []const u8) !TokenState {
    const text = try std.fs.cwd().readFileAlloc(allocator, token_path, 4 * 1024 * 1024);
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const root = parsed.value;
    const access = getString(root, "access_token") orelse {
        std.debug.print("token file does not contain access_token: {s}\n", .{token_path});
        return AppError.AuthRequired;
    };
    const access_token = try allocator.dupe(u8, access);
    errdefer allocator.free(access_token);
    const refresh_token = try dupeOptionalString(allocator, getString(root, "refresh_token"));
    errdefer if (refresh_token) |value| allocator.free(value);
    const token_type = try dupeOptionalString(allocator, getString(root, "token_type"));
    errdefer if (token_type) |value| allocator.free(value);
    const scope = try dupeOptionalString(allocator, getString(root, "scope"));
    errdefer if (scope) |value| allocator.free(value);
    const account_user_id = try dupeOptionalString(allocator, getString(root, "account_user_id"));
    errdefer if (account_user_id) |value| allocator.free(value);
    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .token_type = token_type,
        .scope = scope,
        .expires_at = getInt(root, "expires_at"),
        .account_user_id = account_user_id,
    };
}

fn dupeOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |string| return try allocator.dupe(u8, string);
    return null;
}

fn refreshTokenIfNeeded(allocator: std.mem.Allocator, cfg: Config, token: *TokenState) !void {
    if (token.expires_at == null or token.refresh_token == null or token.expires_at.? > std.time.timestamp() + 300) return;
    const refreshed = try refreshToken(allocator, cfg, token.*);
    token.deinit(allocator);
    token.* = refreshed;
}

fn refreshToken(allocator: std.mem.Allocator, cfg: Config, token: TokenState) !TokenState {
    if (token.refresh_token == null) return AppError.AuthRequired;
    const payload = if (cfg.client_secret != null) try oauthPayload(allocator, &.{
        .{ "grant_type", "refresh_token" },
        .{ "refresh_token", token.refresh_token.? },
    }) else try oauthPayload(allocator, &.{
        .{ "grant_type", "refresh_token" },
        .{ "client_id", cfg.client_id },
        .{ "refresh_token", token.refresh_token.? },
    });
    defer allocator.free(payload);
    const basic_auth = try oauthBasicAuthHeader(allocator, cfg.client_id, cfg.client_secret);
    defer if (basic_auth) |value| allocator.free(value);
    var headers_buf = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Authorization", .value = "" },
    };
    var header_count: usize = 2;
    if (basic_auth) |value| {
        headers_buf[2] = .{ .name = "Authorization", .value = value };
        header_count = 3;
    }
    const response = try httpFetch(allocator, .POST, "https://api.x.com/2/oauth2/token", payload, headers_buf[0..header_count]);
    defer freeHttpResponse(allocator, response);
    if (response.status != .ok) return AppError.AuthRequired;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const access = getString(parsed.value, "access_token") orelse return AppError.AuthRequired;
    const refresh = getString(parsed.value, "refresh_token") orelse token.refresh_token.?;
    const expires_in = getInt(parsed.value, "expires_in") orelse 0;
    const expires_at = if (expires_in > 0) std.time.timestamp() + expires_in else 0;
    const updated = try timestampString(allocator);
    defer allocator.free(updated);
    const account_json = try optionalJsonStringAlloc(allocator, nonEmptyOptional(token.account_user_id));
    defer allocator.free(account_json);
    const token_json = try std.fmt.allocPrint(
        allocator,
        "{{\n  \"access_token\": {f},\n  \"refresh_token\": {f},\n  \"token_type\": {f},\n  \"scope\": {f},\n  \"expires_at\": {},\n  \"account_user_id\": {s},\n  \"updated_at\": {f}\n}}\n",
        .{
            std.json.fmt(access, .{}),
            std.json.fmt(refresh, .{}),
            std.json.fmt(getString(parsed.value, "token_type") orelse token.token_type orelse "bearer", .{}),
            std.json.fmt(getString(parsed.value, "scope") orelse token.scope orelse default_scopes, .{}),
            expires_at,
            account_json,
            std.json.fmt(updated, .{}),
        },
    );
    defer allocator.free(token_json);
    try writePrivateFile(cfg.token_path, token_json);
    return try loadToken(allocator, cfg.token_path);
}

fn fetchMe(allocator: std.mem.Allocator, access_token: []const u8) !AccountInfo {
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth);
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth },
        .{ .name = "Accept", .value = "application/json" },
    };
    const url = x_api_base ++ "/users/me?user.fields=id,name,username,description,created_at,verified,verified_type,profile_image_url,profile_banner_url,public_metrics,url,location,protected";
    const response = try httpFetch(allocator, .GET, url, null, &headers);
    defer freeHttpResponse(allocator, response);
    if (response.status != .ok) {
        std.debug.print("/2/users/me failed HTTP {}\n", .{@intFromEnum(response.status)});
        return AppError.AuthRequired;
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const data = getObject(parsed.value, "data") orelse return AppError.AuthRequired;
    const raw = try jsonValueAlloc(allocator, data);
    return .{
        .user_id = try allocator.dupe(u8, getString(data, "id") orelse return AppError.AuthRequired),
        .username = try allocator.dupe(u8, getString(data, "username") orelse ""),
        .name = try allocator.dupe(u8, getString(data, "name") orelse ""),
        .raw_json = raw,
    };
}

fn syncRequestJson(allocator: std.mem.Allocator, cfg: Config, full: bool, yolo: bool, limit_pages: ?u32) ![]const u8 {
    const limit_text = if (limit_pages) |n| try std.fmt.allocPrint(allocator, "{}", .{n}) else try allocator.dupe(u8, "null");
    defer allocator.free(limit_text);
    return std.fmt.allocPrint(
        allocator,
        "{{\"mode\":\"{s}\",\"max_results\":{},\"download_media\":{},\"quote_post_depth\":{},\"limit_pages\":{s},\"yolo\":{},\"request_shape\":{{\"endpoint\":\"GET /2/users/:id/bookmarks\",\"tweet.fields\":{f},\"expansions\":{f},\"user.fields\":{f},\"media.fields\":{f},\"poll.fields\":{f}}},\"folder_request_shape\":{{\"folders_endpoint\":\"GET /2/users/:id/bookmarks/folders\",\"folder_items_endpoint\":\"GET /2/users/:id/bookmarks/folders/:folder_id\"}}}}",
        .{
            if (full) "full" else "incremental",
            cfg.max_results,
            cfg.download_media,
            cfg.quote_post_depth,
            limit_text,
            yolo,
            std.json.fmt(bookmark_tweet_fields, .{}),
            std.json.fmt(bookmark_expansions, .{}),
            std.json.fmt(bookmark_user_fields, .{}),
            std.json.fmt(bookmark_media_fields, .{}),
            std.json.fmt(bookmark_poll_fields, .{}),
        },
    );
}

fn runBookmarkSync(db: *Db, allocator: std.mem.Allocator, cfg: Config, access_token: []const u8, account_user_id: []const u8, run_id: i64, full: bool, limit_pages: ?u32, wait_rate_limit: bool) !SyncResult {
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth);
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth },
        .{ .name = "Accept", .value = "application/json" },
    };

    var result = SyncResult{};
    var next_token: ?[]u8 = null;
    defer if (next_token) |value| allocator.free(value);
    var page_number: u32 = 1;
    while (true) : (page_number += 1) {
        if (limit_pages) |max| if (page_number > max) break;
        if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("sync: requesting bookmark page {} max_results={}\n", .{ page_number, cfg.max_results });
        const url = try buildBookmarksUrl(allocator, account_user_id, cfg.max_results, next_token);
        defer allocator.free(url);
        const response = try httpFetch(allocator, .GET, url, null, &headers);
        defer freeHttpResponse(allocator, response);
        if (response.status == .too_many_requests) {
            if (wait_rate_limit and response.rate_limit_reset != null) {
                const now = std.time.timestamp();
                if (response.rate_limit_reset.? > now) {
                    const seconds = response.rate_limit_reset.? - now;
                    try std.fs.File.stderr().deprecatedWriter().print("rate limited; waiting {} seconds until reset\n", .{seconds});
                    std.Thread.sleep(@as(u64, @intCast(seconds)) * std.time.ns_per_s);
                    page_number -= 1;
                    continue;
                }
            }
            if (response.rate_limit_reset) |reset| {
                try std.fs.File.stderr().deprecatedWriter().print("rate limited; x-rate-limit-reset={}\n", .{reset});
            }
            return AppError.RateLimited;
        }
        if (response.status == .unauthorized) return AppError.AuthRequired;
        if (response.status != .ok) {
            std.debug.print("bookmark page failed HTTP {}\n", .{@intFromEnum(response.status)});
            return AppError.HttpError;
        }
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
        defer parsed.deinit();
        const meta = getObject(parsed.value, "meta");
        const next = if (meta) |m| getString(m, "next_token") else null;
        const result_count = if (meta) |m| getInt(m, "result_count") orelse 0 else 0;
        const tweets_before_page = result.tweets;
        try beginTransaction(db);
        if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("sync: storing bookmark page {} result_count={}\n", .{ page_number, result_count });
        ingestBookmarkPage(db, allocator, cfg, account_user_id, run_id, full, page_number, next_token, next, result_count, response.body, parsed.value, &result) catch |err| {
            try rollbackTransaction(db);
            return err;
        };
        try commitTransaction(db);
        if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("sync: committed page {} tweets_seen={} new_bookmarks={} early_stop={}\n", .{ page_number, result.tweets, result.new_bookmarks, result.early_stop_used });
        if (cfg.download_media and result.tweets > tweets_before_page) {
            if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("sync: downloading assets for page {}\n", .{page_number});
            try downloadAssetsFromIncludes(db, allocator, cfg.assets_dir, parsed.value, cfg.media_policy);
            if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("sync: finished assets for page {}\n", .{page_number});
        }
        result.pages += 1;
        if (result.early_stop_used) break;
        if (next) |tok| {
            try replaceOwnedOptionalString(allocator, &next_token, tok);
        } else {
            if (result.tweets >= 800) result.cap_warning = true;
            break;
        }
    }
    if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().writeAll("sync: syncing bookmark folders\n");
    result.folder_state_accounted = try syncFolders(db, allocator, access_token, account_user_id, run_id, wait_rate_limit);
    if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("sync: bookmark folders accounted={}\n", .{result.folder_state_accounted});
    return result;
}

fn discoverSyncWork(db: *Db, allocator: std.mem.Allocator, cfg: Config, access_token: []const u8, account_user_id: []const u8, full: bool, limit_pages: ?u32, wait_rate_limit: bool) !SyncDiscovery {
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth);
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth },
        .{ .name = "Accept", .value = "application/json" },
    };

    var result = SyncDiscovery{};
    var next_token: ?[]u8 = null;
    defer if (next_token) |value| allocator.free(value);
    var page_number: u32 = 1;
    while (true) : (page_number += 1) {
        if (limit_pages) |max| if (page_number > max) break;
        const url = try buildBookmarksUrl(allocator, account_user_id, cfg.max_results, next_token);
        defer allocator.free(url);
        const response = try httpFetch(allocator, .GET, url, null, &headers);
        defer freeHttpResponse(allocator, response);
        if (response.status == .too_many_requests) {
            if (rateLimitWaitSeconds(response, wait_rate_limit, std.time.timestamp())) |seconds| {
                try std.fs.File.stderr().deprecatedWriter().print("rate limited during discovery; waiting {} seconds until reset\n", .{seconds});
                std.Thread.sleep(@as(u64, @intCast(seconds)) * std.time.ns_per_s);
                page_number -= 1;
                continue;
            }
            return AppError.RateLimited;
        }
        if (response.status == .unauthorized) return AppError.AuthRequired;
        if (response.status != .ok) return AppError.HttpError;

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
        defer parsed.deinit();
        result.pages += 1;
        result.media_assets += countPlannedMediaAssets(parsed.value, cfg.media_policy);

        if (getArray(parsed.value, "data")) |tweets| {
            for (tweets.items) |tweet| {
                if (tweet != .object) continue;
                const tweet_id = getString(tweet, "id") orelse continue;
                result.tweets_seen += 1;
                if (!try bookmarkExists(db, account_user_id, tweet_id)) result.new_bookmarks += 1;
                if (!full and cfg.stop_at_first_complete_bookmark and try isBookmarkComplete(db, account_user_id, tweet_id)) {
                    result.early_stop_used = true;
                    break;
                }
            }
        }
        if (result.early_stop_used) break;
        const meta = getObject(parsed.value, "meta");
        const next = if (meta) |m| getString(m, "next_token") else null;
        if (next) |tok| try replaceOwnedOptionalString(allocator, &next_token, tok) else break;
    }
    return result;
}

fn replaceOwnedOptionalString(allocator: std.mem.Allocator, target: *?[]u8, value: []const u8) !void {
    const owned = try allocator.dupe(u8, value);
    if (target.*) |old| allocator.free(old);
    target.* = owned;
}

fn countPlannedMediaAssets(root: std.json.Value, media_policy: []const u8) u32 {
    var count: u32 = 0;
    const includes = getObject(root, "includes") orelse return 0;
    if (getArray(includes, "media")) |media_arr| {
        for (media_arr.items) |media| {
            if (media != .object) continue;
            if (!std.mem.eql(u8, media_policy, "metadata-only")) {
                if (getString(media, "url") != null) count += 1;
                if (getString(media, "preview_image_url") != null) count += 1;
            }
            if (getArray(media, "variants")) |variants| {
                if (variants.items.len > 0 and !std.mem.eql(u8, media_policy, "metadata-only")) count += 1;
            }
        }
    }
    if (getArray(includes, "users")) |users_arr| {
        for (users_arr.items) |user| {
            if (user != .object) continue;
            if (!std.mem.eql(u8, media_policy, "metadata-only") and getString(user, "profile_image_url") != null) count += 1;
        }
    }
    return count;
}

fn buildBookmarksUrl(allocator: std.mem.Allocator, account_user_id: []const u8, max_results: u32, next_token: ?[]const u8) ![]const u8 {
    const pagination = if (next_token) |tok| blk: {
        const encoded = try urlEncode(allocator, tok);
        defer allocator.free(encoded);
        break :blk try std.fmt.allocPrint(allocator, "&pagination_token={s}", .{encoded});
    } else try allocator.dupe(u8, "");
    defer allocator.free(pagination);
    return std.fmt.allocPrint(
        allocator,
        x_api_base ++ "/users/{s}/bookmarks?max_results={}&tweet.fields={s}&expansions={s}&user.fields={s}&media.fields={s}&poll.fields={s}{s}",
        .{
            account_user_id,
            max_results,
            bookmark_tweet_fields,
            bookmark_expansions,
            bookmark_user_fields,
            bookmark_media_fields,
            bookmark_poll_fields,
            pagination,
        },
    );
}

fn ingestBookmarkPage(
    db: *Db,
    allocator: std.mem.Allocator,
    cfg: Config,
    account_user_id: []const u8,
    run_id: i64,
    full: bool,
    page_number: u32,
    pagination_token: ?[]const u8,
    next_token: ?[]const u8,
    result_count: i64,
    response_body: []const u8,
    root: std.json.Value,
    result: *SyncResult,
) !void {
    if (cfg.store_raw_pages) try insertRawPage(db, allocator, run_id, page_number, pagination_token, next_token, result_count, response_body);
    try ingestIncludes(db, allocator, root);
    if (getArray(root, "data")) |tweets| {
        for (tweets.items, 0..) |tweet, idx| {
            if (tweet != .object) continue;
            const tweet_id = getString(tweet, "id") orelse continue;
            if (!full and cfg.stop_at_first_complete_bookmark and try isBookmarkComplete(db, account_user_id, tweet_id)) {
                result.early_stop_used = true;
                result.early_stop_tweet_id = try allocator.dupe(u8, tweet_id);
                break;
            }
            try upsertTweetFromValue(db, allocator, tweet);
            try recordMissingQuoteReferences(db, allocator, root, tweet);
            const complete = try bookmarkCompleteForOfflineRender(db, allocator, tweet_id);
            const position: i64 = @intCast((page_number - 1) * cfg.max_results + @as(u32, @intCast(idx)));
            if (!full) {
                if (try previousImportPosition(db, account_user_id, tweet_id)) |previous| {
                    if (previous > position) result.ordering_warning = true;
                }
            }
            const was_new = try upsertBookmarkItem(db, allocator, account_user_id, tweet_id, run_id, position, complete);
            _ = try detectAndRecordThreadCandidate(db, allocator, tweet, false);
            if (was_new) result.new_bookmarks += 1;
            result.tweets += 1;
        }
    }
}

fn upsertAccount(db: *Db, allocator: std.mem.Allocator, user_id: []const u8, username: []const u8, name: []const u8, raw_json: []const u8) !void {
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const stmt = try db.prepare(
        \\INSERT INTO accounts(user_id, username, name, raw_json, created_at, updated_at)
        \\VALUES (?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(user_id) DO UPDATE SET username=excluded.username, name=excluded.name, raw_json=excluded.raw_json, updated_at=excluded.updated_at
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, user_id);
    try bindText(stmt, 2, username);
    try bindText(stmt, 3, name);
    try bindText(stmt, 4, raw_json);
    try bindText(stmt, 5, now);
    try bindText(stmt, 6, now);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn upsertTokenObservation(db: *Db, allocator: std.mem.Allocator, user_id: []const u8, token_type: []const u8, scope: []const u8, expires_at: i64, token_path: []const u8) !void {
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const exp = try std.fmt.allocPrint(allocator, "{}", .{expires_at});
    defer allocator.free(exp);
    const stmt = try db.prepare(
        \\INSERT INTO oauth_token_observations(account_user_id, token_type, scope, expires_at, token_file_path, created_at, updated_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(account_user_id) DO UPDATE SET token_type=excluded.token_type, scope=excluded.scope, expires_at=excluded.expires_at, token_file_path=excluded.token_file_path, updated_at=excluded.updated_at
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, user_id);
    try bindText(stmt, 2, token_type);
    try bindText(stmt, 3, scope);
    try bindText(stmt, 4, exp);
    try bindText(stmt, 5, token_path);
    try bindText(stmt, 6, now);
    try bindText(stmt, 7, now);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn upsertTokenObservationFromState(db: *Db, allocator: std.mem.Allocator, cfg: Config, account_user_id: []const u8, token: TokenState) !void {
    try upsertTokenObservation(
        db,
        allocator,
        account_user_id,
        token.token_type orelse "bearer",
        token.scope orelse default_scopes,
        token.expires_at orelse 0,
        cfg.token_path,
    );
}

fn insertRawPage(db: *Db, allocator: std.mem.Allocator, run_id: i64, page_number: u32, pagination_token: ?[]const u8, next_token: ?[]const u8, result_count: i64, response_json: []const u8) !void {
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const stmt = try db.prepare(
        "INSERT INTO raw_pages(sync_run_id, page_number, pagination_token, next_token, result_count, response_json, fetched_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    );
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, run_id);
    _ = c.sqlite3_bind_int(stmt, 2, @intCast(page_number));
    if (pagination_token) |v| try bindText(stmt, 3, v) else _ = c.sqlite3_bind_null(stmt, 3);
    if (next_token) |v| try bindText(stmt, 4, v) else _ = c.sqlite3_bind_null(stmt, 4);
    _ = c.sqlite3_bind_int64(stmt, 5, result_count);
    try bindText(stmt, 6, response_json);
    try bindText(stmt, 7, now);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn recordSyncWarning(db: *Db, allocator: std.mem.Allocator, run_id: i64, warning_type: []const u8, context_json: []const u8) !void {
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const stmt = try db.prepare(
        "INSERT INTO sync_warnings(sync_run_id, warning_type, context_json, created_at) VALUES (?, ?, ?, ?)",
    );
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, run_id);
    try bindText(stmt, 2, warning_type);
    try bindText(stmt, 3, context_json);
    try bindText(stmt, 4, now);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn ingestIncludes(db: *Db, allocator: std.mem.Allocator, root: std.json.Value) !void {
    const includes = getObject(root, "includes") orelse return;
    if (getArray(includes, "users")) |users_arr| {
        for (users_arr.items) |user| {
            if (user != .object) continue;
            try upsertUserFromValue(db, allocator, user);
        }
    }
    if (getArray(includes, "media")) |media_arr| {
        for (media_arr.items) |media| {
            if (media != .object) continue;
            try upsertMediaFromValue(db, allocator, media);
        }
    }
    if (getArray(includes, "tweets")) |tweets_arr| {
        for (tweets_arr.items) |tweet| {
            if (tweet != .object) continue;
            try upsertTweetFromValue(db, allocator, tweet);
        }
    }
}

fn upsertTweetFromValue(db: *Db, allocator: std.mem.Allocator, tweet: std.json.Value) !void {
    const tweet_id = getString(tweet, "id") orelse return;
    const author_id = getString(tweet, "author_id");
    const username = if (author_id) |aid| try usernameForUser(db, allocator, aid) else null;
    defer if (username) |u| allocator.free(u);
    const canonical = try canonicalUri(allocator, username, tweet_id);
    defer allocator.free(canonical);
    const twitter = try std.fmt.allocPrint(allocator, "https://twitter.com/i/web/status/{s}", .{tweet_id});
    defer allocator.free(twitter);
    const raw = try jsonValueAlloc(allocator, tweet);
    defer allocator.free(raw);
    const now = try timestampString(allocator);
    defer allocator.free(now);

    const stmt = try db.prepare(
        \\INSERT INTO tweets(tweet_id, author_id, conversation_id, canonical_uri, twitter_uri, created_at, text, lang, possibly_sensitive, raw_json, first_seen_at, last_seen_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(tweet_id) DO UPDATE SET author_id=excluded.author_id, conversation_id=excluded.conversation_id, canonical_uri=excluded.canonical_uri, twitter_uri=excluded.twitter_uri, created_at=excluded.created_at, text=excluded.text, lang=excluded.lang, possibly_sensitive=excluded.possibly_sensitive, raw_json=excluded.raw_json, last_seen_at=excluded.last_seen_at
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    if (author_id) |v| try bindText(stmt, 2, v) else _ = c.sqlite3_bind_null(stmt, 2);
    if (getString(tweet, "conversation_id")) |v| try bindText(stmt, 3, v) else _ = c.sqlite3_bind_null(stmt, 3);
    try bindText(stmt, 4, canonical);
    try bindText(stmt, 5, twitter);
    if (getString(tweet, "created_at")) |v| try bindText(stmt, 6, v) else _ = c.sqlite3_bind_null(stmt, 6);
    const stored_text = rawXPostText(tweet, getString(tweet, "text") orelse "");
    if (stored_text.len > 0) try bindText(stmt, 7, stored_text) else _ = c.sqlite3_bind_null(stmt, 7);
    if (getString(tweet, "lang")) |v| try bindText(stmt, 8, v) else _ = c.sqlite3_bind_null(stmt, 8);
    if (getBool(tweet, "possibly_sensitive")) |v| _ = c.sqlite3_bind_int(stmt, 9, if (v) 1 else 0) else _ = c.sqlite3_bind_null(stmt, 9);
    try bindText(stmt, 10, raw);
    try bindText(stmt, 11, now);
    try bindText(stmt, 12, now);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
    try upsertTweetMedia(db, tweet_id, tweet);
}

fn upsertUserFromValue(db: *Db, allocator: std.mem.Allocator, user: std.json.Value) !void {
    const user_id = getString(user, "id") orelse return;
    const raw = try jsonValueAlloc(allocator, user);
    defer allocator.free(raw);
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const stmt = try db.prepare(
        \\INSERT INTO users(user_id, username, name, description, profile_image_url, raw_json, first_seen_at, last_seen_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(user_id) DO UPDATE SET username=excluded.username, name=excluded.name, description=excluded.description, profile_image_url=excluded.profile_image_url, raw_json=excluded.raw_json, last_seen_at=excluded.last_seen_at
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, user_id);
    if (getString(user, "username")) |v| try bindText(stmt, 2, v) else _ = c.sqlite3_bind_null(stmt, 2);
    if (getString(user, "name")) |v| try bindText(stmt, 3, v) else _ = c.sqlite3_bind_null(stmt, 3);
    if (getString(user, "description")) |v| try bindText(stmt, 4, v) else _ = c.sqlite3_bind_null(stmt, 4);
    if (getString(user, "profile_image_url")) |v| try bindText(stmt, 5, v) else _ = c.sqlite3_bind_null(stmt, 5);
    try bindText(stmt, 6, raw);
    try bindText(stmt, 7, now);
    try bindText(stmt, 8, now);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn upsertMediaFromValue(db: *Db, allocator: std.mem.Allocator, media: std.json.Value) !void {
    const media_key = getString(media, "media_key") orelse return;
    const raw = try jsonValueAlloc(allocator, media);
    defer allocator.free(raw);
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const stmt = try db.prepare(
        \\INSERT INTO media(media_key, type, url, preview_image_url, raw_json, first_seen_at, last_seen_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(media_key) DO UPDATE SET type=excluded.type, url=excluded.url, preview_image_url=excluded.preview_image_url, raw_json=excluded.raw_json, last_seen_at=excluded.last_seen_at
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, media_key);
    if (getString(media, "type")) |v| try bindText(stmt, 2, v) else _ = c.sqlite3_bind_null(stmt, 2);
    if (getString(media, "url")) |v| try bindText(stmt, 3, v) else _ = c.sqlite3_bind_null(stmt, 3);
    if (getString(media, "preview_image_url")) |v| try bindText(stmt, 4, v) else _ = c.sqlite3_bind_null(stmt, 4);
    try bindText(stmt, 5, raw);
    try bindText(stmt, 6, now);
    try bindText(stmt, 7, now);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn upsertTweetMedia(db: *Db, tweet_id: []const u8, tweet: std.json.Value) !void {
    try deleteTweetMedia(db, tweet_id);
    const attachments = getObject(tweet, "attachments") orelse return;
    const keys = getArray(attachments, "media_keys") orelse return;
    for (keys.items, 0..) |item, idx| {
        if (item != .string) continue;
        const stmt = try db.prepare("INSERT OR REPLACE INTO tweet_media(tweet_id, media_key, position) VALUES (?, ?, ?)");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, tweet_id);
        try bindText(stmt, 2, item.string);
        _ = c.sqlite3_bind_int(stmt, 3, @intCast(idx));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
    }
}

fn deleteTweetMedia(db: *Db, tweet_id: []const u8) !void {
    const stmt = try db.prepare("DELETE FROM tweet_media WHERE tweet_id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn recordMissingQuoteReferences(db: *Db, allocator: std.mem.Allocator, root: std.json.Value, tweet: std.json.Value) !void {
    const tweet_id = getString(tweet, "id") orelse return;
    const refs = getArray(tweet, "referenced_tweets") orelse return;
    for (refs.items) |ref| {
        if (ref != .object) continue;
        if (!std.mem.eql(u8, getString(ref, "type") orelse "", "quoted")) continue;
        const referenced_id = getString(ref, "id") orelse continue;
        if (try tweetExists(db, referenced_id)) continue;
        const matching_error = findErrorForReference(root, referenced_id);
        const status = if (matching_error) |err| missingStatusFromError(allocator, err) else "missing";
        const raw = try jsonValueAlloc(allocator, matching_error orelse ref);
        defer allocator.free(raw);
        const now = try timestampString(allocator);
        defer allocator.free(now);
        const stmt = try db.prepare(
            \\INSERT INTO missing_references(tweet_id, referenced_tweet_id, reference_type, status, raw_json, first_seen_at, last_seen_at)
            \\VALUES (?, ?, 'quoted', ?, ?, ?, ?)
            \\ON CONFLICT(tweet_id, referenced_tweet_id, reference_type) DO UPDATE SET status=excluded.status, raw_json=excluded.raw_json, last_seen_at=excluded.last_seen_at
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, tweet_id);
        try bindText(stmt, 2, referenced_id);
        try bindText(stmt, 3, status);
        try bindText(stmt, 4, raw);
        try bindText(stmt, 5, now);
        try bindText(stmt, 6, now);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
    }
}

fn findErrorForReference(root: std.json.Value, referenced_id: []const u8) ?std.json.Value {
    const errors = getArray(root, "errors") orelse return null;
    for (errors.items) |err| {
        if (err != .object) continue;
        if (errorMentionsReference(err, referenced_id)) return err;
    }
    return null;
}

fn errorMentionsReference(err: std.json.Value, referenced_id: []const u8) bool {
    if (getString(err, "resource_id")) |v| if (std.mem.eql(u8, v, referenced_id)) return true;
    if (getString(err, "value")) |v| if (std.mem.eql(u8, v, referenced_id)) return true;
    if (getString(err, "id")) |v| if (std.mem.eql(u8, v, referenced_id)) return true;
    var buf: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    stream.print("{f}", .{std.json.fmt(err, .{})}) catch return false;
    return std.mem.indexOf(u8, stream.buffered(), referenced_id) != null;
}

fn missingStatusFromError(allocator: std.mem.Allocator, err: std.json.Value) []const u8 {
    const raw = jsonValueAlloc(allocator, err) catch return "missing";
    defer allocator.free(raw);
    if (containsIgnoreCase(raw, "protected")) return "protected";
    if (containsIgnoreCase(raw, "deleted")) return "deleted";
    if (containsIgnoreCase(raw, "not found")) return "not_found";
    if (containsIgnoreCase(raw, "unavailable")) return "unavailable";
    return "missing";
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        } else return true;
    }
    return false;
}

fn tweetExists(db: *Db, tweet_id: []const u8) !bool {
    const stmt = try db.prepare("SELECT 1 FROM tweets WHERE tweet_id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn upsertBookmarkItem(db: *Db, allocator: std.mem.Allocator, account_user_id: []const u8, tweet_id: []const u8, run_id: i64, import_position: i64, complete: bool) !bool {
    const was_existing = try bookmarkExists(db, account_user_id, tweet_id);
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const stmt = try db.prepare(
        \\INSERT INTO bookmark_items(account_user_id, tweet_id, active, complete_for_offline_render, first_seen_run_id, last_seen_run_id, first_seen_at, last_seen_at, import_position)
        \\VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(account_user_id, tweet_id) DO UPDATE SET active=1, complete_for_offline_render=excluded.complete_for_offline_render, last_seen_run_id=excluded.last_seen_run_id, last_seen_at=excluded.last_seen_at, import_position=excluded.import_position
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, account_user_id);
    try bindText(stmt, 2, tweet_id);
    _ = c.sqlite3_bind_int(stmt, 3, if (complete) 1 else 0);
    _ = c.sqlite3_bind_int64(stmt, 4, run_id);
    _ = c.sqlite3_bind_int64(stmt, 5, run_id);
    try bindText(stmt, 6, now);
    try bindText(stmt, 7, now);
    _ = c.sqlite3_bind_int64(stmt, 8, import_position);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
    return !was_existing;
}

fn detectThreadCandidates(db: *Db, allocator: std.mem.Allocator, changed_only: bool) !u32 {
    const stmt = try db.prepare(
        \\SELECT t.raw_json
        \\FROM bookmark_items b
        \\JOIN tweets t ON t.tweet_id = b.tweet_id
        \\WHERE b.active = 1
        \\ORDER BY b.import_position IS NULL, b.import_position, b.tweet_id DESC
    );
    defer _ = c.sqlite3_finalize(stmt);
    var count: u32 = 0;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, colText(stmt, 0), .{}) catch continue;
        defer parsed.deinit();
        if (try detectAndRecordThreadCandidate(db, allocator, parsed.value, changed_only)) count += 1;
    }
    return count;
}

fn detectAndRecordThreadCandidate(db: *Db, allocator: std.mem.Allocator, tweet: std.json.Value, changed_only: bool) !bool {
    const tweet_id = getString(tweet, "id") orelse return false;
    const reasons = try threadDetectionReasonsJson(allocator, tweet);
    defer if (reasons) |r| allocator.free(r);
    if (reasons == null) return false;
    if (changed_only and try threadCandidateExists(db, tweet_id)) return false;
    try upsertThreadCandidate(db, allocator, tweet_id, reasons.?);
    try upsertMissingThreadExpansionForTweet(db, allocator, tweet, "missing");
    return true;
}

fn threadDetectionReasonsJson(allocator: std.mem.Allocator, tweet: std.json.Value) !?[]const u8 {
    const text = rawXPostText(tweet, getString(tweet, "text") orelse "");
    var reasons = std.ArrayList([]const u8).empty;
    defer reasons.deinit(allocator);
    if (containsThreadOneOfN(text)) try reasons.append(allocator, "text contains 1/N");
    if (containsStandaloneOneSlash(text)) try reasons.append(allocator, "text contains standalone 1/");
    if (containsThreadMarker(text)) try reasons.append(allocator, "text contains thread marker");
    if (containsThreadPhrase(text)) try reasons.append(allocator, "text contains thread phrase");
    const tweet_id = getString(tweet, "id") orelse "";
    const conversation_id = getString(tweet, "conversation_id") orelse "";
    const replies = tweetReplyCount(tweet);
    if (tweet_id.len > 0 and std.mem.eql(u8, tweet_id, conversation_id) and replies > 0 and (containsThreadMarker(text) or containsThreadOneOfN(text) or containsStandaloneOneSlash(text))) {
        try reasons.append(allocator, "root post has replies and thread signal");
    }
    if (reasons.items.len == 0) return null;
    var out = std.ArrayList(u8).empty;
    const w = out.writer(allocator);
    try w.writeAll("[");
    for (reasons.items, 0..) |reason, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{f}", .{std.json.fmt(reason, .{})});
    }
    try w.writeAll("]");
    const slice = try out.toOwnedSlice(allocator);
    return slice;
}

fn containsThreadOneOfN(text: []const u8) bool {
    var i: usize = 0;
    while (i + 3 <= text.len) : (i += 1) {
        if (text[i] != '1' or text[i + 1] != '/') continue;
        const n = text[i + 2];
        if (n == 'N' or n == 'n' or (n >= '2' and n <= '9')) return true;
    }
    return false;
}

fn containsStandaloneOneSlash(text: []const u8) bool {
    var i: usize = 0;
    while (i + 2 <= text.len) : (i += 1) {
        if (text[i] != '1' or text[i + 1] != '/') continue;
        if (i > 0 and std.ascii.isAlphanumeric(text[i - 1])) continue;
        return true;
    }
    return false;
}

fn containsThreadMarker(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "\xF0\x9F\xA7\xB5") != null;
}

fn containsThreadPhrase(text: []const u8) bool {
    return containsIgnoreCase(text, "thread below") or
        containsIgnoreCase(text, "in the thread below") or
        containsIgnoreCase(text, "some thoughts") or
        containsIgnoreCase(text, "here are my thoughts") or
        containsIgnoreCase(text, "a thread") or
        containsIgnoreCase(text, "1 of");
}

fn hasThreadNumberingSignal(tweet: std.json.Value) bool {
    const text = rawXPostText(tweet, getString(tweet, "text") orelse "");
    return containsThreadOneOfN(text) or containsStandaloneOneSlash(text) or containsThreadMarker(text) or containsNumericPrefix(text);
}

fn containsNumericPrefix(text: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, text, " \t\r\n");
    if (trimmed.len < 2) return false;
    var i: usize = 0;
    while (i < trimmed.len and trimmed[i] >= '0' and trimmed[i] <= '9') : (i += 1) {}
    if (i == 0 or i > 3 or i >= trimmed.len) return false;
    return trimmed[i] == '.' or trimmed[i] == '/';
}

fn tweetReplyCount(tweet: std.json.Value) i64 {
    const metrics = getObject(tweet, "public_metrics") orelse return 0;
    return getInt(metrics, "reply_count") orelse 0;
}

fn threadCandidateExists(db: *Db, tweet_id: []const u8) !bool {
    const stmt = try db.prepare("SELECT 1 FROM thread_candidates WHERE tweet_id=? LIMIT 1");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn upsertThreadCandidate(db: *Db, allocator: std.mem.Allocator, tweet_id: []const u8, reason_json: []const u8) !void {
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const stmt = try db.prepare(
        \\INSERT INTO thread_candidates(tweet_id, detected_at, reason_json, status)
        \\VALUES (?, ?, ?, 'missing')
        \\ON CONFLICT(tweet_id) DO UPDATE SET reason_json=excluded.reason_json, status=CASE WHEN status='ignored' THEN status ELSE excluded.status END
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    try bindText(stmt, 2, now);
    try bindText(stmt, 3, reason_json);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn upsertMissingThreadExpansionForTweet(db: *Db, allocator: std.mem.Allocator, tweet: std.json.Value, status: []const u8) !void {
    const tweet_id = getString(tweet, "id") orelse return;
    const author_id = getString(tweet, "author_id") orelse "";
    const conversation_id = getString(tweet, "conversation_id") orelse tweet_id;
    const username = if (author_id.len > 0) try usernameForUser(db, allocator, author_id) else null;
    defer if (username) |u| allocator.free(u);
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const stmt = try db.prepare(
        \\INSERT INTO thread_expansions(root_tweet_id, root_author_id, root_author_username, conversation_id, status, post_count, first_seen_at, last_seen_at)
        \\VALUES (?, ?, ?, ?, ?, 0, ?, ?)
        \\ON CONFLICT(root_tweet_id) DO UPDATE SET root_author_id=excluded.root_author_id, root_author_username=excluded.root_author_username, conversation_id=excluded.conversation_id, last_seen_at=excluded.last_seen_at
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    try bindText(stmt, 2, author_id);
    if (username) |u| try bindText(stmt, 3, u) else _ = c.sqlite3_bind_null(stmt, 3);
    try bindText(stmt, 4, conversation_id);
    try bindText(stmt, 5, status);
    try bindText(stmt, 6, now);
    try bindText(stmt, 7, now);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn printThreadStatus(db: *Db) !void {
    const out = std.fs.File.stdout().deprecatedWriter();
    try out.print("thread candidates: {}\n", .{try scalarCount(db, "SELECT count(*) FROM thread_candidates")});
    try out.print("thread expansions: {}\n", .{try scalarCount(db, "SELECT count(*) FROM thread_expansions")});
    const stmt = try db.prepare(
        \\SELECT status, count(*)
        \\FROM thread_expansions
        \\GROUP BY status
        \\ORDER BY status
    );
    defer _ = c.sqlite3_finalize(stmt);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        try out.print("{s}: {}\n", .{ colText(stmt, 0), c.sqlite3_column_int64(stmt, 1) });
    }
}

fn expandThreads(db: *Db, allocator: std.mem.Allocator, cfg: Config, access_token: ?[]const u8, opts: ThreadExpansionOptions) !u32 {
    if (opts.changed) _ = try detectThreadCandidates(db, allocator, true);
    var targets = std.ArrayList([]const u8).empty;
    defer {
        for (targets.items) |id| allocator.free(id);
        targets.deinit(allocator);
    }
    if (opts.tweet_id) |id| {
        try targets.append(allocator, try allocator.dupe(u8, id));
    } else {
        try collectChangedThreadTargets(db, allocator, opts.limit, &targets);
    }

    var processed: u32 = 0;
    for (targets.items) |root_id| {
        if (!opts.retry_partial and try threadExpansionComplete(db, root_id)) {
            if (!builtin.is_test) try std.fs.File.stdout().deprecatedWriter().print("thread expansion cached: {s}\n", .{root_id});
            continue;
        }
        const plan = try buildThreadExpansionPlan(db, allocator, root_id, opts.mode, opts.max_results, opts.max_posts);
        defer plan.deinit(allocator);
        if (!builtin.is_test) try printThreadExpansionPlan(plan, opts.dry_run);
        if (opts.dry_run) {
            processed += 1;
            continue;
        }
        const token = access_token orelse return AppError.AuthRequired;
        try runThreadExpansionFetch(db, allocator, cfg, token, plan);
        processed += 1;
    }
    return processed;
}

fn collectChangedThreadTargets(db: *Db, allocator: std.mem.Allocator, limit: ?u32, targets: *std.ArrayList([]const u8)) !void {
    const limit_clause = if (limit != null) " LIMIT ?" else "";
    const sql = try std.fmt.allocPrint(allocator,
        \\SELECT te.root_tweet_id
        \\FROM thread_expansions te
        \\JOIN bookmark_items b ON b.tweet_id = te.root_tweet_id AND b.active = 1
        \\WHERE te.status IN ('missing', 'failed', 'unavailable')
        \\ORDER BY te.last_seen_at DESC, te.root_tweet_id DESC{s}
    , .{limit_clause});
    defer allocator.free(sql);
    const stmt = try db.prepare(sql);
    defer _ = c.sqlite3_finalize(stmt);
    if (limit) |n| _ = c.sqlite3_bind_int(stmt, 1, @intCast(n));
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        try targets.append(allocator, try allocator.dupe(u8, colText(stmt, 0)));
    }
}

fn threadExpansionComplete(db: *Db, root_tweet_id: []const u8) !bool {
    const stmt = try db.prepare("SELECT 1 FROM thread_expansions WHERE root_tweet_id=? AND status='complete' LIMIT 1");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, root_tweet_id);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn buildThreadExpansionPlan(db: *Db, allocator: std.mem.Allocator, root_tweet_id: []const u8, mode: ThreadSearchMode, max_results: u32, max_posts: u32) !ThreadExpansionPlan {
    const stmt = try db.prepare(
        \\SELECT t.tweet_id, coalesce(t.author_id, ''), coalesce(u.username, ''), coalesce(t.conversation_id, t.tweet_id), coalesce(t.created_at, '')
        \\FROM tweets t
        \\LEFT JOIN users u ON u.user_id = t.author_id
        \\WHERE t.tweet_id = ?
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, root_tweet_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return AppError.InvalidArguments;
    const username = colText(stmt, 2);
    if (username.len == 0) return AppError.InvalidArguments;
    const query = try std.fmt.allocPrint(allocator, "conversation_id:{s} from:{s}", .{ root_tweet_id, username });
    errdefer allocator.free(query);
    const start_time = try threadApiStartTime(allocator, colText(stmt, 4));
    errdefer allocator.free(start_time);
    const end_time = try threadApiEndTime(allocator, start_time, default_thread_window_hours);
    errdefer allocator.free(end_time);
    return .{
        .root_tweet_id = try allocator.dupe(u8, colText(stmt, 0)),
        .root_author_id = try allocator.dupe(u8, colText(stmt, 1)),
        .root_author_username = try allocator.dupe(u8, username),
        .conversation_id = try allocator.dupe(u8, colText(stmt, 3)),
        .query = query,
        .start_time = start_time,
        .end_time = end_time,
        .endpoint = mode,
        .max_results = max_results,
        .max_posts = max_posts,
        .estimated_cost_micros = threadEstimatedCostMicros(mode, max_results),
    };
}

fn threadEstimatedCostMicros(mode: ThreadSearchMode, max_results: u32) i64 {
    return switch (mode) {
        .auto, .timeline => 0,
        .recent, .all => @as(i64, max_results) * thread_estimated_cost_micros_per_post,
    };
}

fn printThreadExpansionPlan(plan: ThreadExpansionPlan, dry_run: bool) !void {
    try std.fs.File.stdout().deprecatedWriter().print(
        \\thread expansion {s}:
        \\  tweet_id: {s}
        \\  query: {s}
        \\  endpoint: {s}
        \\  max_results: {}
        \\  max_posts: {}
        \\  start_time: {s}
        \\  end_time: {s}
        \\  estimated_cost: ${d:.3}
        \\  expected_rate_limit_impact: 1 API request
        \\
    , .{
        if (dry_run) "dry run" else "run",
        plan.root_tweet_id,
        plan.query,
        plan.endpoint.endpointLabel(),
        plan.max_results,
        plan.max_posts,
        plan.start_time,
        plan.end_time,
        @as(f64, @floatFromInt(plan.estimated_cost_micros)) / 1_000_000.0,
    });
}

fn runThreadExpansionFetch(db: *Db, allocator: std.mem.Allocator, cfg: Config, access_token: []const u8, plan: ThreadExpansionPlan) !void {
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth);
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth },
        .{ .name = "Accept", .value = "application/json" },
    };
    const url = try buildThreadSearchUrl(allocator, plan);
    defer allocator.free(url);
    const response = try httpFetch(allocator, .GET, url, null, &headers);
    defer freeHttpResponse(allocator, response);
    if (response.status == .unauthorized) return AppError.AuthRequired;
    if (response.status == .too_many_requests) return AppError.RateLimited;
    if (response.status == .forbidden or response.status == .not_found) {
        const err = try std.fmt.allocPrint(allocator, "{{\"http_status\":{}}}", .{@intFromEnum(response.status)});
        defer allocator.free(err);
        try upsertThreadExpansionStatus(db, allocator, plan, "unavailable", null, 0, 0, err);
        return;
    }
    if (response.status != .ok) {
        const err = try std.fmt.allocPrint(allocator, "{{\"http_status\":{}}}", .{@intFromEnum(response.status)});
        defer allocator.free(err);
        try upsertThreadExpansionStatus(db, allocator, plan, "failed", null, 0, 0, err);
        return AppError.HttpError;
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    try beginTransaction(db);
    ingestThreadSearchResponse(db, allocator, parsed.value, plan) catch |err| {
        try rollbackTransaction(db);
        return err;
    };
    try commitTransaction(db);
    if (cfg.download_media) try downloadAssetsForThread(db, allocator, cfg.assets_dir, cfg.media_policy, plan.root_tweet_id);
}

fn buildThreadSearchUrl(allocator: std.mem.Allocator, plan: ThreadExpansionPlan) ![]const u8 {
    if (plan.endpoint == .auto or plan.endpoint == .timeline) return buildThreadTimelineUrl(allocator, plan);
    const q = try urlEncode(allocator, plan.query);
    defer allocator.free(q);
    return std.fmt.allocPrint(
        allocator,
        x_api_base ++ "{s}?query={s}&max_results={}&tweet.fields={s}&expansions={s}&user.fields={s}&media.fields={s}&poll.fields={s}",
        .{ plan.endpoint.endpointPath(), q, plan.max_results, bookmark_tweet_fields, bookmark_expansions, bookmark_user_fields, bookmark_media_fields, bookmark_poll_fields },
    );
}

fn buildThreadTimelineUrl(allocator: std.mem.Allocator, plan: ThreadExpansionPlan) ![]const u8 {
    const start = try urlEncode(allocator, plan.start_time);
    defer allocator.free(start);
    const end = try urlEncode(allocator, plan.end_time);
    defer allocator.free(end);
    return std.fmt.allocPrint(
        allocator,
        x_api_base ++ "/users/{s}/tweets?start_time={s}&end_time={s}&max_results={}&tweet.fields={s}&expansions={s}&user.fields={s}&media.fields={s}&poll.fields={s}",
        .{ plan.root_author_id, start, end, plan.max_results, bookmark_tweet_fields, bookmark_expansions, bookmark_user_fields, bookmark_media_fields, bookmark_poll_fields },
    );
}

fn ingestThreadSearchResponse(db: *Db, allocator: std.mem.Allocator, root: std.json.Value, plan: ThreadExpansionPlan) !void {
    const root_created_at = try tweetCreatedAt(db, allocator, plan.root_tweet_id);
    defer allocator.free(root_created_at);
    var eligible_media_keys = std.StringHashMap(void).init(allocator);
    defer {
        var it = eligible_media_keys.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        eligible_media_keys.deinit();
    }
    try collectEligibleThreadMediaKeys(allocator, root, plan, root_created_at, &eligible_media_keys);
    try ingestThreadIncludes(db, allocator, root, plan, root_created_at, &eligible_media_keys);
    var result_count: i64 = 0;
    if (getArray(root, "data")) |tweets| {
        result_count = @intCast(tweets.items.len);
        for (tweets.items) |tweet| {
            if (tweet != .object) continue;
            if (!threadSearchTweetEligible(tweet, plan, root_created_at)) continue;
            try upsertTweetFromValue(db, allocator, tweet);
        }
    }
    const build = try buildAndPersistThreadMembership(db, allocator, plan);
    try upsertThreadExpansionStatus(db, allocator, plan, build.status, build.confidence, build.post_count, result_count, null);
}

fn collectEligibleThreadMediaKeys(allocator: std.mem.Allocator, root: std.json.Value, plan: ThreadExpansionPlan, root_created_at: []const u8, keys: *std.StringHashMap(void)) !void {
    if (getArray(root, "data")) |tweets| {
        for (tweets.items) |tweet| {
            if (tweet != .object) continue;
            if (!threadSearchTweetEligible(tweet, plan, root_created_at)) continue;
            try collectMediaKeysFromTweet(allocator, tweet, keys);
        }
    }
    const includes = getObject(root, "includes") orelse return;
    if (getArray(includes, "tweets")) |tweets_arr| {
        for (tweets_arr.items) |tweet| {
            if (tweet != .object) continue;
            if (!threadSearchTweetEligible(tweet, plan, root_created_at)) continue;
            try collectMediaKeysFromTweet(allocator, tweet, keys);
        }
    }
}

fn collectMediaKeysFromTweet(allocator: std.mem.Allocator, tweet: std.json.Value, keys: *std.StringHashMap(void)) !void {
    const attachments = getObject(tweet, "attachments") orelse return;
    const arr = getArray(attachments, "media_keys") orelse return;
    for (arr.items) |item| {
        if (item != .string) continue;
        if (keys.contains(item.string)) continue;
        try keys.put(try allocator.dupe(u8, item.string), {});
    }
}

fn ingestThreadIncludes(db: *Db, allocator: std.mem.Allocator, root: std.json.Value, plan: ThreadExpansionPlan, root_created_at: []const u8, eligible_media_keys: *std.StringHashMap(void)) !void {
    const includes = getObject(root, "includes") orelse return;
    if (getArray(includes, "users")) |users_arr| {
        for (users_arr.items) |user| {
            if (user != .object) continue;
            if (!std.mem.eql(u8, getString(user, "id") orelse "", plan.root_author_id)) continue;
            try upsertUserFromValue(db, allocator, user);
        }
    }
    if (getArray(includes, "media")) |media_arr| {
        for (media_arr.items) |media| {
            if (media != .object) continue;
            const media_key = getString(media, "media_key") orelse continue;
            if (!eligible_media_keys.contains(media_key)) continue;
            try upsertMediaFromValue(db, allocator, media);
        }
    }
    if (getArray(includes, "tweets")) |tweets_arr| {
        for (tweets_arr.items) |tweet| {
            if (tweet != .object) continue;
            if (!threadSearchTweetEligible(tweet, plan, root_created_at)) continue;
            try upsertTweetFromValue(db, allocator, tweet);
        }
    }
}

fn threadSearchTweetEligible(tweet: std.json.Value, plan: ThreadExpansionPlan, root_created_at: []const u8) bool {
    const tweet_id = getString(tweet, "id") orelse return false;
    if (std.mem.eql(u8, tweet_id, plan.root_tweet_id)) return true;
    if (!std.mem.eql(u8, getString(tweet, "conversation_id") orelse "", plan.root_tweet_id)) return false;
    if (!std.mem.eql(u8, getString(tweet, "author_id") orelse "", plan.root_author_id)) return false;
    if (getString(tweet, "in_reply_to_user_id")) |reply_to_user| {
        if (!std.mem.eql(u8, reply_to_user, plan.root_author_id)) return false;
    }
    const created_at = getString(tweet, "created_at") orelse return false;
    if (root_created_at.len > 0 and std.mem.lessThan(u8, created_at, root_created_at)) return false;
    return true;
}

fn tweetCreatedAt(db: *Db, allocator: std.mem.Allocator, tweet_id: []const u8) ![]const u8 {
    const stmt = try db.prepare("SELECT coalesce(created_at, '') FROM tweets WHERE tweet_id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return allocator.dupe(u8, "");
    return allocator.dupe(u8, colText(stmt, 0));
}

fn threadApiStartTime(allocator: std.mem.Allocator, created_at: []const u8) ![]const u8 {
    if (created_at.len == 0) return allocator.dupe(u8, "");
    const seconds = parseIsoUtcTimestampSeconds(created_at) catch return allocator.dupe(u8, created_at);
    return formatIsoUtcTimestampSeconds(allocator, seconds);
}

fn threadApiEndTime(allocator: std.mem.Allocator, start_time: []const u8, window_hours: u32) ![]const u8 {
    if (start_time.len == 0) return allocator.dupe(u8, "");
    const seconds = parseIsoUtcTimestampSeconds(start_time) catch return allocator.dupe(u8, start_time);
    return formatIsoUtcTimestampSeconds(allocator, seconds + @as(i64, window_hours) * 3600);
}

fn parseIsoUtcTimestampSeconds(value: []const u8) !i64 {
    if (value.len < 20) return AppError.InvalidArguments;
    if (value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') return AppError.InvalidArguments;
    const year = try std.fmt.parseInt(i64, value[0..4], 10);
    const month = try std.fmt.parseInt(u8, value[5..7], 10);
    const day = try std.fmt.parseInt(u8, value[8..10], 10);
    const hour = try std.fmt.parseInt(u8, value[11..13], 10);
    const minute = try std.fmt.parseInt(u8, value[14..16], 10);
    const second = try std.fmt.parseInt(u8, value[17..19], 10);
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60) return AppError.InvalidArguments;
    const days = daysFromCivil(year, month, day);
    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

fn formatIsoUtcTimestampSeconds(allocator: std.mem.Allocator, timestamp: i64) ![]const u8 {
    const days = @divFloor(timestamp, 86400);
    const day_seconds = @mod(timestamp, 86400);
    const civil = civilFromDays(days);
    const hour = @divFloor(day_seconds, 3600);
    const minute = @divFloor(@mod(day_seconds, 3600), 60);
    const second = @mod(day_seconds, 60);
    var out = std.ArrayList(u8).empty;
    try appendPaddedDecimal(allocator, &out, civil.year, 4);
    try out.append(allocator, '-');
    try appendPaddedDecimal(allocator, &out, civil.month, 2);
    try out.append(allocator, '-');
    try appendPaddedDecimal(allocator, &out, civil.day, 2);
    try out.append(allocator, 'T');
    try appendPaddedDecimal(allocator, &out, hour, 2);
    try out.append(allocator, ':');
    try appendPaddedDecimal(allocator, &out, minute, 2);
    try out.append(allocator, ':');
    try appendPaddedDecimal(allocator, &out, second, 2);
    try out.append(allocator, 'Z');
    return out.toOwnedSlice(allocator);
}

fn appendPaddedDecimal(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: i64, width: usize) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{}", .{value});
    if (text.len < width) {
        for (0..(width - text.len)) |_| try out.append(allocator, '0');
    }
    try out.appendSlice(allocator, text);
}

fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    var y = year;
    const m: i64 = @intCast(month);
    y -= if (m <= 2) 1 else 0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = m + if (m > 2) @as(i64, -3) else @as(i64, 9);
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, @intCast(day)) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const CivilDate = struct {
    year: i64,
    month: i64,
    day: i64,
};

fn civilFromDays(days: i64) CivilDate {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = mp + if (mp < 10) @as(i64, 3) else @as(i64, -9);
    y += if (m <= 2) 1 else 0;
    return .{ .year = y, .month = m, .day = d };
}

fn upsertThreadExpansionStatus(db: *Db, allocator: std.mem.Allocator, plan: ThreadExpansionPlan, status: []const u8, confidence: ?[]const u8, post_count: u32, result_count: i64, error_json: ?[]const u8) !void {
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const stmt = try db.prepare(
        \\INSERT INTO thread_expansions(root_tweet_id, root_author_id, root_author_username, conversation_id, status, method, confidence, post_count, fetched_at, api_endpoint, query, max_results, result_count, estimated_cost_micros, error_json, first_seen_at, last_seen_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(root_tweet_id) DO UPDATE SET root_author_id=excluded.root_author_id, root_author_username=excluded.root_author_username, conversation_id=excluded.conversation_id, status=excluded.status, method=excluded.method, confidence=excluded.confidence, post_count=excluded.post_count, fetched_at=excluded.fetched_at, api_endpoint=excluded.api_endpoint, query=excluded.query, max_results=excluded.max_results, result_count=excluded.result_count, estimated_cost_micros=excluded.estimated_cost_micros, error_json=excluded.error_json, last_seen_at=excluded.last_seen_at
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, plan.root_tweet_id);
    try bindText(stmt, 2, plan.root_author_id);
    try bindText(stmt, 3, plan.root_author_username);
    try bindText(stmt, 4, plan.root_tweet_id);
    try bindText(stmt, 5, status);
    try bindText(stmt, 6, plan.endpoint.methodLabel());
    if (confidence) |v| try bindText(stmt, 7, v) else _ = c.sqlite3_bind_null(stmt, 7);
    _ = c.sqlite3_bind_int(stmt, 8, @intCast(post_count));
    try bindText(stmt, 9, now);
    try bindText(stmt, 10, plan.endpoint.endpointLabel());
    try bindText(stmt, 11, plan.query);
    _ = c.sqlite3_bind_int(stmt, 12, @intCast(plan.max_results));
    _ = c.sqlite3_bind_int64(stmt, 13, result_count);
    _ = c.sqlite3_bind_int64(stmt, 14, plan.estimated_cost_micros);
    if (error_json) |e| try bindText(stmt, 15, e) else _ = c.sqlite3_bind_null(stmt, 15);
    try bindText(stmt, 16, now);
    try bindText(stmt, 17, now);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
    if (std.mem.eql(u8, status, "complete") or std.mem.eql(u8, status, "partial")) {
        try updateThreadCandidateStatus(db, plan.root_tweet_id, status);
    }
}

fn updateThreadCandidateStatus(db: *Db, tweet_id: []const u8, status: []const u8) !void {
    const stmt = try db.prepare("UPDATE thread_candidates SET status=? WHERE tweet_id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, status);
    try bindText(stmt, 2, tweet_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn buildAndPersistThreadMembership(db: *Db, allocator: std.mem.Allocator, plan: ThreadExpansionPlan) !ThreadBuildResult {
    var posts = try loadThreadCandidatePosts(db, allocator, plan);
    defer {
        for (posts.items) |post| post.deinit(allocator);
        posts.deinit(allocator);
    }
    try clearThreadPosts(db, plan.root_tweet_id);

    var kept = std.StringHashMap(void).init(allocator);
    defer kept.deinit();
    var position: u32 = 0;
    var inferred: u32 = 0;
    var truncated = false;

    for (posts.items) |post| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, post.raw_json, .{}) catch continue;
        defer parsed.deinit();
        var include = false;
        var reason: []const u8 = "root";
        var confidence: []const u8 = "high";
        if (std.mem.eql(u8, post.tweet_id, plan.root_tweet_id)) {
            include = true;
        } else if (replyReferencesKept(parsed.value, &kept)) {
            include = true;
            reason = "reply_chain";
        } else if (hasThreadNumberingSignal(parsed.value)) {
            include = true;
            reason = "numbering_inferred";
            confidence = "medium";
            inferred += 1;
        }
        if (!include) continue;
        if (position >= plan.max_posts) {
            truncated = true;
            continue;
        }
        try kept.put(post.tweet_id, {});
        position += 1;
        try insertThreadPost(db, plan.root_tweet_id, post.tweet_id, position, reason, confidence);
    }

    if (position == 0) {
        try insertThreadPost(db, plan.root_tweet_id, plan.root_tweet_id, 1, "root", "low");
        return .{ .status = "partial", .confidence = "low", .post_count = 1, .inferred_posts = 0 };
    }
    if (position == 1) return .{ .status = "partial", .confidence = "low", .post_count = position, .inferred_posts = inferred };
    if (truncated) return .{ .status = "partial", .confidence = "medium", .post_count = position, .inferred_posts = inferred };
    if (inferred > 0) return .{ .status = "partial", .confidence = "medium", .post_count = position, .inferred_posts = inferred };
    return .{ .status = "complete", .confidence = "high", .post_count = position, .inferred_posts = inferred };
}

fn loadThreadCandidatePosts(db: *Db, allocator: std.mem.Allocator, plan: ThreadExpansionPlan) !std.ArrayList(ThreadMembershipPost) {
    var posts = std.ArrayList(ThreadMembershipPost).empty;
    const stmt = try db.prepare(
        \\SELECT tweet_id, raw_json, coalesce(created_at, '')
        \\FROM tweets
        \\WHERE conversation_id = ?
        \\  AND author_id = ?
        \\  AND (created_at IS NULL OR created_at = '' OR created_at >= (SELECT coalesce(created_at, '') FROM tweets WHERE tweet_id = ?))
        \\ORDER BY coalesce(created_at, ''), tweet_id
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, plan.root_tweet_id);
    try bindText(stmt, 2, plan.root_author_id);
    try bindText(stmt, 3, plan.root_tweet_id);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        try posts.append(allocator, .{
            .tweet_id = try allocator.dupe(u8, colText(stmt, 0)),
            .raw_json = try allocator.dupe(u8, colText(stmt, 1)),
            .created_at = try allocator.dupe(u8, colText(stmt, 2)),
        });
    }
    return posts;
}

fn clearThreadPosts(db: *Db, root_tweet_id: []const u8) !void {
    const stmt = try db.prepare("DELETE FROM thread_posts WHERE root_tweet_id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, root_tweet_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn insertThreadPost(db: *Db, root_tweet_id: []const u8, tweet_id: []const u8, position: u32, reason: []const u8, confidence: []const u8) !void {
    const stmt = try db.prepare("INSERT OR REPLACE INTO thread_posts(root_tweet_id, tweet_id, position, include_reason, confidence) VALUES (?, ?, ?, ?, ?)");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, root_tweet_id);
    try bindText(stmt, 2, tweet_id);
    _ = c.sqlite3_bind_int(stmt, 3, @intCast(position));
    try bindText(stmt, 4, reason);
    try bindText(stmt, 5, confidence);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn replyReferencesKept(tweet: std.json.Value, kept: *std.StringHashMap(void)) bool {
    const refs = getArray(tweet, "referenced_tweets") orelse return false;
    for (refs.items) |ref| {
        if (ref != .object) continue;
        if (!std.mem.eql(u8, getString(ref, "type") orelse "", "replied_to")) continue;
        const id = getString(ref, "id") orelse continue;
        if (kept.contains(id)) return true;
    }
    return false;
}

fn bookmarkCompleteForOfflineRender(db: *Db, allocator: std.mem.Allocator, tweet_id: []const u8) !bool {
    if (!try tweetExists(db, tweet_id)) return false;
    if (!try tweetAuthorMetadataComplete(db, allocator, tweet_id)) return false;
    if (!try tweetRequiredAssetsPresent(db, allocator, tweet_id)) return false;
    if (try tweetHasFailedAssets(db, allocator, tweet_id)) return false;

    const raw = try tweetRawJson(db, allocator, tweet_id);
    defer if (raw) |value| allocator.free(value);
    if (raw) |json| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return false;
        defer parsed.deinit();
        if (getArray(parsed.value, "referenced_tweets")) |refs| {
            for (refs.items) |ref| {
                if (ref != .object) continue;
                if (!std.mem.eql(u8, getString(ref, "type") orelse "", "quoted")) continue;
                const quote_id = getString(ref, "id") orelse return false;
                if (try tweetExists(db, quote_id)) {
                    if (!try tweetAuthorMetadataComplete(db, allocator, quote_id)) return false;
                    if (!try tweetRequiredAssetsPresent(db, allocator, quote_id)) return false;
                } else if (!try missingReferenceExists(db, tweet_id, quote_id, "quoted")) {
                    return false;
                }
            }
        }
    }
    return true;
}

fn tweetRequiredAssetsPresent(db: *Db, allocator: std.mem.Allocator, tweet_id: []const u8) !bool {
    if (!try tweetMediaAssetsPresent(db, allocator, tweet_id)) return false;
    const author = try tweetAuthorId(db, allocator, tweet_id);
    defer if (author) |value| allocator.free(value);
    if (author) |author_id| {
        if (try userAvatarRequired(db, allocator, author_id)) {
            const key = try std.fmt.allocPrint(allocator, "user:{s}", .{author_id});
            defer allocator.free(key);
            if (!try assetPresentForMediaKeyKind(db, key, "author_avatar")) return false;
        }
    }
    return true;
}

fn tweetMediaAssetsPresent(db: *Db, allocator: std.mem.Allocator, tweet_id: []const u8) !bool {
    const stmt = try db.prepare("SELECT media_key FROM tweet_media WHERE tweet_id=? ORDER BY position");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        const media_key = colText(stmt, 0);
        const raw = try mediaRawJson(db, allocator, media_key) orelse return false;
        defer allocator.free(raw);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return false;
        defer parsed.deinit();
        if (getString(parsed.value, "url") != null and !try assetPresentForMediaKeyKind(db, media_key, "image")) return false;
        if (getString(parsed.value, "preview_image_url") != null and !try assetPresentForMediaKeyKind(db, media_key, "preview_image")) return false;
        if (getArray(parsed.value, "variants")) |variants| {
            if (variants.items.len > 0 and !try videoAssetPresentForMediaKey(db, media_key)) return false;
        }
    }
    return true;
}

fn userAvatarRequired(db: *Db, allocator: std.mem.Allocator, user_id: []const u8) !bool {
    const stmt = try db.prepare("SELECT profile_image_url FROM users WHERE user_id=? AND profile_image_url IS NOT NULL AND profile_image_url <> ''");
    defer _ = c.sqlite3_finalize(stmt);
    _ = allocator;
    try bindText(stmt, 1, user_id);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn mediaRawJson(db: *Db, allocator: std.mem.Allocator, media_key: []const u8) !?[]const u8 {
    const stmt = try db.prepare("SELECT raw_json FROM media WHERE media_key=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, media_key);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return try allocator.dupe(u8, colText(stmt, 0));
}

fn assetPresentForMediaKeyKind(db: *Db, media_key: []const u8, kind: []const u8) !bool {
    const stmt = try db.prepare("SELECT 1 FROM media_assets WHERE media_key=? AND asset_kind=? AND status IN ('downloaded', 'ok', 'skipped') LIMIT 1");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, media_key);
    try bindText(stmt, 2, kind);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn videoAssetPresentForMediaKey(db: *Db, media_key: []const u8) !bool {
    const stmt = try db.prepare("SELECT 1 FROM media_assets WHERE media_key=? AND asset_kind IN ('video_variant', 'animated_gif_variant') AND status IN ('downloaded', 'ok', 'skipped', 'remote_only', 'removed') LIMIT 1");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, media_key);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn tweetAuthorMetadataComplete(db: *Db, allocator: std.mem.Allocator, tweet_id: []const u8) !bool {
    const author = try tweetAuthorId(db, allocator, tweet_id);
    defer if (author) |value| allocator.free(value);
    if (author) |author_id| {
        if (author_id.len == 0) return true;
        return userExists(db, author_id);
    }
    return true;
}

fn tweetHasFailedAssets(db: *Db, allocator: std.mem.Allocator, tweet_id: []const u8) !bool {
    if (try tweetOwnAssetsFailed(db, tweet_id)) return true;
    const author = try tweetAuthorId(db, allocator, tweet_id);
    defer if (author) |value| allocator.free(value);
    if (author) |author_id| {
        const key = try std.fmt.allocPrint(allocator, "user:{s}", .{author_id});
        defer allocator.free(key);
        if (try failedAssetForMediaKey(db, key)) return true;
    }

    const raw = try tweetRawJson(db, allocator, tweet_id);
    defer if (raw) |value| allocator.free(value);
    if (raw) |json| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return false;
        defer parsed.deinit();
        if (getArray(parsed.value, "referenced_tweets")) |refs| {
            for (refs.items) |ref| {
                if (ref != .object) continue;
                if (!std.mem.eql(u8, getString(ref, "type") orelse "", "quoted")) continue;
                const quote_id = getString(ref, "id") orelse continue;
                if (try tweetOwnAssetsFailed(db, quote_id)) return true;
                const quote_author = try tweetAuthorId(db, allocator, quote_id);
                defer if (quote_author) |value| allocator.free(value);
                if (quote_author) |quote_author_id| {
                    const key = try std.fmt.allocPrint(allocator, "user:{s}", .{quote_author_id});
                    defer allocator.free(key);
                    if (try failedAssetForMediaKey(db, key)) return true;
                }
            }
        }
    }
    return false;
}

fn tweetOwnAssetsFailed(db: *Db, tweet_id: []const u8) !bool {
    const stmt = try db.prepare(
        \\SELECT 1
        \\FROM tweet_media tm
        \\JOIN media_assets ma ON ma.media_key = tm.media_key
        \\WHERE tm.tweet_id = ? AND ma.status = 'failed'
        \\LIMIT 1
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn failedAssetForMediaKey(db: *Db, media_key: []const u8) !bool {
    const stmt = try db.prepare("SELECT 1 FROM media_assets WHERE media_key=? AND status='failed' LIMIT 1");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, media_key);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn tweetAuthorId(db: *Db, allocator: std.mem.Allocator, tweet_id: []const u8) !?[]const u8 {
    const stmt = try db.prepare("SELECT author_id FROM tweets WHERE tweet_id=? AND author_id IS NOT NULL");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return try allocator.dupe(u8, colText(stmt, 0));
}

fn tweetRawJson(db: *Db, allocator: std.mem.Allocator, tweet_id: []const u8) !?[]const u8 {
    const stmt = try db.prepare("SELECT raw_json FROM tweets WHERE tweet_id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return try allocator.dupe(u8, colText(stmt, 0));
}

fn userExists(db: *Db, user_id: []const u8) !bool {
    const stmt = try db.prepare("SELECT 1 FROM users WHERE user_id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, user_id);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn missingReferenceExists(db: *Db, tweet_id: []const u8, referenced_tweet_id: []const u8, reference_type: []const u8) !bool {
    const stmt = try db.prepare("SELECT 1 FROM missing_references WHERE tweet_id=? AND referenced_tweet_id=? AND reference_type=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    try bindText(stmt, 2, referenced_tweet_id);
    try bindText(stmt, 3, reference_type);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn bookmarkExists(db: *Db, account_user_id: []const u8, tweet_id: []const u8) !bool {
    const stmt = try db.prepare("SELECT 1 FROM bookmark_items WHERE account_user_id=? AND tweet_id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, account_user_id);
    try bindText(stmt, 2, tweet_id);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn markBookmarksInactiveNotSeen(db: *Db, account_user_id: []const u8, run_id: i64) !void {
    const stmt = try db.prepare("UPDATE bookmark_items SET active=0 WHERE account_user_id=? AND active=1 AND last_seen_run_id<>?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, account_user_id);
    _ = c.sqlite3_bind_int64(stmt, 2, run_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn markRunBookmarksIncomplete(db: *Db, account_user_id: []const u8, run_id: i64) !void {
    const stmt = try db.prepare("UPDATE bookmark_items SET complete_for_offline_render=0 WHERE account_user_id=? AND last_seen_run_id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, account_user_id);
    _ = c.sqlite3_bind_int64(stmt, 2, run_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn refreshBookmarkCompletenessForRun(db: *Db, allocator: std.mem.Allocator, account_user_id: []const u8, run_id: i64, folder_state_accounted: bool) !void {
    const stmt = try db.prepare("SELECT tweet_id FROM bookmark_items WHERE account_user_id=? AND last_seen_run_id=? ORDER BY import_position");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, account_user_id);
    _ = c.sqlite3_bind_int64(stmt, 2, run_id);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        const tweet_id = try allocator.dupe(u8, colText(stmt, 0));
        defer allocator.free(tweet_id);
        try updateBookmarkCompleteness(db, account_user_id, tweet_id, folder_state_accounted and try bookmarkCompleteForOfflineRender(db, allocator, tweet_id));
    }
}

fn updateBookmarkCompleteness(db: *Db, account_user_id: []const u8, tweet_id: []const u8, complete: bool) !void {
    const stmt = try db.prepare("UPDATE bookmark_items SET complete_for_offline_render=? WHERE account_user_id=? AND tweet_id=?");
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, if (complete) 1 else 0);
    try bindText(stmt, 2, account_user_id);
    try bindText(stmt, 3, tweet_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn previousImportPosition(db: *Db, account_user_id: []const u8, tweet_id: []const u8) !?i64 {
    const stmt = try db.prepare("SELECT import_position FROM bookmark_items WHERE account_user_id=? AND tweet_id=? AND import_position IS NOT NULL");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, account_user_id);
    try bindText(stmt, 2, tweet_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return c.sqlite3_column_int64(stmt, 0);
}

fn isBookmarkComplete(db: *Db, account_user_id: []const u8, tweet_id: []const u8) !bool {
    const stmt = try db.prepare("SELECT complete_for_offline_render FROM bookmark_items WHERE account_user_id=? AND tweet_id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, account_user_id);
    try bindText(stmt, 2, tweet_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return false;
    return c.sqlite3_column_int(stmt, 0) != 0;
}

fn usernameForUser(db: *Db, allocator: std.mem.Allocator, user_id: []const u8) !?[]const u8 {
    const stmt = try db.prepare("SELECT username FROM users WHERE user_id=? AND username IS NOT NULL");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return try allocator.dupe(u8, colText(stmt, 0));
}

fn canonicalUri(allocator: std.mem.Allocator, username: ?[]const u8, tweet_id: []const u8) ![]const u8 {
    if (username) |u| if (u.len > 0) return std.fmt.allocPrint(allocator, "https://x.com/{s}/status/{s}", .{ u, tweet_id });
    return std.fmt.allocPrint(allocator, "https://x.com/i/web/status/{s}", .{tweet_id});
}

fn rateLimitWaitSeconds(response: HttpResponse, wait_rate_limit: bool, now: i64) ?i64 {
    if (!wait_rate_limit) return null;
    const reset = response.rate_limit_reset orelse return null;
    if (reset <= now) return null;
    return reset - now;
}

fn syncFolders(db: *Db, allocator: std.mem.Allocator, access_token: []const u8, account_user_id: []const u8, run_id: i64, wait_rate_limit: bool) !bool {
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth);
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth },
        .{ .name = "Accept", .value = "application/json" },
    };

    var next_token: ?[]u8 = null;
    defer if (next_token) |value| allocator.free(value);
    var page_number: u32 = 1;
    while (true) {
        if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("folders: requesting folder page {}\n", .{page_number});
        const url = try buildBookmarkFoldersUrl(allocator, account_user_id, next_token);
        defer allocator.free(url);
        const response = httpFetch(allocator, .GET, url, null, &headers) catch |err| {
            const context = try std.fmt.allocPrint(allocator, "{{\"endpoint\":\"folders\",\"error\":\"{}\"}}", .{err});
            defer allocator.free(context);
            try recordSyncWarning(db, allocator, run_id, "bookmark_folder_sync_failed", context);
            try std.fs.File.stderr().deprecatedWriter().print("warning: bookmark folder sync failed: {}\n", .{err});
            return false;
        };
        defer freeHttpResponse(allocator, response);
        if (response.status == .too_many_requests) {
            if (rateLimitWaitSeconds(response, wait_rate_limit, std.time.timestamp())) |seconds| {
                try std.fs.File.stderr().deprecatedWriter().print("rate limited during folder sync; waiting {} seconds until reset\n", .{seconds});
                std.Thread.sleep(@as(u64, @intCast(seconds)) * std.time.ns_per_s);
                continue;
            }
            if (response.rate_limit_reset) |reset| {
                try std.fs.File.stderr().deprecatedWriter().print("rate limited during folder sync; x-rate-limit-reset={}\n", .{reset});
            }
            return AppError.RateLimited;
        }
        if (response.status != .ok) {
            const context = try std.fmt.allocPrint(allocator, "{{\"endpoint\":\"folders\",\"http_status\":{}}}", .{@intFromEnum(response.status)});
            defer allocator.free(context);
            try recordSyncWarning(db, allocator, run_id, "bookmark_folder_sync_failed", context);
            try std.fs.File.stderr().deprecatedWriter().print("warning: bookmark folder sync returned HTTP {}\n", .{@intFromEnum(response.status)});
            return false;
        }
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
        defer parsed.deinit();
        var folders_seen: u32 = 0;
        if (getArray(parsed.value, "data")) |data| {
            folders_seen = @intCast(data.items.len);
            if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("folders: page {} returned {} folder(s)\n", .{ page_number, folders_seen });
            for (data.items) |folder| {
                if (folder != .object) continue;
                try upsertFolderFromValue(db, allocator, account_user_id, folder);
                const folder_id = getString(folder, "id") orelse getString(folder, "folder_id") orelse continue;
                if (!try syncFolderItems(db, allocator, access_token, account_user_id, folder_id, run_id, wait_rate_limit)) return false;
            }
        }
        const meta = getObject(parsed.value, "meta");
        if (meta) |m| {
            if (getString(m, "next_token")) |tok| {
                try replaceOwnedOptionalString(allocator, &next_token, tok);
                page_number += 1;
                continue;
            }
        }
        break;
    }
    return true;
}

fn buildBookmarkFoldersUrl(allocator: std.mem.Allocator, account_user_id: []const u8, next_token: ?[]const u8) ![]const u8 {
    const pagination = if (next_token) |tok| blk: {
        const encoded = try urlEncode(allocator, tok);
        defer allocator.free(encoded);
        break :blk try std.fmt.allocPrint(allocator, "?pagination_token={s}", .{encoded});
    } else try allocator.dupe(u8, "");
    defer allocator.free(pagination);
    return std.fmt.allocPrint(allocator, x_api_base ++ "/users/{s}/bookmarks/folders{s}", .{ account_user_id, pagination });
}

fn buildBookmarkFolderItemsUrl(allocator: std.mem.Allocator, account_user_id: []const u8, encoded_folder_id: []const u8, next_token: ?[]const u8) ![]const u8 {
    const pagination = if (next_token) |tok| blk: {
        const encoded = try urlEncode(allocator, tok);
        defer allocator.free(encoded);
        break :blk try std.fmt.allocPrint(allocator, "?pagination_token={s}", .{encoded});
    } else try allocator.dupe(u8, "");
    defer allocator.free(pagination);
    return std.fmt.allocPrint(allocator, x_api_base ++ "/users/{s}/bookmarks/folders/{s}{s}", .{ account_user_id, encoded_folder_id, pagination });
}

fn syncFolderItems(db: *Db, allocator: std.mem.Allocator, access_token: []const u8, account_user_id: []const u8, folder_id: []const u8, run_id: i64, wait_rate_limit: bool) !bool {
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth);
    const encoded_folder = try urlEncode(allocator, folder_id);
    defer allocator.free(encoded_folder);
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth },
        .{ .name = "Accept", .value = "application/json" },
    };
    var next_token: ?[]u8 = null;
    defer if (next_token) |value| allocator.free(value);
    try beginFolderItemPrune(db);
    var page_number: u32 = 1;
    while (true) {
        if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("folders: requesting items for folder {s} page {}\n", .{ folder_id, page_number });
        const url = try buildBookmarkFolderItemsUrl(allocator, account_user_id, encoded_folder, next_token);
        defer allocator.free(url);
        const response = httpFetch(allocator, .GET, url, null, &headers) catch |err| {
            const context = try std.fmt.allocPrint(allocator, "{{\"endpoint\":\"folder_items\",\"folder_id\":{f},\"error\":\"{}\"}}", .{ std.json.fmt(folder_id, .{}), err });
            defer allocator.free(context);
            try recordSyncWarning(db, allocator, run_id, "bookmark_folder_item_sync_failed", context);
            try std.fs.File.stderr().deprecatedWriter().print("warning: bookmark folder item sync failed for folder {s}: {}\n", .{ folder_id, err });
            return false;
        };
        defer freeHttpResponse(allocator, response);
        if (response.status == .too_many_requests) {
            if (rateLimitWaitSeconds(response, wait_rate_limit, std.time.timestamp())) |seconds| {
                try std.fs.File.stderr().deprecatedWriter().print("rate limited during folder item sync for folder {s}; waiting {} seconds until reset\n", .{ folder_id, seconds });
                std.Thread.sleep(@as(u64, @intCast(seconds)) * std.time.ns_per_s);
                continue;
            }
            if (response.rate_limit_reset) |reset| {
                try std.fs.File.stderr().deprecatedWriter().print("rate limited during folder item sync for folder {s}; x-rate-limit-reset={}\n", .{ folder_id, reset });
            }
            return AppError.RateLimited;
        }
        if (response.status != .ok) {
            const context = try std.fmt.allocPrint(allocator, "{{\"endpoint\":\"folder_items\",\"folder_id\":{f},\"http_status\":{}}}", .{ std.json.fmt(folder_id, .{}), @intFromEnum(response.status) });
            defer allocator.free(context);
            try recordSyncWarning(db, allocator, run_id, "bookmark_folder_item_sync_failed", context);
            try std.fs.File.stderr().deprecatedWriter().print("warning: bookmark folder item sync for folder {s} returned HTTP {}\n", .{ folder_id, @intFromEnum(response.status) });
            return false;
        }
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
        defer parsed.deinit();
        var items_seen: u32 = 0;
        if (getArray(parsed.value, "data")) |tweets| {
            items_seen = @intCast(tweets.items.len);
            for (tweets.items) |tweet| {
                if (tweet != .object) continue;
                const tweet_id = getString(tweet, "id") orelse continue;
                try upsertFolderItem(db, allocator, account_user_id, folder_id, tweet_id);
                try rememberFolderItemForPrune(db, tweet_id);
            }
        }
        if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("folders: folder {s} page {} returned {} item(s)\n", .{ folder_id, page_number, items_seen });
        const meta = getObject(parsed.value, "meta");
        if (meta) |m| {
            if (getString(m, "next_token")) |tok| {
                try replaceOwnedOptionalString(allocator, &next_token, tok);
                page_number += 1;
                continue;
            }
        }
        break;
    }
    try pruneFolderItemsNotSeen(db, account_user_id, folder_id);
    return true;
}

fn upsertFolderItem(db: *Db, allocator: std.mem.Allocator, account_user_id: []const u8, folder_id: []const u8, tweet_id: []const u8) !void {
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const stmt = try db.prepare(
        \\INSERT INTO bookmark_folder_items(account_user_id, folder_id, tweet_id, first_seen_at, last_seen_at)
        \\VALUES (?, ?, ?, ?, ?)
        \\ON CONFLICT(account_user_id, folder_id, tweet_id) DO UPDATE SET last_seen_at=excluded.last_seen_at
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, account_user_id);
    try bindText(stmt, 2, folder_id);
    try bindText(stmt, 3, tweet_id);
    try bindText(stmt, 4, now);
    try bindText(stmt, 5, now);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn beginFolderItemPrune(db: *Db) !void {
    try db.exec(
        \\CREATE TEMP TABLE IF NOT EXISTS current_folder_items(tweet_id TEXT PRIMARY KEY);
        \\DELETE FROM current_folder_items;
    );
}

fn rememberFolderItemForPrune(db: *Db, tweet_id: []const u8) !void {
    const stmt = try db.prepare("INSERT OR IGNORE INTO current_folder_items(tweet_id) VALUES (?)");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn pruneFolderItemsNotSeen(db: *Db, account_user_id: []const u8, folder_id: []const u8) !void {
    const stmt = try db.prepare(
        \\DELETE FROM bookmark_folder_items
        \\WHERE account_user_id=? AND folder_id=? AND tweet_id NOT IN (SELECT tweet_id FROM current_folder_items)
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, account_user_id);
    try bindText(stmt, 2, folder_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn upsertFolderFromValue(db: *Db, allocator: std.mem.Allocator, account_user_id: []const u8, folder: std.json.Value) !void {
    const folder_id = getString(folder, "id") orelse getString(folder, "folder_id") orelse return;
    const raw = try jsonValueAlloc(allocator, folder);
    defer allocator.free(raw);
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const stmt = try db.prepare(
        \\INSERT INTO bookmark_folders(account_user_id, folder_id, name, raw_json, first_seen_at, last_seen_at)
        \\VALUES (?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(account_user_id, folder_id) DO UPDATE SET name=excluded.name, raw_json=excluded.raw_json, last_seen_at=excluded.last_seen_at
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, account_user_id);
    try bindText(stmt, 2, folder_id);
    if (getString(folder, "name")) |v| try bindText(stmt, 3, v) else _ = c.sqlite3_bind_null(stmt, 3);
    try bindText(stmt, 4, raw);
    try bindText(stmt, 5, now);
    try bindText(stmt, 6, now);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn downloadAssetsFromIncludes(db: *Db, allocator: std.mem.Allocator, assets_dir: []const u8, root: std.json.Value, media_policy: []const u8) !void {
    const includes = getObject(root, "includes") orelse return;
    if (getArray(includes, "media")) |media_arr| {
        for (media_arr.items) |media| {
            if (media != .object) continue;
            try downloadAssetsForMediaValue(db, allocator, assets_dir, media_policy, media);
        }
    }
    if (getArray(includes, "users")) |users_arr| {
        for (users_arr.items) |user| {
            if (user != .object) continue;
            try downloadAssetsForUserValue(db, allocator, assets_dir, media_policy, user);
        }
    }
}

fn downloadAssetsForThread(db: *Db, allocator: std.mem.Allocator, assets_dir: []const u8, media_policy: []const u8, root_tweet_id: []const u8) !void {
    const media_stmt = try db.prepare(
        \\SELECT DISTINCT m.raw_json
        \\FROM thread_posts tp
        \\JOIN tweet_media tm ON tm.tweet_id = tp.tweet_id
        \\JOIN media m ON m.media_key = tm.media_key
        \\WHERE tp.root_tweet_id = ?
        \\ORDER BY m.media_key
    );
    defer _ = c.sqlite3_finalize(media_stmt);
    try bindText(media_stmt, 1, root_tweet_id);
    while (true) {
        const rc = c.sqlite3_step(media_stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, colText(media_stmt, 0), .{}) catch continue;
        defer parsed.deinit();
        try downloadAssetsForMediaValue(db, allocator, assets_dir, media_policy, parsed.value);
    }

    const user_stmt = try db.prepare(
        \\SELECT DISTINCT u.raw_json
        \\FROM thread_posts tp
        \\JOIN tweets t ON t.tweet_id = tp.tweet_id
        \\JOIN users u ON u.user_id = t.author_id
        \\WHERE tp.root_tweet_id = ?
        \\ORDER BY u.user_id
    );
    defer _ = c.sqlite3_finalize(user_stmt);
    try bindText(user_stmt, 1, root_tweet_id);
    while (true) {
        const rc = c.sqlite3_step(user_stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, colText(user_stmt, 0), .{}) catch continue;
        defer parsed.deinit();
        try downloadAssetsForUserValue(db, allocator, assets_dir, media_policy, parsed.value);
    }
}

fn downloadAssetsForMediaValue(db: *Db, allocator: std.mem.Allocator, assets_dir: []const u8, media_policy: []const u8, media: std.json.Value) !void {
    const key = getString(media, "media_key") orelse "";
    const width = getInt(media, "width");
    const height = getInt(media, "height");
    if (!std.mem.eql(u8, media_policy, "metadata-only")) {
        if (getString(media, "url")) |url| try downloadAsset(db, allocator, assets_dir, key, "image", url, width, height);
        if (getString(media, "preview_image_url")) |url| try downloadAsset(db, allocator, assets_dir, key, "preview_image", url, width, height);
    } else {
        if (getString(media, "url")) |url| try recordSkippedMediaAssetOnce(db, allocator, key, "image", url, width, height, "{\"reason\":\"metadata_only_policy\"}");
        if (getString(media, "preview_image_url")) |url| try recordSkippedMediaAssetOnce(db, allocator, key, "preview_image", url, width, height, "{\"reason\":\"metadata_only_policy\"}");
    }
    if (getArray(media, "variants")) |variants| {
        if (selectVideoVariant(variants)) |url| {
            const kind = if (std.mem.eql(u8, getString(media, "type") orelse "", "animated_gif")) "animated_gif_variant" else "video_variant";
            if (std.mem.eql(u8, media_policy, "all-local")) {
                try downloadAsset(db, allocator, assets_dir, key, kind, url, width, height);
            } else {
                try recordRemoteOnlyMediaAssetOnce(db, allocator, key, kind, url, width, height, "{\"reason\":\"local_video_disabled_by_policy\"}");
            }
        } else if (variants.items.len > 0) {
            const source = try std.fmt.allocPrint(allocator, "x-bookmarks:media:{s}:variant", .{key});
            defer allocator.free(source);
            try recordSkippedMediaAssetOnce(db, allocator, key, "video_variant", source, width, height, "{\"reason\":\"no_mp4_variant\"}");
        }
    }
}

fn downloadAssetsForUserValue(db: *Db, allocator: std.mem.Allocator, assets_dir: []const u8, media_policy: []const u8, user: std.json.Value) !void {
    const user_id = getString(user, "id") orelse "";
    if (!std.mem.eql(u8, media_policy, "metadata-only") and getString(user, "profile_image_url") != null) {
        const url = getString(user, "profile_image_url").?;
        const key = try std.fmt.allocPrint(allocator, "user:{s}", .{user_id});
        defer allocator.free(key);
        try downloadAsset(db, allocator, assets_dir, key, "author_avatar", url, null, null);
    } else if (std.mem.eql(u8, media_policy, "metadata-only")) {
        if (getString(user, "profile_image_url")) |url| {
            const key = try std.fmt.allocPrint(allocator, "user:{s}", .{user_id});
            defer allocator.free(key);
            try recordSkippedMediaAssetOnce(db, allocator, key, "author_avatar", url, null, null, "{\"reason\":\"metadata_only_policy\"}");
        }
    }
}

fn selectVideoVariant(variants: std.json.Array) ?[]const u8 {
    const preview_max_bitrate = 2_500_000;
    var best_preview_url: ?[]const u8 = null;
    var best_preview_bitrate: i64 = -1;
    var smallest_url: ?[]const u8 = null;
    var smallest_bitrate: i64 = std.math.maxInt(i64);
    for (variants.items) |variant| {
        if (variant != .object) continue;
        const content_type = getString(variant, "content_type") orelse "";
        if (!std.mem.eql(u8, content_type, "video/mp4")) continue;
        const url = getString(variant, "url") orelse continue;
        const bitrate = getInt(variant, "bit_rate") orelse getInt(variant, "bitrate") orelse 0;
        if (bitrate <= preview_max_bitrate and bitrate > best_preview_bitrate) {
            best_preview_bitrate = bitrate;
            best_preview_url = url;
        }
        if (bitrate < smallest_bitrate) {
            smallest_bitrate = bitrate;
            smallest_url = url;
        }
    }
    return best_preview_url orelse smallest_url;
}

fn downloadAsset(db: *Db, allocator: std.mem.Allocator, assets_dir: []const u8, media_key: []const u8, kind: []const u8, source_url: []const u8, width: ?i64, height: ?i64) !void {
    if (try validAssetForSourceKeyKind(db, allocator, source_url, media_key, kind)) |existing| {
        if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("assets: reuse existing {s} {s} bytes={}\n", .{ kind, media_key, existing.byte_size });
        existing.deinit(allocator);
        return;
    }
    if (try validAssetForSource(db, allocator, source_url)) |existing| {
        defer existing.deinit(allocator);
        if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("assets: reuse content for {s} {s} bytes={}\n", .{ kind, media_key, existing.byte_size });
        try recordMediaAsset(
            db,
            allocator,
            media_key,
            kind,
            source_url,
            existing.local_path,
            if (existing.content_type.len > 0) existing.content_type else null,
            existing.byte_size,
            if (existing.sha256.len > 0) existing.sha256 else null,
            width,
            height,
            "downloaded",
            null,
        );
        return;
    }
    if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("assets: downloading {s} {s}\n", .{ kind, media_key });
    const response = httpFetch(allocator, .GET, source_url, null, &.{}) catch |err| {
        const err_json = try errorJson(allocator, err);
        defer allocator.free(err_json);
        try recordMediaAsset(db, allocator, media_key, kind, source_url, "", null, 0, null, width, height, "failed", err_json);
        if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("assets: failed {s} {s}: {}\n", .{ kind, media_key, err });
        return;
    };
    defer freeHttpResponse(allocator, response);
    if (response.status != .ok) {
        const err = try std.fmt.allocPrint(allocator, "{{\"http_status\":{}}}", .{@intFromEnum(response.status)});
        defer allocator.free(err);
        try recordMediaAsset(db, allocator, media_key, kind, source_url, "", response.content_type, 0, null, width, height, "failed", err);
        if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("assets: failed {s} {s} HTTP {}\n", .{ kind, media_key, @intFromEnum(response.status) });
        return;
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(response.body, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (try downloadedPathForHash(db, allocator, &hex)) |existing_path| {
        defer allocator.free(existing_path);
        try recordMediaAsset(db, allocator, media_key, kind, source_url, existing_path, response.content_type, @intCast(response.body.len), &hex, width, height, "downloaded", null);
        if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("assets: reused hash for {s} {s} bytes={}\n", .{ kind, media_key, response.body.len });
        return;
    }
    const ext = extensionForUrl(source_url);
    const dir = try std.fs.path.join(allocator, &.{ assets_dir, kind, media_key });
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);
    const filename = try std.fmt.allocPrint(allocator, "{s}{s}", .{ &hex, ext });
    defer allocator.free(filename);
    const path = try std.fs.path.join(allocator, &.{ dir, filename });
    defer allocator.free(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = response.body });
    try recordMediaAsset(db, allocator, media_key, kind, source_url, path, response.content_type, @intCast(response.body.len), &hex, width, height, "downloaded", null);
    if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("assets: downloaded {s} {s} bytes={}\n", .{ kind, media_key, response.body.len });
}

fn assetSourceValid(db: *Db, allocator: std.mem.Allocator, source_url: []const u8) !bool {
    const existing = try validAssetForSource(db, allocator, source_url) orelse return false;
    existing.deinit(allocator);
    return true;
}

fn validAssetForSourceKeyKind(db: *Db, allocator: std.mem.Allocator, source_url: []const u8, media_key: []const u8, kind: []const u8) !?ExistingAsset {
    const stmt = try db.prepare("SELECT coalesce(media_key, ''), asset_kind, local_path, coalesce(content_type, ''), coalesce(byte_size, -1), coalesce(sha256, '') FROM media_assets WHERE source_url=? AND media_key=? AND asset_kind=? AND status='downloaded' AND local_path IS NOT NULL ORDER BY id DESC");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, source_url);
    try bindText(stmt, 2, media_key);
    try bindText(stmt, 3, kind);
    return validAssetFromSteppedStatement(allocator, stmt);
}

fn validAssetForSource(db: *Db, allocator: std.mem.Allocator, source_url: []const u8) !?ExistingAsset {
    const stmt = try db.prepare("SELECT coalesce(media_key, ''), asset_kind, local_path, coalesce(content_type, ''), coalesce(byte_size, -1), coalesce(sha256, '') FROM media_assets WHERE source_url=? AND status='downloaded' AND local_path IS NOT NULL ORDER BY id DESC");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, source_url);
    return validAssetFromSteppedStatement(allocator, stmt);
}

fn validAssetFromSteppedStatement(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !?ExistingAsset {
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        const path = colText(stmt, 2);
        const expected_size = c.sqlite3_column_int64(stmt, 4);
        const expected_hash = colText(stmt, 5);
        if (!try assetFileMatches(allocator, path, expected_size, expected_hash)) continue;
        return .{
            .media_key = try allocator.dupe(u8, colText(stmt, 0)),
            .asset_kind = try allocator.dupe(u8, colText(stmt, 1)),
            .local_path = try allocator.dupe(u8, path),
            .content_type = try allocator.dupe(u8, colText(stmt, 3)),
            .byte_size = expected_size,
            .sha256 = try allocator.dupe(u8, expected_hash),
        };
    }
}

fn downloadedPathForHash(db: *Db, allocator: std.mem.Allocator, sha256: []const u8) !?[]const u8 {
    const stmt = try db.prepare("SELECT local_path, coalesce(byte_size, -1), coalesce(sha256, '') FROM media_assets WHERE sha256=? AND status='downloaded' AND local_path IS NOT NULL ORDER BY id ASC");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, sha256);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        const path = colText(stmt, 0);
        const expected_size = c.sqlite3_column_int64(stmt, 1);
        const expected_hash = colText(stmt, 2);
        if (!try assetFileMatches(allocator, path, expected_size, expected_hash)) continue;
        return try allocator.dupe(u8, path);
    }
}

fn assetFileMatches(allocator: std.mem.Allocator, path: []const u8, expected_size: i64, expected_hash: []const u8) !bool {
    if (path.len == 0) return false;
    const data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024 * 1024) catch return false;
    defer allocator.free(data);
    if (expected_size >= 0 and expected_size != @as(i64, @intCast(data.len))) return false;
    if (expected_hash.len > 0) {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        const actual = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, expected_hash, &actual)) return false;
    }
    return true;
}

fn recordMediaAsset(db: *Db, allocator: std.mem.Allocator, media_key: []const u8, kind: []const u8, source_url: []const u8, local_path: []const u8, content_type: ?[]const u8, byte_size: i64, sha256: ?[]const u8, width: ?i64, height: ?i64, status: []const u8, err_json: ?[]const u8) !void {
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const retrieval_policy = defaultRetrievalPolicyForAsset(kind, status);
    const retry_class = classifyAssetRetry(status, err_json);
    const stmt = try db.prepare(
        "INSERT INTO media_assets(media_key, asset_kind, source_url, local_path, content_type, byte_size, sha256, width, height, status, error_json, first_seen_at, last_checked_at, retrieval_policy, retry_class, attempts, last_error_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)",
    );
    defer _ = c.sqlite3_finalize(stmt);
    if (media_key.len > 0) try bindText(stmt, 1, media_key) else _ = c.sqlite3_bind_null(stmt, 1);
    try bindText(stmt, 2, kind);
    try bindText(stmt, 3, source_url);
    try bindText(stmt, 4, local_path);
    if (content_type) |v| try bindText(stmt, 5, v) else _ = c.sqlite3_bind_null(stmt, 5);
    _ = c.sqlite3_bind_int64(stmt, 6, byte_size);
    if (sha256) |v| try bindText(stmt, 7, v) else _ = c.sqlite3_bind_null(stmt, 7);
    if (width) |v| _ = c.sqlite3_bind_int64(stmt, 8, v) else _ = c.sqlite3_bind_null(stmt, 8);
    if (height) |v| _ = c.sqlite3_bind_int64(stmt, 9, v) else _ = c.sqlite3_bind_null(stmt, 9);
    try bindText(stmt, 10, status);
    if (err_json) |v| try bindText(stmt, 11, v) else _ = c.sqlite3_bind_null(stmt, 11);
    try bindText(stmt, 12, now);
    try bindText(stmt, 13, now);
    try bindText(stmt, 14, retrieval_policy);
    if (retry_class) |v| try bindText(stmt, 15, v) else _ = c.sqlite3_bind_null(stmt, 15);
    if (err_json != null and !std.mem.eql(u8, status, "downloaded")) try bindText(stmt, 16, now) else _ = c.sqlite3_bind_null(stmt, 16);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn defaultRetrievalPolicyForAsset(kind: []const u8, status: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "video_variant") or std.mem.eql(u8, kind, "animated_gif_variant")) {
        if (std.mem.eql(u8, status, "downloaded")) return "all-local";
        return "images-only";
    }
    return "images-only";
}

fn classifyAssetRetry(status: []const u8, err_json: ?[]const u8) ?[]const u8 {
    if (std.mem.eql(u8, status, "downloaded")) return null;
    if (std.mem.eql(u8, status, "skipped") or std.mem.eql(u8, status, "remote_only") or std.mem.eql(u8, status, "removed")) return "policy";
    if (!std.mem.eql(u8, status, "failed")) return null;
    const err = err_json orelse return "unknown";
    if (containsIgnoreCase(err, "503") or containsIgnoreCase(err, "502") or containsIgnoreCase(err, "500") or containsIgnoreCase(err, "504") or containsIgnoreCase(err, "UnknownHostName") or containsIgnoreCase(err, "timeout") or containsIgnoreCase(err, "connection reset")) return "transient";
    if (containsIgnoreCase(err, "403") or containsIgnoreCase(err, "404")) return "permanent";
    return "unknown";
}

fn recordSkippedMediaAssetOnce(db: *Db, allocator: std.mem.Allocator, media_key: []const u8, kind: []const u8, source_url: []const u8, width: ?i64, height: ?i64, err_json: []const u8) !void {
    if (try mediaAssetRecordExists(db, media_key, kind, source_url, "skipped")) return;
    try recordMediaAsset(db, allocator, media_key, kind, source_url, "", null, 0, null, width, height, "skipped", err_json);
}

fn recordRemoteOnlyMediaAssetOnce(db: *Db, allocator: std.mem.Allocator, media_key: []const u8, kind: []const u8, source_url: []const u8, width: ?i64, height: ?i64, err_json: []const u8) !void {
    if (try mediaAssetRecordExists(db, media_key, kind, source_url, "remote_only")) return;
    try recordMediaAsset(db, allocator, media_key, kind, source_url, "", null, 0, null, width, height, "remote_only", err_json);
}

fn mediaAssetRecordExists(db: *Db, media_key: []const u8, kind: []const u8, source_url: []const u8, status: []const u8) !bool {
    const stmt = try db.prepare("SELECT 1 FROM media_assets WHERE media_key=? AND asset_kind=? AND source_url=? AND status=? LIMIT 1");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, media_key);
    try bindText(stmt, 2, kind);
    try bindText(stmt, 3, source_url);
    try bindText(stmt, 4, status);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn extensionForUrl(url: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    const clean = url[0..end];
    if (std.mem.endsWith(u8, clean, ".jpg") or std.mem.endsWith(u8, clean, ".jpeg")) return ".jpg";
    if (std.mem.endsWith(u8, clean, ".png")) return ".png";
    if (std.mem.endsWith(u8, clean, ".gif")) return ".gif";
    if (std.mem.endsWith(u8, clean, ".webp")) return ".webp";
    if (std.mem.endsWith(u8, clean, ".mp4")) return ".mp4";
    return ".bin";
}

fn errorJson(allocator: std.mem.Allocator, err: anyerror) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"error\":\"{}\"}}", .{err});
}

fn jsonValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{std.json.fmt(value, .{})});
    return out.toOwnedSlice();
}

fn jsonStringAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{std.json.fmt(value, .{})});
    return out.toOwnedSlice();
}

fn optionalJsonStringAlloc(allocator: std.mem.Allocator, value: ?[]const u8) ![]u8 {
    if (value) |v| return jsonStringAlloc(allocator, v);
    return allocator.dupe(u8, "null");
}

fn nonEmptyOptional(value: ?[]const u8) ?[]const u8 {
    if (value) |v| if (v.len > 0) return v;
    return null;
}

fn exportJsonl(db: *Db, allocator: std.mem.Allocator, writer: anytype) !void {
    const stmt = try db.prepare(
        \\SELECT b.account_user_id, b.tweet_id, b.complete_for_offline_render, t.canonical_uri, t.twitter_uri,
        \\       coalesce(t.text, ''), coalesce(t.created_at, ''), coalesce(t.author_id, ''), coalesce(u.username, ''), coalesce(u.name, ''), t.raw_json
        \\FROM bookmark_items b
        \\JOIN tweets t ON t.tweet_id = b.tweet_id
        \\LEFT JOIN users u ON u.user_id = t.author_id
        \\WHERE b.active = 1
        \\ORDER BY b.import_position IS NULL, b.import_position, b.last_seen_at DESC, b.tweet_id DESC
    );
    defer _ = c.sqlite3_finalize(stmt);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        try w.writeAll("{");
        try jsonField(w, "account_user_id", colText(stmt, 0), false);
        try jsonField(w, "tweet_id", colText(stmt, 1), true);
        try w.print(",\"complete_for_offline_render\":{}", .{c.sqlite3_column_int(stmt, 2) != 0});
        try jsonField(w, "canonical_uri", colText(stmt, 3), true);
        try jsonField(w, "twitter_uri", colText(stmt, 4), true);
        try jsonField(w, "text", colText(stmt, 5), true);
        try jsonField(w, "created_at", colText(stmt, 6), true);
        try jsonField(w, "author_id", colText(stmt, 7), true);
        try jsonField(w, "author_username", colText(stmt, 8), true);
        try jsonField(w, "author_name", colText(stmt, 9), true);
        try jsonAuthorAvatarPathField(db, w, colText(stmt, 7));
        try jsonField(w, "raw_json", colText(stmt, 10), true);
        try jsonStringArrayField(db, allocator, w, "local_asset_paths",
            \\SELECT ma.local_path
            \\FROM media_assets ma
            \\JOIN tweet_media tm ON tm.media_key = ma.media_key
            \\WHERE tm.tweet_id = ? AND ma.status = 'downloaded'
            \\ORDER BY tm.position, ma.id
        , colText(stmt, 1));
        try jsonStringArrayField(db, allocator, w, "folder_ids", "SELECT folder_id FROM bookmark_folder_items WHERE tweet_id = ? ORDER BY folder_id", colText(stmt, 1));
        try jsonFoldersField(db, w, colText(stmt, 1));
        try jsonQuotePostsField(db, allocator, w, colText(stmt, 10));
        try jsonMissingReferencesField(db, w, colText(stmt, 1));
        try w.writeAll("}\n");
        try writer.writeAll(buf.items);
    }
}

fn jsonQuotePostsField(db: *Db, allocator: std.mem.Allocator, writer: anytype, tweet_raw_json: []const u8) !void {
    try writer.writeAll(",\"quote_posts\":[");
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, tweet_raw_json, .{}) catch {
        try writer.writeAll("]");
        return;
    };
    defer parsed.deinit();
    const refs = getArray(parsed.value, "referenced_tweets") orelse {
        try writer.writeAll("]");
        return;
    };
    var first = true;
    for (refs.items) |ref| {
        if (ref != .object) continue;
        if (!std.mem.eql(u8, getString(ref, "type") orelse "", "quoted")) continue;
        const quote_id = getString(ref, "id") orelse continue;
        const stmt = try db.prepare(
            \\SELECT tweet_id, canonical_uri, twitter_uri, coalesce(text, ''), coalesce(created_at, ''), coalesce(author_id, ''), raw_json
            \\FROM tweets
            \\WHERE tweet_id = ?
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, quote_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) continue;
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.writeAll("{");
        try jsonField(writer, "tweet_id", colText(stmt, 0), false);
        try jsonField(writer, "canonical_uri", colText(stmt, 1), true);
        try jsonField(writer, "twitter_uri", colText(stmt, 2), true);
        try jsonField(writer, "text", colText(stmt, 3), true);
        try jsonField(writer, "created_at", colText(stmt, 4), true);
        try jsonField(writer, "author_id", colText(stmt, 5), true);
        try jsonAuthorAvatarPathField(db, writer, colText(stmt, 5));
        try jsonStringArrayField(db, allocator, writer, "local_asset_paths",
            \\SELECT ma.local_path
            \\FROM media_assets ma
            \\JOIN tweet_media tm ON tm.media_key = ma.media_key
            \\WHERE tm.tweet_id = ? AND ma.status = 'downloaded'
            \\ORDER BY tm.position, ma.id
        , quote_id);
        try jsonField(writer, "raw_json", colText(stmt, 6), true);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn jsonAuthorAvatarPathField(db: *Db, writer: anytype, author_id: []const u8) !void {
    if (author_id.len == 0) {
        try jsonField(writer, "author_avatar_path", "", true);
        return;
    }
    var key_buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "user:{s}", .{author_id}) catch {
        try jsonField(writer, "author_avatar_path", "", true);
        return;
    };
    try jsonOptionalStringQueryField(db, writer, "author_avatar_path",
        \\SELECT local_path
        \\FROM media_assets
        \\WHERE media_key=? AND asset_kind='author_avatar' AND status='downloaded'
        \\ORDER BY id DESC
        \\LIMIT 1
    , key);
}

fn jsonOptionalStringQueryField(db: *Db, writer: anytype, name: []const u8, sql: []const u8, bind_value: []const u8) !void {
    const stmt = try db.prepare(sql);
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, bind_value);
    try writer.print(",{f}:", .{std.json.fmt(name, .{})});
    const rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_DONE) {
        try writer.print("{f}", .{std.json.fmt("", .{})});
    } else if (rc == c.SQLITE_ROW) {
        try writer.print("{f}", .{std.json.fmt(colText(stmt, 0), .{})});
    } else {
        return AppError.SqliteError;
    }
}

fn jsonMissingReferencesField(db: *Db, writer: anytype, tweet_id: []const u8) !void {
    try writer.writeAll(",\"missing_references\":[");
    const stmt = try db.prepare(
        \\SELECT referenced_tweet_id, reference_type, status, raw_json
        \\FROM missing_references
        \\WHERE tweet_id = ?
        \\ORDER BY reference_type, referenced_tweet_id
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    var first = true;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.writeAll("{");
        try jsonField(writer, "referenced_tweet_id", colText(stmt, 0), false);
        try jsonField(writer, "reference_type", colText(stmt, 1), true);
        try jsonField(writer, "status", colText(stmt, 2), true);
        try jsonField(writer, "raw_json", colText(stmt, 3), true);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn jsonFoldersField(db: *Db, writer: anytype, tweet_id: []const u8) !void {
    try writer.writeAll(",\"folders\":[");
    const stmt = try db.prepare(
        \\SELECT f.folder_id, coalesce(f.name, ''), f.raw_json
        \\FROM bookmark_folder_items bfi
        \\JOIN bookmark_folders f ON f.account_user_id = bfi.account_user_id AND f.folder_id = bfi.folder_id
        \\WHERE bfi.tweet_id = ?
        \\ORDER BY f.name, f.folder_id
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    var first = true;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.writeAll("{");
        try jsonField(writer, "folder_id", colText(stmt, 0), false);
        try jsonField(writer, "name", colText(stmt, 1), true);
        try jsonField(writer, "raw_json", colText(stmt, 2), true);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn jsonStringArrayField(db: *Db, allocator: std.mem.Allocator, writer: anytype, name: []const u8, sql: []const u8, bind_value: []const u8) !void {
    _ = allocator;
    const stmt = try db.prepare(sql);
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, bind_value);
    try writer.print(",{f}:[", .{std.json.fmt(name, .{})});
    var first = true;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.print("{f}", .{std.json.fmt(colText(stmt, 0), .{})});
    }
    try writer.writeAll("]");
}

fn viewerExport(db: *Db, allocator: std.mem.Allocator, cfg: Config) !void {
    try reconcileMissingDownloadedAssets(db, allocator);
    try refreshCompletenessForAllActiveBookmarks(db, allocator);
    try resetExportDir(allocator, cfg.export_dir);

    const bookmarks_path = try std.fs.path.join(allocator, &.{ cfg.export_dir, "data", "bookmarks.json" });
    defer allocator.free(bookmarks_path);
    const folders_path = try std.fs.path.join(allocator, &.{ cfg.export_dir, "data", "folders.json" });
    defer allocator.free(folders_path);
    const media_assets_path = try std.fs.path.join(allocator, &.{ cfg.export_dir, "data", "media-assets.json" });
    defer allocator.free(media_assets_path);
    const tweet_media_path = try std.fs.path.join(allocator, &.{ cfg.export_dir, "data", "tweet-media.json" });
    defer allocator.free(tweet_media_path);
    const tweets_path = try std.fs.path.join(allocator, &.{ cfg.export_dir, "data", "tweets.json" });
    defer allocator.free(tweets_path);
    const folder_items_path = try std.fs.path.join(allocator, &.{ cfg.export_dir, "data", "folder-items.json" });
    defer allocator.free(folder_items_path);
    const missing_refs_path = try std.fs.path.join(allocator, &.{ cfg.export_dir, "data", "missing-references.json" });
    defer allocator.free(missing_refs_path);
    const sync_warnings_path = try std.fs.path.join(allocator, &.{ cfg.export_dir, "data", "sync-warnings.json" });
    defer allocator.free(sync_warnings_path);
    const summary_path = try std.fs.path.join(allocator, &.{ cfg.export_dir, "data", "sync-summary.json" });
    defer allocator.free(summary_path);
    const index_path = try std.fs.path.join(allocator, &.{ cfg.export_dir, "index.html" });
    defer allocator.free(index_path);
    try copyBuiltViewerIfPresent(allocator, cfg.export_dir);

    try writeQueryJsonArray(db, allocator, bookmarks_path,
        \\SELECT b.account_user_id, b.tweet_id, b.complete_for_offline_render, t.canonical_uri, t.twitter_uri,
        \\       coalesce(t.text, ''), coalesce(t.created_at, ''), coalesce(t.author_id, ''), coalesce(u.username, ''), coalesce(u.name, ''),
        \\       coalesce(u.profile_image_url, ''), t.raw_json
        \\FROM bookmark_items b
        \\JOIN tweets t ON t.tweet_id = b.tweet_id
        \\LEFT JOIN users u ON u.user_id = t.author_id
        \\WHERE b.active = 1
        \\ORDER BY b.import_position IS NULL, b.import_position, b.last_seen_at DESC, b.tweet_id DESC
    , &.{ "account_user_id", "tweet_id", "complete_for_offline_render:bool", "canonical_uri", "twitter_uri", "text", "created_at", "author_id", "author_username", "author_name", "author_avatar_url", "raw_json" });

    try writeQueryJsonArray(db, allocator, folders_path, "SELECT account_user_id, folder_id, coalesce(name, ''), raw_json FROM bookmark_folders ORDER BY name, folder_id", &.{ "account_user_id", "folder_id", "name", "raw_json" });

    try writeMediaAssetsJsonAndCopy(db, allocator, media_assets_path, cfg.export_dir);

    try writeQueryJsonArray(db, allocator, tweet_media_path, "SELECT tweet_id, media_key, coalesce(position, 0) FROM tweet_media ORDER BY tweet_id, position", &.{ "tweet_id", "media_key", "position:int" });

    try writeQueryJsonArray(db, allocator, tweets_path,
        \\SELECT t.tweet_id, t.canonical_uri, t.twitter_uri, coalesce(t.text, ''), coalesce(t.created_at, ''),
        \\       coalesce(t.author_id, ''), coalesce(u.username, ''), coalesce(u.name, ''), t.raw_json
        \\FROM tweets t
        \\LEFT JOIN users u ON u.user_id = t.author_id
        \\ORDER BY t.created_at DESC, t.tweet_id DESC
    , &.{ "tweet_id", "canonical_uri", "twitter_uri", "text", "created_at", "author_id", "author_username", "author_name", "raw_json" });

    try writeQueryJsonArray(db, allocator, folder_items_path, "SELECT account_user_id, folder_id, tweet_id FROM bookmark_folder_items ORDER BY folder_id, tweet_id", &.{ "account_user_id", "folder_id", "tweet_id" });

    try writeQueryJsonArray(db, allocator, missing_refs_path, "SELECT tweet_id, referenced_tweet_id, reference_type, status, raw_json FROM missing_references ORDER BY tweet_id, referenced_tweet_id", &.{ "tweet_id", "referenced_tweet_id", "reference_type", "status", "raw_json" });

    try writeQueryJsonArray(db, allocator, sync_warnings_path, "SELECT sync_run_id, warning_type, context_json, created_at FROM sync_warnings ORDER BY id", &.{ "sync_run_id:int", "warning_type", "context_json", "created_at" });

    try writeSummaryJson(db, allocator, summary_path);
    if (!fileExists(index_path)) {
        try std.fs.cwd().writeFile(.{ .sub_path = index_path, .data = fallbackViewerHtml });
    }
    try validateViewerExportFiles(allocator, cfg.export_dir);
    try std.fs.File.stdout().deprecatedWriter().print("exported viewer: {s}\n", .{cfg.export_dir});
}

fn validateCompleteBookmarksForExport(db: *Db, allocator: std.mem.Allocator) !void {
    const stmt = try db.prepare("SELECT account_user_id, tweet_id, last_seen_run_id FROM bookmark_items WHERE active = 1 AND complete_for_offline_render = 1 ORDER BY account_user_id, tweet_id");
    defer _ = c.sqlite3_finalize(stmt);
    var invalid: u32 = 0;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        const account_user_id = try allocator.dupe(u8, colText(stmt, 0));
        defer allocator.free(account_user_id);
        const tweet_id = try allocator.dupe(u8, colText(stmt, 1));
        defer allocator.free(tweet_id);
        const run_id = c.sqlite3_column_int64(stmt, 2);
        if (!try bookmarkCompleteForOfflineRender(db, allocator, tweet_id) or !try folderStateAccountedForBookmarkRun(db, account_user_id, run_id)) {
            invalid += 1;
            if (!builtin.is_test) {
                try std.fs.File.stderr().deprecatedWriter().print("complete bookmark no longer exportable: tweet_id={s}\n", .{tweet_id});
            }
        }
    }
    if (invalid > 0) return AppError.IoError;
}

fn refreshCompletenessForAllActiveBookmarks(db: *Db, allocator: std.mem.Allocator) !void {
    const stmt = try db.prepare("SELECT account_user_id, tweet_id, last_seen_run_id FROM bookmark_items WHERE active = 1 ORDER BY account_user_id, tweet_id");
    defer _ = c.sqlite3_finalize(stmt);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        const account_user_id = try allocator.dupe(u8, colText(stmt, 0));
        defer allocator.free(account_user_id);
        const tweet_id = try allocator.dupe(u8, colText(stmt, 1));
        defer allocator.free(tweet_id);
        const run_id = c.sqlite3_column_int64(stmt, 2);
        const complete = try bookmarkCompleteForOfflineRender(db, allocator, tweet_id) and try folderStateAccountedForBookmarkRun(db, account_user_id, run_id);
        try updateBookmarkCompleteness(db, account_user_id, tweet_id, complete);
    }
}

fn reconcileMissingDownloadedAssets(db: *Db, allocator: std.mem.Allocator) !void {
    const stmt = try db.prepare("SELECT id, local_path, coalesce(byte_size, -1), coalesce(sha256, ''), status FROM media_assets WHERE status IN ('downloaded', 'ok') ORDER BY id");
    defer _ = c.sqlite3_finalize(stmt);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        const id = c.sqlite3_column_int64(stmt, 0);
        const path = try allocator.dupe(u8, colText(stmt, 1));
        defer allocator.free(path);
        const expected_size = c.sqlite3_column_int64(stmt, 2);
        const expected_hash = try allocator.dupe(u8, colText(stmt, 3));
        defer allocator.free(expected_hash);
        if (try assetFileMatches(allocator, path, expected_size, expected_hash)) continue;
        try markMediaAssetFailed(db, allocator, id, "{\"error\":\"local_asset_missing_or_invalid\"}");
        if (!builtin.is_test) try std.fs.File.stderr().deprecatedWriter().print("warning: marked missing/invalid local asset failed id={} path={s}\n", .{ id, path });
    }
}

fn markMediaAssetFailed(db: *Db, allocator: std.mem.Allocator, id: i64, error_json: []const u8) !void {
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const stmt = try db.prepare("UPDATE media_assets SET status='failed', error_json=?, last_checked_at=? WHERE id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, error_json);
    try bindText(stmt, 2, now);
    _ = c.sqlite3_bind_int64(stmt, 3, id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn folderStateAccountedForBookmarkRun(db: *Db, account_user_id: []const u8, run_id: i64) !bool {
    const stmt = try db.prepare(
        \\SELECT 1
        \\FROM sync_runs
        \\WHERE id=? AND account_user_id=? AND status='succeeded'
        \\  AND NOT EXISTS (
        \\    SELECT 1
        \\    FROM sync_warnings
        \\    WHERE sync_run_id=sync_runs.id
        \\      AND warning_type IN ('bookmark_folder_sync_failed', 'bookmark_folder_item_sync_failed')
        \\  )
        \\LIMIT 1
    );
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, run_id);
    try bindText(stmt, 2, account_user_id);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn resetExportDir(allocator: std.mem.Allocator, export_dir: []const u8) !void {
    if (fileExists(export_dir)) {
        try std.fs.cwd().deleteTree(export_dir);
    }
    try std.fs.cwd().makePath(export_dir);
    const data_dir = try std.fs.path.join(allocator, &.{ export_dir, "data" });
    defer allocator.free(data_dir);
    const assets_dir = try std.fs.path.join(allocator, &.{ export_dir, "assets" });
    defer allocator.free(assets_dir);
    const static_dir = try std.fs.path.join(allocator, &.{ export_dir, "static" });
    defer allocator.free(static_dir);
    try std.fs.cwd().makePath(data_dir);
    try std.fs.cwd().makePath(assets_dir);
    try std.fs.cwd().makePath(static_dir);
}

fn copyBuiltViewerIfPresent(allocator: std.mem.Allocator, export_dir: []const u8) !void {
    if (!fileExists("viewer/dist/index.html")) return;
    const index_text = try std.fs.cwd().readFileAlloc(allocator, "viewer/dist/index.html", 1024 * 1024);
    defer allocator.free(index_text);
    const dest_index = try std.fs.path.join(allocator, &.{ export_dir, "index.html" });
    defer allocator.free(dest_index);
    try ensureParentDir(dest_index);
    try std.fs.cwd().copyFile("viewer/dist/index.html", std.fs.cwd(), dest_index, .{});

    var assets = std.fs.cwd().openDir("viewer/dist/assets", .{ .iterate = true }) catch return;
    defer assets.close();
    var iterator = assets.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOf(u8, index_text, entry.name) == null) continue;
        const src_path = try std.fs.path.join(allocator, &.{ "viewer/dist/assets", entry.name });
        defer allocator.free(src_path);
        const dest_path = try std.fs.path.join(allocator, &.{ export_dir, "assets", entry.name });
        defer allocator.free(dest_path);
        try ensureParentDir(dest_path);
        try std.fs.cwd().copyFile(src_path, std.fs.cwd(), dest_path, .{});
    }
}

fn copyDirRecursive(allocator: std.mem.Allocator, src_dir: std.fs.Dir, src_root: []const u8, dest_root: []const u8) !void {
    var iterator = src_dir.iterate();
    while (try iterator.next()) |entry| {
        const src_path = try std.fs.path.join(allocator, &.{ src_root, entry.name });
        defer allocator.free(src_path);
        const dest_path = try std.fs.path.join(allocator, &.{ dest_root, entry.name });
        defer allocator.free(dest_path);
        switch (entry.kind) {
            .file => {
                try ensureParentDir(dest_path);
                try std.fs.cwd().copyFile(src_path, std.fs.cwd(), dest_path, .{});
            },
            .directory => {
                try std.fs.cwd().makePath(dest_path);
                var child = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
                defer child.close();
                try copyDirRecursive(allocator, child, src_path, dest_path);
            },
            else => {},
        }
    }
}

fn writeQueryJsonArray(db: *Db, allocator: std.mem.Allocator, path: []const u8, sql: []const u8, fields: []const []const u8) !void {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.writeAll("[\n");
    const stmt = try db.prepare(sql);
    defer _ = c.sqlite3_finalize(stmt);
    var first = true;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        if (!first) try w.writeAll(",\n");
        first = false;
        try w.writeAll("  {");
        for (fields, 0..) |field_spec, idx| {
            const split = std.mem.indexOfScalar(u8, field_spec, ':');
            const name = if (split) |s| field_spec[0..s] else field_spec;
            const typ = if (split) |s| field_spec[s + 1 ..] else "text";
            if (idx > 0) try w.writeAll(",");
            try w.print("{f}:", .{std.json.fmt(name, .{})});
            if (std.mem.eql(u8, typ, "bool")) {
                try w.print("{}", .{c.sqlite3_column_int(stmt, @intCast(idx)) != 0});
            } else if (std.mem.eql(u8, typ, "int")) {
                try w.print("{}", .{c.sqlite3_column_int64(stmt, @intCast(idx))});
            } else {
                try w.print("{f}", .{std.json.fmt(colText(stmt, @intCast(idx)), .{})});
            }
        }
        try w.writeAll("}");
    }
    try w.writeAll("\n]\n");
    try ensureParentDir(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = out.items });
}

fn writeMediaAssetsJsonAndCopy(db: *Db, allocator: std.mem.Allocator, path: []const u8, export_dir: []const u8) !void {
    const export_assets_dir = try std.fs.path.join(allocator, &.{ export_dir, "assets", "media-assets" });
    defer allocator.free(export_assets_dir);
    try std.fs.cwd().makePath(export_assets_dir);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.writeAll("[\n");
    const stmt = try db.prepare(
        "SELECT id, coalesce(media_key, ''), asset_kind, source_url, local_path, coalesce(content_type, ''), coalesce(byte_size, 0), coalesce(sha256, ''), coalesce(width, 0), coalesce(height, 0), status, coalesce(error_json, '') FROM media_assets ORDER BY id",
    );
    defer _ = c.sqlite3_finalize(stmt);
    var first = true;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        const id = c.sqlite3_column_int64(stmt, 0);
        const local_path = colText(stmt, 4);
        const status = colText(stmt, 10);
        var viewer_path: []const u8 = "";
        if (std.mem.eql(u8, status, "downloaded") and local_path.len > 0) {
            const base = std.fs.path.basename(local_path);
            const rel = try std.fmt.allocPrint(allocator, "assets/media-assets/{}-{s}", .{ id, base });
            defer allocator.free(rel);
            const dest = try std.fs.path.join(allocator, &.{ export_dir, rel });
            defer allocator.free(dest);
            if (try copyValidatedAssetFile(allocator, local_path, dest, c.sqlite3_column_int64(stmt, 6), colText(stmt, 7), false)) {
                viewer_path = try allocator.dupe(u8, rel);
            }
        }
        defer if (viewer_path.len > 0) allocator.free(viewer_path);
        if (!first) try w.writeAll(",\n");
        first = false;
        try w.writeAll("  {");
        try w.print("{f}:{}", .{ std.json.fmt("id", .{}), id });
        try jsonField(w, "media_key", colText(stmt, 1), true);
        try jsonField(w, "asset_kind", colText(stmt, 2), true);
        try jsonField(w, "source_url", colText(stmt, 3), true);
        try jsonField(w, "local_path", local_path, true);
        try jsonField(w, "viewer_path", viewer_path, true);
        try jsonField(w, "content_type", colText(stmt, 5), true);
        try w.print(",{f}:{}", .{ std.json.fmt("byte_size", .{}), c.sqlite3_column_int64(stmt, 6) });
        try jsonField(w, "sha256", colText(stmt, 7), true);
        try w.print(",{f}:{}", .{ std.json.fmt("width", .{}), c.sqlite3_column_int64(stmt, 8) });
        try w.print(",{f}:{}", .{ std.json.fmt("height", .{}), c.sqlite3_column_int64(stmt, 9) });
        try jsonField(w, "status", status, true);
        try jsonField(w, "error_json", colText(stmt, 11), true);
        try w.writeAll("}");
    }
    try w.writeAll("\n]\n");
    try ensureParentDir(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = out.items });
}

fn writeSummaryJson(db: *Db, allocator: std.mem.Allocator, path: []const u8) !void {
    const generated = try timestampString(allocator);
    defer allocator.free(generated);
    const total = try scalarCount(db, "SELECT count(*) FROM bookmark_items WHERE active = 1");
    const new_bookmarks = try scalarCount(db, "SELECT coalesce((SELECT new_bookmarks FROM sync_runs WHERE status = 'succeeded' ORDER BY id DESC LIMIT 1), 0)");
    const complete = try scalarCount(db, "SELECT count(*) FROM bookmark_items WHERE active = 1 AND complete_for_offline_render = 1");
    const failed = try scalarCount(db, "SELECT count(*) FROM media_assets WHERE status = 'failed'");
    const skipped = try scalarCount(db, "SELECT count(*) FROM media_assets WHERE status = 'skipped'");
    const folders = try scalarCount(db, "SELECT count(*) FROM bookmark_folders");
    const quote_posts = try countStoredQuotePosts(db, allocator);
    const sync_warnings = try scalarCount(db, "SELECT count(*) FROM sync_warnings");
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\n  \"generated_at\": \"{s}\",\n  \"total_bookmarks\": {},\n  \"new_bookmarks\": {},\n  \"complete_bookmarks\": {},\n  \"incomplete_bookmarks\": {},\n  \"failed_media_assets\": {},\n  \"skipped_media_assets\": {},\n  \"folders\": {},\n  \"quote_posts\": {},\n  \"sync_warnings\": {}\n}}\n",
        .{ generated, total, new_bookmarks, complete, total - complete, failed, skipped, folders, quote_posts, sync_warnings },
    );
    defer allocator.free(json);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = json });
}

fn countStoredQuotePosts(db: *Db, allocator: std.mem.Allocator) !i64 {
    const stmt = try db.prepare("SELECT raw_json FROM tweets WHERE raw_json LIKE '%\"referenced_tweets\"%' ORDER BY tweet_id");
    defer _ = c.sqlite3_finalize(stmt);
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        seen.deinit();
    }
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, colText(stmt, 0), .{}) catch continue;
        defer parsed.deinit();
        const refs = getArray(parsed.value, "referenced_tweets") orelse continue;
        for (refs.items) |ref| {
            if (ref != .object) continue;
            if (!std.mem.eql(u8, getString(ref, "type") orelse "", "quoted")) continue;
            const quote_id = getString(ref, "id") orelse continue;
            if (!try tweetExists(db, quote_id)) continue;
            if (!seen.contains(quote_id)) try seen.put(try allocator.dupe(u8, quote_id), {});
        }
    }
    return @intCast(seen.count());
}

fn scalarCount(db: *Db, sql: []const u8) !i64 {
    const stmt = try db.prepare(sql);
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return AppError.SqliteError;
    return c.sqlite3_column_int64(stmt, 0);
}

fn resolveObsidianPaths(allocator: std.mem.Allocator, cfg: Config, vault_override: ?[]const u8) !ObsidianPaths {
    const vault_config = vault_override orelse cfg.obsidian_vault_path orelse {
        try std.fs.File.stderr().deprecatedWriter().writeAll("obsidian vault is not configured; run `x-bookmarks obsidian init --vault PATH` or pass `--vault PATH`\n");
        return AppError.ConfigInvalid;
    };
    if (!std.fs.path.isAbsolute(vault_config)) return AppError.ConfigInvalid;
    if (!validManagedRelativePath(cfg.obsidian_root_dir) or !validManagedRelativePath(cfg.obsidian_timeline_dir) or !validManagedRelativePath(cfg.obsidian_note_dir) or !validManagedRelativePath(cfg.obsidian_asset_dir) or !validManagedRelativePath(cfg.obsidian_index_dir) or !validManagedRelativePath(cfg.obsidian_data_dir)) return AppError.ConfigInvalid;
    const vault = try allocator.dupe(u8, vault_config);
    const root = try std.fs.path.join(allocator, &.{ vault, cfg.obsidian_root_dir });
    const notes = try std.fs.path.join(allocator, &.{ root, cfg.obsidian_note_dir });
    const assets = try std.fs.path.join(allocator, &.{ root, cfg.obsidian_asset_dir });
    const images = try std.fs.path.join(allocator, &.{ assets, "images" });
    const previews = try std.fs.path.join(allocator, &.{ assets, "previews" });
    const avatars = try std.fs.path.join(allocator, &.{ assets, "avatars" });
    const indexes = try std.fs.path.join(allocator, &.{ root, cfg.obsidian_index_dir });
    const timeline = try std.fs.path.join(allocator, &.{ root, cfg.obsidian_timeline_dir });
    const data = try std.fs.path.join(allocator, &.{ root, cfg.obsidian_data_dir });
    return .{ .vault = vault, .root = root, .notes = notes, .assets = assets, .images = images, .previews = previews, .avatars = avatars, .indexes = indexes, .timeline = timeline, .data = data };
}

fn makeObsidianTimelineDirs(paths: ObsidianPaths) !void {
    try std.fs.cwd().makePath(paths.indexes);
    try std.fs.cwd().makePath(paths.timeline);
    try std.fs.cwd().makePath(paths.data);
}

fn makeObsidianFullDirs(paths: ObsidianPaths) !void {
    try makeObsidianTimelineDirs(paths);
    try std.fs.cwd().makePath(paths.notes);
    try std.fs.cwd().makePath(paths.images);
    try std.fs.cwd().makePath(paths.previews);
    try std.fs.cwd().makePath(paths.avatars);
}

const KbExportStats = struct {
    total: u32 = 0,
    written: u32 = 0,
    skipped_unchanged: u32 = 0,
    skipped_processed: u32 = 0,
};

const kbSchemaStarter =
    \\# Wiki Schema
    \\
    \\This knowledge base follows the LLM Wiki pattern: raw sources are immutable inputs, and the wiki is the compiled Markdown artifact maintained by an agent.
    \\
    \\## Directory Contract
    \\
    \\- `raw/x/inbox/`: bookmarked X posts waiting for ingestion.
    \\- `raw/x/ingested/`: raw X posts already incorporated into the wiki.
    \\- `raw/x/ignored/`: raw X posts reviewed and intentionally skipped.
    \\- `raw/web/`, `raw/papers/`, `raw/repos/`, `raw/images/`: follow-up sources collected outside the bookmark API.
    \\- `wiki/`: agent-maintained pages, indexes, logs, syntheses, and outputs.
    \\
    \\Raw files should not be rewritten for synthesis. The only acceptable raw-source mutation during ingestion is status/move bookkeeping.
    \\
    \\## Page Types
    \\
    \\Use these wiki page families:
    \\
    \\- `concepts/`: durable ideas, patterns, techniques, and claims.
    \\- `people/`: authors, researchers, builders, and recurring experts.
    \\- `projects/`: products, repos, apps, and named projects.
    \\- `tools/`: specific tools or technical utilities.
    \\- `papers/`: papers and formal source documents.
    \\- `companies/`: organizations and labs.
    \\- `questions/`: unresolved questions worth revisiting.
    \\- `syntheses/`: compiled answers or essays that should persist.
    \\- `outputs/`: health checks, query outputs, and temporary reports.
    \\
    \\## Frontmatter
    \\
    \\Every wiki page should start with frontmatter:
    \\
    \\```yaml
    \\---
    \\type: concept
    \\status: active
    \\created: 2026-05-11
    \\updated: 2026-05-11
    \\source_count: 1
    \\tags: []
    \\---
    \\```
    \\
    \\Valid `type` values are `concept`, `person`, `project`, `tool`, `paper`, `company`, `question`, `synthesis`, and `output`.
    \\
    \\## Citation Style
    \\
    \\Every factual claim should cite raw files or related wiki pages. Prefer Obsidian links:
    \\
    \\```markdown
    \\This pattern treats the wiki as a compiled artifact rather than a retrieval index. Sources: [[../raw/x/ingested/2052423637500571963]], [[concepts/llm-agent-memory]].
    \\```
    \\
    \\When citing a raw X bookmark before moving it, link to `../raw/x/inbox/<tweet_id>`. After processing, move the raw file to `../raw/x/ingested/<tweet_id>` or `../raw/x/ignored/<tweet_id>` and update citations if needed.
    \\
    \\## Ingestion Workflow
    \\
    \\1. Read this schema.
    \\2. Read `wiki/index.md` to understand existing pages.
    \\3. Select files from `raw/x/inbox/`.
    \\4. For each raw bookmark, determine the core subject and search the wiki for related pages.
    \\5. Decide whether to create a page, update a page, add evidence, record a contradiction/caveat, request follow-up source collection, or ignore the source.
    \\6. Update relevant wiki pages with citations and backlinks.
    \\7. Update `wiki/index.md`.
    \\8. Append a structured entry to `wiki/log.md`.
    \\9. Move each processed raw X file to `raw/x/ingested/` or `raw/x/ignored/`.
    \\
    \\Prefer updating existing pages over creating duplicates. A high-signal source may touch many pages; a low-signal source may be ignored with a short reason in the log.
    \\
    \\## Page Structure
    \\
    \\Use this default shape for concept/entity pages:
    \\
    \\```markdown
    \\# Page Title
    \\
    \\## Summary
    \\
    \\One or two paragraphs that state the durable idea.
    \\
    \\## Notes
    \\
    \\- Specific claims, each with citations.
    \\
    \\## Examples / Evidence
    \\
    \\- Bookmark, article, paper, or repo evidence with links.
    \\
    \\## Contradictions / Caveats
    \\
    \\- Conflicting evidence, stale assumptions, or uncertainty.
    \\
    \\## Related
    \\
    \\- [[other-page]]
    \\```
    \\
    \\## Ingestion Example
    \\
    \\Before:
    \\
    \\- Raw source: `raw/x/inbox/2052423637500571963.md`
    \\- The post describes agent memory and links to a fuller article.
    \\
    \\After:
    \\
    \\- Update `wiki/concepts/llm-agent-memory.md` with the new claim and a citation to `[[../raw/x/ingested/2052423637500571963]]`.
    \\- Create `wiki/questions/how-should-agent-memory-handle-stale-claims.md` if the source raises an unresolved issue.
    \\- Add both pages to `wiki/index.md`.
    \\- Append an ingest entry to `wiki/log.md`.
    \\- Move the raw source from `raw/x/inbox/` to `raw/x/ingested/`.
    \\
    \\## Index Rules
    \\
    \\Update `wiki/index.md` on every ingest. Include page path, one-line summary, page type, source count, and last updated date.
    \\
    \\## Log Rules
    \\
    \\Append to `wiki/log.md` on every ingest, query, or lint pass. Use stable headings:
    \\
    \\```markdown
    \\## [2026-05-11] ingest | X bookmark 2052423637500571963
    \\
    \\- Raw source: [[../raw/x/ingested/2052423637500571963]]
    \\- Updated: [[concepts/llm-agent-memory]]
    \\- Created: [[questions/how-should-agent-maintained-wikis-handle-contradictions]]
    \\- Notes: Added distinction between RAG retrieval and compiled persistent wiki.
    \\```
    \\
    \\## Query Workflow
    \\
    \\Answer from the compiled wiki first. Read raw sources only when citations need verification or the wiki is thin. If the answer is worth preserving, write it to `wiki/syntheses/` or `wiki/outputs/`, update the index, and append the log.
    \\
    \\## Lint Workflow
    \\
    \\Health checks should look for duplicate pages, missing citations, orphan pages, stale claims, contradictions, raw inbox backlog, and high-signal sources that received shallow treatment. Write reports to `wiki/outputs/wiki-health-YYYY-MM-DD.md` and append the log.
    \\
;

const kbIndexStarter =
    \\# Wiki Index
    \\
    \\This is the navigation catalog for the agent and user. Update it on every ingest.
    \\
    \\## Concepts
    \\
    \\## People
    \\
    \\## Projects
    \\
    \\## Tools
    \\
    \\## Papers
    \\
    \\## Companies
    \\
    \\## Open Questions
    \\
    \\## Syntheses
    \\
;

const kbLogStarter =
    \\# Wiki Log
    \\
    \\Append-only chronological record of ingestion, query, and lint passes.
    \\
;

fn kbInit(allocator: std.mem.Allocator, paths: ObsidianPaths) !void {
    try makeKbDirs(allocator, paths);

    const schema_path = try std.fs.path.join(allocator, &.{ paths.root, "wiki", "schema.md" });
    defer allocator.free(schema_path);
    const index_path = try std.fs.path.join(allocator, &.{ paths.root, "wiki", "index.md" });
    defer allocator.free(index_path);
    const log_path = try std.fs.path.join(allocator, &.{ paths.root, "wiki", "log.md" });
    defer allocator.free(log_path);

    try writeFileIfMissing(schema_path, kbSchemaStarter);
    try writeFileIfMissing(index_path, kbIndexStarter);
    try writeFileIfMissing(log_path, kbLogStarter);
    if (!builtin.is_test) try std.fs.File.stdout().deprecatedWriter().print("initialized knowledge base: {s}\n", .{paths.root});
}

fn makeKbDirs(allocator: std.mem.Allocator, paths: ObsidianPaths) !void {
    const dirs = [_][]const u8{
        "raw/x/inbox",
        "raw/x/ingested",
        "raw/x/ignored",
        "raw/web",
        "raw/papers",
        "raw/repos",
        "raw/images",
        "wiki/concepts",
        "wiki/people",
        "wiki/projects",
        "wiki/tools",
        "wiki/papers",
        "wiki/companies",
        "wiki/questions",
        "wiki/syntheses",
        "wiki/outputs",
    };
    for (dirs) |dir| {
        const path = try std.fs.path.join(allocator, &.{ paths.root, dir });
        defer allocator.free(path);
        try std.fs.cwd().makePath(path);
    }
}

fn writeFileIfMissing(path: []const u8, data: []const u8) !void {
    if (fileExists(path)) return;
    try ensureParentDir(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
}

fn kbStatus(db: *Db, allocator: std.mem.Allocator, paths: ObsidianPaths) !void {
    const inbox = try std.fs.path.join(allocator, &.{ paths.root, "raw", "x", "inbox" });
    defer allocator.free(inbox);
    const ingested = try std.fs.path.join(allocator, &.{ paths.root, "raw", "x", "ingested" });
    defer allocator.free(ingested);
    const ignored = try std.fs.path.join(allocator, &.{ paths.root, "raw", "x", "ignored" });
    defer allocator.free(ignored);
    const wiki = try std.fs.path.join(allocator, &.{ paths.root, "wiki" });
    defer allocator.free(wiki);
    const out = std.fs.File.stdout().deprecatedWriter();
    try out.print("kb root: {s}\n", .{paths.root});
    try out.print("active bookmarks: {}\n", .{try scalarCount(db, "SELECT count(*) FROM bookmark_items WHERE active = 1")});
    try out.print("raw x inbox: {}\n", .{try countFilesWithSuffix(allocator, inbox, ".md")});
    try out.print("raw x ingested: {}\n", .{try countFilesWithSuffix(allocator, ingested, ".md")});
    try out.print("raw x ignored: {}\n", .{try countFilesWithSuffix(allocator, ignored, ".md")});
    try out.print("wiki pages: {}\n", .{try countMarkdownFilesRecursive(allocator, wiki)});
}

fn countMarkdownFilesRecursive(allocator: std.mem.Allocator, root: []const u8) !i64 {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return 0;
    defer dir.close();
    var it = dir.iterate();
    var count: i64 = 0;
    while (try it.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
            count += 1;
        } else if (entry.kind == .directory) {
            const child = try std.fs.path.join(allocator, &.{ root, entry.name });
            defer allocator.free(child);
            count += try countMarkdownFilesRecursive(allocator, child);
        }
    }
    return count;
}

fn kbExportRawX(db: *Db, allocator: std.mem.Allocator, paths: ObsidianPaths, changed_only: bool) !KbExportStats {
    try makeKbDirs(allocator, paths);
    var stats = KbExportStats{};
    const stmt = try db.prepare(
        \\SELECT b.tweet_id, coalesce(t.canonical_uri, ''), coalesce(t.twitter_uri, ''), coalesce(t.text, ''),
        \\       coalesce(t.created_at, ''), coalesce(t.author_id, ''), coalesce(u.username, ''), coalesce(u.name, ''),
        \\       b.first_seen_at, t.raw_json
        \\FROM bookmark_items b
        \\JOIN tweets t ON t.tweet_id = b.tweet_id
        \\LEFT JOIN users u ON u.user_id = t.author_id
        \\WHERE b.active = 1
        \\ORDER BY b.import_position IS NULL, b.import_position, b.last_seen_at DESC, b.tweet_id DESC
    );
    defer _ = c.sqlite3_finalize(stmt);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        stats.total += 1;
        const tweet_id = colText(stmt, 0);
        const processed_target = try kbRawXProcessedTarget(allocator, paths, tweet_id);
        defer if (processed_target) |target| target.deinit(allocator);
        const raw_status = if (processed_target) |target| target.status else "inbox";
        var inbox_path: ?[]const u8 = null;
        defer if (inbox_path) |p| allocator.free(p);
        const path = if (processed_target) |target| target.path else blk: {
            const filename = try std.fmt.allocPrint(allocator, "{s}.md", .{tweet_id});
            defer allocator.free(filename);
            inbox_path = try std.fs.path.join(allocator, &.{ paths.root, "raw", "x", "inbox", filename });
            break :blk inbox_path.?;
        };
        const data = try buildRawXBookmarkMarkdown(
            db,
            allocator,
            tweet_id,
            colText(stmt, 1),
            colText(stmt, 2),
            colText(stmt, 3),
            colText(stmt, 4),
            colText(stmt, 5),
            colText(stmt, 6),
            colText(stmt, 7),
            colText(stmt, 8),
            raw_status,
            colText(stmt, 9),
        );
        defer allocator.free(data);
        if (try writeKbRawFile(allocator, path, data, changed_only)) {
            stats.written += 1;
        } else if (processed_target != null) {
            stats.skipped_processed += 1;
        } else {
            stats.skipped_unchanged += 1;
        }
    }
    return stats;
}

const KbRawXProcessedTarget = struct {
    path: []const u8,
    status: []const u8,

    fn deinit(self: KbRawXProcessedTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

fn kbRawXProcessedTarget(allocator: std.mem.Allocator, paths: ObsidianPaths, tweet_id: []const u8) !?KbRawXProcessedTarget {
    const filename = try std.fmt.allocPrint(allocator, "{s}.md", .{tweet_id});
    defer allocator.free(filename);
    const ingested = try std.fs.path.join(allocator, &.{ paths.root, "raw", "x", "ingested", filename });
    if (fileExists(ingested)) return .{ .path = ingested, .status = "ingested" };
    allocator.free(ingested);
    const ignored = try std.fs.path.join(allocator, &.{ paths.root, "raw", "x", "ignored", filename });
    if (fileExists(ignored)) return .{ .path = ignored, .status = "ignored" };
    allocator.free(ignored);
    return null;
}

fn writeKbRawFile(allocator: std.mem.Allocator, path: []const u8, data: []const u8, changed_only: bool) !bool {
    if (changed_only and fileExists(path)) {
        const existing = try std.fs.cwd().readFileAlloc(allocator, path, 8 * 1024 * 1024);
        defer allocator.free(existing);
        if (std.mem.eql(u8, existing, data)) return false;
    }
    try ensureParentDir(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
    return true;
}

fn buildRawXBookmarkMarkdown(
    db: *Db,
    allocator: std.mem.Allocator,
    tweet_id: []const u8,
    canonical_uri: []const u8,
    twitter_uri: []const u8,
    stored_text: []const u8,
    created_at: []const u8,
    author_id: []const u8,
    username: []const u8,
    author_name: []const u8,
    bookmarked_at: []const u8,
    raw_status: []const u8,
    raw_json: []const u8,
) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch null;
    defer if (parsed) |*p| p.deinit();
    const root = if (parsed) |p| p.value else null;
    const post_text = rawXPostText(root, stored_text);
    const thread_info = try loadThreadExportInfo(db, allocator, tweet_id, root);
    defer thread_info.deinit(allocator);
    var urls = std.StringHashMap(void).init(allocator);
    defer {
        var it = urls.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        urls.deinit();
    }
    if (root) |value| try collectTweetUrls(allocator, value, &urls);

    var out = std.ArrayList(u8).empty;
    const w = out.writer(allocator);
    try w.writeAll("---\n");
    try yamlString(w, "source_type", "x_bookmark");
    try yamlString(w, "tweet_id", tweet_id);
    try yamlString(w, "canonical_url", canonical_uri);
    try yamlString(w, "twitter_url", twitter_uri);
    try yamlString(w, "author_username", username);
    try yamlString(w, "author_name", author_name);
    try yamlString(w, "author_id", author_id);
    try yamlString(w, "created_at", created_at);
    try yamlString(w, "bookmarked_at", bookmarked_at);
    try yamlStringArrayForQuery(db, allocator, w, "folders", "SELECT coalesce(f.name, bfi.folder_id) FROM bookmark_folder_items bfi LEFT JOIN bookmark_folders f ON f.account_user_id=bfi.account_user_id AND f.folder_id=bfi.folder_id WHERE bfi.tweet_id=? ORDER BY f.name, bfi.folder_id", tweet_id);
    try w.print("thread_candidate: {}\n", .{thread_info.candidate});
    if (thread_info.candidate) {
        try yamlString(w, "thread_expansion_status", thread_info.status);
        if (thread_info.post_count > 0) try w.print("thread_post_count: {}\n", .{thread_info.post_count});
        if (thread_info.method.len > 0) try yamlString(w, "thread_expansion_method", thread_info.method);
        if (thread_info.confidence.len > 0) try yamlString(w, "thread_expansion_confidence", thread_info.confidence);
    }
    try yamlString(w, "status", raw_status);
    try w.writeAll("---\n\n");
    try w.print("# X Bookmark: @{s} / {s}\n\n", .{ if (username.len > 0) username else "unknown", tweet_id });
    try w.writeAll("## Post\n\n");
    try w.print("![]({s})\n\n", .{canonical_uri});
    try writeSourceTextSection(db, allocator, w, tweet_id, post_text, thread_info);
    try writeRawWhyThisMayMatter(db, allocator, w, tweet_id, author_id, root, &urls);
    try writeRawLinksSection(w, canonical_uri, twitter_uri, &urls);
    try writeRawQuotePostSection(db, allocator, w, root);
    try writeRawMediaSection(db, w, tweet_id);
    try writeRawThreadContext(db, allocator, w, tweet_id, thread_info);
    try w.writeAll("## Raw Metadata\n\n```json\n");
    try w.writeAll(raw_json);
    try w.writeAll("\n```\n");
    return out.toOwnedSlice(allocator);
}

fn rawXPostText(root: ?std.json.Value, fallback: []const u8) []const u8 {
    if (root) |value| {
        if (getObject(value, "note_tweet")) |note| {
            if (getString(note, "text")) |text| return text;
        }
        if (getString(value, "text")) |text| return text;
    }
    return fallback;
}

fn writeSourceTextSection(db: *Db, allocator: std.mem.Allocator, writer: anytype, tweet_id: []const u8, fallback_text: []const u8, info: ThreadExportInfo) !void {
    try writer.writeAll("## Source Text\n\n");
    if (info.candidate and (std.mem.eql(u8, info.status, "complete") or std.mem.eql(u8, info.status, "partial"))) {
        if (try writeThreadSourceTextPosts(db, allocator, writer, tweet_id)) return;
    }
    if (fallback_text.len > 0) {
        try writer.writeAll(fallback_text);
        try writer.writeAll("\n\n");
    } else {
        try writer.writeAll("_No post text stored._\n\n");
    }
}

fn writeThreadSourceTextPosts(db: *Db, allocator: std.mem.Allocator, writer: anytype, tweet_id: []const u8) !bool {
    const stmt = try db.prepare(
        \\SELECT tp.position, coalesce(t.text, ''), t.raw_json
        \\FROM thread_posts tp
        \\JOIN tweets t ON t.tweet_id = tp.tweet_id
        \\WHERE tp.root_tweet_id = ?
        \\ORDER BY tp.position
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    var wrote = false;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        wrote = true;
        try writer.print("### Post {}\n\n", .{c.sqlite3_column_int64(stmt, 0)});
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, colText(stmt, 2), .{}) catch null;
        defer if (parsed) |*p| p.deinit();
        const text = rawXPostText(if (parsed) |p| p.value else null, colText(stmt, 1));
        if (text.len > 0) {
            try writer.writeAll(text);
            try writer.writeAll("\n\n");
        } else {
            try writer.writeAll("_No post text stored._\n\n");
        }
    }
    return wrote;
}

const ThreadExportInfo = struct {
    candidate: bool,
    status: []const u8,
    reason_json: []const u8,
    method: []const u8,
    confidence: []const u8,
    post_count: i64,
    estimated_cost_micros: i64,
    query: []const u8,

    fn deinit(self: ThreadExportInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.status);
        allocator.free(self.reason_json);
        allocator.free(self.method);
        allocator.free(self.confidence);
        allocator.free(self.query);
    }
};

fn loadThreadExportInfo(db: *Db, allocator: std.mem.Allocator, tweet_id: []const u8, root: ?std.json.Value) !ThreadExportInfo {
    var candidate = false;
    var status: []const u8 = try allocator.dupe(u8, "");
    var reason_json: []const u8 = try allocator.dupe(u8, "");
    var method: []const u8 = try allocator.dupe(u8, "");
    var confidence: []const u8 = try allocator.dupe(u8, "");
    var query: []const u8 = try allocator.dupe(u8, "");
    var post_count: i64 = 0;
    var estimated_cost_micros: i64 = 0;

    const cstmt = try db.prepare("SELECT reason_json, status FROM thread_candidates WHERE tweet_id=?");
    defer _ = c.sqlite3_finalize(cstmt);
    try bindText(cstmt, 1, tweet_id);
    if (c.sqlite3_step(cstmt) == c.SQLITE_ROW) {
        candidate = true;
        allocator.free(reason_json);
        reason_json = try allocator.dupe(u8, colText(cstmt, 0));
        allocator.free(status);
        status = try allocator.dupe(u8, colText(cstmt, 1));
    } else if (root) |value| {
        if (try threadDetectionReasonsJson(allocator, value)) |detected| {
            candidate = true;
            allocator.free(reason_json);
            reason_json = detected;
            allocator.free(status);
            status = try allocator.dupe(u8, "missing");
        }
    }

    const estmt = try db.prepare("SELECT status, coalesce(method, ''), coalesce(confidence, ''), post_count, coalesce(estimated_cost_micros, 0), coalesce(query, '') FROM thread_expansions WHERE root_tweet_id=?");
    defer _ = c.sqlite3_finalize(estmt);
    try bindText(estmt, 1, tweet_id);
    if (c.sqlite3_step(estmt) == c.SQLITE_ROW) {
        candidate = true;
        allocator.free(status);
        status = try allocator.dupe(u8, colText(estmt, 0));
        allocator.free(method);
        method = try allocator.dupe(u8, colText(estmt, 1));
        allocator.free(confidence);
        confidence = try allocator.dupe(u8, colText(estmt, 2));
        post_count = c.sqlite3_column_int64(estmt, 3);
        estimated_cost_micros = c.sqlite3_column_int64(estmt, 4);
        allocator.free(query);
        query = try allocator.dupe(u8, colText(estmt, 5));
    }

    if (candidate and status.len == 0) {
        allocator.free(status);
        status = try allocator.dupe(u8, "missing");
    }
    return .{
        .candidate = candidate,
        .status = status,
        .reason_json = reason_json,
        .method = method,
        .confidence = confidence,
        .post_count = post_count,
        .estimated_cost_micros = estimated_cost_micros,
        .query = query,
    };
}

fn writeRawThreadContext(db: *Db, allocator: std.mem.Allocator, writer: anytype, tweet_id: []const u8, info: ThreadExportInfo) !void {
    if (!info.candidate) return;
    try writer.writeAll("## Thread Context\n\n");
    try writer.writeAll("- Thread candidate: yes\n");
    try writer.print("- Expansion status: {s}\n", .{info.status});
    if (info.reason_json.len > 0) try writer.print("- Detection reason: `{s}`\n", .{info.reason_json});
    if (info.method.len > 0) try writer.print("- Method: {s}\n", .{info.method});
    if (info.confidence.len > 0) try writer.print("- Confidence: {s}\n", .{info.confidence});
    if (info.post_count > 0) try writer.print("- Posts: {}\n", .{info.post_count});
    if (info.estimated_cost_micros > 0) try writer.print("- Estimated X API cost: ${d:.3}\n", .{@as(f64, @floatFromInt(info.estimated_cost_micros)) / 1_000_000.0});
    if (std.mem.eql(u8, info.status, "missing")) {
        try writer.print("- Suggested command: `x-bookmarks threads expand --tweet-id {s} --dry-run`\n\n", .{tweet_id});
        return;
    }
    try writer.writeAll("\n");
    const stmt = try db.prepare(
        \\SELECT tp.position, t.tweet_id, coalesce(t.canonical_uri, ''), coalesce(u.username, ''), coalesce(t.created_at, ''), coalesce(t.text, ''), t.raw_json
        \\FROM thread_posts tp
        \\JOIN tweets t ON t.tweet_id = tp.tweet_id
        \\LEFT JOIN users u ON u.user_id = t.author_id
        \\WHERE tp.root_tweet_id = ?
        \\ORDER BY tp.position
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        try writer.print("### Thread Post {}\n\n", .{c.sqlite3_column_int64(stmt, 0)});
        try writer.print("![]({s})\n\n", .{colText(stmt, 2)});
        try writer.print("- Author: @{s}\n- Created: {s}\n- Tweet ID: {s}\n\n", .{ colText(stmt, 3), colText(stmt, 4), colText(stmt, 1) });
        const raw = colText(stmt, 6);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch null;
        defer if (parsed) |*p| p.deinit();
        const text = rawXPostText(if (parsed) |p| p.value else null, colText(stmt, 5));
        try writeMarkdownEscaped(writer, text);
        try writer.writeAll("\n\n");
        try writeThreadPostMediaRefs(db, writer, colText(stmt, 1));
    }
}

fn writeThreadPostMediaRefs(db: *Db, writer: anytype, tweet_id: []const u8) !void {
    const stmt = try db.prepare("SELECT media_key FROM tweet_media WHERE tweet_id=? ORDER BY position");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    var first = true;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        if (first) {
            try writer.writeAll("Media:\n");
            first = false;
        }
        try writer.print("- {s}\n", .{colText(stmt, 0)});
    }
    if (!first) try writer.writeAll("\n");
}

fn writeObsidianThreadSummary(db: *Db, allocator: std.mem.Allocator, writer: anytype, tweet_id: []const u8, info: ThreadExportInfo) !void {
    if (!info.candidate or !(std.mem.eql(u8, info.status, "complete") or std.mem.eql(u8, info.status, "partial"))) return;
    try writer.print("## Thread\n\nExpansion: {s}, {} posts", .{ info.status, info.post_count });
    if (info.confidence.len > 0) try writer.print(", {s} confidence", .{info.confidence});
    try writer.writeAll(".\n\n");
    const stmt = try db.prepare(
        \\SELECT tp.position, coalesce(t.text, ''), t.raw_json
        \\FROM thread_posts tp
        \\JOIN tweets t ON t.tweet_id = tp.tweet_id
        \\WHERE tp.root_tweet_id = ?
        \\ORDER BY tp.position
        \\LIMIT 12
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, colText(stmt, 2), .{}) catch null;
        defer if (parsed) |*p| p.deinit();
        const text = rawXPostText(if (parsed) |p| p.value else null, colText(stmt, 1));
        try writer.print("{}. ", .{c.sqlite3_column_int64(stmt, 0)});
        try writeMarkdownEscaped(writer, shortText(text));
        try writer.writeAll("\n");
    }
    try writer.writeAll("\n");
}

fn collectTweetUrls(allocator: std.mem.Allocator, tweet: std.json.Value, urls: *std.StringHashMap(void)) !void {
    if (getObject(tweet, "entities")) |entities| try collectUrlsFromEntities(allocator, entities, urls);
    if (getObject(tweet, "note_tweet")) |note| {
        if (getObject(note, "entities")) |entities| try collectUrlsFromEntities(allocator, entities, urls);
    }
}

fn collectUrlsFromEntities(allocator: std.mem.Allocator, entities: std.json.Value, urls: *std.StringHashMap(void)) !void {
    const arr = getArray(entities, "urls") orelse return;
    for (arr.items) |item| {
        if (item != .object) continue;
        const url = getString(item, "unwound_url") orelse getString(item, "expanded_url") orelse getString(item, "url") orelse continue;
        if (url.len == 0 or urls.contains(url)) continue;
        try urls.put(try allocator.dupe(u8, url), {});
    }
}

fn writeRawWhyThisMayMatter(db: *Db, allocator: std.mem.Allocator, writer: anytype, tweet_id: []const u8, author_id: []const u8, root: ?std.json.Value, urls: *std.StringHashMap(void)) !void {
    try writer.writeAll("## Why This May Matter\n\n");
    var wrote = false;
    if (urls.count() > 0) {
        try writer.writeAll("- Has external link(s).\n");
        wrote = true;
    }
    if (rawTweetHasQuote(root)) {
        try writer.writeAll("- Quote-post present.\n");
        wrote = true;
    }
    if (try tweetHasMedia(db, tweet_id)) {
        try writer.writeAll("- Media present.\n");
        wrote = true;
    }
    if (try tweetHasFolders(db, tweet_id)) {
        try writer.writeAll("- Foldered bookmark.\n");
        wrote = true;
    }
    const author_count = try authorBookmarkCount(db, allocator, author_id);
    if (author_count > 1) {
        try writer.print("- Repeated author in bookmark corpus: {} active bookmarks.\n", .{author_count});
        wrote = true;
    }
    if (!wrote) try writer.writeAll("- No deterministic hints beyond being bookmarked.\n");
    try writer.writeAll("\n");
}

fn rawTweetHasQuote(root: ?std.json.Value) bool {
    const value = root orelse return false;
    const refs = getArray(value, "referenced_tweets") orelse return false;
    for (refs.items) |ref| {
        if (ref == .object and std.mem.eql(u8, getString(ref, "type") orelse "", "quoted")) return true;
    }
    return false;
}

fn tweetHasMedia(db: *Db, tweet_id: []const u8) !bool {
    const stmt = try db.prepare("SELECT 1 FROM tweet_media WHERE tweet_id=? LIMIT 1");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn tweetHasFolders(db: *Db, tweet_id: []const u8) !bool {
    const stmt = try db.prepare("SELECT 1 FROM bookmark_folder_items WHERE tweet_id=? LIMIT 1");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn authorBookmarkCount(db: *Db, allocator: std.mem.Allocator, author_id: []const u8) !i64 {
    _ = allocator;
    if (author_id.len == 0) return 0;
    const stmt = try db.prepare(
        \\SELECT count(*)
        \\FROM bookmark_items b
        \\JOIN tweets t ON t.tweet_id = b.tweet_id
        \\WHERE b.active = 1 AND t.author_id = ?
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, author_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return AppError.SqliteError;
    return c.sqlite3_column_int64(stmt, 0);
}

fn writeRawLinksSection(writer: anytype, canonical_uri: []const u8, twitter_uri: []const u8, urls: *std.StringHashMap(void)) !void {
    try writer.writeAll("## Links\n\n");
    try writer.print("- X: {s}\n", .{canonical_uri});
    try writer.print("- Twitter: {s}\n", .{twitter_uri});
    var it = urls.keyIterator();
    while (it.next()) |url| try writer.print("- Extracted URL: {s}\n", .{url.*});
    try writer.writeAll("\n");
}

fn writeRawQuotePostSection(db: *Db, allocator: std.mem.Allocator, writer: anytype, root: ?std.json.Value) !void {
    if (!rawTweetHasQuote(root)) return;
    try writer.writeAll("## Quote Post\n\n");
    const value = root.?;
    const refs = getArray(value, "referenced_tweets") orelse return;
    for (refs.items) |ref| {
        if (ref != .object or !std.mem.eql(u8, getString(ref, "type") orelse "", "quoted")) continue;
        const quote_id = getString(ref, "id") orelse continue;
        const stmt = try db.prepare(
            \\SELECT coalesce(t.text, ''), coalesce(t.canonical_uri, ''), coalesce(u.username, '')
            \\FROM tweets t
            \\LEFT JOIN users u ON u.user_id = t.author_id
            \\WHERE t.tweet_id = ?
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, quote_id);
        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try writer.print("- Quoted @{s}: ", .{if (colText(stmt, 2).len > 0) colText(stmt, 2) else "unknown"});
            try writeMarkdownEscaped(writer, colText(stmt, 0));
            try writer.print("\n- URL: {s}\n\n", .{colText(stmt, 1)});
        } else {
            const uri = try canonicalUri(allocator, null, quote_id);
            defer allocator.free(uri);
            try writer.print("- Quoted post not locally available: {s}\n\n", .{uri});
        }
    }
}

fn writeRawMediaSection(db: *Db, writer: anytype, tweet_id: []const u8) !void {
    const stmt = try db.prepare(
        \\SELECT tm.media_key, coalesce(m.type, ''), coalesce(m.url, ''), coalesce(m.preview_image_url, ''),
        \\       coalesce(ma.asset_kind, ''), coalesce(ma.status, ''), coalesce(ma.local_path, '')
        \\FROM tweet_media tm
        \\LEFT JOIN media m ON m.media_key = tm.media_key
        \\LEFT JOIN media_assets ma ON ma.media_key = tm.media_key
        \\WHERE tm.tweet_id = ?
        \\ORDER BY tm.position, ma.id
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    var wrote_heading = false;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        if (!wrote_heading) {
            try writer.writeAll("## Media\n\n");
            wrote_heading = true;
        }
        try writer.print("- {s} ({s})", .{ colText(stmt, 0), if (colText(stmt, 1).len > 0) colText(stmt, 1) else "unknown" });
        if (colText(stmt, 6).len > 0) {
            try writer.print(": `{s}` ({s}, {s})", .{ colText(stmt, 6), colText(stmt, 4), colText(stmt, 5) });
        } else if (colText(stmt, 2).len > 0) {
            try writer.print(": {s}", .{colText(stmt, 2)});
        } else if (colText(stmt, 3).len > 0) {
            try writer.print(": {s}", .{colText(stmt, 3)});
        }
        try writer.writeAll("\n");
    }
    if (wrote_heading) try writer.writeAll("\n");
}

fn obsidianStatus(db: *Db, allocator: std.mem.Allocator, cfg: Config, vault_override: ?[]const u8) !void {
    var paths = try resolveObsidianPaths(allocator, cfg, vault_override);
    defer paths.deinit(allocator);
    const note_count = if (fileExists(paths.notes)) try countFilesWithSuffix(allocator, paths.notes, ".md") else 0;
    const active = try scalarCount(db, "SELECT count(*) FROM bookmark_items WHERE active = 1");
    const failed = try scalarCount(db, "SELECT count(*) FROM media_assets WHERE status = 'failed'");
    const stale = if (fileExists(paths.notes)) try countStaleObsidianNotes(db, allocator, paths.notes) else 0;
    const out = std.fs.File.stdout().deprecatedWriter();
    try out.print("vault: {s}\nmanaged root: {s}\nexport mode: {s}\nnotes dir: {s}\nassets dir: {s}\nindexes dir: {s}\ntimeline dir: {s}\ndata dir: {s}\nmedia policy: {s}\nactive bookmarks: {}\nexported notes: {}\nfailed media assets: {}\nstale notes: {}\n", .{
        paths.vault,
        paths.root,
        cfg.obsidian_export_mode.label(),
        paths.notes,
        paths.assets,
        paths.indexes,
        paths.timeline,
        paths.data,
        cfg.media_policy,
        active,
        note_count,
        failed,
        stale,
    });
}

fn countFilesWithSuffix(allocator: std.mem.Allocator, dir_path: []const u8, suffix: []const u8) !i64 {
    _ = allocator;
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close();
    var it = dir.iterate();
    var count: i64 = 0;
    while (try it.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, suffix)) count += 1;
    }
    return count;
}

fn countStaleObsidianNotes(db: *Db, allocator: std.mem.Allocator, notes_dir: []const u8) !i64 {
    var dir = std.fs.cwd().openDir(notes_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();
    var it = dir.iterate();
    var count: i64 = 0;
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        const id = entry.name[0 .. entry.name.len - ".md".len];
        if (!try activeBookmarkExists(db, allocator, id)) count += 1;
    }
    return count;
}

fn activeBookmarkExists(db: *Db, allocator: std.mem.Allocator, tweet_id: []const u8) !bool {
    _ = allocator;
    const stmt = try db.prepare("SELECT 1 FROM bookmark_items WHERE tweet_id=? AND active=1 LIMIT 1");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

const TimelineWriteStats = struct {
    months_total: u32 = 0,
    months_written: u32 = 0,
    months_skipped: u32 = 0,
    index_written: bool = false,
    index_skipped: bool = false,
    summary_written: bool = false,
    summary_skipped: bool = false,
};

fn obsidianExport(db: *Db, allocator: std.mem.Allocator, cfg: Config, opts: ObsidianExportOptions) !void {
    const mode = opts.mode_override orelse cfg.obsidian_export_mode;
    if (opts.clean_stale and mode == .timeline_only) {
        try std.fs.File.stderr().deprecatedWriter().writeAll("--clean-stale only applies to full Obsidian export; rerun with `--mode full --clean-stale`\n");
        return AppError.InvalidArguments;
    }
    switch (mode) {
        .timeline_only => {
            _ = try obsidianExportTimelineOnly(db, allocator, cfg, opts);
        },
        .full => try obsidianExportFull(db, allocator, cfg, opts),
    }
}

fn obsidianExportTimelineOnly(db: *Db, allocator: std.mem.Allocator, cfg: Config, opts: ObsidianExportOptions) !TimelineWriteStats {
    var paths = try resolveObsidianPaths(allocator, cfg, opts.vault_override);
    defer paths.deinit(allocator);
    if (!opts.dry_run) try makeObsidianTimelineDirs(paths);

    var stats = try writeObsidianTimeline(db, allocator, paths, cfg.obsidian_timeline_dir, opts.dry_run, opts.changed_only);
    stats.summary_written = try writeObsidianTimelineSummary(db, allocator, paths, stats.months_total, opts.dry_run, opts.changed_only);
    stats.summary_skipped = !stats.summary_written;
    if (!builtin.is_test) {
        try std.fs.File.stdout().deprecatedWriter().print("{s}obsidian export: mode=timeline-only months={} written={} skipped={} index={s} summary={s}\n", .{
            if (opts.dry_run) "dry-run " else "",
            stats.months_total,
            stats.months_written,
            stats.months_skipped,
            if (stats.index_written) "written" else "skipped",
            if (stats.summary_written) "written" else "skipped",
        });
    }
    return stats;
}

fn obsidianExportFull(db: *Db, allocator: std.mem.Allocator, cfg: Config, opts: ObsidianExportOptions) !void {
    const timeline_stats = try obsidianExportTimelineOnly(db, allocator, cfg, opts);

    var paths = try resolveObsidianPaths(allocator, cfg, opts.vault_override);
    defer paths.deinit(allocator);
    if (!opts.dry_run) try makeObsidianFullDirs(paths);

    var asset_map = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = asset_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        asset_map.deinit();
    }
    const materialized = try materializeObsidianAssets(db, allocator, cfg.assets_dir, paths, opts.dry_run, &asset_map);
    const notes = try writeObsidianNotes(db, allocator, cfg, paths, opts.dry_run, opts.changed_only, &asset_map);
    const stale = try countStaleObsidianNotes(db, allocator, paths.notes);
    if (opts.clean_stale and stale > 0) try markStaleObsidianNotes(allocator, paths, opts.dry_run);
    if (!opts.dry_run) {
        try writeObsidianIndexes(db, allocator, paths);
        try writeObsidianSidecars(db, allocator, paths, cfg, materialized, notes);
    }
    if (!builtin.is_test) {
        try std.fs.File.stdout().deprecatedWriter().print("{s}obsidian export: mode=full notes={} assets={} stale={} timeline_months={} timeline_written={}\n", .{ if (opts.dry_run) "dry-run " else "", notes, materialized, stale, timeline_stats.months_total, timeline_stats.months_written });
    }
}

fn materializeObsidianAssets(db: *Db, allocator: std.mem.Allocator, source_assets_dir: []const u8, paths: ObsidianPaths, dry_run: bool, asset_map: *std.StringHashMap([]const u8)) !u32 {
    const stmt = try db.prepare(
        \\SELECT id, coalesce(media_key, ''), asset_kind, source_url, local_path, coalesce(sha256, '')
        \\FROM media_assets
        \\WHERE status='downloaded' AND asset_kind IN ('image', 'preview_image', 'author_avatar') AND local_path <> ''
        \\ORDER BY id
    );
    defer _ = c.sqlite3_finalize(stmt);
    var count: u32 = 0;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        const id = c.sqlite3_column_int64(stmt, 0);
        const media_key = colText(stmt, 1);
        const kind = colText(stmt, 2);
        const source_url = colText(stmt, 3);
        const local_path = colText(stmt, 4);
        const sha = colText(stmt, 5);
        const source_path = try resolvedAssetLocalPath(allocator, source_assets_dir, local_path);
        defer allocator.free(source_path);
        const dest_dir = if (std.mem.eql(u8, kind, "image")) paths.images else if (std.mem.eql(u8, kind, "preview_image")) paths.previews else paths.avatars;
        const rel_dir = if (std.mem.eql(u8, kind, "image")) "../assets/images" else if (std.mem.eql(u8, kind, "preview_image")) "../assets/previews" else "../assets/avatars";
        const base_id = if (std.mem.eql(u8, kind, "author_avatar") and std.mem.startsWith(u8, media_key, "user:")) media_key["user:".len..] else media_key;
        const ext = extensionForAsset(local_path, source_url);
        const filename = try std.fmt.allocPrint(allocator, "{s}-{s}{s}", .{ base_id, if (sha.len > 0) sha else "unhashed", ext });
        defer allocator.free(filename);
        const dest = try std.fs.path.join(allocator, &.{ dest_dir, filename });
        defer allocator.free(dest);
        const rel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_dir, filename });
        if (!try copyValidatedAssetFile(allocator, source_path, dest, -1, sha, dry_run)) {
            allocator.free(rel);
            continue;
        }
        const key = try std.fmt.allocPrint(allocator, "{}", .{id});
        try asset_map.put(key, rel);
        count += 1;
        if (dry_run) {
            try std.fs.File.stdout().deprecatedWriter().print("would materialize asset id={} {s}\n", .{ id, rel });
        }
    }
    return count;
}

fn copyValidatedAssetFile(allocator: std.mem.Allocator, source_path: []const u8, dest_path: []const u8, expected_size: i64, expected_hash: []const u8, dry_run: bool) !bool {
    if (!try assetFileMatches(allocator, source_path, expected_size, expected_hash)) return false;
    if (!dry_run and !fileExists(dest_path)) {
        try ensureParentDir(dest_path);
        try std.fs.cwd().copyFile(source_path, std.fs.cwd(), dest_path, .{});
    }
    return true;
}

fn extensionForAsset(local_path: []const u8, source_url: []const u8) []const u8 {
    const base_ext = std.fs.path.extension(local_path);
    if (base_ext.len > 0 and base_ext.len <= 8) return base_ext;
    return extensionForUrl(source_url);
}

fn resolvedAssetLocalPath(allocator: std.mem.Allocator, assets_dir: []const u8, local_path: []const u8) ![]const u8 {
    if (pathUnderDir(allocator, local_path, assets_dir) and fileExists(local_path)) return allocator.dupe(u8, local_path);
    if (std.mem.indexOf(u8, local_path, "/assets/")) |idx| {
        const suffix = local_path[idx + "/assets/".len ..];
        const candidate = try std.fs.path.join(allocator, &.{ assets_dir, suffix });
        if (fileExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    return allocator.dupe(u8, local_path);
}

fn writeObsidianNotes(db: *Db, allocator: std.mem.Allocator, cfg: Config, paths: ObsidianPaths, dry_run: bool, changed_only: bool, asset_map: *std.StringHashMap([]const u8)) !u32 {
    _ = cfg;
    const stmt = try db.prepare(
        \\SELECT b.tweet_id, b.complete_for_offline_render, coalesce(t.canonical_uri, ''), coalesce(t.twitter_uri, ''), coalesce(t.text, ''),
        \\       coalesce(t.created_at, ''), coalesce(t.author_id, ''), coalesce(u.username, ''), coalesce(u.name, ''), b.last_seen_at, t.raw_json
        \\FROM bookmark_items b
        \\JOIN tweets t ON t.tweet_id = b.tweet_id
        \\LEFT JOIN users u ON u.user_id = t.author_id
        \\WHERE b.active = 1
        \\ORDER BY b.import_position IS NULL, b.import_position, b.last_seen_at DESC, b.tweet_id DESC
    );
    defer _ = c.sqlite3_finalize(stmt);
    var count: u32 = 0;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        const tweet_id = colText(stmt, 0);
        const note_name = try std.fmt.allocPrint(allocator, "{s}.md", .{tweet_id});
        defer allocator.free(note_name);
        const note_path = try std.fs.path.join(allocator, &.{ paths.notes, note_name });
        defer allocator.free(note_path);
        const generated = try buildObsidianNote(db, allocator, tweet_id, c.sqlite3_column_int(stmt, 1) != 0, colText(stmt, 2), colText(stmt, 3), colText(stmt, 4), colText(stmt, 5), colText(stmt, 6), colText(stmt, 7), colText(stmt, 8), colText(stmt, 9), colText(stmt, 10), asset_map);
        defer allocator.free(generated);
        const final = try mergeGeneratedNote(allocator, note_path, generated);
        defer allocator.free(final);
        if (changed_only and fileExists(note_path)) {
            const existing = try std.fs.cwd().readFileAlloc(allocator, note_path, 8 * 1024 * 1024);
            defer allocator.free(existing);
            if (std.mem.eql(u8, existing, final)) continue;
        }
        count += 1;
        if (dry_run) {
            try std.fs.File.stdout().deprecatedWriter().print("would write note {s}\n", .{note_path});
        } else {
            try ensureParentDir(note_path);
            try std.fs.cwd().writeFile(.{ .sub_path = note_path, .data = final });
        }
    }
    return count;
}

fn buildObsidianNote(
    db: *Db,
    allocator: std.mem.Allocator,
    tweet_id: []const u8,
    complete: bool,
    canonical_uri: []const u8,
    twitter_uri: []const u8,
    text: []const u8,
    created_at: []const u8,
    author_id: []const u8,
    username: []const u8,
    author_name: []const u8,
    bookmarked_at: []const u8,
    raw_json: []const u8,
    asset_map: *std.StringHashMap([]const u8),
) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch null;
    defer if (parsed) |*p| p.deinit();
    const root = if (parsed) |p| p.value else null;
    const post_text = rawXPostText(root, text);
    const thread_info = try loadThreadExportInfo(db, allocator, tweet_id, root);
    defer thread_info.deinit(allocator);
    var out = std.ArrayList(u8).empty;
    const w = out.writer(allocator);
    const asset_error_count = try noteAssetErrorCount(db, tweet_id, author_id);
    const nonlocal_media_count = try noteNonlocalMediaCount(db, tweet_id, author_id);
    const media_status = if (asset_error_count > 0 or nonlocal_media_count > 0 or !complete) "partial" else "complete";
    try w.writeAll("---\n");
    try w.writeAll("x_bookmarks_schema: 1\n");
    try yamlString(w, "tweet_id", tweet_id);
    try yamlString(w, "author_id", author_id);
    try yamlString(w, "author_username", username);
    try yamlString(w, "author_name", author_name);
    try yamlString(w, "created_at", created_at);
    try yamlString(w, "bookmarked_at", bookmarked_at);
    try yamlString(w, "canonical_url", canonical_uri);
    try yamlString(w, "twitter_url", twitter_uri);
    try yamlStringArrayForQuery(db, allocator, w, "folders", "SELECT coalesce(f.name, bfi.folder_id) FROM bookmark_folder_items bfi LEFT JOIN bookmark_folders f ON f.account_user_id=bfi.account_user_id AND f.folder_id=bfi.folder_id WHERE bfi.tweet_id=? ORDER BY f.name, bfi.folder_id", tweet_id);
    try w.print("thread_candidate: {}\n", .{thread_info.candidate});
    if (thread_info.candidate) {
        try yamlString(w, "thread_expansion_status", thread_info.status);
        if (thread_info.post_count > 0) try w.print("thread_post_count: {}\n", .{thread_info.post_count});
        if (thread_info.confidence.len > 0) try yamlString(w, "thread_expansion_confidence", thread_info.confidence);
    }
    try w.print("complete_for_offline_render: {}\n", .{complete});
    try yamlString(w, "media_status", media_status);
    try w.print("asset_error_count: {}\n", .{asset_error_count});
    try w.writeAll("tags:\n  - x-bookmark\n");
    if (!complete) try w.writeAll("  - x-bookmark/incomplete\n");
    if (asset_error_count > 0) try w.writeAll("  - x-bookmark/media-partial\n");
    try w.writeAll("---\n\n<!-- x-bookmarks:generated:start -->\n");
    try w.print("# @{s}\n\n", .{if (username.len > 0) username else "unknown"});
    try w.print("![]({s})\n\n", .{canonical_uri});
    try writeSourceTextSection(db, allocator, w, tweet_id, post_text, thread_info);
    try writeQuotePostsMarkdown(db, allocator, w, raw_json);
    try writeTweetMediaMarkdown(db, allocator, w, tweet_id, canonical_uri, asset_map);
    try writeObsidianThreadSummary(db, allocator, w, tweet_id, thread_info);
    try w.print("\n[Open on X]({s})\n\n", .{canonical_uri});
    try writeMediaRetrievalTable(db, allocator, w, tweet_id, author_id, canonical_uri, asset_map);
    try w.writeAll("<!-- x-bookmarks:generated:end -->\n\n## Notes\n\n<!-- User notes below this line are preserved by x-bookmarks. -->\n");
    return out.toOwnedSlice(allocator);
}

fn yamlString(writer: anytype, name: []const u8, value: []const u8) !void {
    try writer.print("{s}: {f}\n", .{ name, std.json.fmt(value, .{}) });
}

fn yamlStringArrayForQuery(db: *Db, allocator: std.mem.Allocator, writer: anytype, name: []const u8, sql: []const u8, bind_value: []const u8) !void {
    var values = std.ArrayList([]const u8).empty;
    defer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }
    const stmt = try db.prepare(sql);
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, bind_value);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        try values.append(allocator, try allocator.dupe(u8, colText(stmt, 0)));
    }
    if (values.items.len == 0) {
        try writer.print("{s}: []\n", .{name});
    } else {
        try writer.print("{s}:\n", .{name});
        for (values.items) |value| try writer.print("  - {f}\n", .{std.json.fmt(value, .{})});
    }
}

fn writeMarkdownEscaped(writer: anytype, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '\\' or ch == '`' or ch == '*' or ch == '_' or ch == '[' or ch == ']' or ch == '<' or ch == '>') try writer.writeByte('\\');
        try writer.writeByte(ch);
    }
}

fn mergeGeneratedNote(allocator: std.mem.Allocator, path: []const u8, generated: []const u8) ![]const u8 {
    if (!fileExists(path)) return allocator.dupe(u8, generated);
    const existing = try std.fs.cwd().readFileAlloc(allocator, path, 8 * 1024 * 1024);
    defer allocator.free(existing);
    const end_marker = "<!-- x-bookmarks:generated:end -->";
    const end = std.mem.indexOf(u8, existing, end_marker) orelse {
        const conflict = try std.fmt.allocPrint(allocator, "{s}.conflict", .{path});
        defer allocator.free(conflict);
        try std.fs.cwd().writeFile(.{ .sub_path = conflict, .data = generated });
        return allocator.dupe(u8, existing);
    };
    const preserve_start = end + end_marker.len;
    const generated_end = std.mem.indexOf(u8, generated, end_marker) orelse generated.len;
    var out = std.ArrayList(u8).empty;
    const w = out.writer(allocator);
    try w.writeAll(generated[0..@min(generated.len, generated_end + end_marker.len)]);
    try w.writeAll(existing[preserve_start..]);
    return out.toOwnedSlice(allocator);
}

fn noteAssetErrorCount(db: *Db, tweet_id: []const u8, author_id: []const u8) !i64 {
    const stmt = try db.prepare(
        \\SELECT count(*)
        \\FROM media_assets ma
        \\WHERE ma.status = 'failed'
        \\  AND (
        \\    ma.media_key IN (SELECT media_key FROM tweet_media WHERE tweet_id=?)
        \\    OR ma.media_key = ?
        \\  )
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    var avatar_key_buf: [256]u8 = undefined;
    const avatar_key = std.fmt.bufPrint(&avatar_key_buf, "user:{s}", .{author_id}) catch "";
    try bindText(stmt, 2, avatar_key);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return AppError.SqliteError;
    return c.sqlite3_column_int64(stmt, 0);
}

fn noteNonlocalMediaCount(db: *Db, tweet_id: []const u8, author_id: []const u8) !i64 {
    const stmt = try db.prepare(
        \\SELECT count(*)
        \\FROM media_assets ma
        \\WHERE ma.status IN ('skipped', 'remote_only', 'removed')
        \\  AND (
        \\    ma.media_key IN (SELECT media_key FROM tweet_media WHERE tweet_id=?)
        \\    OR ma.media_key = ?
        \\  )
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    var avatar_key_buf: [256]u8 = undefined;
    const avatar_key = std.fmt.bufPrint(&avatar_key_buf, "user:{s}", .{author_id}) catch "";
    try bindText(stmt, 2, avatar_key);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return AppError.SqliteError;
    return c.sqlite3_column_int64(stmt, 0);
}

fn writeQuotePostsMarkdown(db: *Db, allocator: std.mem.Allocator, writer: anytype, raw_json: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch return;
    defer parsed.deinit();
    const refs = getArray(parsed.value, "referenced_tweets") orelse return;
    for (refs.items) |ref| {
        if (ref != .object) continue;
        if (!std.mem.eql(u8, getString(ref, "type") orelse "", "quoted")) continue;
        const quote_id = getString(ref, "id") orelse continue;
        const stmt = try db.prepare(
            \\SELECT coalesce(t.text, ''), coalesce(t.canonical_uri, ''), coalesce(u.username, '')
            \\FROM tweets t
            \\LEFT JOIN users u ON u.user_id=t.author_id
            \\WHERE t.tweet_id=?
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, quote_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) continue;
        try writer.print("> Quoted @{s}: ", .{if (colText(stmt, 2).len > 0) colText(stmt, 2) else "unknown"});
        try writeMarkdownEscaped(writer, colText(stmt, 0));
        try writer.print("\n> [Open quoted post]({s})\n\n", .{colText(stmt, 1)});
    }
}

fn writeTweetMediaMarkdown(db: *Db, allocator: std.mem.Allocator, writer: anytype, tweet_id: []const u8, canonical_uri: []const u8, asset_map: *std.StringHashMap([]const u8)) !void {
    const stmt = try db.prepare(
        \\SELECT ma.id, ma.asset_kind, ma.status, ma.source_url
        \\FROM tweet_media tm
        \\JOIN media_assets ma ON ma.media_key=tm.media_key
        \\WHERE tm.tweet_id=?
        \\ORDER BY tm.position, ma.id
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        const id = c.sqlite3_column_int64(stmt, 0);
        const kind = colText(stmt, 1);
        const status = colText(stmt, 2);
        const key = try std.fmt.allocPrint(allocator, "{}", .{id});
        defer allocator.free(key);
        if (asset_map.get(key)) |rel| {
            if (std.mem.eql(u8, kind, "preview_image")) {
                try writer.print("[![Video preview]({s})]({s})\n\n", .{ rel, canonical_uri });
            } else if (std.mem.eql(u8, kind, "image")) {
                try writer.print("![Image]({s})\n\n", .{rel});
            }
        } else if (std.mem.eql(u8, status, "remote_only")) {
            try writer.print("[Remote video]({s})\n\n", .{canonical_uri});
        }
    }
}

fn writeMediaRetrievalTable(db: *Db, allocator: std.mem.Allocator, writer: anytype, tweet_id: []const u8, author_id: []const u8, canonical_uri: []const u8, asset_map: *std.StringHashMap([]const u8)) !void {
    try writer.writeAll("Media retrieval:\n\n| Kind | Status | Detail |\n| --- | --- | --- |\n");
    const stmt = try db.prepare(
        \\SELECT ma.id, ma.asset_kind, ma.status, ma.source_url, coalesce(ma.error_json, ''), coalesce(ma.retry_class, '')
        \\FROM media_assets ma
        \\WHERE ma.media_key IN (SELECT media_key FROM tweet_media WHERE tweet_id=?)
        \\   OR ma.media_key=?
        \\ORDER BY ma.asset_kind, ma.id
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, tweet_id);
    var avatar_key_buf: [256]u8 = undefined;
    const avatar_key = std.fmt.bufPrint(&avatar_key_buf, "user:{s}", .{author_id}) catch "";
    try bindText(stmt, 2, avatar_key);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        const id = c.sqlite3_column_int64(stmt, 0);
        const kind = colText(stmt, 1);
        const status = colText(stmt, 2);
        const source = colText(stmt, 3);
        const err = colText(stmt, 4);
        const key = try std.fmt.allocPrint(allocator, "{}", .{id});
        defer allocator.free(key);
        const is_video = std.mem.eql(u8, kind, "video_variant") or std.mem.eql(u8, kind, "animated_gif_variant");
        const display_status = if (is_video and std.mem.eql(u8, status, "downloaded")) "remote_only" else status;
        const detail = asset_map.get(key) orelse if (is_video) canonical_uri else if (std.mem.eql(u8, status, "remote_only")) source else if (err.len > 0) err else "";
        try writer.print("| {s} | {s} | `{s}` |\n", .{ kind, display_status, detail });
    }
    try writer.writeAll("\n");
}

fn markStaleObsidianNotes(allocator: std.mem.Allocator, paths: ObsidianPaths, dry_run: bool) !void {
    const inactive_path = try std.fs.path.join(allocator, &.{ paths.indexes, "inactive.md" });
    defer allocator.free(inactive_path);
    if (dry_run) {
        try std.fs.File.stdout().deprecatedWriter().writeAll("would write stale-note inactive index\n");
    } else {
        try ensureParentDir(inactive_path);
        try std.fs.cwd().writeFile(.{ .sub_path = inactive_path, .data = "# Inactive Bookmarks\n\nStale generated notes are retained in place so user notes are not deleted.\n" });
    }
}

fn writeObsidianIndexes(db: *Db, allocator: std.mem.Allocator, paths: ObsidianPaths) !void {
    const all_path = try std.fs.path.join(allocator, &.{ paths.indexes, "all-bookmarks.md" });
    defer allocator.free(all_path);
    const incomplete_path = try std.fs.path.join(allocator, &.{ paths.indexes, "incomplete.md" });
    defer allocator.free(incomplete_path);
    const failed_path = try std.fs.path.join(allocator, &.{ paths.indexes, "failed-assets.md" });
    defer allocator.free(failed_path);
    try writeAllBookmarksIndex(db, allocator, all_path);
    try writeIncompleteIndex(db, allocator, incomplete_path);
    try writeFailedAssetsIndex(db, allocator, failed_path);
}

fn writeAllBookmarksIndex(db: *Db, allocator: std.mem.Allocator, path: []const u8) !void {
    var out = std.ArrayList(u8).empty;
    const w = out.writer(allocator);
    try w.writeAll("# All Bookmarks\n\n");
    const stmt = try db.prepare(
        \\SELECT b.tweet_id, coalesce(u.username, ''), coalesce(t.created_at, ''), coalesce(t.text, '')
        \\FROM bookmark_items b JOIN tweets t ON t.tweet_id=b.tweet_id LEFT JOIN users u ON u.user_id=t.author_id
        \\WHERE b.active=1
        \\ORDER BY b.import_position IS NULL, b.import_position, b.last_seen_at DESC, b.tweet_id DESC
    );
    defer _ = c.sqlite3_finalize(stmt);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        try w.print("- [[{s}]] @{s} {s} - ", .{ colText(stmt, 0), colText(stmt, 1), colText(stmt, 2) });
        try writeMarkdownEscaped(w, shortText(colText(stmt, 3)));
        try w.writeAll("\n");
    }
    try ensureParentDir(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = out.items });
}

fn shortText(text: []const u8) []const u8 {
    return if (text.len > 120) text[0..120] else text;
}

fn writeIncompleteIndex(db: *Db, allocator: std.mem.Allocator, path: []const u8) !void {
    var out = std.ArrayList(u8).empty;
    const w = out.writer(allocator);
    try w.writeAll("# Incomplete Bookmarks\n\n");
    const stmt = try db.prepare("SELECT tweet_id FROM bookmark_items WHERE active=1 AND complete_for_offline_render=0 ORDER BY import_position IS NULL, import_position, tweet_id DESC");
    defer _ = c.sqlite3_finalize(stmt);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        try w.print("- [[{s}]]\n", .{colText(stmt, 0)});
    }
    try ensureParentDir(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = out.items });
}

fn writeObsidianTimeline(db: *Db, allocator: std.mem.Allocator, paths: ObsidianPaths, timeline_dir_name: []const u8, dry_run: bool, changed_only: bool) !TimelineWriteStats {
    if (!dry_run) try std.fs.cwd().makePath(paths.timeline);
    const stmt = try db.prepare(
        \\SELECT coalesce(t.created_at, ''), coalesce(t.canonical_uri, '')
        \\FROM bookmark_items b
        \\JOIN tweets t ON t.tweet_id=b.tweet_id
        \\WHERE b.active=1
        \\ORDER BY substr(coalesce(t.created_at, ''), 1, 7) DESC, coalesce(t.created_at, '') DESC, b.import_position IS NULL, b.import_position, b.tweet_id DESC
    );
    defer _ = c.sqlite3_finalize(stmt);

    var current_month: ?[]const u8 = null;
    defer if (current_month) |value| allocator.free(value);
    var current_day: ?[]const u8 = null;
    defer if (current_day) |value| allocator.free(value);
    var month_doc = std.ArrayList(u8).empty;
    defer month_doc.deinit(allocator);
    var timeline_index = std.ArrayList(u8).empty;
    defer timeline_index.deinit(allocator);
    try timeline_index.writer(allocator).writeAll("# Timeline\n\n");
    var stats = TimelineWriteStats{};

    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        const created_at = colText(stmt, 0);
        const month = timelineMonth(created_at);
        if (current_month == null or !std.mem.eql(u8, current_month.?, month)) {
            if (current_month) |existing| {
                const written = try writeTimelineMonthFile(allocator, paths, existing, month_doc.items, dry_run, changed_only);
                if (written) stats.months_written += 1 else stats.months_skipped += 1;
                month_doc.clearRetainingCapacity();
                allocator.free(existing);
            }
            if (current_day) |existing_day| {
                allocator.free(existing_day);
                current_day = null;
            }
            current_month = try allocator.dupe(u8, month);
            stats.months_total += 1;
            try month_doc.writer(allocator).print("# {s}\n\n", .{month});
            try timeline_index.writer(allocator).print("- [{s}](../{s}/{s}/{s}.md)\n", .{ month, timeline_dir_name, timelineYear(month), month });
        }
        const day = timelineDay(created_at);
        if (current_day == null or !std.mem.eql(u8, current_day.?, day)) {
            if (current_day) |existing_day| allocator.free(existing_day);
            current_day = try allocator.dupe(u8, day);
            try month_doc.writer(allocator).print("## {s}\n\n", .{day});
        }
        try appendTimelineEntry(month_doc.writer(allocator), colText(stmt, 1));
    }
    if (current_month) |month| {
        const written = try writeTimelineMonthFile(allocator, paths, month, month_doc.items, dry_run, changed_only);
        if (written) stats.months_written += 1 else stats.months_skipped += 1;
    }
    const timeline_index_path = try std.fs.path.join(allocator, &.{ paths.indexes, "timeline.md" });
    defer allocator.free(timeline_index_path);
    stats.index_written = try writeGeneratedFile(allocator, timeline_index_path, timeline_index.items, "timeline index", dry_run, changed_only);
    stats.index_skipped = !stats.index_written;
    return stats;
}

fn timelineMonth(created_at: []const u8) []const u8 {
    if (created_at.len >= 7 and created_at[4] == '-') return created_at[0..7];
    return "unknown";
}

fn timelineYear(month: []const u8) []const u8 {
    if (month.len >= 4) return month[0..4];
    return "unknown";
}

fn timelineDay(created_at: []const u8) []const u8 {
    if (created_at.len >= 10) return created_at[0..10];
    return "unknown date";
}

fn writeTimelineMonthFile(allocator: std.mem.Allocator, paths: ObsidianPaths, month: []const u8, data: []const u8, dry_run: bool, changed_only: bool) !bool {
    const year_dir = try std.fs.path.join(allocator, &.{ paths.timeline, timelineYear(month) });
    defer allocator.free(year_dir);
    if (!dry_run) try std.fs.cwd().makePath(year_dir);
    const filename = try std.fmt.allocPrint(allocator, "{s}.md", .{month});
    defer allocator.free(filename);
    const path = try std.fs.path.join(allocator, &.{ year_dir, filename });
    defer allocator.free(path);
    return writeGeneratedFile(allocator, path, data, "timeline month", dry_run, changed_only);
}

fn appendTimelineEntry(writer: anytype, canonical_uri: []const u8) !void {
    try writer.print("![]({s})\n\n", .{canonical_uri});
}

fn writeGeneratedFile(allocator: std.mem.Allocator, path: []const u8, data: []const u8, label: []const u8, dry_run: bool, changed_only: bool) !bool {
    if (changed_only and fileExists(path)) {
        const existing = try std.fs.cwd().readFileAlloc(allocator, path, 8 * 1024 * 1024);
        defer allocator.free(existing);
        if (std.mem.eql(u8, existing, data)) return false;
    }
    if (dry_run) {
        try std.fs.File.stdout().deprecatedWriter().print("would write {s} {s}\n", .{ label, path });
    } else {
        try ensureParentDir(path);
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
    }
    return true;
}

fn writeObsidianTimelineSummary(db: *Db, allocator: std.mem.Allocator, paths: ObsidianPaths, timeline_months: u32, dry_run: bool, changed_only: bool) !bool {
    const summary_path = try std.fs.path.join(allocator, &.{ paths.data, "export-summary.json" });
    defer allocator.free(summary_path);
    const active = try scalarCount(db, "SELECT count(*) FROM bookmark_items WHERE active=1");
    const summary = try std.fmt.allocPrint(
        allocator,
        "{{\n  \"export_mode\": \"timeline-only\",\n  \"active_bookmarks\": {},\n  \"timeline_months\": {}\n}}\n",
        .{ active, timeline_months },
    );
    defer allocator.free(summary);
    return writeGeneratedFile(allocator, summary_path, summary, "timeline summary", dry_run, changed_only);
}

fn writeFailedAssetsIndex(db: *Db, allocator: std.mem.Allocator, path: []const u8) !void {
    var out = std.ArrayList(u8).empty;
    const w = out.writer(allocator);
    try w.writeAll("# Failed Assets\n\nRetry examples:\n\n```bash\nx-bookmarks assets retry --only-transient\nx-bookmarks assets retry --kind image\n```\n\n");
    const stmt = try db.prepare("SELECT coalesce(retry_class, 'unknown'), asset_kind, count(*) FROM media_assets WHERE status='failed' GROUP BY retry_class, asset_kind ORDER BY retry_class, asset_kind");
    defer _ = c.sqlite3_finalize(stmt);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        try w.print("- {s} / {s}: {}\n", .{ colText(stmt, 0), colText(stmt, 1), c.sqlite3_column_int64(stmt, 2) });
    }
    try ensureParentDir(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = out.items });
}

fn writeObsidianSidecars(db: *Db, allocator: std.mem.Allocator, paths: ObsidianPaths, cfg: Config, materialized_assets: u32, exported_notes: u32) !void {
    const bookmarks_path = try std.fs.path.join(allocator, &.{ paths.data, "bookmarks-index.json" });
    defer allocator.free(bookmarks_path);
    const media_path = try std.fs.path.join(allocator, &.{ paths.data, "media-assets-index.json" });
    defer allocator.free(media_path);
    const summary_path = try std.fs.path.join(allocator, &.{ paths.data, "export-summary.json" });
    defer allocator.free(summary_path);
    try writeQueryJsonArray(db, allocator, bookmarks_path,
        \\SELECT b.tweet_id, b.account_user_id, b.complete_for_offline_render, coalesce(t.canonical_uri, ''), coalesce(t.created_at, ''), coalesce(u.username, ''), coalesce(t.text, '')
        \\FROM bookmark_items b JOIN tweets t ON t.tweet_id=b.tweet_id LEFT JOIN users u ON u.user_id=t.author_id
        \\WHERE b.active=1
        \\ORDER BY b.import_position IS NULL, b.import_position, b.last_seen_at DESC, b.tweet_id DESC
    , &.{ "tweet_id", "account_user_id", "complete_for_offline_render:bool", "canonical_uri", "created_at", "author_username", "text" });
    try writeQueryJsonArray(db, allocator, media_path,
        \\SELECT id, coalesce(media_key, ''), asset_kind, source_url, local_path, coalesce(content_type, ''), coalesce(byte_size, 0), coalesce(sha256, ''), status, coalesce(error_json, ''), coalesce(retrieval_policy, ''), coalesce(retry_class, ''), coalesce(attempts, 0), coalesce(removed_at, ''), coalesce(removal_reason, '')
        \\FROM media_assets
        \\ORDER BY id
    , &.{ "id:int", "media_key", "asset_kind", "source_url", "local_path", "content_type", "byte_size:int", "sha256", "status", "error_json", "retrieval_policy", "retry_class", "attempts:int", "removed_at", "removal_reason" });
    const generated = try timestampString(allocator);
    defer allocator.free(generated);
    const active = try scalarCount(db, "SELECT count(*) FROM bookmark_items WHERE active=1");
    const failed = try scalarCount(db, "SELECT count(*) FROM media_assets WHERE status='failed'");
    const remote = try scalarCount(db, "SELECT count(*) FROM media_assets WHERE status IN ('remote_only', 'removed', 'skipped')");
    const summary = try std.fmt.allocPrint(
        allocator,
        "{{\n  \"generated_at\": \"{s}\",\n  \"media_policy\": {f},\n  \"active_bookmarks\": {},\n  \"exported_notes\": {},\n  \"materialized_assets\": {},\n  \"failed_media_assets\": {},\n  \"nonlocal_media_assets\": {}\n}}\n",
        .{ generated, std.json.fmt(cfg.media_policy, .{}), active, exported_notes, materialized_assets, failed, remote },
    );
    defer allocator.free(summary);
    try ensureParentDir(summary_path);
    try std.fs.cwd().writeFile(.{ .sub_path = summary_path, .data = summary });
}

fn writeObsidianConfig(allocator: std.mem.Allocator, config_path: []const u8, vault_path: []const u8, root_dir: []const u8) !void {
    const text = try std.fs.cwd().readFileAlloc(allocator, config_path, 4 * 1024 * 1024);
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return AppError.ConfigInvalid;

    const json_allocator = parsed.arena.allocator();
    var obs = std.json.ObjectMap.init(json_allocator);
    try obs.put("vault_path", .{ .string = vault_path });
    try obs.put("root_dir", .{ .string = root_dir });
    try obs.put("export_mode", .{ .string = "timeline-only" });
    try obs.put("timeline_dir", .{ .string = "timeline" });
    try obs.put("index_dir", .{ .string = "indexes" });
    try obs.put("data_dir", .{ .string = "data" });
    try obs.put("media_policy", .{ .string = "images-only" });
    try parsed.value.object.put("obsidian", .{ .object = obs });

    const out = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
    defer allocator.free(out);
    const with_newline = try std.fmt.allocPrint(allocator, "{s}\n", .{out});
    defer allocator.free(with_newline);
    try writePrivateFile(config_path, with_newline);
}

fn obsidianMigrateMedia(db: *Db, allocator: std.mem.Allocator, cfg: Config, dry_run: bool) !void {
    const stmt = try db.prepare(
        \\SELECT id, local_path, coalesce(byte_size, 0), coalesce(sha256, ''), source_url
        \\FROM media_assets
        \\WHERE asset_kind IN ('video_variant', 'animated_gif_variant') AND status='downloaded'
        \\ORDER BY id
    );
    defer _ = c.sqlite3_finalize(stmt);
    var eligible: u32 = 0;
    var missing: u32 = 0;
    var recoverable: i64 = 0;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        const id = c.sqlite3_column_int64(stmt, 0);
        const path = try allocator.dupe(u8, colText(stmt, 1));
        defer allocator.free(path);
        const byte_size = c.sqlite3_column_int64(stmt, 2);
        const sha = colText(stmt, 3);
        const source = colText(stmt, 4);
        if (source.len == 0 or sha.len == 0) continue;
        const resolved_path = try resolvedAssetLocalPath(allocator, cfg.assets_dir, path);
        defer allocator.free(resolved_path);
        eligible += 1;
        if (fileExists(resolved_path)) {
            recoverable += byte_size;
        } else {
            missing += 1;
        }
        if (!dry_run) {
            if (!pathUnderDir(allocator, resolved_path, cfg.assets_dir)) return AppError.ConfigInvalid;
            if (fileExists(resolved_path)) try std.fs.cwd().deleteFile(resolved_path);
            try markMediaAssetRemoved(db, allocator, id);
        }
    }
    try std.fs.File.stdout().deprecatedWriter().print("video/GIF local assets eligible for removal: {}\nbytes recoverable: {}\ndatabase rows to mark removed: {}\nfiles missing already: {}\n", .{ eligible, recoverable, eligible, missing });
    if (!dry_run) try refreshCompletenessForAllActiveBookmarks(db, allocator);
}

fn pathUnderDir(allocator: std.mem.Allocator, path: []const u8, dir: []const u8) bool {
    const abs_path = absolutize(allocator, path) catch return false;
    defer allocator.free(abs_path);
    const abs_dir = absolutize(allocator, dir) catch return false;
    defer allocator.free(abs_dir);
    return std.mem.eql(u8, abs_path, abs_dir) or (std.mem.startsWith(u8, abs_path, abs_dir) and abs_path.len > abs_dir.len and (abs_path[abs_dir.len] == '/' or abs_path[abs_dir.len] == '\\'));
}

fn markMediaAssetRemoved(db: *Db, allocator: std.mem.Allocator, id: i64) !void {
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const stmt = try db.prepare("UPDATE media_assets SET status='removed', removed_at=?, removal_reason='images-only media policy; remote playback retained', retrieval_policy='images-only', retry_class='policy', last_checked_at=? WHERE id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, now);
    try bindText(stmt, 2, now);
    _ = c.sqlite3_bind_int64(stmt, 3, id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn assetsVerify(db: *Db, allocator: std.mem.Allocator) !void {
    const stmt = try db.prepare("SELECT id, local_path, coalesce(byte_size, -1), coalesce(sha256, ''), status FROM media_assets WHERE status IN ('downloaded', 'ok')");
    defer _ = c.sqlite3_finalize(stmt);
    var checked: u32 = 0;
    var failed: u32 = 0;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        checked += 1;
        const id = c.sqlite3_column_int64(stmt, 0);
        const path = colText(stmt, 1);
        const expected_size = c.sqlite3_column_int64(stmt, 2);
        const expected_hash = colText(stmt, 3);
        const data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024 * 1024) catch {
            failed += 1;
            try std.fs.File.stderr().deprecatedWriter().print("missing asset id={} path={s}\n", .{ id, path });
            continue;
        };
        defer allocator.free(data);
        if (expected_size >= 0 and expected_size != @as(i64, @intCast(data.len))) {
            failed += 1;
            try std.fs.File.stderr().deprecatedWriter().print("size mismatch asset id={} path={s}\n", .{ id, path });
        }
        if (expected_hash.len > 0) {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
            const actual = std.fmt.bytesToHex(digest, .lower);
            if (!std.mem.eql(u8, expected_hash, &actual)) {
                failed += 1;
                try std.fs.File.stderr().deprecatedWriter().print("hash mismatch asset id={} path={s}\n", .{ id, path });
            }
        }
    }
    try std.fs.File.stdout().deprecatedWriter().print("assets checked: {}\nasset failures: {}\n", .{ checked, failed });
    if (failed > 0) return AppError.IoError;
}

fn assetsRetry(db: *Db, allocator: std.mem.Allocator, cfg: Config, opts: AssetRetryOptions) !void {
    const out = std.fs.File.stdout().deprecatedWriter();
    const stmt = try db.prepare(
        \\SELECT id, coalesce(media_key, ''), asset_kind, source_url, coalesce(width, 0), coalesce(height, 0), coalesce(attempts, 0), coalesce(retry_class, 'unknown')
        \\FROM media_assets
        \\WHERE status = 'failed'
        \\  AND (? IS NULL OR asset_kind = ?)
        \\  AND coalesce(attempts, 0) < ?
        \\  AND (? = 0 OR coalesce(retry_class, 'unknown') = 'transient')
        \\  AND NOT (? = 'images-only' AND asset_kind IN ('video_variant', 'animated_gif_variant'))
        \\ORDER BY id
    );
    defer _ = c.sqlite3_finalize(stmt);
    if (opts.kind) |kind| {
        try bindText(stmt, 1, kind);
        try bindText(stmt, 2, kind);
    } else {
        _ = c.sqlite3_bind_null(stmt, 1);
        _ = c.sqlite3_bind_null(stmt, 2);
    }
    _ = c.sqlite3_bind_int(stmt, 3, @intCast(opts.max_attempts));
    _ = c.sqlite3_bind_int(stmt, 4, if (opts.only_transient) 1 else 0);
    try bindText(stmt, 5, cfg.media_policy);

    var planned: u32 = 0;
    var attempted: u32 = 0;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return AppError.SqliteError;
        planned += 1;
        const id = c.sqlite3_column_int64(stmt, 0);
        const media_key = try allocator.dupe(u8, colText(stmt, 1));
        defer allocator.free(media_key);
        const kind = try allocator.dupe(u8, colText(stmt, 2));
        defer allocator.free(kind);
        const source_url = try allocator.dupe(u8, colText(stmt, 3));
        defer allocator.free(source_url);
        const width_raw = c.sqlite3_column_int64(stmt, 4);
        const height_raw = c.sqlite3_column_int64(stmt, 5);
        const retry_class = colText(stmt, 7);
        try out.print("{s}retry asset id={} kind={s} media_key={s} class={s}\n", .{ if (opts.dry_run) "would " else "", id, kind, media_key, retry_class });
        if (!opts.dry_run) {
            attempted += 1;
            try incrementAssetAttempt(db, allocator, id);
            try downloadAsset(db, allocator, cfg.assets_dir, media_key, kind, source_url, if (width_raw > 0) width_raw else null, if (height_raw > 0) height_raw else null);
        }
    }
    try out.print("retry candidates: {}\nretry attempts: {}\n", .{ planned, attempted });
}

fn incrementAssetAttempt(db: *Db, allocator: std.mem.Allocator, id: i64) !void {
    const now = try timestampString(allocator);
    defer allocator.free(now);
    const stmt = try db.prepare("UPDATE media_assets SET attempts=coalesce(attempts, 0)+1, last_checked_at=? WHERE id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, now);
    _ = c.sqlite3_bind_int64(stmt, 2, id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return AppError.SqliteError;
}

fn serveDirectory(allocator: std.mem.Allocator, root: []const u8, port: u16) !void {
    const address = try std.net.Address.parseIp4("127.0.0.1", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    try std.fs.File.stdout().deprecatedWriter().print("serving {s} at http://127.0.0.1:{}/\n", .{ root, port });
    while (true) {
        var conn = try server.accept();
        defer conn.stream.close();
        var buf: [4096]u8 = undefined;
        const n = try conn.stream.read(&buf);
        if (n == 0) continue;
        const req = buf[0..n];
        const method = parseHttpMethod(req) orelse {
            try conn.stream.writeAll("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
            continue;
        };
        if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "HEAD")) {
            try conn.stream.writeAll("HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\nContent-Length: 0\r\n\r\n");
            continue;
        }
        const path = parseHttpPath(req) orelse {
            try conn.stream.writeAll("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
            continue;
        };
        const safe_path = if (std.mem.eql(u8, path, "/")) "/index.html" else path;
        if (std.mem.indexOf(u8, safe_path, "..") != null) {
            try conn.stream.writeAll("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
            continue;
        }
        const rel = std.mem.trimLeft(u8, safe_path, "/");
        const full = try std.fs.path.join(allocator, &.{ root, rel });
        defer allocator.free(full);
        var file = std.fs.cwd().openFile(full, .{}) catch {
            try conn.stream.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            continue;
        };
        defer file.close();
        const file_size = try file.getEndPos();
        const ctype = contentType(full);
        const range = parseRangeHeader(req, file_size) catch {
            const header = try std.fmt.allocPrint(allocator, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{file_size});
            defer allocator.free(header);
            try conn.stream.writeAll(header);
            continue;
        };
        const header = if (range) |r|
            try std.fmt.allocPrint(allocator, "HTTP/1.1 206 Partial Content\r\nContent-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Range: bytes {}-{}/{}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", .{ ctype, r.start, r.end, file_size, r.end - r.start + 1 })
        else
            try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", .{ ctype, file_size });
        defer allocator.free(header);
        try conn.stream.writeAll(header);
        if (std.mem.eql(u8, method, "GET")) {
            if (range) |r| {
                try writeFileRange(&conn.stream, &file, r.start, r.end - r.start + 1);
            } else {
                try writeFileRange(&conn.stream, &file, 0, file_size);
            }
        }
    }
}

fn parseHttpMethod(req: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, req, ' ') orelse return null;
    return req[0..end];
}

fn parseHttpTarget(req: []const u8) ?[]const u8 {
    const method_end = std.mem.indexOfScalar(u8, req, ' ') orelse return null;
    const method = req[0..method_end];
    if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "HEAD")) return null;
    const rest = req[method_end + 1 ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    return rest[0..end];
}

fn parseHttpPath(req: []const u8) ?[]const u8 {
    const target = parseHttpTarget(req) orelse return null;
    return httpTargetPath(target);
}

fn httpTargetPath(target: []const u8) []const u8 {
    const query = std.mem.indexOfAny(u8, target, "?#") orelse target.len;
    return target[0..query];
}

const ByteRange = struct {
    start: u64,
    end: u64,
};

fn parseRangeHeader(req: []const u8, file_size: u64) !?ByteRange {
    const value = headerValue(req, "range") orelse return null;
    if (file_size == 0) return error.InvalidRange;
    const trimmed = std.mem.trim(u8, value, " \t");
    if (!std.mem.startsWith(u8, trimmed, "bytes=")) return error.InvalidRange;
    const spec = trimmed["bytes=".len..];
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return error.InvalidRange;
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return error.InvalidRange;
    const start_text = std.mem.trim(u8, spec[0..dash], " \t");
    const end_text = std.mem.trim(u8, spec[dash + 1 ..], " \t");
    if (start_text.len == 0) {
        if (end_text.len == 0) return error.InvalidRange;
        const suffix_len = try std.fmt.parseInt(u64, end_text, 10);
        if (suffix_len == 0) return error.InvalidRange;
        const actual_len = @min(suffix_len, file_size);
        return .{ .start = file_size - actual_len, .end = file_size - 1 };
    }
    const start = try std.fmt.parseInt(u64, start_text, 10);
    if (start >= file_size) return error.InvalidRange;
    const requested_end = if (end_text.len == 0) file_size - 1 else try std.fmt.parseInt(u64, end_text, 10);
    if (requested_end < start) return error.InvalidRange;
    return .{ .start = start, .end = @min(requested_end, file_size - 1) };
}

fn headerValue(req: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, req, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) return null;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn writeFileRange(stream: anytype, file: *std.fs.File, start: u64, len: u64) !void {
    try file.seekTo(start);
    var remaining = len;
    var buffer: [64 * 1024]u8 = undefined;
    while (remaining > 0) {
        const chunk = @min(remaining, @as(u64, buffer.len));
        const n = try file.read(buffer[0..@intCast(chunk)]);
        if (n == 0) break;
        try stream.writeAll(buffer[0..n]);
        remaining -= n;
    }
}

fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".mp4")) return "video/mp4";
    return "application/octet-stream";
}

fn bindText(stmt: *c.sqlite3_stmt, idx: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_text(stmt, idx, value.ptr, @intCast(value.len), null) != c.SQLITE_OK) return AppError.SqliteError;
}

fn colText(stmt: *c.sqlite3_stmt, idx: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, idx) orelse return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
}

fn getObject(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn getArray(v: std.json.Value, key: []const u8) ?std.json.Array {
    const x = getObject(v, key) orelse return null;
    if (x != .array) return null;
    return x.array;
}

fn getString(v: std.json.Value, key: []const u8) ?[]const u8 {
    const x = getObject(v, key) orelse return null;
    if (x != .string) return null;
    return x.string;
}

fn getNullableString(v: std.json.Value, key: []const u8) ??[]const u8 {
    const x = getObject(v, key) orelse return null;
    if (x == .null) return null;
    if (x == .string) return x.string;
    return null;
}

fn getBool(v: std.json.Value, key: []const u8) ?bool {
    const x = getObject(v, key) orelse return null;
    if (x != .bool) return null;
    return x.bool;
}

fn getInt(v: std.json.Value, key: []const u8) ?i64 {
    const x = getObject(v, key) orelse return null;
    return switch (x) {
        .integer => |i| i,
        else => null,
    };
}

fn parseScopes(allocator: std.mem.Allocator, arr: std.json.Array) ![]const []const u8 {
    var scopes = try allocator.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |item, idx| {
        if (item != .string) return AppError.ConfigInvalid;
        scopes[idx] = try allocator.dupe(u8, item.string);
    }
    return scopes;
}

fn cloneScopes(allocator: std.mem.Allocator, scopes: []const []const u8) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, scopes.len);
    for (scopes, 0..) |s, i| out[i] = try allocator.dupe(u8, s);
    return out;
}

fn joinScopes(allocator: std.mem.Allocator, scopes: []const []const u8, sep: []const u8) ![]const u8 {
    var list = std.ArrayList(u8).empty;
    for (scopes, 0..) |scope, i| {
        if (i > 0) try list.appendSlice(allocator, sep);
        try list.appendSlice(allocator, scope);
    }
    return list.toOwnedSlice(allocator);
}

fn makePkceVerifier(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len);
    const out = try allocator.alloc(u8, size);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, &bytes);
    return out;
}

fn makePkceChallenge(allocator: std.mem.Allocator, verifier: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(digest.len);
    const out = try allocator.alloc(u8, size);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, &digest);
    return out;
}

fn buildAuthUrl(allocator: std.mem.Allocator, client_id: []const u8, redirect_uri: []const u8, scopes: []const u8, state: []const u8, challenge: []const u8) ![]const u8 {
    const cid = try urlEncode(allocator, client_id);
    defer allocator.free(cid);
    const redir = try urlEncode(allocator, redirect_uri);
    defer allocator.free(redir);
    const scope = try urlEncode(allocator, scopes);
    defer allocator.free(scope);
    const st = try urlEncode(allocator, state);
    defer allocator.free(st);
    const ch = try urlEncode(allocator, challenge);
    defer allocator.free(ch);
    return std.fmt.allocPrint(allocator, "https://x.com/i/oauth2/authorize?response_type=code&client_id={s}&redirect_uri={s}&scope={s}&state={s}&code_challenge={s}&code_challenge_method=S256", .{ cid, redir, scope, st, ch });
}

fn parseLocalHttpRedirectUri(allocator: std.mem.Allocator, redirect_uri: []const u8) !LocalRedirect {
    const prefix = "http://";
    if (!std.mem.startsWith(u8, redirect_uri, prefix)) return AppError.ConfigInvalid;
    const rest = redirect_uri[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return AppError.ConfigInvalid;
    const host_port = rest[0..slash];
    if (host_port.len == 0) return AppError.ConfigInvalid;
    const path_and_query = rest[slash..];
    const path_end = std.mem.indexOfAny(u8, path_and_query, "?#") orelse path_and_query.len;
    const path = path_and_query[0..path_end];
    if (path.len == 0 or path[0] != '/') return AppError.ConfigInvalid;

    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':');
    const host = if (colon) |idx| host_port[0..idx] else host_port;
    const port_text = if (colon) |idx| host_port[idx + 1 ..] else "80";
    if (!std.mem.eql(u8, host, "127.0.0.1") and !std.mem.eql(u8, host, "localhost")) return AppError.ConfigInvalid;
    const port = std.fmt.parseInt(u16, port_text, 10) catch return AppError.ConfigInvalid;
    if (port == 0) return AppError.ConfigInvalid;
    return .{
        .host = try allocator.dupe(u8, host),
        .port = port,
        .path = try allocator.dupe(u8, path),
    };
}

fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (input) |ch| {
        if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(allocator, ch);
        } else if (ch == ' ') {
            try out.appendSlice(allocator, "%20");
        } else {
            try out.writer(allocator).print("%{X:0>2}", .{ch});
        }
    }
    return out.toOwnedSlice(allocator);
}

fn codeFromCallbackUrl(allocator: std.mem.Allocator, callback_url: []const u8) ![]const u8 {
    return callbackParamFromUrl(allocator, callback_url, "code");
}

fn callbackParamFromUrl(allocator: std.mem.Allocator, callback_url: []const u8, name: []const u8) ![]const u8 {
    const query_start = if (std.mem.indexOfScalar(u8, callback_url, '?')) |idx| idx + 1 else 0;
    const fragment_start = std.mem.indexOfScalarPos(u8, callback_url, query_start, '#') orelse callback_url.len;
    var parts = std.mem.splitScalar(u8, callback_url[query_start..fragment_start], '&');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = try urlDecode(allocator, part[0..eq]);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, name)) continue;
        return urlDecode(allocator, part[eq + 1 ..]);
    }
    return AppError.InvalidArguments;
}

fn validateCallbackState(pending: std.json.Value, actual_state: []const u8) !void {
    const expected_state = getString(pending, "state") orelse return AppError.AuthRequired;
    if (!std.mem.eql(u8, expected_state, actual_state)) return AppError.AuthRequired;
}

fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const byte = try std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16);
            try out.append(allocator, byte);
            i += 3;
        } else if (input[i] == '+') {
            try out.append(allocator, ' ');
            i += 1;
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn jsonField(writer: anytype, name: []const u8, value: []const u8, comma: bool) !void {
    if (comma) try writer.writeAll(",");
    try writer.print("{f}:{f}", .{ std.json.fmt(name, .{}), std.json.fmt(value, .{}) });
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn ensureParentDir(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
}

fn getHome(allocator: std.mem.Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => AppError.MissingHome,
        else => err,
    };
}

fn absolutize(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.cwd().realpathAlloc(allocator, path) catch {
        const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(cwd);
        return std.fs.path.join(allocator, &.{ cwd, path });
    };
}

fn dirnameDup(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.dirname(path)) |dir| return allocator.dupe(u8, dir);
    return allocator.dupe(u8, ".");
}

fn timestampString(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{}", .{std.time.timestamp()});
}

fn uniqueRunDirectoryName(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    var random_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    const hex = std.fmt.bytesToHex(random_bytes, .lower);
    return std.fmt.allocPrint(allocator, "{s}-{}-{s}", .{ prefix, std.time.timestamp(), &hex });
}

fn replaceOwned(allocator: std.mem.Allocator, original: []u8, needle: []const u8, replacement: []const u8) ![]u8 {
    const replaced = try std.mem.replaceOwned(u8, allocator, original, needle, replacement);
    allocator.free(original);
    return replaced;
}

fn writePrivateFile(path: []const u8, data: []const u8) !void {
    try ensureParentDir(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    if (builtin.os.tag != .windows) try file.chmod(0o600);
    try file.writeAll(data);
}

const fallbackViewerHtml =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1">
    \\  <title>x-bookmarks viewer</title>
    \\  <style>
    \\    :root { color-scheme: light dark; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    \\    body { margin: 0; background: #f7f8fa; color: #0f1419; }
    \\    header { position: sticky; top: 0; z-index: 2; background: rgba(255,255,255,.94); border-bottom: 1px solid #d8dde3; padding: 12px 20px; display: flex; gap: 12px; align-items: center; }
    \\    h1 { font-size: 18px; margin: 0; }
    \\    main { max-width: 760px; margin: 0 auto; padding: 16px; }
    \\    .filters { margin-left: auto; display: flex; gap: 8px; align-items: center; }
    \\    input, select { border: 1px solid #c8d0d8; border-radius: 6px; padding: 8px 10px; background: #fff; color: inherit; }
    \\    article { background: #fff; border: 1px solid #d8dde3; border-radius: 8px; padding: 14px 16px; margin: 12px 0; }
    \\    .byline { display: flex; gap: 8px; align-items: baseline; font-weight: 700; }
    \\    .muted { color: #536471; font-weight: 400; }
    \\    .text { white-space: pre-wrap; line-height: 1.45; margin: 10px 0; }
    \\    .links { display: flex; flex-wrap: wrap; gap: 10px; font-size: 14px; }
    \\    a { color: #0f6cbd; text-decoration: none; }
    \\    .badge { border: 1px solid #c8d0d8; border-radius: 999px; padding: 2px 8px; font-size: 12px; }
    \\    pre { max-height: 240px; overflow: auto; background: #f1f3f5; padding: 10px; border-radius: 6px; }
    \\    @media (prefers-color-scheme: dark) {
    \\      body { background: #101214; color: #edf1f5; }
    \\      header, article { background: #171a1d; border-color: #30363d; }
    \\      input, select { background: #101214; border-color: #30363d; }
    \\      .muted { color: #98a6b3; }
    \\      pre { background: #101214; }
    \\    }
    \\  </style>
    \\</head>
    \\<body>
    \\  <header>
    \\    <h1>x-bookmarks</h1>
    \\    <div class="filters">
    \\      <input id="q" type="search" placeholder="Search">
    \\      <select id="complete">
    \\        <option value="all">All</option>
    \\        <option value="complete">Complete</option>
    \\        <option value="incomplete">Incomplete</option>
    \\      </select>
    \\    </div>
    \\  </header>
    \\  <main id="app"></main>
    \\  <script>
    \\    const app = document.getElementById('app');
    \\    const q = document.getElementById('q');
    \\    const complete = document.getElementById('complete');
    \\    let bookmarks = [];
    \\    function esc(s){return String(s ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
    \\    function fullText(b){try{const raw=JSON.parse(b.raw_json||'{}');return raw.note_tweet?.text || raw.text || b.text || '';}catch{return b.text || '';}}
    \\    function render(){
    \\      const query = q.value.toLowerCase();
    \\      const mode = complete.value;
    \\      const rows = bookmarks.filter(b => (!query || fullText(b).toLowerCase().includes(query) || (b.author_username || '').toLowerCase().includes(query)) && (mode === 'all' || (mode === 'complete') === !!b.complete_for_offline_render));
    \\      app.innerHTML = rows.map(b => `<article>
    \\        <div class="byline"><span>${esc(b.author_name || b.author_username || 'Unknown author')}</span><span class="muted">@${esc(b.author_username || 'unknown')}</span><span class="badge">${b.complete_for_offline_render ? 'complete' : 'incomplete'}</span></div>
    \\        <div class="muted">${esc(b.created_at || '')}</div>
    \\        <div class="text">${esc(fullText(b))}</div>
    \\        <div class="links"><a href="${esc(b.canonical_uri)}">X URI</a><a href="${esc(b.twitter_uri)}">Twitter URI</a></div>
    \\        <details><summary>Raw JSON</summary><pre>${esc(b.raw_json || '')}</pre></details>
    \\      </article>`).join('') || '<p class="muted">No bookmarks exported.</p>';
    \\    }
    \\    fetch('./data/bookmarks.json').then(r=>r.json()).then(data=>{bookmarks=data;render();}).catch(()=>{app.innerHTML='<p class="muted">No export data found.</p>';});
    \\    q.addEventListener('input', render);
    \\    complete.addEventListener('change', render);
    \\  </script>
    \\</body>
    \\</html>
;

test "PKCE challenge has URL-safe base64 shape" {
    const allocator = std.testing.allocator;
    const challenge = try makePkceChallenge(allocator, "abc");
    defer allocator.free(challenge);
    try std.testing.expectEqualStrings("ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0", challenge);
}

test "URL encoding uses RFC3986 spaces" {
    const allocator = std.testing.allocator;
    const out = try urlEncode(allocator, "a b/c?");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a%20b%2Fc%3F", out);
}

test "home override resolves config and state paths under the selected directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const paths = try resolvePaths(allocator, null, home);

    try std.testing.expect(std.mem.endsWith(u8, paths.config_path, "/config.json"));
    try std.testing.expect(std.mem.endsWith(u8, paths.config_dir, &tmp.sub_path));
    try std.testing.expect(std.mem.endsWith(u8, paths.state_dir, &tmp.sub_path));

    const cfg = try Config.default(allocator, paths, home);
    try std.testing.expect(std.mem.endsWith(u8, cfg.database_path, "/x_bookmarks.sqlite"));
    try std.testing.expect(std.mem.endsWith(u8, cfg.token_path, "/oauth-token.json"));
    try std.testing.expect(std.mem.endsWith(u8, cfg.assets_dir, "/assets"));
    try std.testing.expect(std.mem.endsWith(u8, cfg.export_dir, "/viewer-export"));
}

test "config parser resolves relative paths against home override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const config_path = try std.fs.path.join(allocator, &.{ home, "config.json" });
    const config_json =
        \\{
        \\  "x": {
        \\    "client_id": "abc",
        \\    "client_secret": null,
        \\    "redirect_uri": "http://127.0.0.1:8765/callback",
        \\    "scopes": ["tweet.read", "users.read", "bookmark.read", "offline.access"]
        \\  },
        \\  "storage": {
        \\    "database_path": "db.sqlite",
        \\    "token_path": "token.json",
        \\    "assets_dir": "assets-local"
        \\  },
        \\  "sync": {
        \\    "max_results": 42,
        \\    "require_approval": false
        \\  },
        \\  "viewer": {
        \\    "export_dir": "viewer-local"
        \\  }
        \\}
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = config_path, .data = config_json });

    const paths = try resolvePaths(allocator, null, home);
    const cfg = try loadConfig(allocator, paths, home);
    try validateConfig(cfg);
    try std.testing.expectEqualStrings("abc", cfg.client_id);
    try std.testing.expectEqual(@as(u32, 42), cfg.max_results);
    try std.testing.expect(!cfg.require_approval);
    try std.testing.expect(std.mem.endsWith(u8, cfg.database_path, "/db.sqlite"));
    try std.testing.expect(std.mem.endsWith(u8, cfg.token_path, "/token.json"));
    try std.testing.expect(std.mem.endsWith(u8, cfg.assets_dir, "/assets-local"));
    try std.testing.expect(std.mem.endsWith(u8, cfg.export_dir, "/viewer-local"));
}

test "config parser rejects negative numeric config values without trapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const config_path = try std.fs.path.join(allocator, &.{ home, "config.json" });
    const config_json =
        \\{
        \\  "x": {"client_id": "abc", "redirect_uri": "http://127.0.0.1:8765/callback", "scopes": ["tweet.read", "users.read", "bookmark.read", "offline.access"]},
        \\  "sync": {"max_results": -1}
        \\}
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = config_path, .data = config_json });

    const paths = try resolvePaths(allocator, null, home);
    try std.testing.expectError(AppError.ConfigInvalid, loadConfig(allocator, paths, home));
}

test "config init substitutions are JSON escaped" {
    const allocator = std.testing.allocator;
    var text = try allocator.dupe(u8,
        \\{"x":{"client_id":"your-client-id","redirect_uri":"http://127.0.0.1:8765/callback"}}
    );
    const client_json = try jsonStringAlloc(allocator, "client\"with\\chars");
    defer allocator.free(client_json);
    text = try replaceOwned(allocator, text, "\"your-client-id\"", client_json);
    const redirect_json = try jsonStringAlloc(allocator, "http://127.0.0.1:8765/callback?x=\"y\"");
    defer allocator.free(redirect_json);
    text = try replaceOwned(allocator, text, "\"http://127.0.0.1:8765/callback\"", redirect_json);
    defer allocator.free(text);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const x = getObject(parsed.value, "x").?;
    try std.testing.expectEqualStrings("client\"with\\chars", getString(x, "client_id").?);
    try std.testing.expectEqualStrings("http://127.0.0.1:8765/callback?x=\"y\"", getString(x, "redirect_uri").?);
}

test "config template state paths can be rewritten to XDG data directory" {
    const allocator = std.testing.allocator;
    var text = try allocator.dupe(u8, config_template);
    text = try replaceTemplateStatePaths(allocator, text, "/tmp/xdg-data/x-bookmarks");
    defer allocator.free(text);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const storage = getObject(parsed.value, "storage").?;
    const viewer = getObject(parsed.value, "viewer").?;
    try std.testing.expectEqualStrings("/tmp/xdg-data/x-bookmarks/x_bookmarks.sqlite", getString(storage, "database_path").?);
    try std.testing.expectEqualStrings("/tmp/xdg-data/x-bookmarks/oauth-token.json", getString(storage, "token_path").?);
    try std.testing.expectEqualStrings("/tmp/xdg-data/x-bookmarks/assets", getString(storage, "assets_dir").?);
    try std.testing.expectEqualStrings("/tmp/xdg-data/x-bookmarks/viewer-export", getString(viewer, "export_dir").?);
}

test "embedded config template is valid and carries required defaults" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, config_template, .{});
    defer parsed.deinit();
    const x = getObject(parsed.value, "x").?;
    const sync = getObject(parsed.value, "sync").?;

    try std.testing.expectEqualStrings("your-client-id", getString(x, "client_id").?);
    try std.testing.expectEqualStrings("http://127.0.0.1:8765/callback", getString(x, "redirect_uri").?);
    const scopes = getArray(x, "scopes").?;
    try std.testing.expect(scopes.items.len == 4);
    try std.testing.expectEqual(@as(i64, 100), getInt(sync, "max_results").?);
    try std.testing.expect(getBool(sync, "require_approval").?);
    try std.testing.expect(getBool(sync, "stop_at_first_complete_bookmark").?);
}

test "committed config example matches embedded config template" {
    const allocator = std.testing.allocator;
    const example = try std.fs.cwd().readFileAlloc(allocator, "config.example.json", 1024 * 1024);
    defer allocator.free(example);
    try std.testing.expectEqualStrings(std.mem.trim(u8, example, " \t\r\n"), std.mem.trim(u8, config_template, " \t\r\n"));
}

test "config validation requires offline access scope for refreshable sync" {
    const cfg = Config{
        .client_id = "client",
        .client_secret = null,
        .redirect_uri = "http://127.0.0.1:8765/callback",
        .scopes = &.{ "tweet.read", "users.read", "bookmark.read" },
        .database_path = "db.sqlite",
        .token_path = "oauth-token.json",
        .assets_dir = "assets",
        .export_dir = "viewer-export",
        .obsidian_vault_path = null,
        .obsidian_root_dir = "X Bookmarks",
        .obsidian_export_mode = .timeline_only,
        .obsidian_timeline_dir = "timeline",
        .obsidian_note_dir = "bookmarks",
        .obsidian_asset_dir = "assets",
        .obsidian_index_dir = "indexes",
        .obsidian_data_dir = "data",
        .obsidian_preserve_user_notes = true,
        .media_policy = "images-only",
        .max_results = 100,
        .store_raw_pages = true,
        .download_media = true,
        .quote_post_depth = 1,
        .require_approval = true,
        .stop_at_first_complete_bookmark = true,
        .config_path = "config.json",
        .base_dir = ".",
        .home_override = null,
    };

    try std.testing.expectError(AppError.ConfigInvalid, validateConfig(cfg));
}

test "config validation rejects unsupported quote post depth" {
    var cfg = Config{
        .client_id = "client",
        .client_secret = null,
        .redirect_uri = "http://127.0.0.1:8765/callback",
        .scopes = &.{ "tweet.read", "users.read", "bookmark.read", "offline.access" },
        .database_path = "db.sqlite",
        .token_path = "oauth-token.json",
        .assets_dir = "assets",
        .export_dir = "viewer-export",
        .obsidian_vault_path = null,
        .obsidian_root_dir = "X Bookmarks",
        .obsidian_export_mode = .timeline_only,
        .obsidian_timeline_dir = "timeline",
        .obsidian_note_dir = "bookmarks",
        .obsidian_asset_dir = "assets",
        .obsidian_index_dir = "indexes",
        .obsidian_data_dir = "data",
        .obsidian_preserve_user_notes = true,
        .media_policy = "images-only",
        .max_results = 100,
        .store_raw_pages = true,
        .download_media = true,
        .quote_post_depth = 2,
        .require_approval = true,
        .stop_at_first_complete_bookmark = true,
        .config_path = "config.json",
        .base_dir = ".",
        .home_override = null,
    };

    try std.testing.expectError(AppError.ConfigInvalid, validateConfig(cfg));
    cfg.quote_post_depth = 1;
    try validateConfig(cfg);
}

test "sync CLI overrides mutate only per-run sync settings" {
    var cfg = Config{
        .client_id = "client",
        .client_secret = null,
        .redirect_uri = "http://127.0.0.1:8765/callback",
        .scopes = &.{ "tweet.read", "users.read", "bookmark.read", "offline.access" },
        .database_path = "db.sqlite",
        .token_path = "oauth-token.json",
        .assets_dir = "assets",
        .export_dir = "viewer-export",
        .obsidian_vault_path = null,
        .obsidian_root_dir = "X Bookmarks",
        .obsidian_export_mode = .timeline_only,
        .obsidian_timeline_dir = "timeline",
        .obsidian_note_dir = "bookmarks",
        .obsidian_asset_dir = "assets",
        .obsidian_index_dir = "indexes",
        .obsidian_data_dir = "data",
        .obsidian_preserve_user_notes = true,
        .media_policy = "images-only",
        .max_results = 100,
        .store_raw_pages = true,
        .download_media = true,
        .quote_post_depth = 1,
        .require_approval = true,
        .stop_at_first_complete_bookmark = true,
        .config_path = "config.json",
        .base_dir = ".",
        .home_override = null,
    };

    try applySyncCliOverrides(&cfg, 25, false);
    try validateConfig(cfg);
    try std.testing.expectEqual(@as(u32, 25), cfg.max_results);
    try std.testing.expect(!cfg.download_media);

    try std.testing.expectError(AppError.InvalidArguments, applySyncCliOverrides(&cfg, 0, null));
    try std.testing.expectError(AppError.InvalidArguments, applySyncCliOverrides(&cfg, 101, null));
}

test "auth URL encodes required OAuth PKCE parameters" {
    const allocator = std.testing.allocator;
    const url = try buildAuthUrl(allocator, "client id", "http://127.0.0.1:8765/callback", default_scopes, "state value", "challenge/value");
    defer allocator.free(url);

    try std.testing.expect(std.mem.indexOf(u8, url, "response_type=code") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "client_id=client%20id") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "scope=tweet.read%20users.read%20bookmark.read%20offline.access") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "state=state%20value") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge=challenge%2Fvalue") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
}

test "callback URL parser extracts and decodes OAuth code without logging callback" {
    const allocator = std.testing.allocator;
    const code = try codeFromCallbackUrl(allocator, "http://127.0.0.1:8765/callback?state=abc%201&xcode=wrong&code=a%2Fb%20c&ignored=1#fragment");
    defer allocator.free(code);
    const state = try callbackParamFromUrl(allocator, "http://127.0.0.1:8765/callback?state=abc%201&xcode=wrong&code=a%2Fb%20c&ignored=1#fragment", "state");
    defer allocator.free(state);

    try std.testing.expectEqualStrings("a/b c", code);
    try std.testing.expectEqualStrings("abc 1", state);
}

test "local OAuth redirect URI parser requires loopback http callback" {
    const allocator = std.testing.allocator;
    const redirect = try parseLocalHttpRedirectUri(allocator, "http://127.0.0.1:8765/callback?ignored=1");
    defer redirect.deinit(allocator);

    try std.testing.expectEqualStrings("127.0.0.1", redirect.host);
    try std.testing.expectEqual(@as(u16, 8765), redirect.port);
    try std.testing.expectEqualStrings("/callback", redirect.path);
    try std.testing.expectError(AppError.ConfigInvalid, parseLocalHttpRedirectUri(allocator, "https://127.0.0.1:8765/callback"));
    try std.testing.expectError(AppError.ConfigInvalid, parseLocalHttpRedirectUri(allocator, "http://example.com:8765/callback"));
}

test "callback state validation rejects mismatched OAuth state" {
    const allocator = std.testing.allocator;
    var pending = try std.json.parseFromSlice(std.json.Value, allocator, "{\"state\":\"expected-state\"}", .{});
    defer pending.deinit();

    try validateCallbackState(pending.value, "expected-state");
    try std.testing.expectError(AppError.AuthRequired, validateCallbackState(pending.value, "wrong-state"));
}

test "unique run directory names include prefix timestamp and random suffix" {
    const allocator = std.testing.allocator;
    const one = try uniqueRunDirectoryName(allocator, "live");
    defer allocator.free(one);
    const two = try uniqueRunDirectoryName(allocator, "live");
    defer allocator.free(two);

    try std.testing.expect(std.mem.startsWith(u8, one, "live-"));
    try std.testing.expect(std.mem.startsWith(u8, two, "live-"));
    try std.testing.expect(!std.mem.eql(u8, one, two));
}

test "private token file writes clamp existing file permissions" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "oauth-token.json" });
    defer allocator.free(path);
    try ensureParentDir(path);
    {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o644 });
        defer file.close();
        try file.writeAll("old");
    }

    try writePrivateFile(path, "secret");

    const stat = try std.fs.cwd().statFile(path);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), stat.mode & 0o777);
    const contents = try std.fs.cwd().readFileAlloc(allocator, path, 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("secret", contents);
}

test "documented application errors map to stable exit codes" {
    try std.testing.expectEqual(@as(u8, 2), exitCode(AppError.InvalidCommand));
    try std.testing.expectEqual(@as(u8, 2), exitCode(AppError.InvalidArguments));
    try std.testing.expectEqual(@as(u8, 3), exitCode(AppError.MissingHome));
    try std.testing.expectEqual(@as(u8, 3), exitCode(AppError.MissingConfig));
    try std.testing.expectEqual(@as(u8, 3), exitCode(AppError.ConfigInvalid));
    try std.testing.expectEqual(@as(u8, 3), exitCode(AppError.ConfigExists));
    try std.testing.expectEqual(@as(u8, 4), exitCode(AppError.AuthRequired));
    try std.testing.expectEqual(@as(u8, 5), exitCode(AppError.RateLimited));
    try std.testing.expectEqual(@as(u8, 6), exitCode(AppError.HttpError));
    try std.testing.expectEqual(@as(u8, 7), exitCode(AppError.SqliteError));
}

test "rate limit wait helper only waits for future reset when enabled" {
    const response = HttpResponse{
        .status = .too_many_requests,
        .body = @constCast(""),
        .rate_limit_reset = 110,
    };
    try std.testing.expectEqual(@as(?i64, 10), rateLimitWaitSeconds(response, true, 100));
    try std.testing.expect(rateLimitWaitSeconds(response, false, 100) == null);
    try std.testing.expect(rateLimitWaitSeconds(response, true, 110) == null);
    try std.testing.expect(rateLimitWaitSeconds(.{
        .status = .too_many_requests,
        .body = @constCast(""),
        .rate_limit_reset = null,
    }, true, 100) == null);
}

test "numeric CLI argument parsing maps malformed values to invalid arguments" {
    try std.testing.expectEqual(@as(u32, 42), try parseU32Arg("42"));
    try std.testing.expectError(AppError.InvalidArguments, parseU32Arg("not-a-number"));
    try std.testing.expectError(AppError.InvalidArguments, parseU32Arg("-1"));
}

test "viewer server parses request paths and content types for exported assets" {
    try std.testing.expectEqualStrings("/data/bookmarks.json", parseHttpPath("GET /data/bookmarks.json?cache=1 HTTP/1.1\r\n").?);
    try std.testing.expectEqualStrings("/callback?code=abc&state=xyz", parseHttpTarget("GET /callback?code=abc&state=xyz HTTP/1.1\r\n").?);
    try std.testing.expectEqualStrings("/assets/media/movie.mp4", parseHttpPath("HEAD /assets/media/movie.mp4 HTTP/1.1\r\n").?);
    try std.testing.expectEqualStrings("/assets/media/photo.webp", parseHttpPath("GET /assets/media/photo.webp#ignored HTTP/1.1\r\n").?);
    try std.testing.expectEqualStrings("application/json", contentType("bookmarks.json"));
    try std.testing.expectEqualStrings("image/webp", contentType("photo.webp"));
    try std.testing.expectEqualStrings("video/mp4", contentType("clip.mp4"));
}

test "viewer server parses byte range headers for video playback" {
    const range = (try parseRangeHeader("GET /clip.mp4 HTTP/1.1\r\nRange: bytes=10-19\r\n\r\n", 100)).?;
    try std.testing.expectEqual(@as(u64, 10), range.start);
    try std.testing.expectEqual(@as(u64, 19), range.end);

    const open_range = (try parseRangeHeader("GET /clip.mp4 HTTP/1.1\r\nRange: bytes=95-\r\n\r\n", 100)).?;
    try std.testing.expectEqual(@as(u64, 95), open_range.start);
    try std.testing.expectEqual(@as(u64, 99), open_range.end);

    const suffix_range = (try parseRangeHeader("GET /clip.mp4 HTTP/1.1\r\nrange: bytes=-12\r\n\r\n", 100)).?;
    try std.testing.expectEqual(@as(u64, 88), suffix_range.start);
    try std.testing.expectEqual(@as(u64, 99), suffix_range.end);

    try std.testing.expectError(error.InvalidRange, parseRangeHeader("GET /clip.mp4 HTTP/1.1\r\nRange: bytes=150-160\r\n\r\n", 100));
}

test "migrations are idempotent and create expected tables" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "migrations.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();

    try applyMigrations(&db);
    try applyMigrations(&db);

    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM schema_migrations WHERE version = '001_initial'"));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'sync_warnings'"));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'bookmark_folder_items'"));
}

test "database opens with a busy timeout for agent command overlap" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "busy-timeout.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();

    const stmt = try db.prepare("PRAGMA busy_timeout");
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(c_int, 5000), c.sqlite3_column_int(stmt, 0));
}

test "account upsert sets created timestamp and preserves it on update" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "accounts.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    try upsertAccount(&db, allocator, "acct", "alice", "Alice", "{\"id\":\"acct\"}");
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM accounts WHERE user_id = 'acct' AND created_at IS NOT NULL AND updated_at IS NOT NULL"));
    try db.exec("UPDATE accounts SET created_at = 'first-created', updated_at = 'first-updated' WHERE user_id = 'acct'");
    try upsertAccount(&db, allocator, "acct", "alice2", "Alice 2", "{\"id\":\"acct\",\"username\":\"alice2\"}");
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM accounts WHERE user_id = 'acct' AND username = 'alice2' AND created_at = 'first-created' AND updated_at <> 'first-updated'"));
}

test "token observations persist refresh metadata without storing token secrets" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "token-observation.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    const cfg = Config{
        .client_id = "client",
        .client_secret = null,
        .redirect_uri = "http://127.0.0.1:8765/callback",
        .scopes = &.{ "tweet.read", "users.read", "bookmark.read", "offline.access" },
        .database_path = db_path,
        .token_path = "/tmp/oauth-token.json",
        .assets_dir = ".",
        .export_dir = ".",
        .obsidian_vault_path = null,
        .obsidian_root_dir = "X Bookmarks",
        .obsidian_export_mode = .timeline_only,
        .obsidian_timeline_dir = "timeline",
        .obsidian_note_dir = "bookmarks",
        .obsidian_asset_dir = "assets",
        .obsidian_index_dir = "indexes",
        .obsidian_data_dir = "data",
        .obsidian_preserve_user_notes = true,
        .media_policy = "images-only",
        .max_results = 100,
        .store_raw_pages = true,
        .download_media = true,
        .quote_post_depth = 1,
        .require_approval = true,
        .stop_at_first_complete_bookmark = true,
        .config_path = "config.json",
        .base_dir = ".",
        .home_override = null,
    };
    try upsertTokenObservationFromState(&db, allocator, cfg, "acct", .{
        .access_token = "secret-access",
        .refresh_token = "secret-refresh",
        .token_type = "bearer",
        .scope = "tweet.read users.read bookmark.read offline.access",
        .expires_at = 1234,
        .account_user_id = "acct",
    });

    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM oauth_token_observations WHERE account_user_id = 'acct' AND token_type = 'bearer' AND expires_at = '1234'"));
    try std.testing.expectEqual(@as(i64, 0), try scalarCount(&db, "SELECT count(*) FROM oauth_token_observations WHERE scope LIKE '%secret%' OR token_file_path LIKE '%secret%'"));
}

test "loadToken returns owned token strings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const token_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "oauth-token.json" });
    defer allocator.free(token_path);
    const token_json =
        \\{
        \\  "access_token": "access-123",
        \\  "refresh_token": "refresh-123",
        \\  "token_type": "bearer",
        \\  "scope": "tweet.read users.read bookmark.read offline.access",
        \\  "expires_at": 123456,
        \\  "account_user_id": "acct-123"
        \\}
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = token_path, .data = token_json });

    const token = try loadToken(allocator, token_path);
    defer token.deinit(allocator);

    try std.testing.expectEqualStrings("access-123", token.access_token);
    try std.testing.expectEqualStrings("refresh-123", token.refresh_token.?);
    try std.testing.expectEqualStrings("bearer", token.token_type.?);
    try std.testing.expectEqualStrings("tweet.read users.read bookmark.read offline.access", token.scope.?);
    try std.testing.expectEqual(@as(?i64, 123456), token.expires_at);
    try std.testing.expectEqualStrings("acct-123", token.account_user_id.?);
}

test "empty account id is treated as missing token account metadata" {
    try std.testing.expect(nonEmptyOptional(null) == null);
    try std.testing.expect(nonEmptyOptional("") == null);
    try std.testing.expectEqualStrings("acct", nonEmptyOptional("acct").?);
}

test "optional JSON string helper preserves null instead of empty account id" {
    const allocator = std.testing.allocator;
    const missing = try optionalJsonStringAlloc(allocator, null);
    defer allocator.free(missing);
    const present = try optionalJsonStringAlloc(allocator, "acct");
    defer allocator.free(present);

    try std.testing.expectEqualStrings("null", missing);
    try std.testing.expectEqualStrings("\"acct\"", present);
}

test "canonical URI uses username when available and fallback otherwise" {
    const allocator = std.testing.allocator;
    const with_user = try canonicalUri(allocator, "alice", "123");
    defer allocator.free(with_user);
    const fallback = try canonicalUri(allocator, null, "123");
    defer allocator.free(fallback);

    try std.testing.expectEqualStrings("https://x.com/alice/status/123", with_user);
    try std.testing.expectEqualStrings("https://x.com/i/web/status/123", fallback);
}

test "tweet media upsert replaces stale attachment relationships" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "tweet-media-replace.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var first = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"tm1","text":"with media","attachments":{"media_keys":["old_media","new_media"]}}
    , .{});
    defer first.deinit();
    try upsertTweetFromValue(&db, allocator, first.value);
    try std.testing.expectEqual(@as(i64, 2), try scalarCount(&db, "SELECT count(*) FROM tweet_media WHERE tweet_id = 'tm1'"));

    var second = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"tm1","text":"updated media","attachments":{"media_keys":["new_media"]}}
    , .{});
    defer second.deinit();
    try upsertTweetFromValue(&db, allocator, second.value);
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM tweet_media WHERE tweet_id = 'tm1' AND media_key = 'new_media'"));
    try std.testing.expectEqual(@as(i64, 0), try scalarCount(&db, "SELECT count(*) FROM tweet_media WHERE tweet_id = 'tm1' AND media_key = 'old_media'"));

    var third = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"tm1","text":"no media"}
    , .{});
    defer third.deinit();
    try upsertTweetFromValue(&db, allocator, third.value);
    try std.testing.expectEqual(@as(i64, 0), try scalarCount(&db, "SELECT count(*) FROM tweet_media WHERE tweet_id = 'tm1'"));
}

test "video variant selection chooses preview-sized mp4" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\[
        \\  {"content_type":"application/x-mpegURL","url":"https://example.invalid/playlist.m3u8"},
        \\  {"content_type":"video/mp4","url":"https://example.invalid/low.mp4","bit_rate":256000},
        \\  {"content_type":"video/mp4","url":"https://example.invalid/preview.mp4","bit_rate":2176000},
        \\  {"content_type":"video/mp4","url":"https://example.invalid/huge.mp4","bit_rate":25128000}
        \\]
    , .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://example.invalid/preview.mp4", selectVideoVariant(parsed.value.array).?);
}

test "video variant selection falls back to smallest mp4 when all are above preview size" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\[
        \\  {"content_type":"video/mp4","url":"https://example.invalid/large.mp4","bit_rate":8000000},
        \\  {"content_type":"video/mp4","url":"https://example.invalid/larger.mp4","bit_rate":12000000}
        \\]
    , .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://example.invalid/large.mp4", selectVideoVariant(parsed.value.array).?);
}

test "bookmark request metadata records concrete query field lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const paths = try resolvePaths(allocator, null, home);
    const cfg = try Config.default(allocator, paths, home);
    const request_json = try syncRequestJson(allocator, cfg, false, true, 2);

    try std.testing.expect(std.mem.indexOf(u8, request_json, "\"endpoint\":\"GET /2/users/:id/bookmarks\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request_json, "\"tweet.fields\":\"id,text,author_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, request_json, "\"expansions\":\"author_id,attachments.media_keys") != null);
    try std.testing.expect(std.mem.indexOf(u8, request_json, "\"media.fields\":\"media_key,type,url,preview_image_url") != null);
    try std.testing.expect(std.mem.indexOf(u8, request_json, "\"folder_request_shape\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request_json, "\"folders_endpoint\":\"GET /2/users/:id/bookmarks/folders\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request_json, "\"folder_items_endpoint\":\"GET /2/users/:id/bookmarks/folders/:folder_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request_json, "\"limit_pages\":2") != null);
}

test "bookmark URL uses stable fields and URL-encoded pagination token" {
    const allocator = std.testing.allocator;
    const url = try buildBookmarksUrl(allocator, "123", 100, "next token/1");
    defer allocator.free(url);

    try std.testing.expect(std.mem.indexOf(u8, url, "/2/users/123/bookmarks?max_results=100") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "tweet.fields=id,text,author_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "expansions=author_id,attachments.media_keys") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "user.fields=id,name,username") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "media.fields=media_key,type,url,preview_image_url") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "poll.fields=id,options,duration_minutes") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "pagination_token=next%20token%2F1") != null);
}

test "bookmark folders URL carries URL-encoded pagination token" {
    const allocator = std.testing.allocator;
    const first = try buildBookmarkFoldersUrl(allocator, "123", null);
    defer allocator.free(first);
    const next = try buildBookmarkFoldersUrl(allocator, "123", "folder page/1");
    defer allocator.free(next);

    try std.testing.expectEqualStrings(x_api_base ++ "/users/123/bookmarks/folders", first);
    try std.testing.expect(std.mem.indexOf(u8, next, "pagination_token=folder%20page%2F1") != null);
}

test "bookmark folder items URL uses documented endpoint with URL-encoded pagination token" {
    const allocator = std.testing.allocator;
    const first = try buildBookmarkFolderItemsUrl(allocator, "123", "folder%201", null);
    defer allocator.free(first);
    const next = try buildBookmarkFolderItemsUrl(allocator, "123", "folder%201", "item page/1");
    defer allocator.free(next);

    try std.testing.expectEqualStrings(x_api_base ++ "/users/123/bookmarks/folders/folder%201", first);
    try std.testing.expect(std.mem.indexOf(u8, next, "pagination_token=item%20page%2F1") != null);
}

test "fixture ingestion stores quote media folders and export metadata" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "fixture.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    const fixture = try std.fs.cwd().readFileAlloc(allocator, "tests/fixtures/bookmark-page-with-quote-media.json", 1024 * 1024);
    defer allocator.free(fixture);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, fixture, .{});
    defer parsed.deinit();

    const account = "acct";
    const run_id = try createSyncRun(&db, account, "fixture", "{\"fixture\":true}", allocator);
    try insertRawPage(&db, allocator, run_id, 1, null, null, 1, fixture);
    try ingestIncludes(&db, allocator, parsed.value);
    const tweets = getArray(parsed.value, "data").?;
    for (tweets.items, 0..) |tweet, idx| {
        try upsertTweetFromValue(&db, allocator, tweet);
        const tweet_id = getString(tweet, "id").?;
        try recordMediaAsset(&db, allocator, "3_abc", "image", "https://example.invalid/photo.jpg", "/missing/photo.jpg", "image/jpeg", 12, "0000", 1200, 800, "failed", "{\"error\":\"fixture\"}");
        try recordMediaAsset(&db, allocator, "3_quote", "image", "https://example.invalid/quote.jpg", "/tmp/quote.jpg", "image/jpeg", 12, "1111", 900, 600, "downloaded", null);
        const complete = try bookmarkCompleteForOfflineRender(&db, allocator, tweet_id);
        _ = try upsertBookmarkItem(&db, allocator, account, tweet_id, run_id, @intCast(idx), complete);
    }
    var folder_parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"folder-1\",\"name\":\"Reading\"}", .{});
    defer folder_parsed.deinit();
    try upsertFolderFromValue(&db, allocator, account, folder_parsed.value);
    try upsertFolderItem(&db, allocator, account, "folder-1", "100");

    try std.testing.expectEqual(@as(i64, 2), try scalarCount(&db, "SELECT count(*) FROM tweets"));
    try std.testing.expectEqual(@as(i64, 2), try scalarCount(&db, "SELECT count(*) FROM users"));
    try std.testing.expectEqual(@as(i64, 2), try scalarCount(&db, "SELECT count(*) FROM media"));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM bookmark_items WHERE complete_for_offline_render = 0"));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM bookmark_folder_items"));
    try std.testing.expectEqual(@as(i64, 0), try scalarCount(&db, "SELECT count(*) FROM missing_references"));

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try exportJsonl(&db, allocator, out.writer(allocator));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"canonical_uri\":\"https://x.com/alice/status/100\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"twitter_uri\":\"https://twitter.com/i/web/status/100\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"folder_ids\":[\"folder-1\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"folders\":[{\"folder_id\":\"folder-1\",\"name\":\"Reading\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"quote_posts\":[{\"tweet_id\":\"200\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"local_asset_paths\":[\"/tmp/quote.jpg\"]") != null);
}

test "bookmark page ingestion can be committed as a single page transaction" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "page-transaction.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    const fixture = try std.fs.cwd().readFileAlloc(allocator, "tests/fixtures/bookmark-page-with-quote-media.json", 1024 * 1024);
    defer allocator.free(fixture);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, fixture, .{});
    defer parsed.deinit();

    const cfg = Config{
        .client_id = "client",
        .client_secret = null,
        .redirect_uri = "http://127.0.0.1:8765/callback",
        .scopes = &.{ "tweet.read", "users.read", "bookmark.read", "offline.access" },
        .database_path = db_path,
        .token_path = "token.json",
        .assets_dir = ".",
        .export_dir = ".",
        .obsidian_vault_path = null,
        .obsidian_root_dir = "X Bookmarks",
        .obsidian_export_mode = .timeline_only,
        .obsidian_timeline_dir = "timeline",
        .obsidian_note_dir = "bookmarks",
        .obsidian_asset_dir = "assets",
        .obsidian_index_dir = "indexes",
        .obsidian_data_dir = "data",
        .obsidian_preserve_user_notes = true,
        .media_policy = "images-only",
        .max_results = 100,
        .store_raw_pages = true,
        .download_media = true,
        .quote_post_depth = 1,
        .require_approval = true,
        .stop_at_first_complete_bookmark = true,
        .config_path = "config.json",
        .base_dir = ".",
        .home_override = null,
    };
    const run_id = try createSyncRun(&db, "acct", "fixture", "{}", allocator);
    var result = SyncResult{};
    try beginTransaction(&db);
    try ingestBookmarkPage(&db, allocator, cfg, "acct", run_id, false, 1, null, null, 1, fixture, parsed.value, &result);
    try commitTransaction(&db);

    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM raw_pages"));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM bookmark_items"));
    try std.testing.expectEqual(@as(u32, 1), result.tweets);
}

test "empty bookmark page stores raw page without bookmark rows" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "empty-page.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    const body =
        \\{"data":[],"meta":{"result_count":0}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const cfg = Config{
        .client_id = "client",
        .client_secret = null,
        .redirect_uri = "http://127.0.0.1:8765/callback",
        .scopes = &.{ "tweet.read", "users.read", "bookmark.read", "offline.access" },
        .database_path = db_path,
        .token_path = "token.json",
        .assets_dir = ".",
        .export_dir = ".",
        .obsidian_vault_path = null,
        .obsidian_root_dir = "X Bookmarks",
        .obsidian_export_mode = .timeline_only,
        .obsidian_timeline_dir = "timeline",
        .obsidian_note_dir = "bookmarks",
        .obsidian_asset_dir = "assets",
        .obsidian_index_dir = "indexes",
        .obsidian_data_dir = "data",
        .obsidian_preserve_user_notes = true,
        .media_policy = "images-only",
        .max_results = 100,
        .store_raw_pages = true,
        .download_media = true,
        .quote_post_depth = 1,
        .require_approval = true,
        .stop_at_first_complete_bookmark = true,
        .config_path = "config.json",
        .base_dir = ".",
        .home_override = null,
    };
    const run_id = try createSyncRun(&db, "acct", "fixture", "{}", allocator);
    var result = SyncResult{};
    try beginTransaction(&db);
    try ingestBookmarkPage(&db, allocator, cfg, "acct", run_id, false, 1, null, null, 0, body, parsed.value, &result);
    try commitTransaction(&db);

    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM raw_pages WHERE result_count = 0"));
    try std.testing.expectEqual(@as(i64, 0), try scalarCount(&db, "SELECT count(*) FROM bookmark_items"));
    try std.testing.expectEqual(@as(u32, 0), result.tweets);
}

test "incremental page ingestion stops at first complete bookmark" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "early-stop.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    _ = try upsertBookmarkItem(&db, allocator, "acct", "600", 1, 0, true);
    const body =
        \\{"data":[{"id":"600","text":"already complete"},{"id":"601","text":"new after complete"}],"meta":{"result_count":2}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const cfg = Config{
        .client_id = "client",
        .client_secret = null,
        .redirect_uri = "http://127.0.0.1:8765/callback",
        .scopes = &.{ "tweet.read", "users.read", "bookmark.read", "offline.access" },
        .database_path = db_path,
        .token_path = "token.json",
        .assets_dir = ".",
        .export_dir = ".",
        .obsidian_vault_path = null,
        .obsidian_root_dir = "X Bookmarks",
        .obsidian_export_mode = .timeline_only,
        .obsidian_timeline_dir = "timeline",
        .obsidian_note_dir = "bookmarks",
        .obsidian_asset_dir = "assets",
        .obsidian_index_dir = "indexes",
        .obsidian_data_dir = "data",
        .obsidian_preserve_user_notes = true,
        .media_policy = "images-only",
        .max_results = 100,
        .store_raw_pages = true,
        .download_media = true,
        .quote_post_depth = 1,
        .require_approval = true,
        .stop_at_first_complete_bookmark = true,
        .config_path = "config.json",
        .base_dir = ".",
        .home_override = null,
    };
    const run_id = try createSyncRun(&db, "acct", "incremental", "{}", allocator);
    var result = SyncResult{};
    defer if (result.early_stop_tweet_id) |value| allocator.free(value);
    try beginTransaction(&db);
    try ingestBookmarkPage(&db, allocator, cfg, "acct", run_id, false, 1, null, null, 2, body, parsed.value, &result);
    try commitTransaction(&db);

    try std.testing.expect(result.early_stop_used);
    try std.testing.expectEqualStrings("600", result.early_stop_tweet_id.?);
    try std.testing.expectEqual(@as(u32, 0), result.tweets);
    try std.testing.expectEqual(@as(i64, 0), try scalarCount(&db, "SELECT count(*) FROM bookmark_items WHERE tweet_id = '601'"));
}

test "partial response with errors and data still ingests available bookmark data" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "partial-errors.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    const body =
        \\{
        \\  "data": [{"id":"500","author_id":"5","text":"available despite errors"}],
        \\  "includes": {"users": [{"id":"5","username":"erin","name":"Erin"}]},
        \\  "errors": [{"title":"Not Found Error","detail":"one expanded object was unavailable"}],
        \\  "meta": {"result_count":1}
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const cfg = Config{
        .client_id = "client",
        .client_secret = null,
        .redirect_uri = "http://127.0.0.1:8765/callback",
        .scopes = &.{ "tweet.read", "users.read", "bookmark.read", "offline.access" },
        .database_path = db_path,
        .token_path = "token.json",
        .assets_dir = ".",
        .export_dir = ".",
        .obsidian_vault_path = null,
        .obsidian_root_dir = "X Bookmarks",
        .obsidian_export_mode = .timeline_only,
        .obsidian_timeline_dir = "timeline",
        .obsidian_note_dir = "bookmarks",
        .obsidian_asset_dir = "assets",
        .obsidian_index_dir = "indexes",
        .obsidian_data_dir = "data",
        .obsidian_preserve_user_notes = true,
        .media_policy = "images-only",
        .max_results = 100,
        .store_raw_pages = true,
        .download_media = true,
        .quote_post_depth = 1,
        .require_approval = true,
        .stop_at_first_complete_bookmark = true,
        .config_path = "config.json",
        .base_dir = ".",
        .home_override = null,
    };
    const run_id = try createSyncRun(&db, "acct", "fixture", "{}", allocator);
    var result = SyncResult{};
    try beginTransaction(&db);
    try ingestBookmarkPage(&db, allocator, cfg, "acct", run_id, false, 1, null, null, 1, body, parsed.value, &result);
    try commitTransaction(&db);

    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM bookmark_items WHERE tweet_id = '500' AND complete_for_offline_render = 1"));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM raw_pages WHERE response_json LIKE '%Not Found Error%'"));
    try std.testing.expectEqual(@as(u32, 1), result.tweets);
}

test "page transaction rollback removes media asset and bookmark writes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "page-rollback.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    try beginTransaction(&db);
    try recordMediaAsset(&db, allocator, "m1", "image", "https://example.invalid/a.jpg", "/tmp/a.jpg", "image/jpeg", 1, null, null, null, "downloaded", null);
    _ = try upsertBookmarkItem(&db, allocator, "acct", "tweet", 1, 0, true);
    try rollbackTransaction(&db);

    try std.testing.expectEqual(@as(i64, 0), try scalarCount(&db, "SELECT count(*) FROM media_assets"));
    try std.testing.expectEqual(@as(i64, 0), try scalarCount(&db, "SELECT count(*) FROM bookmark_items"));
}

test "full sync deactivates bookmarks not seen in the run" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "full.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    _ = try upsertBookmarkItem(&db, allocator, "acct", "old", 999, 0, true);
    _ = try upsertBookmarkItem(&db, allocator, "acct", "seen", 999, 1, true);

    const run_id = try createSyncRun(&db, "acct", "full", "{}", allocator);
    _ = try upsertBookmarkItem(&db, allocator, "acct", "seen", run_id, 0, true);
    try markBookmarksInactiveNotSeen(&db, "acct", run_id);

    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM bookmark_items WHERE active = 1"));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM bookmark_items WHERE active = 0 AND tweet_id = 'old'"));
}

test "limited full sync does not deactivate bookmarks outside the limited scan" {
    try std.testing.expect(shouldDeactivateMissingAfterSync(true, null));
    try std.testing.expect(!shouldDeactivateMissingAfterSync(true, 1));
    try std.testing.expect(!shouldDeactivateMissingAfterSync(false, null));
}

test "missing quoted post references are recorded" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "missing.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"101","author_id":"1","text":"quote missing","referenced_tweets":[{"type":"quoted","id":"999"}]}
    , .{});
    defer parsed.deinit();
    try upsertTweetFromValue(&db, allocator, parsed.value);
    try recordMissingQuoteReferences(&db, allocator, parsed.value, parsed.value);

    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM missing_references WHERE tweet_id = '101' AND referenced_tweet_id = '999'"));
}

test "timeline-only obsidian export writes only timeline index and summary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_rel = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const base = try absolutize(allocator, base_rel);
    const db_path = try std.fs.path.join(allocator, &.{ base, "obsidian-timeline.sqlite" });
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var user = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"1\",\"username\":\"alice\",\"name\":\"Alice\"}", .{});
    defer user.deinit();
    try upsertUserFromValue(&db, allocator, user.value);
    var tweet = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"100","author_id":"1","text":"timeline text should not be exported","created_at":"2026-05-07T10:11:12.000Z"}
    , .{});
    defer tweet.deinit();
    try upsertTweetFromValue(&db, allocator, tweet.value);
    const run_id = try createSyncRun(&db, "acct", "fixture", "{}", allocator);
    _ = try upsertBookmarkItem(&db, allocator, "acct", "100", run_id, 0, true);

    const config_paths = try resolvePaths(allocator, null, base);
    var cfg = try Config.default(allocator, config_paths, base);
    const vault = try std.fs.path.join(allocator, &.{ base, "Vault" });
    cfg.obsidian_vault_path = vault;

    var stats = try obsidianExportTimelineOnly(&db, allocator, cfg, .{});
    try std.testing.expectEqual(@as(u32, 1), stats.months_total);
    try std.testing.expectEqual(@as(u32, 1), stats.months_written);
    try std.testing.expect(stats.index_written);
    try std.testing.expect(stats.summary_written);

    const root = try std.fs.path.join(allocator, &.{ vault, "X Bookmarks" });
    const month_path = try std.fs.path.join(allocator, &.{ root, "timeline", "2026", "2026-05.md" });
    const month = try std.fs.cwd().readFileAlloc(allocator, month_path, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, month, "# 2026-05") != null);
    try std.testing.expect(std.mem.indexOf(u8, month, "## 2026-05-07") != null);
    try std.testing.expect(std.mem.indexOf(u8, month, "![](https://x.com/alice/status/100)") != null);
    try std.testing.expect(std.mem.indexOf(u8, month, "timeline text should not be exported") == null);

    const timeline_index = try std.fs.path.join(allocator, &.{ root, "indexes", "timeline.md" });
    const summary = try std.fs.path.join(allocator, &.{ root, "data", "export-summary.json" });
    try std.testing.expect(fileExists(timeline_index));
    try std.testing.expect(fileExists(summary));
    try std.testing.expect(!fileExists(try std.fs.path.join(allocator, &.{ root, "bookmarks", "100.md" })));
    try std.testing.expect(!fileExists(try std.fs.path.join(allocator, &.{ root, "assets" })));
    try std.testing.expect(!fileExists(try std.fs.path.join(allocator, &.{ root, "indexes", "all-bookmarks.md" })));
    try std.testing.expect(!fileExists(try std.fs.path.join(allocator, &.{ root, "data", "bookmarks-index.json" })));
    try std.testing.expect(!fileExists(try std.fs.path.join(allocator, &.{ root, "data", "media-assets-index.json" })));

    stats = try obsidianExportTimelineOnly(&db, allocator, cfg, .{ .changed_only = true });
    try std.testing.expectEqual(@as(u32, 0), stats.months_written);
    try std.testing.expectEqual(@as(u32, 1), stats.months_skipped);
    try std.testing.expect(!stats.index_written);
    try std.testing.expect(!stats.summary_written);
}

test "full obsidian export is explicit and writes notes assets and diagnostic indexes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_rel = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const base = try absolutize(allocator, base_rel);
    const db_path = try std.fs.path.join(allocator, &.{ base, "obsidian-full.sqlite" });
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var user = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"2\",\"username\":\"bob\",\"name\":\"Bob\"}", .{});
    defer user.deinit();
    try upsertUserFromValue(&db, allocator, user.value);
    var tweet = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"200","author_id":"2","text":"full export text","created_at":"2026-06-01T01:02:03.000Z"}
    , .{});
    defer tweet.deinit();
    try upsertTweetFromValue(&db, allocator, tweet.value);
    const run_id = try createSyncRun(&db, "acct", "fixture", "{}", allocator);
    _ = try upsertBookmarkItem(&db, allocator, "acct", "200", run_id, 0, true);

    const source_asset = try std.fs.path.join(allocator, &.{ base, "assets", "photo.jpg" });
    try ensureParentDir(source_asset);
    try std.fs.cwd().writeFile(.{ .sub_path = source_asset, .data = "image bytes" });
    try recordMediaAsset(&db, allocator, "3_full", "image", "https://example.invalid/photo.jpg", source_asset, "image/jpeg", 11, null, null, null, "downloaded", null);

    const config_paths = try resolvePaths(allocator, null, base);
    var cfg = try Config.default(allocator, config_paths, base);
    const vault = try std.fs.path.join(allocator, &.{ base, "Vault" });
    cfg.obsidian_vault_path = vault;
    cfg.assets_dir = try std.fs.path.join(allocator, &.{ base, "assets" });

    try obsidianExport(&db, allocator, cfg, .{ .mode_override = .full });

    const root = try std.fs.path.join(allocator, &.{ vault, "X Bookmarks" });
    try std.testing.expect(fileExists(try std.fs.path.join(allocator, &.{ root, "timeline", "2026", "2026-06.md" })));
    const note_path = try std.fs.path.join(allocator, &.{ root, "bookmarks", "200.md" });
    try std.testing.expect(fileExists(note_path));
    const note = try std.fs.cwd().readFileAlloc(allocator, note_path, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, note, "![](https://x.com/bob/status/200)") != null);
    try std.testing.expect(fileExists(try std.fs.path.join(allocator, &.{ root, "assets", "images", "3_full-unhashed.jpg" })));
    try std.testing.expect(fileExists(try std.fs.path.join(allocator, &.{ root, "indexes", "all-bookmarks.md" })));
    try std.testing.expect(fileExists(try std.fs.path.join(allocator, &.{ root, "indexes", "failed-assets.md" })));
    try std.testing.expect(fileExists(try std.fs.path.join(allocator, &.{ root, "data", "bookmarks-index.json" })));
    try std.testing.expect(fileExists(try std.fs.path.join(allocator, &.{ root, "data", "media-assets-index.json" })));
}

test "kb init and raw X export create agent-ingestable raw inbox" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_rel = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const base = try absolutize(allocator, base_rel);
    const db_path = try std.fs.path.join(allocator, &.{ base, "kb.sqlite" });
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var user = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"1\",\"username\":\"alice\",\"name\":\"Alice\"}", .{});
    defer user.deinit();
    try upsertUserFromValue(&db, allocator, user.value);
    var quote_user = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"2\",\"username\":\"bob\",\"name\":\"Bob\"}", .{});
    defer quote_user.deinit();
    try upsertUserFromValue(&db, allocator, quote_user.value);
    var media = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"media_key":"3_kb","type":"photo","url":"https://example.invalid/photo.jpg","alt_text":"fixture photo"}
    , .{});
    defer media.deinit();
    try upsertMediaFromValue(&db, allocator, media.value);
    var quote = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"901","author_id":"2","text":"Quoted idea","created_at":"2026-05-10T10:00:00.000Z"}
    , .{});
    defer quote.deinit();
    try upsertTweetFromValue(&db, allocator, quote.value);
    var tweet = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"900","author_id":"1","text":"Short text https://t.co/a","created_at":"2026-05-11T12:00:00.000Z","attachments":{"media_keys":["3_kb"]},"referenced_tweets":[{"type":"quoted","id":"901"}],"entities":{"urls":[{"url":"https://t.co/a","expanded_url":"https://example.invalid/article"}]},"note_tweet":{"text":"Expanded long text","entities":{"urls":[{"url":"https://t.co/b","expanded_url":"https://example.invalid/deeper"}]}}}
    , .{});
    defer tweet.deinit();
    try upsertTweetFromValue(&db, allocator, tweet.value);
    const run_id = try createSyncRun(&db, "acct", "fixture", "{}", allocator);
    _ = try upsertBookmarkItem(&db, allocator, "acct", "900", run_id, 0, true);
    var folder = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"folder-1\",\"name\":\"Reading\"}", .{});
    defer folder.deinit();
    try upsertFolderFromValue(&db, allocator, "acct", folder.value);
    try upsertFolderItem(&db, allocator, "acct", "folder-1", "900");
    try recordMediaAsset(&db, allocator, "3_kb", "image", "https://example.invalid/photo.jpg", "/tmp/photo.jpg", "image/jpeg", 12, null, null, null, "downloaded", null);

    const config_paths = try resolvePaths(allocator, null, base);
    var cfg = try Config.default(allocator, config_paths, base);
    const vault = try std.fs.path.join(allocator, &.{ base, "Vault" });
    cfg.obsidian_vault_path = vault;
    var paths = try resolveObsidianPaths(allocator, cfg, null);
    defer paths.deinit(allocator);

    try kbInit(allocator, paths);
    var stats = try kbExportRawX(&db, allocator, paths, true);
    try std.testing.expectEqual(@as(u32, 1), stats.total);
    try std.testing.expectEqual(@as(u32, 1), stats.written);
    try std.testing.expectEqual(@as(u32, 0), stats.skipped_unchanged);

    const raw_path = try std.fs.path.join(allocator, &.{ paths.root, "raw", "x", "inbox", "900.md" });
    const raw = try std.fs.cwd().readFileAlloc(allocator, raw_path, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, raw, "source_type: \"x_bookmark\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "status: \"inbox\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "![](https://x.com/alice/status/900)") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Expanded long text") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "- Has external link(s).") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "- Quote-post present.") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "- Foldered bookmark.") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "- Extracted URL: https://example.invalid/article") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "- Quoted @bob: Quoted idea") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "`/tmp/photo.jpg`") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "## Raw Metadata") != null);
    try std.testing.expect(fileExists(try std.fs.path.join(allocator, &.{ paths.root, "wiki", "schema.md" })));
    try std.testing.expect(fileExists(try std.fs.path.join(allocator, &.{ paths.root, "wiki", "index.md" })));
    try std.testing.expect(fileExists(try std.fs.path.join(allocator, &.{ paths.root, "wiki", "log.md" })));

    stats = try kbExportRawX(&db, allocator, paths, true);
    try std.testing.expectEqual(@as(u32, 0), stats.written);
    try std.testing.expectEqual(@as(u32, 1), stats.skipped_unchanged);
}

test "kb raw X export does not move processed sources back to inbox" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_rel = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const base = try absolutize(allocator, base_rel);
    const db_path = try std.fs.path.join(allocator, &.{ base, "kb-processed.sqlite" });
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var tweet = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"950\",\"text\":\"already processed\"}", .{});
    defer tweet.deinit();
    try upsertTweetFromValue(&db, allocator, tweet.value);
    const run_id = try createSyncRun(&db, "acct", "fixture", "{}", allocator);
    _ = try upsertBookmarkItem(&db, allocator, "acct", "950", run_id, 0, true);

    const config_paths = try resolvePaths(allocator, null, base);
    var cfg = try Config.default(allocator, config_paths, base);
    const vault = try std.fs.path.join(allocator, &.{ base, "Vault" });
    cfg.obsidian_vault_path = vault;
    var paths = try resolveObsidianPaths(allocator, cfg, null);
    defer paths.deinit(allocator);
    try kbInit(allocator, paths);
    const ingested_path = try std.fs.path.join(allocator, &.{ paths.root, "raw", "x", "ingested", "950.md" });
    try ensureParentDir(ingested_path);
    try std.fs.cwd().writeFile(.{ .sub_path = ingested_path, .data = "processed" });

    const stats = try kbExportRawX(&db, allocator, paths, true);
    try std.testing.expectEqual(@as(u32, 1), stats.total);
    try std.testing.expectEqual(@as(u32, 1), stats.written);
    try std.testing.expectEqual(@as(u32, 0), stats.skipped_processed);
    try std.testing.expect(!fileExists(try std.fs.path.join(allocator, &.{ paths.root, "raw", "x", "inbox", "950.md" })));
    const updated = try std.fs.cwd().readFileAlloc(allocator, ingested_path, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, updated, "status: \"ingested\"") != null);
}

test "missing quoted post references preserve protected error status" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "missing-status.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var page = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "data": [{"id":"102","author_id":"1","text":"quote protected","referenced_tweets":[{"type":"quoted","id":"888"}]}],
        \\  "errors": [{"resource_id":"888","title":"Authorization Error","detail":"This Tweet is protected"}],
        \\  "meta": {"result_count":1}
        \\}
    , .{});
    defer page.deinit();
    const tweet = getArray(page.value, "data").?.items[0];
    try upsertTweetFromValue(&db, allocator, tweet);
    try recordMissingQuoteReferences(&db, allocator, page.value, tweet);

    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM missing_references WHERE tweet_id = '102' AND referenced_tweet_id = '888' AND status = 'protected'"));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM missing_references WHERE raw_json LIKE '%Authorization Error%'"));
}

test "offline completeness requires stored author metadata when author id is present" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "author-complete.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var tweet = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"301\",\"author_id\":\"42\",\"text\":\"needs author\"}", .{});
    defer tweet.deinit();
    try upsertTweetFromValue(&db, allocator, tweet.value);
    try std.testing.expect(!try bookmarkCompleteForOfflineRender(&db, allocator, "301"));

    var user = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"42\",\"username\":\"author\",\"name\":\"Author\"}", .{});
    defer user.deinit();
    try upsertUserFromValue(&db, allocator, user.value);
    try std.testing.expect(try bookmarkCompleteForOfflineRender(&db, allocator, "301"));
}

test "offline completeness accepts missing quote records as explicit unavailable state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "quote-complete.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var user = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"1\",\"username\":\"alice\",\"name\":\"Alice\"}", .{});
    defer user.deinit();
    try upsertUserFromValue(&db, allocator, user.value);
    var tweet = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"302","author_id":"1","text":"quote missing","referenced_tweets":[{"type":"quoted","id":"999"}]}
    , .{});
    defer tweet.deinit();
    try upsertTweetFromValue(&db, allocator, tweet.value);
    try std.testing.expect(!try bookmarkCompleteForOfflineRender(&db, allocator, "302"));
    try recordMissingQuoteReferences(&db, allocator, tweet.value, tweet.value);
    try std.testing.expect(try bookmarkCompleteForOfflineRender(&db, allocator, "302"));
}

test "jsonl export includes missing quote reference placeholders" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "jsonl-missing-ref.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var user = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"1\",\"username\":\"alice\",\"name\":\"Alice\"}", .{});
    defer user.deinit();
    try upsertUserFromValue(&db, allocator, user.value);
    var tweet = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"307","author_id":"1","text":"quote missing","referenced_tweets":[{"type":"quoted","id":"999"}]}
    , .{});
    defer tweet.deinit();
    try upsertTweetFromValue(&db, allocator, tweet.value);
    try recordMissingQuoteReferences(&db, allocator, tweet.value, tweet.value);
    const run_id = try createSyncRun(&db, "acct", "fixture", "{}", allocator);
    _ = try upsertBookmarkItem(&db, allocator, "acct", "307", run_id, 0, true);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try exportJsonl(&db, allocator, out.writer(allocator));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"missing_references\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"referenced_tweet_id\":\"999\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"reference_type\":\"quoted\"") != null);
}

test "jsonl export includes local author avatar paths" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "jsonl-avatar.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var user = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"13\",\"username\":\"avatarjsonl\",\"name\":\"Avatar Jsonl\",\"profile_image_url\":\"https://example.invalid/avatar.jpg\"}", .{});
    defer user.deinit();
    try upsertUserFromValue(&db, allocator, user.value);
    var tweet = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"310\",\"author_id\":\"13\",\"text\":\"avatar jsonl\"}", .{});
    defer tweet.deinit();
    try upsertTweetFromValue(&db, allocator, tweet.value);

    const run_id = try createSyncRun(&db, "acct", "fixture", "{}", allocator);
    try finishSyncRun(&db, run_id, "succeeded", 1, 1, 1, false, null, null, allocator);
    _ = try upsertBookmarkItem(&db, allocator, "acct", "310", run_id, 0, true);
    try recordMediaAsset(&db, allocator, "user:13", "author_avatar", "https://example.invalid/avatar.jpg", "/tmp/avatar-jsonl.jpg", "image/jpeg", 12, null, null, null, "downloaded", null);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try validateCompleteBookmarksForExport(&db, allocator);
    try exportJsonl(&db, allocator, out.writer(allocator));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"author_avatar_path\":\"/tmp/avatar-jsonl.jpg\"") != null);
}

test "jsonl export validation rejects stale complete bookmark rows" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "jsonl-stale.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var user = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"12\",\"username\":\"jsonlstale\",\"name\":\"Jsonl Stale\"}", .{});
    defer user.deinit();
    try upsertUserFromValue(&db, allocator, user.value);
    var media = try std.json.parseFromSlice(std.json.Value, allocator, "{\"media_key\":\"jsonl_media\",\"type\":\"photo\",\"url\":\"https://example.invalid/jsonl.jpg\"}", .{});
    defer media.deinit();
    try upsertMediaFromValue(&db, allocator, media.value);
    var tweet = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"309\",\"author_id\":\"12\",\"text\":\"stale jsonl\",\"attachments\":{\"media_keys\":[\"jsonl_media\"]}}", .{});
    defer tweet.deinit();
    try upsertTweetFromValue(&db, allocator, tweet.value);

    const run_id = try createSyncRun(&db, "acct", "fixture", "{}", allocator);
    try finishSyncRun(&db, run_id, "succeeded", 1, 1, 1, false, null, null, allocator);
    _ = try upsertBookmarkItem(&db, allocator, "acct", "309", run_id, 0, true);

    try std.testing.expectError(AppError.IoError, validateCompleteBookmarksForExport(&db, allocator));
}

test "failed author avatar makes bookmark incomplete" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "avatar.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var tweet = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"300\",\"author_id\":\"42\",\"text\":\"avatar failure\"}", .{});
    defer tweet.deinit();
    try upsertTweetFromValue(&db, allocator, tweet.value);
    try recordMediaAsset(&db, allocator, "user:42", "author_avatar", "https://example.invalid/avatar.jpg", "", "image/jpeg", 0, null, null, null, "failed", "{\"error\":\"fixture\"}");

    try std.testing.expect(try tweetHasFailedAssets(&db, allocator, "300"));
    try std.testing.expect(!try bookmarkCompleteForOfflineRender(&db, allocator, "300"));
}

test "offline completeness requires local media assets for attached media" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "required-media.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var user = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"7\",\"username\":\"mediauser\",\"name\":\"Media User\"}", .{});
    defer user.deinit();
    try upsertUserFromValue(&db, allocator, user.value);

    var media = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"media_key":"3_photo","type":"photo","url":"https://example.invalid/photo.jpg","width":1200,"height":800}
    , .{});
    defer media.deinit();
    try upsertMediaFromValue(&db, allocator, media.value);

    var tweet = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"303","author_id":"7","text":"attached media","attachments":{"media_keys":["3_photo"]}}
    , .{});
    defer tweet.deinit();
    try upsertTweetFromValue(&db, allocator, tweet.value);

    try std.testing.expect(!try bookmarkCompleteForOfflineRender(&db, allocator, "303"));
    try recordMediaAsset(&db, allocator, "3_photo", "image", "https://example.invalid/photo.jpg", "/tmp/photo.jpg", "image/jpeg", 12, null, 1200, 800, "downloaded", null);
    try std.testing.expect(try bookmarkCompleteForOfflineRender(&db, allocator, "303"));
}

test "offline completeness accepts skipped video variants as accounted for" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "required-video.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var user = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"8\",\"username\":\"videouser\",\"name\":\"Video User\"}", .{});
    defer user.deinit();
    try upsertUserFromValue(&db, allocator, user.value);

    var media = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"media_key":"7_video","type":"video","preview_image_url":"https://example.invalid/preview.jpg","variants":[{"content_type":"application/x-mpegURL","url":"https://example.invalid/stream.m3u8"}]}
    , .{});
    defer media.deinit();
    try upsertMediaFromValue(&db, allocator, media.value);

    var tweet = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"304","author_id":"8","text":"attached video","attachments":{"media_keys":["7_video"]}}
    , .{});
    defer tweet.deinit();
    try upsertTweetFromValue(&db, allocator, tweet.value);

    try std.testing.expect(!try bookmarkCompleteForOfflineRender(&db, allocator, "304"));
    try recordMediaAsset(&db, allocator, "7_video", "preview_image", "https://example.invalid/preview.jpg", "/tmp/preview.jpg", "image/jpeg", 12, null, null, null, "downloaded", null);
    try std.testing.expect(!try bookmarkCompleteForOfflineRender(&db, allocator, "304"));
    try recordMediaAsset(&db, allocator, "7_video", "video_variant", "x-bookmarks:media:7_video:variant", "", null, 0, null, null, null, "skipped", "{\"reason\":\"no_mp4_variant\"}");
    try std.testing.expect(try bookmarkCompleteForOfflineRender(&db, allocator, "304"));
}

test "skipped media asset records are idempotent by media key kind and source" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "skipped-idempotent.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    try recordSkippedMediaAssetOnce(&db, allocator, "7_video", "video_variant", "x-bookmarks:media:7_video:variant", 640, 360, "{\"reason\":\"no_mp4_variant\"}");
    try recordSkippedMediaAssetOnce(&db, allocator, "7_video", "video_variant", "x-bookmarks:media:7_video:variant", 640, 360, "{\"reason\":\"no_mp4_variant\"}");
    try recordSkippedMediaAssetOnce(&db, allocator, "8_video", "video_variant", "x-bookmarks:media:8_video:variant", 640, 360, "{\"reason\":\"no_mp4_variant\"}");

    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM media_assets WHERE media_key = '7_video' AND status = 'skipped'"));
    try std.testing.expectEqual(@as(i64, 2), try scalarCount(&db, "SELECT count(*) FROM media_assets WHERE status = 'skipped'"));
}

test "offline completeness requires local avatar asset when user has avatar url" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "required-avatar.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var user = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"9","username":"avataruser","name":"Avatar User","profile_image_url":"https://example.invalid/avatar.jpg"}
    , .{});
    defer user.deinit();
    try upsertUserFromValue(&db, allocator, user.value);

    var tweet = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"305\",\"author_id\":\"9\",\"text\":\"avatar required\"}", .{});
    defer tweet.deinit();
    try upsertTweetFromValue(&db, allocator, tweet.value);

    try std.testing.expect(!try bookmarkCompleteForOfflineRender(&db, allocator, "305"));
    try recordMediaAsset(&db, allocator, "user:9", "author_avatar", "https://example.invalid/avatar.jpg", "/tmp/avatar.jpg", "image/jpeg", 12, null, null, null, "downloaded", null);
    try std.testing.expect(try bookmarkCompleteForOfflineRender(&db, allocator, "305"));
}

test "asset idempotency verifies local file hash and reuses existing content hash" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const db_path = try std.fs.path.join(allocator, &.{ tmp_root, "assets.sqlite" });
    defer allocator.free(db_path);
    const asset_path = try std.fs.path.join(allocator, &.{ tmp_root, "asset.bin" });
    defer allocator.free(asset_path);
    try std.fs.cwd().writeFile(.{ .sub_path = asset_path, .data = "same bytes" });

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("same bytes", &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);

    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);
    try recordMediaAsset(&db, allocator, "m1", "image", "https://example.invalid/a.jpg", asset_path, "image/jpeg", 10, &hash, null, null, "downloaded", null);

    try std.testing.expect(try assetSourceValid(&db, allocator, "https://example.invalid/a.jpg"));
    try std.testing.expect(!try assetSourceValid(&db, allocator, "https://example.invalid/missing.jpg"));
    const reused = (try downloadedPathForHash(&db, allocator, &hash)).?;
    defer allocator.free(reused);
    try std.testing.expectEqualStrings(asset_path, reused);

    try std.fs.cwd().writeFile(.{ .sub_path = asset_path, .data = "changed" });
    try std.testing.expect(!try assetSourceValid(&db, allocator, "https://example.invalid/a.jpg"));
    try std.testing.expect(try downloadedPathForHash(&db, allocator, &hash) == null);
}

test "asset source reuse records current media key without redownload" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const db_path = try std.fs.path.join(allocator, &.{ tmp_root, "asset-source-reuse.sqlite" });
    defer allocator.free(db_path);
    const asset_path = try std.fs.path.join(allocator, &.{ tmp_root, "asset.bin" });
    defer allocator.free(asset_path);
    const assets_dir = try std.fs.path.join(allocator, &.{ tmp_root, "assets" });
    defer allocator.free(assets_dir);
    try std.fs.cwd().writeFile(.{ .sub_path = asset_path, .data = "same bytes" });

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("same bytes", &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);

    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);
    try recordMediaAsset(&db, allocator, "m1", "image", "https://example.invalid/shared.jpg", asset_path, "image/jpeg", 10, &hash, 100, 100, "downloaded", null);

    try downloadAsset(&db, allocator, assets_dir, "m1", "image", "https://example.invalid/shared.jpg", 100, 100);
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM media_assets WHERE media_key = 'm1' AND source_url = 'https://example.invalid/shared.jpg'"));

    try downloadAsset(&db, allocator, assets_dir, "m2", "image", "https://example.invalid/shared.jpg", 200, 150);
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM media_assets WHERE media_key = 'm2' AND asset_kind = 'image' AND byte_size = 10 AND width = 200 AND height = 150"));
    try std.testing.expectEqual(@as(i64, 2), try scalarCount(&db, "SELECT count(*) FROM media_assets WHERE source_url = 'https://example.invalid/shared.jpg' AND status = 'downloaded'"));

    try downloadAsset(&db, allocator, assets_dir, "m1", "image", "https://example.invalid/shared.jpg", 100, 100);
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM media_assets WHERE media_key = 'm1' AND source_url = 'https://example.invalid/shared.jpg'"));
}

test "asset reuse skips corrupt newest candidate and uses older valid candidate" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const db_path = try std.fs.path.join(allocator, &.{ tmp_root, "asset-candidates.sqlite" });
    defer allocator.free(db_path);
    const valid_path = try std.fs.path.join(allocator, &.{ tmp_root, "valid.bin" });
    defer allocator.free(valid_path);
    const corrupt_path = try std.fs.path.join(allocator, &.{ tmp_root, "corrupt.bin" });
    defer allocator.free(corrupt_path);
    try std.fs.cwd().writeFile(.{ .sub_path = valid_path, .data = "same bytes" });
    try std.fs.cwd().writeFile(.{ .sub_path = corrupt_path, .data = "changed" });

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("same bytes", &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);

    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);
    try recordMediaAsset(&db, allocator, "old", "image", "https://example.invalid/candidate.jpg", valid_path, "image/jpeg", 10, &hash, null, null, "downloaded", null);
    try recordMediaAsset(&db, allocator, "new", "image", "https://example.invalid/candidate.jpg", corrupt_path, "image/jpeg", 10, &hash, null, null, "downloaded", null);

    const source_asset = (try validAssetForSource(&db, allocator, "https://example.invalid/candidate.jpg")).?;
    defer source_asset.deinit(allocator);
    try std.testing.expectEqualStrings(valid_path, source_asset.local_path);

    const hash_path = (try downloadedPathForHash(&db, allocator, &hash)).?;
    defer allocator.free(hash_path);
    try std.testing.expectEqualStrings(valid_path, hash_path);
}

test "structured sync warnings are persisted for degraded folder sync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "warnings.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    const run_id = try createSyncRun(&db, "acct", "incremental", "{}", allocator);
    try recordSyncWarning(&db, allocator, run_id, "bookmark_folder_sync_failed", "{\"endpoint\":\"folders\",\"http_status\":403}");

    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM sync_warnings WHERE sync_run_id > 0 AND warning_type = 'bookmark_folder_sync_failed'"));
}

test "folder item pruning removes memberships absent from successful folder scan" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "folder-prune.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    try upsertFolderItem(&db, allocator, "acct", "folder1", "old");
    try upsertFolderItem(&db, allocator, "acct", "folder1", "keep");
    try upsertFolderItem(&db, allocator, "acct", "folder2", "old");

    try beginFolderItemPrune(&db);
    try rememberFolderItemForPrune(&db, "keep");
    try pruneFolderItemsNotSeen(&db, "acct", "folder1");

    try std.testing.expectEqual(@as(i64, 0), try scalarCount(&db, "SELECT count(*) FROM bookmark_folder_items WHERE account_user_id = 'acct' AND folder_id = 'folder1' AND tweet_id = 'old'"));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM bookmark_folder_items WHERE account_user_id = 'acct' AND folder_id = 'folder1' AND tweet_id = 'keep'"));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM bookmark_folder_items WHERE account_user_id = 'acct' AND folder_id = 'folder2' AND tweet_id = 'old'"));
}

test "viewer export rejects stale complete bookmark rows with missing required assets" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "stale-complete.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var user = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"10\",\"username\":\"stale\",\"name\":\"Stale\"}", .{});
    defer user.deinit();
    try upsertUserFromValue(&db, allocator, user.value);

    var media = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"media_key":"3_stale","type":"photo","url":"https://example.invalid/stale.jpg"}
    , .{});
    defer media.deinit();
    try upsertMediaFromValue(&db, allocator, media.value);

    var tweet = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"306","author_id":"10","text":"stale complete","attachments":{"media_keys":["3_stale"]}}
    , .{});
    defer tweet.deinit();
    try upsertTweetFromValue(&db, allocator, tweet.value);

    const run_id = try createSyncRun(&db, "acct", "fixture", "{}", allocator);
    _ = try upsertBookmarkItem(&db, allocator, "acct", "306", run_id, 0, true);

    try std.testing.expectError(AppError.IoError, validateCompleteBookmarksForExport(&db, allocator));
    try recordMediaAsset(&db, allocator, "3_stale", "image", "https://example.invalid/stale.jpg", "/tmp/stale.jpg", "image/jpeg", 12, null, null, null, "downloaded", null);
    try finishSyncRun(&db, run_id, "succeeded", 1, 1, 1, false, null, null, allocator);
    try validateCompleteBookmarksForExport(&db, allocator);
}

test "viewer export rejects complete bookmarks whose folder sync run did not succeed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "folder-state-complete.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var user = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"11\",\"username\":\"folderstate\",\"name\":\"Folder State\"}", .{});
    defer user.deinit();
    try upsertUserFromValue(&db, allocator, user.value);
    var tweet = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"308\",\"author_id\":\"11\",\"text\":\"needs folder state\"}", .{});
    defer tweet.deinit();
    try upsertTweetFromValue(&db, allocator, tweet.value);

    const run_id = try createSyncRun(&db, "acct", "fixture", "{}", allocator);
    _ = try upsertBookmarkItem(&db, allocator, "acct", "308", run_id, 0, true);

    try std.testing.expect(try bookmarkCompleteForOfflineRender(&db, allocator, "308"));
    try std.testing.expectError(AppError.IoError, validateCompleteBookmarksForExport(&db, allocator));
    try finishSyncRun(&db, run_id, "succeeded", 1, 1, 1, false, null, null, allocator);
    try validateCompleteBookmarksForExport(&db, allocator);
}

test "degraded folder sync prevents offline completeness for current run" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "folder-degraded-complete.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var user = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"12\",\"username\":\"degraded\",\"name\":\"Degraded\"}", .{});
    defer user.deinit();
    try upsertUserFromValue(&db, allocator, user.value);
    var tweet = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"309\",\"author_id\":\"12\",\"text\":\"folder degraded\"}", .{});
    defer tweet.deinit();
    try upsertTweetFromValue(&db, allocator, tweet.value);

    const run_id = try createSyncRun(&db, "acct", "fixture", "{}", allocator);
    _ = try upsertBookmarkItem(&db, allocator, "acct", "309", run_id, 0, true);
    try std.testing.expect(try bookmarkCompleteForOfflineRender(&db, allocator, "309"));

    try refreshBookmarkCompletenessForRun(&db, allocator, "acct", run_id, false);

    try std.testing.expectEqual(@as(i64, 0), try scalarCount(&db, "SELECT count(*) FROM bookmark_items WHERE account_user_id = 'acct' AND tweet_id = '309' AND complete_for_offline_render = 1"));
}

test "viewer export rejects complete bookmarks from runs with folder warnings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "folder-warning-complete.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var user = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"14\",\"username\":\"warned\",\"name\":\"Warned\"}", .{});
    defer user.deinit();
    try upsertUserFromValue(&db, allocator, user.value);
    var tweet = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"311\",\"author_id\":\"14\",\"text\":\"folder warning\"}", .{});
    defer tweet.deinit();
    try upsertTweetFromValue(&db, allocator, tweet.value);

    const run_id = try createSyncRun(&db, "acct", "fixture", "{}", allocator);
    try finishSyncRun(&db, run_id, "succeeded", 1, 1, 1, false, null, null, allocator);
    try recordSyncWarning(&db, allocator, run_id, "bookmark_folder_sync_failed", "{\"endpoint\":\"folders\",\"http_status\":403}");
    _ = try upsertBookmarkItem(&db, allocator, "acct", "311", run_id, 0, true);

    try std.testing.expectError(AppError.IoError, validateCompleteBookmarksForExport(&db, allocator));
}

test "summary quote post count only includes distinct stored quote posts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "quote-count.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var quote = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"q1\",\"text\":\"stored quote\"}", .{});
    defer quote.deinit();
    try upsertTweetFromValue(&db, allocator, quote.value);

    var parent = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"p1","text":"parent","referenced_tweets":[{"type":"replied_to","id":"r1"},{"type":"quoted","id":"q1"},{"type":"quoted","id":"missing"}]}
    , .{});
    defer parent.deinit();
    try upsertTweetFromValue(&db, allocator, parent.value);

    var another = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"p2","text":"parent 2","referenced_tweets":[{"type":"quoted","id":"q1"}]}
    , .{});
    defer another.deinit();
    try upsertTweetFromValue(&db, allocator, another.value);

    try std.testing.expectEqual(@as(i64, 1), try countStoredQuotePosts(&db, allocator));
}

test "viewer export carries local avatar assets and sync warnings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const db_path = try std.fs.path.join(allocator, &.{ tmp_root, "viewer.sqlite" });
    defer allocator.free(db_path);
    const asset_path = try std.fs.path.join(allocator, &.{ tmp_root, "avatar.jpg" });
    defer allocator.free(asset_path);
    const export_dir = try std.fs.path.join(allocator, &.{ tmp_root, "viewer-export" });
    defer allocator.free(export_dir);

    try std.fs.cwd().writeFile(.{ .sub_path = asset_path, .data = "abc" });
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var user = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"1","username":"alice","name":"Alice","profile_image_url":"https://example.invalid/avatar.jpg"}
    , .{});
    defer user.deinit();
    var tweet = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"400","author_id":"1","text":"viewer export"}
    , .{});
    defer tweet.deinit();
    try upsertUserFromValue(&db, allocator, user.value);
    try upsertTweetFromValue(&db, allocator, tweet.value);
    const run_id = try createSyncRun(&db, "acct", "fixture", "{}", allocator);
    _ = try upsertBookmarkItem(&db, allocator, "acct", "400", run_id, 0, true);
    try recordMediaAsset(&db, allocator, "user:1", "author_avatar", "https://example.invalid/avatar.jpg", asset_path, "image/jpeg", 3, null, null, null, "downloaded", null);
    try recordSyncWarning(&db, allocator, run_id, "bookmark_folder_sync_failed", "{\"endpoint\":\"folders\",\"http_status\":403}");

    const bookmarks_path = try std.fs.path.join(allocator, &.{ export_dir, "data", "bookmarks.json" });
    defer allocator.free(bookmarks_path);
    const media_path = try std.fs.path.join(allocator, &.{ export_dir, "data", "media-assets.json" });
    defer allocator.free(media_path);
    const warnings_path = try std.fs.path.join(allocator, &.{ export_dir, "data", "sync-warnings.json" });
    defer allocator.free(warnings_path);
    const summary_path = try std.fs.path.join(allocator, &.{ export_dir, "data", "sync-summary.json" });
    defer allocator.free(summary_path);

    const data_dir = try std.fs.path.join(allocator, &.{ export_dir, "data" });
    defer allocator.free(data_dir);
    try std.fs.cwd().makePath(data_dir);
    try writeQueryJsonArray(&db, allocator, bookmarks_path,
        \\SELECT b.account_user_id, b.tweet_id, b.complete_for_offline_render, t.canonical_uri, t.twitter_uri,
        \\       coalesce(t.text, ''), coalesce(t.created_at, ''), coalesce(t.author_id, ''), coalesce(u.username, ''), coalesce(u.name, ''),
        \\       coalesce(u.profile_image_url, ''), t.raw_json
        \\FROM bookmark_items b
        \\JOIN tweets t ON t.tweet_id = b.tweet_id
        \\LEFT JOIN users u ON u.user_id = t.author_id
        \\WHERE b.active = 1
        \\ORDER BY b.import_position IS NULL, b.import_position, b.last_seen_at DESC, b.tweet_id DESC
    , &.{ "account_user_id", "tweet_id", "complete_for_offline_render:bool", "canonical_uri", "twitter_uri", "text", "created_at", "author_id", "author_username", "author_name", "author_avatar_url", "raw_json" });
    try writeMediaAssetsJsonAndCopy(&db, allocator, media_path, export_dir);
    try writeQueryJsonArray(&db, allocator, warnings_path, "SELECT sync_run_id, warning_type, context_json, created_at FROM sync_warnings ORDER BY id", &.{ "sync_run_id:int", "warning_type", "context_json", "created_at" });
    try writeSummaryJson(&db, allocator, summary_path);

    const bookmarks_json = try std.fs.cwd().readFileAlloc(allocator, bookmarks_path, 1024 * 1024);
    defer allocator.free(bookmarks_json);
    const media_json = try std.fs.cwd().readFileAlloc(allocator, media_path, 1024 * 1024);
    defer allocator.free(media_json);
    const warnings_json = try std.fs.cwd().readFileAlloc(allocator, warnings_path, 1024 * 1024);
    defer allocator.free(warnings_json);
    const summary_json = try std.fs.cwd().readFileAlloc(allocator, summary_path, 1024 * 1024);
    defer allocator.free(summary_json);

    try std.testing.expect(std.mem.indexOf(u8, bookmarks_json, "\"author_id\":\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, media_json, "\"viewer_path\":\"assets/media-assets/") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings_json, "\"warning_type\":\"bookmark_folder_sync_failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_json, "\"new_bookmarks\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_json, "\"sync_warnings\": 1") != null);
}

test "viewer export reset removes stale files before regeneration" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const export_dir = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "viewer-export" });
    defer allocator.free(export_dir);
    const stale_path = try std.fs.path.join(allocator, &.{ export_dir, "assets", "stale.js" });
    defer allocator.free(stale_path);
    try ensureParentDir(stale_path);
    try std.fs.cwd().writeFile(.{ .sub_path = stale_path, .data = "stale" });
    try std.testing.expect(fileExists(stale_path));

    try resetExportDir(allocator, export_dir);

    try std.testing.expect(!fileExists(stale_path));
    const data_dir = try std.fs.path.join(allocator, &.{ export_dir, "data" });
    defer allocator.free(data_dir);
    const assets_dir = try std.fs.path.join(allocator, &.{ export_dir, "assets" });
    defer allocator.free(assets_dir);
    const static_dir = try std.fs.path.join(allocator, &.{ export_dir, "static" });
    defer allocator.free(static_dir);
    try std.testing.expect(fileExists(data_dir));
    try std.testing.expect(fileExists(assets_dir));
    try std.testing.expect(fileExists(static_dir));
}

test "viewer export file validation requires static shell and data manifests" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const export_dir = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "viewer-export" });
    defer allocator.free(export_dir);
    try std.fs.cwd().makePath(export_dir);
    try std.testing.expectError(AppError.IoError, validateViewerExportFiles(allocator, export_dir));

    const required = [_][]const u8{
        "index.html",
        "data/bookmarks.json",
        "data/tweets.json",
        "data/folders.json",
        "data/folder-items.json",
        "data/media-assets.json",
        "data/tweet-media.json",
        "data/missing-references.json",
        "data/sync-warnings.json",
        "data/sync-summary.json",
    };
    for (required) |rel| {
        const path = try std.fs.path.join(allocator, &.{ export_dir, rel });
        defer allocator.free(path);
        try ensureParentDir(path);
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "{}" });
    }
    try validateViewerExportFiles(allocator, export_dir);

    const index_path = try std.fs.path.join(allocator, &.{ export_dir, "index.html" });
    defer allocator.free(index_path);
    try std.fs.cwd().writeFile(.{ .sub_path = index_path, .data = "<script src=\"./assets/app.js\"></script>" });
    try std.testing.expectError(AppError.IoError, validateViewerExportFiles(allocator, export_dir));
    const asset_path = try std.fs.path.join(allocator, &.{ export_dir, "assets", "app.js" });
    defer allocator.free(asset_path);
    try ensureParentDir(asset_path);
    try std.fs.cwd().writeFile(.{ .sub_path = asset_path, .data = "console.log('ok');" });
    try validateViewerExportFiles(allocator, export_dir);
}

test "thread candidate detection catches numbering and markers only" {
    const allocator = std.testing.allocator;
    var numbered = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"1","author_id":"a","conversation_id":"1","text":"A useful opener 1/N","public_metrics":{"reply_count":2}}
    , .{});
    defer numbered.deinit();
    const numbered_reasons = try threadDetectionReasonsJson(allocator, numbered.value);
    defer if (numbered_reasons) |r| allocator.free(r);
    try std.testing.expect(numbered_reasons != null);
    try std.testing.expect(std.mem.indexOf(u8, numbered_reasons.?, "1/N") != null);

    var marker = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"2\",\"author_id\":\"a\",\"conversation_id\":\"2\",\"text\":\"\\uD83E\\uDDF5 notes on systems\"}", .{});
    defer marker.deinit();
    const marker_reasons = try threadDetectionReasonsJson(allocator, marker.value);
    defer if (marker_reasons) |r| allocator.free(r);
    try std.testing.expect(marker_reasons != null);

    var ordinary = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"3","author_id":"a","conversation_id":"3","text":"One ordinary standalone post","public_metrics":{"reply_count":10}}
    , .{});
    defer ordinary.deinit();
    const ordinary_reasons = try threadDetectionReasonsJson(allocator, ordinary.value);
    try std.testing.expect(ordinary_reasons == null);
}

test "thread membership keeps same-author chain and excludes comments" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "threads.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var author = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"1\",\"username\":\"alice\",\"name\":\"Alice\"}", .{});
    defer author.deinit();
    try upsertUserFromValue(&db, allocator, author.value);
    var commenter = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"2\",\"username\":\"bob\",\"name\":\"Bob\"}", .{});
    defer commenter.deinit();
    try upsertUserFromValue(&db, allocator, commenter.value);

    const tweets = [_][]const u8{
        \\{"id":"100","author_id":"1","conversation_id":"100","created_at":"2026-05-14T10:00:00.000Z","text":"Thread opener 1/N"}
        ,
        \\{"id":"101","author_id":"1","conversation_id":"100","created_at":"2026-05-14T10:01:00.000Z","text":"Second post","referenced_tweets":[{"type":"replied_to","id":"100"}]}
        ,
        \\{"id":"102","author_id":"2","conversation_id":"100","created_at":"2026-05-14T10:02:00.000Z","text":"A comment","referenced_tweets":[{"type":"replied_to","id":"100"}]}
        ,
        \\{"id":"103","author_id":"1","conversation_id":"100","created_at":"2026-05-14T10:03:00.000Z","text":"Third post","referenced_tweets":[{"type":"replied_to","id":"101"}]}
        ,
        \\{"id":"104","author_id":"1","conversation_id":"100","created_at":"2026-05-14T10:04:00.000Z","text":"Side reply","referenced_tweets":[{"type":"replied_to","id":"999"}]}
    };
    for (tweets) |json| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        try upsertTweetFromValue(&db, allocator, parsed.value);
    }

    const plan = ThreadExpansionPlan{
        .root_tweet_id = "100",
        .root_author_id = "1",
        .root_author_username = "alice",
        .conversation_id = "100",
        .query = "conversation_id:100 from:alice",
        .start_time = "2026-05-14T10:00:00Z",
        .end_time = "2026-05-14T16:00:00Z",
        .endpoint = .all,
        .max_results = 100,
        .max_posts = default_thread_max_posts,
        .estimated_cost_micros = 100000,
    };
    const result = try buildAndPersistThreadMembership(&db, allocator, plan);
    try std.testing.expectEqualStrings("complete", result.status);
    try std.testing.expectEqual(@as(i64, 3), try scalarCount(&db, "SELECT count(*) FROM thread_posts WHERE root_tweet_id='100'"));
    try std.testing.expectEqual(@as(i64, 0), try scalarCount(&db, "SELECT count(*) FROM thread_posts WHERE tweet_id IN ('102','104')"));
}

test "thread membership caps kept posts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "thread-cap.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var author = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"1\",\"username\":\"alice\",\"name\":\"Alice\"}", .{});
    defer author.deinit();
    try upsertUserFromValue(&db, allocator, author.value);

    var root = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"500","author_id":"1","conversation_id":"500","created_at":"2026-05-14T10:00:00.000Z","text":"Thread opener 1/N"}
    , .{});
    defer root.deinit();
    try upsertTweetFromValue(&db, allocator, root.value);
    for (1..8) |idx| {
        const id = try std.fmt.allocPrint(allocator, "50{}", .{idx});
        defer allocator.free(id);
        const previous_id = if (idx == 1) try allocator.dupe(u8, "500") else try std.fmt.allocPrint(allocator, "50{}", .{idx - 1});
        defer allocator.free(previous_id);
        const json = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":\"{s}\",\"author_id\":\"1\",\"conversation_id\":\"500\",\"created_at\":\"2026-05-14T10:0{}:00.000Z\",\"text\":\"Post {}\",\"referenced_tweets\":[{{\"type\":\"replied_to\",\"id\":\"{s}\"}}]}}",
            .{ id, idx, idx, previous_id },
        );
        defer allocator.free(json);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        try upsertTweetFromValue(&db, allocator, parsed.value);
    }

    const plan = ThreadExpansionPlan{
        .root_tweet_id = "500",
        .root_author_id = "1",
        .root_author_username = "alice",
        .conversation_id = "500",
        .query = "conversation_id:500 from:alice",
        .start_time = "2026-05-14T10:00:00Z",
        .end_time = "2026-05-14T16:00:00Z",
        .endpoint = .timeline,
        .max_results = 100,
        .max_posts = 5,
        .estimated_cost_micros = 100000,
    };
    const result = try buildAndPersistThreadMembership(&db, allocator, plan);
    try std.testing.expectEqualStrings("partial", result.status);
    try std.testing.expectEqual(@as(u32, 5), result.post_count);
    try std.testing.expectEqual(@as(i64, 5), try scalarCount(&db, "SELECT count(*) FROM thread_posts WHERE root_tweet_id='500'"));
}

test "thread timeline url uses root author and time window" {
    const allocator = std.testing.allocator;
    const start = try threadApiStartTime(allocator, "2026-05-14T22:30:00.000Z");
    defer allocator.free(start);
    const end = try threadApiEndTime(allocator, start, 6);
    defer allocator.free(end);
    try std.testing.expectEqualStrings("2026-05-14T22:30:00Z", start);
    try std.testing.expectEqualStrings("2026-05-15T04:30:00Z", end);

    const plan = ThreadExpansionPlan{
        .root_tweet_id = "600",
        .root_author_id = "1",
        .root_author_username = "alice",
        .conversation_id = "600",
        .query = "conversation_id:600 from:alice",
        .start_time = start,
        .end_time = end,
        .endpoint = .timeline,
        .max_results = 100,
        .max_posts = default_thread_max_posts,
        .estimated_cost_micros = 100000,
    };
    const url = try buildThreadSearchUrl(allocator, plan);
    defer allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "/2/users/1/tweets?") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "start_time=2026-05-14T22%3A30%3A00Z") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "end_time=2026-05-15T04%3A30%3A00Z") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "in_reply_to_user_id") != null);
}

test "raw export emits missing and complete thread context" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "raw-thread.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var author = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"1\",\"username\":\"alice\",\"name\":\"Alice\"}", .{});
    defer author.deinit();
    try upsertUserFromValue(&db, allocator, author.value);
    var root = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"200","author_id":"1","conversation_id":"200","created_at":"2026-05-14T10:00:00.000Z","text":"Thread opener 1/N","public_metrics":{"reply_count":4}}
    , .{});
    defer root.deinit();
    try upsertTweetFromValue(&db, allocator, root.value);
    const missing_raw_json = try jsonValueAlloc(allocator, root.value);
    defer allocator.free(missing_raw_json);
    const missing = try buildRawXBookmarkMarkdown(&db, allocator, "200", "https://x.com/alice/status/200", "https://twitter.com/i/web/status/200", "Thread opener 1/N", "2026-05-14T10:00:00.000Z", "1", "alice", "Alice", "2026-05-14", "inbox", missing_raw_json);
    defer allocator.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "thread_candidate: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "thread_expansion_status: \"missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "## Source Text\n\nThread opener 1/N") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "## Thread Context") != null);

    var second = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"201","author_id":"1","conversation_id":"200","created_at":"2026-05-14T10:01:00.000Z","text":"Second post","referenced_tweets":[{"type":"replied_to","id":"200"}]}
    , .{});
    defer second.deinit();
    try upsertTweetFromValue(&db, allocator, second.value);
    var comment = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"202","author_id":"2","conversation_id":"200","created_at":"2026-05-14T10:02:00.000Z","text":"Comment","referenced_tweets":[{"type":"replied_to","id":"200"}]}
    , .{});
    defer comment.deinit();
    try upsertTweetFromValue(&db, allocator, comment.value);
    const plan = ThreadExpansionPlan{
        .root_tweet_id = "200",
        .root_author_id = "1",
        .root_author_username = "alice",
        .conversation_id = "200",
        .query = "conversation_id:200 from:alice",
        .start_time = "2026-05-14T10:00:00Z",
        .end_time = "2026-05-14T16:00:00Z",
        .endpoint = .all,
        .max_results = 100,
        .max_posts = default_thread_max_posts,
        .estimated_cost_micros = 100000,
    };
    const build = try buildAndPersistThreadMembership(&db, allocator, plan);
    try upsertThreadExpansionStatus(&db, allocator, plan, build.status, build.confidence, build.post_count, 2, null);
    const raw_json = try jsonValueAlloc(allocator, root.value);
    defer allocator.free(raw_json);
    const complete = try buildRawXBookmarkMarkdown(&db, allocator, "200", "https://x.com/alice/status/200", "https://twitter.com/i/web/status/200", "Thread opener 1/N", "2026-05-14T10:00:00.000Z", "1", "alice", "Alice", "2026-05-14", "inbox", raw_json);
    defer allocator.free(complete);
    try std.testing.expect(std.mem.indexOf(u8, complete, "thread_expansion_status: \"complete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete, "## Source Text\n\n### Post 1\n\nThread opener 1/N") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete, "### Post 2\n\nSecond post") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete, "### Thread Post 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete, "Second post") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete, "Comment") == null);
}

test "thread search ingestion persists filtered same-author results only" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "thread-ingest.sqlite" });
    defer allocator.free(db_path);
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);

    var author = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":\"1\",\"username\":\"alice\",\"name\":\"Alice\"}", .{});
    defer author.deinit();
    try upsertUserFromValue(&db, allocator, author.value);
    var root = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"300","author_id":"1","conversation_id":"300","created_at":"2026-05-14T10:00:00.000Z","text":"Thread opener 1/N"}
    , .{});
    defer root.deinit();
    try upsertTweetFromValue(&db, allocator, root.value);

    const plan = ThreadExpansionPlan{
        .root_tweet_id = "300",
        .root_author_id = "1",
        .root_author_username = "alice",
        .conversation_id = "300",
        .query = "conversation_id:300 from:alice",
        .start_time = "2026-05-14T10:00:00Z",
        .end_time = "2026-05-14T16:00:00Z",
        .endpoint = .recent,
        .max_results = 100,
        .max_posts = default_thread_max_posts,
        .estimated_cost_micros = 100000,
    };
    var response = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "data": [
        \\    {"id":"301","author_id":"1","conversation_id":"300","created_at":"2026-05-14T10:01:00.000Z","text":"Second post","referenced_tweets":[{"type":"replied_to","id":"300"}]},
        \\    {"id":"302","author_id":"2","conversation_id":"300","created_at":"2026-05-14T10:02:00.000Z","text":"Comment","referenced_tweets":[{"type":"replied_to","id":"300"}]}
        \\  ],
        \\  "includes": {
        \\    "users": [{"id":"2","username":"bob","name":"Bob"}],
        \\    "tweets": [{"id":"303","author_id":"2","conversation_id":"300","created_at":"2026-05-14T10:03:00.000Z","text":"Included comment"}]
        \\  }
        \\}
    , .{});
    defer response.deinit();
    try ingestThreadSearchResponse(&db, allocator, response.value, plan);
    try std.testing.expect(try tweetExists(&db, "301"));
    try std.testing.expect(!try tweetExists(&db, "302"));
    try std.testing.expect(!try tweetExists(&db, "303"));
}

test "cached complete thread expansion is skipped by default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "thread-cache.sqlite" });
    var db = try Db.open(db_path, allocator);
    defer db.close();
    try applyMigrations(&db);
    try db.exec(
        \\INSERT INTO thread_expansions(root_tweet_id, root_author_id, root_author_username, conversation_id, status, method, confidence, post_count, first_seen_at, last_seen_at)
        \\VALUES ('400', '1', 'alice', '400', 'complete', 'search_all', 'high', 2, 'now', 'now');
    );
    const paths = Paths{ .config_path = "config.json", .config_dir = ".", .state_dir = "." };
    const cfg = try Config.default(allocator, paths, null);
    const processed = try expandThreads(&db, allocator, cfg, null, .{ .tweet_id = "400", .yes = true });
    try std.testing.expectEqual(@as(u32, 0), processed);
}
