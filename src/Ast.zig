const Ast = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

const builtin = @import("builtin");
const ziggy = @import("ziggy");
const scripty = @import("scripty");
const ScriptyVM = scripty.VM(Value);

const superhtml = @import("superhtml");
const html = superhtml.html;

const supermd = @import("root.zig");
const c = supermd.c;
const Span = supermd.Span;
const Range = supermd.Range;
const Value = supermd.Value;
const Content = supermd.Content;
const Directive = supermd.Directive;

const utils = @import("context/utils.zig");
const Node = @import("Node.zig");

const log = std.log.scoped(.supermd);

md: CMarkAst,
errors: []const Error,
ids: std.StringArrayHashMapUnmanaged(Node) = .{},
footnotes: std.StringArrayHashMapUnmanaged(Footnote) = .{},
arena: std.heap.ArenaAllocator.State,

pub const Footnote = struct {
    node: Node,
    def_id: []const u8,
    ref_ids: [][]const u8,
};

pub const Error = struct {
    main: Range,
    kind: Kind,

    pub const Kind = union(enum) {
        inline_html,
        // nested_section_directive,
        // section_must_not_have_text,
        // end_section_in_heading,
        // must_be_first_under_blockquote,
        // must_be_first_under_heading,
        heading_section_missing_id,
        invalid_ref,
        no_alt_in_links,
        expression_in_image_syntax,
        empty_expression,
        duplicate_id: struct {
            id: []const u8,
            original: Node,
        },
        scripty: struct {
            len: u32,
            span: Span,
            err: []const u8,
        },
        html: html.Ast.Error,
        heading_skip: struct {
            have: u8,
            last: ?Node,
        },
    };

    pub fn fmt(
        err: Error,
        frontmatter_line_count: u32,
        src: []const u8,
        path: []const u8,
    ) Fmt {
        return .{
            .err = err,
            .src = src,
            .path = path,
            .fm_lines = frontmatter_line_count,
        };
    }

    pub const Fmt = struct {
        err: Error,
        src: []const u8,
        path: []const u8,
        fm_lines: u32,

        pub fn format(f: Fmt, w: *Io.Writer) Io.Writer.Error!void {
            try w.print("{s}:{}:{}: ", .{
                f.path,
                f.fm_lines + f.err.main.start.row,
                f.err.main.start.col,
            });

            var lp = linePreview(f.src, f.err.main);
            lp.carets += 1;
            switch (f.err.kind) {
                .inline_html => {
                    try w.print(
                        \\error: markdown inline html syntax is forbidden
                        \\{f}
                        \\| -- note: superhtml supports `=html` code blocks as an alternative
                        \\
                    , .{lp});
                },
                // .nested_section_directive => {
                //     try w.print(
                //         \\section directives must be placed at the top level
                //         \\
                //     , .{});
                // },
                // .section_must_not_have_text => {
                //     try w.print(
                //         \\don't put text in the square brackets when defining a section
                //         \\
                //     , .{});
                // },
                .heading_section_missing_id => {
                    try w.print(
                        \\error: missing section id
                        \\{f}
                        \\| -- note: all heading sections must have an id
                        \\
                    , .{lp});
                },
                .invalid_ref => {
                    try w.print(
                        \\error: unknown ref
                        \\{f}
                        \\
                    , .{lp});
                },
                .no_alt_in_links => {
                    try w.print(
                        \\error: vanilla alt text in scripted link syntax
                        \\{f}
                        \\| -- note: use `.alt()` to provide alt text
                        \\
                    , .{lp});
                },
                .expression_in_image_syntax => {
                    try w.print(
                        \\error: scripty expression in image syntax
                        \\{f}
                        \\| -- note: scripty expressions go in link syntax, remove the '!'
                        \\
                    , .{lp});
                },
                .empty_expression => {
                    try w.print(
                        \\error: link syntax without link or scripty expression
                        \\{f}
                        \\
                    , .{lp});
                },
                .duplicate_id => |dup| {
                    const orig = dup.original.range();
                    var lp_dup = linePreview(f.src, orig);
                    lp_dup.carets += 1;
                    try w.print(
                        \\error: duplicate id '{s}'
                        \\{f}
                        \\| -- note: first definition was on line {} col {}:
                        \\{f}
                        \\
                    , .{
                        dup.id,
                        lp,
                        f.fm_lines + orig.start.row,
                        orig.start.col,
                        lp_dup,
                    });
                },
                .scripty => |sy| {
                    const full_span = f.err.main.span(f.src);

                    const range = if (std.mem.indexOf(u8, full_span.slice(f.src), "](")) |rel| blk: {
                        const base: u32 = @intCast(full_span.start + rel + "](".len);
                        const span: Span = .{
                            .start = base + sy.span.start,
                            .end = base + sy.span.end,
                        };
                        break :blk span.range(f.src);
                    } else f.err.main;

                    const lp_scripty = linePreview(f.src, range);
                    try w.print(
                        \\[scripty] error: {s}
                        \\{f}
                        \\
                    , .{ sy.err, lp_scripty });
                },
                .html => |html_err| {
                    try w.print(
                        \\[html] error: {f}
                        \\{f}
                        \\
                    , .{
                        html_err.tag.fmt("test"),
                        linePreview(f.src, f.err.main),
                    });
                },
                .heading_skip => |gap| {
                    try w.print(
                        \\error: skipped heading level
                        \\{f}
                        \\
                    , .{lp});

                    if (gap.last) |last| {
                        const range = last.range();
                        var lp_heading = linePreview(f.src, range);
                        lp_heading.carets += 1;
                        try w.print(
                            \\| -- note: previous heading (level {}):
                            \\{f}
                            \\
                        , .{ last.headingLevel(), lp_heading });
                    } else {
                        try w.writeAll(
                            \\| -- note: supermd documents start at heading level 1 ('#')
                            \\| -- note: if your intent is to start the content at '<h2>', you
                            \\|          can change how headings render in html by setting the
                            \\|          corresponding option in your zine config file
                            \\
                        );
                    }

                    // : struct {
                    //     have: u8,
                    //     last: u8,
                    // },
                },
            }
        }
    };
};

pub fn deinit(a: Ast, gpa: Allocator) void {
    // TODO: stop leaking the cmark ast
    a.arena.promote(gpa).deinit();
}

pub const CmarkParser = struct {
    parser: *c.cmark_parser,

    pub fn default() CmarkParser {
        const options = c.CMARK_OPT_DEFAULT | c.CMARK_OPT_SAFE | c.CMARK_OPT_SMART | c.CMARK_OPT_FOOTNOTES;

        const parser = c.cmark_parser_new(options);

        _ = c.cmark_parser_attach_syntax_extension(
            parser,
            c.cmark_find_syntax_extension("table"),
        );

        _ = c.cmark_parser_attach_syntax_extension(
            parser,
            c.cmark_find_syntax_extension("strikethrough"),
        );

        _ = c.cmark_parser_attach_syntax_extension(
            parser,
            c.cmark_find_syntax_extension("tasklist"),
        );

        _ = c.cmark_parser_attach_syntax_extension(
            parser,
            c.cmark_find_syntax_extension("autolink"),
        );
        return .{ .parser = parser.? };
    }
};

pub const Options = struct {
    auto_target_blank: bool = false,
};

pub fn init(
    gpa: Allocator,
    src: []const u8,
    rcp: CmarkParser,
    opts: Options,
) error{OutOfMemory}!Ast {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_impl.allocator();

    log.debug("starting analysis", .{});
    var p: Parser = .{ .gpa = arena, .opts = opts };

    c.cmark_parser_feed(rcp.parser, src.ptr, src.len);
    const ast: CMarkAst = .{
        .root = .{ .n = c.cmark_parser_finish(rcp.parser).? },
        .extensions = c.cmark_parser_get_syntax_extensions(rcp.parser),
    };

    var current = ast.root.firstChild();
    var last_heading_lvl: i32 = 0;
    var last_heading: ?Node = null;
    while (current) |n| : (current = n.nextSibling()) switch (n.nodeType()) {
        .BLOCK_QUOTE => try p.analyzeBlockQuote(n),
        .LIST => try p.analyzeList(n),
        .ITEM => try p.analyzeItem(n),
        .CODE_BLOCK => try p.analyzeCodeBlock(n),
        .HTML_BLOCK => try p.addError(n.range(), .inline_html),
        .CUSTOM_BLOCK => try p.analyzeCustomBlock(n),
        .PARAGRAPH => try p.analyzeParagraph(n),
        .HEADING => {
            const new_lvl = n.headingLevel();
            if (!p.sectioned and (new_lvl > last_heading_lvl + 1)) {
                try p.addError(n.range(), .{
                    .heading_skip = .{
                        .have = @intCast(new_lvl),
                        .last = last_heading,
                    },
                });
            }
            last_heading_lvl = new_lvl;
            last_heading = n;
            try p.analyzeHeading(n);
        },
        .THEMATIC_BREAK => {},
        .FOOTNOTE_DEFINITION => try p.analyzeFootnoteDefinition(n),

        // Inlines
        .TEXT,
        .SOFTBREAK,
        .LINEBREAK,
        .CODE,
        .HTML_INLINE,
        .CUSTOM_INLINE,
        .EMPH,
        .STRONG,
        .LINK,
        .IMAGE,
        .FOOTNOTE_REFERENCE,
        => unreachable,

        else => |nt| if (@intFromEnum(nt) == c.CMARK_NODE_STRIKETHROUGH) {
            unreachable; // can't be a block level node
        } else if (@intFromEnum(nt) == c.CMARK_NODE_TABLE) {
            try p.analyzeTable(n);
        } else std.debug.panic(
            "TODO: implement support for {x}",
            .{n.nodeType()},
        ),
    };

    for (p.referenced_ids.keys()) |k| {
        if (!p.ids.contains(k)) {
            try p.errors.append(arena, .{
                .main = p.referenced_ids.get(k).?.range(),
                .kind = .invalid_ref,
            });
        }
    }

    for (p.footnotes.values()) |footnote| {
        footnote.node.unlink();
    }

    return .{
        .md = ast,
        .errors = try p.errors.toOwnedSlice(arena),
        .ids = p.ids,
        .footnotes = p.footnotes,
        .arena = arena_impl.state,
    };
}

const Parser = struct {
    gpa: Allocator,
    opts: Options,
    errors: std.ArrayList(Error) = .empty,
    sectioned: bool = false,
    ids: std.StringArrayHashMapUnmanaged(Node) = .{},
    referenced_ids: std.StringArrayHashMapUnmanaged(Node) = .{},
    footnotes: std.StringArrayHashMapUnmanaged(Footnote) = .{},
    vm: ScriptyVM = .{},

    pub fn addId(p: *Parser, id: []const u8, n: Node) !void {
        const gop = try p.ids.getOrPut(p.gpa, id);
        if (gop.found_existing) {
            try p.addError(n.range(), .{
                .duplicate_id = .{
                    .id = id,
                    .original = gop.value_ptr.*,
                },
            });
            return;
        }

        gop.value_ptr.* = n;
    }

    pub fn analyzeHeading(p: *Parser, h: Node) !void {
        const link = h.firstChild() orelse return;

        var next: ?Node = link;
        blk: {
            if (link.nodeType() != .LINK) break :blk;
            next = link.nextSibling();
            const src = link.link() orelse break :blk;
            const directive = try p.runScript(link, src) orelse break :blk;
            switch (directive.kind) {
                else => {
                    if (directive.id) |id| try p.addId(id, h);
                    break :blk;
                },
                .block => return,
                .heading => {
                    if (directive.id) |id| try p.addId(id, h);
                    _ = try h.setDirective(p.gpa, directive, false);
                },
                .section => {
                    p.sectioned = true;
                    const id = directive.id orelse {
                        try p.addError(link.range(), .heading_section_missing_id);
                        return;
                    };

                    try p.addId(id, h);

                    // Copies the directive.
                    _ = try h.setDirective(p.gpa, directive, true);

                    // We mutate the original one to a link to the
                    // block, useful both for sticky headings and
                    // for generally making it easier for users to
                    // deep link the content.
                    directive.id = null;
                    directive.attrs = &.{};
                    directive.kind = .{
                        .link = .{
                            .src = .{ .url = "" },
                            .ref = id,
                        },
                    };
                },
            }
        }

        try p.analyzeSiblings(next, h);
    }

    pub fn analyzeTable(p: *Parser, table: Node) !void {
        var row = table.firstChild();
        while (row) |r| : (row = r.nextSibling()) {
            var cell = r.firstChild();
            while (cell) |cl| : (cell = cl.nextSibling()) {
                try p.analyzeSiblings(cl.firstChild(), r);
            }
        }
    }

    pub fn analyzeParagraph(p: *Parser, block: Node) !void {
        try p.analyzeSiblings(block.firstChild(), block);
    }

    pub fn analyzeCodeBlock(p: *Parser, block: Node) !void {
        const fence = block.fenceInfo() orelse return;
        if (std.mem.startsWith(u8, fence, "=html")) {
            const src = block.literal() orelse return;
            const ast = try html.Ast.init(p.gpa, src, .html, false);
            defer ast.deinit(p.gpa);
            for (ast.errors) |err| {
                const md_range = block.range();
                const html_range = err.main_location.range(src);

                try p.errors.append(p.gpa, .{
                    .main = .{
                        .start = .{
                            .row = md_range.start.row + 1 + html_range.start.row,
                            .col = 1 + html_range.start.col,
                        },
                        .end = .{
                            .row = md_range.start.row + 1 + html_range.end.row,
                            .col = 1 + html_range.end.col,
                        },
                    },
                    .kind = .{ .html = err },
                });
            }
        }
        // try p.analyzeSiblings(block.firstChild(), block);
    }
    pub fn analyzeList(p: *Parser, block: Node) !void {
        try p.analyzeSiblings(block.firstChild(), block);
    }
    pub fn analyzeCustomBlock(p: *Parser, block: Node) !void {
        try p.analyzeSiblings(block.firstChild(), block);
    }
    pub fn analyzeBlockQuote(p: *Parser, quote: Node) !void {
        const para_or_h = quote.firstChild() orelse return;
        // std.debug.assert(para_or_h.nodeType() == .PARAGRAPH or
        //     para_or_h.nodeType() == .HEADING);
        const link = para_or_h.firstChild() orelse return;
        var next: ?Node = link;
        blk: {
            if (link.nodeType() != .LINK) break :blk;
            next = link.nextSibling() orelse para_or_h.nextSibling();
            const src = link.link() orelse break :blk;
            const directive = try p.runScript(link, src) orelse break :blk;
            if (directive.id) |id| try p.addId(id, quote);
            switch (directive.kind) {
                else => break :blk,
                .block => {
                    _ = try quote.setDirective(p.gpa, directive, false);

                    // link.unlink();
                    // const h1 = try Node.create(.HEADING);
                    // try h1.prependChild(link);
                    // try quote.prependChild(h1);
                },
            }
        }

        try p.analyzeSiblings(next, quote);
    }
    pub fn analyzeItem(p: *Parser, block: Node) !void {
        try p.analyzeSiblings(block.firstChild(), block);
    }
    pub fn analyzeFootnoteReference(p: *Parser, footnoteRef: Node) !void {
        const name = footnoteRef.literal().?;
        const result = try p.footnotes.getOrPut(p.gpa, name);
        log.debug("found footnote {s}: {any}", .{ name, result.found_existing });
        if (!result.found_existing) {
            const def = footnoteRef.parentFootnoteDef().?;
            const def_id = try std.fmt.allocPrint(p.gpa, "fn-{d}", .{result.index + 1});
            try p.addId(def_id, def);

            const ref_ids = try p.gpa.alloc([]const u8, @intCast(def.footnoteDefCount()));
            for (ref_ids, 0..) |_, ref_idx| {
                ref_ids[ref_idx] = try std.fmt.allocPrint(p.gpa, "fn-{d}-ref-{d}", .{ result.index + 1, ref_idx + 1 });
            }

            result.value_ptr.* = .{
                .def_id = def_id,
                .ref_ids = ref_ids,
                .node = def,
            };
        }

        // cmark-gfm uses 1-based indices.
        const ref_id = result.value_ptr.*.ref_ids[@intCast(footnoteRef.footnoteRefIx() - 1)];
        try p.addId(ref_id, footnoteRef);
    }
    pub fn analyzeFootnoteDefinition(p: *Parser, footnote: Node) !void {
        try p.analyzeSiblings(footnote.firstChild(), footnote);
    }

    pub fn analyzeSiblings(p: *Parser, start: ?Node, stop: Node) error{OutOfMemory}!void {
        var current = start;
        while (current) |n| {
            const kind = n.nodeType();
            switch (kind) {
                .LIST,
                .ITEM,
                .CODE_BLOCK,
                .HTML_BLOCK,
                .CUSTOM_BLOCK,
                .PARAGRAPH,
                .HEADING,
                => {
                    current = n.nextSibling();
                },
                else => {
                    current = n.next(stop);
                },
            }

            switch (kind) {
                .BLOCK_QUOTE => try p.analyzeBlockQuote(n),
                .LIST => try p.analyzeList(n),
                .ITEM => try p.analyzeItem(n),
                .CODE_BLOCK => try p.analyzeCodeBlock(n),
                .HTML_BLOCK => try p.addError(n.range(), .inline_html),
                .CUSTOM_BLOCK => try p.analyzeCustomBlock(n),
                .PARAGRAPH => try p.analyzeParagraph(n),
                .HEADING => try p.analyzeHeading(n),
                .FOOTNOTE_REFERENCE => try p.analyzeFootnoteReference(n),
                .IMAGE => {
                    const src = n.link() orelse return;
                    switch (src[0]) {
                        '$' => {
                            try p.addError(n.range(), .expression_in_image_syntax);
                            continue;
                        },
                        '/' => {
                            var d: Directive = .{
                                .kind = .{
                                    .image = .{
                                        .src = .{ .site_asset = .{ .ref = src[1..] } },
                                        .alt = n.title(),
                                    },
                                },
                            };
                            _ = try n.setDirective(p.gpa, &d, true);
                        },
                        else => {
                            if (std.mem.indexOf(u8, src, "://") != null) {
                                _ = std.Uri.parse(src) catch {
                                    try p.addError(n.range(), .{
                                        .scripty = .{
                                            .len = @intCast(src.len),
                                            .span = .{
                                                .start = 0,
                                                .end = @intCast(src.len),
                                            },
                                            .err = "invalid URL",
                                        },
                                    });
                                    continue;
                                };
                                var d: Directive = .{
                                    .kind = .{
                                        .image = .{
                                            .src = .{ .url = src },
                                            .alt = n.title(),
                                        },
                                    },
                                };
                                _ = try n.setDirective(p.gpa, &d, true);
                                return;
                            }

                            const clean_src = if (std.mem.startsWith(u8, src, "./")) src[2..] else src;
                            var d: Directive = .{
                                .kind = .{
                                    .image = .{
                                        .src = .{ .page_asset = .{ .ref = clean_src } },
                                        .alt = n.title(),
                                    },
                                },
                            };
                            _ = try n.setDirective(p.gpa, &d, true);
                        },
                    }
                },
                .LINK => {
                    const src = n.link() orelse continue;
                    const directive = try p.runScript(n, src) orelse continue;
                    switch (directive.kind) {
                        else => {
                            if (directive.id) |id| try p.addId(id, n);
                        },
                        .mathtex => {
                            current = n.nextSibling();
                        },
                        .section, .heading => {
                            if (directive.kind == .section) {
                                p.sectioned = true;
                            }
                            const parent = n.parent().?;
                            _ = try parent.setDirective(p.gpa, directive, false);

                            if (directive.id) |id| try p.addId(id, parent);
                        },
                    }
                },
                else => if (@intFromEnum(kind) == c.CMARK_NODE_TABLE) {
                    try p.analyzeTable(n);
                } else continue,
            }
        }
    }

    // If the script results in anything other than a Directive,
    // an error is appended and the function will return null.
    fn runScript(p: *Parser, n: Node, src: []const u8) !?*Directive {
        if (src.len == 0) {
            try p.addError(n.range(), .empty_expression);
            return null;
        }

        if (n.title() != null) {
            try p.addError(n.range(), .no_alt_in_links);
        }

        switch (src[0]) {
            '$' => {},
            '#' => {
                var d: Directive = .{
                    .kind = .{
                        .link = .{
                            .ref = src[1..],
                            .src = .{ .self_page = null },
                        },
                    },
                };
                try p.referenced_ids.put(p.gpa, src[1..], n);
                return n.setDirective(p.gpa, &d, true);
            },
            '/' => {
                var it = std.mem.splitScalar(u8, src[1..], '#');
                const path_raw = it.first();
                const ref = it.next();
                const path = utils.stripTrailingSlash(path_raw);

                var d: Directive = .{
                    .kind = .{
                        .link = .{
                            .ref = ref,
                            .src = .{
                                .page = .{ .ref = path, .kind = .absolute },
                            },
                        },
                    },
                };
                return n.setDirective(p.gpa, &d, true);
            },
            '.' => {
                var it = std.mem.tokenizeScalar(u8, src[2..], '#');
                const path = utils.stripTrailingSlash(it.next() orelse "");
                const ref = it.next();
                var d: Directive = .{
                    .kind = .{
                        .link = .{
                            .ref = ref,
                            .src = .{
                                .page = .{
                                    .ref = path,
                                    .kind = .sub,
                                },
                            },
                        },
                    },
                };
                return n.setDirective(p.gpa, &d, true);
            },
            else => {
                if (std.mem.startsWith(u8, src, "mailto:")) {
                    var d: Directive = .{
                        .kind = .{
                            .link = .{
                                .src = .{ .url = src },
                                .new = p.opts.auto_target_blank,
                            },
                        },
                    };
                    return n.setDirective(p.gpa, &d, true);
                }
                if (std.mem.indexOf(u8, src, "://") != null) {
                    _ = std.Uri.parse(src) catch {
                        try p.addError(n.range(), .{
                            .scripty = .{
                                .len = @intCast(src.len),
                                .span = .{
                                    .start = 0,
                                    .end = @intCast(src.len),
                                },
                                .err = "invalid URL",
                            },
                        });
                        return null;
                    };
                    var d: Directive = .{
                        .kind = .{
                            .link = .{
                                .src = .{ .url = src },
                                .new = p.opts.auto_target_blank,
                            },
                        },
                    };
                    return n.setDirective(p.gpa, &d, true);
                }

                var d: Directive = .{
                    .kind = .{
                        .link = .{
                            .src = .{
                                .page = .{ .ref = src, .kind = .sibling },
                            },
                        },
                    },
                };
                return n.setDirective(p.gpa, &d, true);
            },
        }

        var ctx: Content = .{};
        const res = p.vm.run(p.gpa, &ctx, src, .{}) catch |err| {
            std.debug.panic("md scripty err: {}", .{err});
        };
        switch (res.value) {
            .directive => |d| {
                // NOTE: we're returning a pointer to the copy
                if (try d.validate(p.gpa, n)) |err| {
                    try p.addError(n.range(), .{
                        .scripty = .{
                            .len = @intCast(src.len),
                            .span = .{ .start = 0, .end = @intCast(src.len) },
                            .err = err.err,
                        },
                    });
                }

                switch (d.kind) {
                    else => {},
                    .link => |lnk| switch (lnk.src.?) {
                        else => {},
                        .self_page => {
                            if (!lnk.ref_unsafe and lnk.ref != null) {
                                const hash = lnk.ref.?;
                                try p.referenced_ids.put(p.gpa, hash, n);
                            }
                        },
                    },
                }
                return n.setDirective(p.gpa, d, true);
            },
            .err => |msg| {
                try p.addError(n.range(), .{
                    .scripty = .{
                        .len = @intCast(src.len),
                        .span = .{
                            .start = res.loc.start,
                            .end = res.loc.end,
                        },
                        .err = msg,
                    },
                });
                return null;
            },
            else => unreachable,
        }
    }

    pub fn addError(p: *Parser, range: Range, kind: Error.Kind) !void {
        try p.errors.append(p.gpa, .{ .main = range, .kind = kind });
    }
};

pub const Iter = struct {
    it: *c.cmark_iter,

    pub fn init(n: Node) Iter {
        return .{ .it = c.cmark_iter_new(n.n).? };
    }

    pub fn deinit(self: Iter) void {
        c.cmark_iter_free(self.it);
    }

    pub fn reset(self: Iter, current: Node, dir: Event.Dir) void {
        c.cmark_iter_reset(
            self.it,
            current.n,
            switch (dir) {
                .enter => c.CMARK_EVENT_ENTER,
                .exit => c.CMARK_EVENT_EXIT,
            },
        );
    }

    pub const Event = struct {
        dir: Dir,
        node: Node,
        pub const Dir = enum { enter, exit };
    };
    pub fn next(self: Iter) ?Event {
        var exited = false;
        while (true) switch (c.cmark_iter_next(self.it)) {
            c.CMARK_EVENT_DONE => return null,
            c.CMARK_EVENT_EXIT => {
                exited = true;
                break;
            },
            c.CMARK_EVENT_ENTER => break,
            else => unreachable,
        };

        return .{
            .dir = if (exited) .exit else .enter,
            .node = .{ .n = c.cmark_iter_get_node(self.it).? },
        };
    }

    pub fn exit(self: Iter, node: Node) void {
        c.cmark_iter_reset(self.it, node.n, c.CMARK_EVENT_EXIT);
    }
};

const CMarkAst = struct {
    root: Node,
    extensions: [*]c.cmark_llist,
};

fn cmark(src: []const u8) CMarkAst {
    const extensions = blk: {
        c.cmark_gfm_core_extensions_ensure_registered();
        break :blk supermd.cmark_list_syntax_extensions(
            c.cmark_get_arena_mem_allocator(),
        );
    };

    const options = c.CMARK_OPT_DEFAULT | c.CMARK_OPT_SAFE | c.CMARK_OPT_SMART | c.CMARK_OPT_FOOTNOTES;
    const parser = c.cmark_parser_new(options);
    defer c.cmark_parser_free(parser);

    _ = c.cmark_parser_attach_syntax_extension(
        parser,
        c.cmark_find_syntax_extension("table"),
    );

    _ = c.cmark_parser_attach_syntax_extension(
        parser,
        c.cmark_find_syntax_extension("strikethrough"),
    );

    _ = c.cmark_parser_attach_syntax_extension(
        parser,
        c.cmark_find_syntax_extension("tasklist"),
    );

    _ = c.cmark_parser_attach_syntax_extension(
        parser,
        c.cmark_find_syntax_extension("autolink"),
    );

    c.cmark_parser_feed(parser, src.ptr, src.len);
    const root = c.cmark_parser_finish(parser).?;
    return .{
        .root = .{ .n = root },
        .extensions = extensions,
    };
}

pub fn format(
    a: Ast,
    w: *Writer,
) !void {
    for (a.errors, 0..) |e, i| {
        try w.print("errors[{}] = '{s}' {s} \n", .{
            i, @tagName(e.kind),
            switch (e.kind) {
                .scripty => |s| s.err,
                else => "",
            },
        });
    }
    var it = a.ids.iterator();
    while (it.next()) |kv| {
        const range = kv.value_ptr.range();
        try w.print("ids[{}:{}] = '{s}'\n", .{
            range.start.row,
            range.start.col,
            kv.key_ptr.*,
        });
    }

    var current: ?Node = a.md.root.firstChild();
    while (current) |n| : (current = n.next(a.md.root)) {
        const directive = n.getDirective() orelse continue;
        const range = n.range();
        try w.print("directive[{}:{}] = '{s}' #{s}\n", .{
            range.start.row,
            range.start.col,
            @tagName(directive.kind),
            directive.id orelse "",
        });
    }
}

pub const LinePreview = struct {
    code: []const u8,
    spaces: u32,
    carets: u32,

    pub fn format(lp: LinePreview, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("|    {s}\n", .{lp.code});
        try w.writeAll("|    ");
        try w.splatByteAll(' ', lp.spaces);
        try w.splatByteAll('^', lp.carets);
    }
};

pub fn linePreview(src: []const u8, range: Range) LinePreview {
    const line = blk: {
        var it = std.mem.splitScalar(u8, src, '\n');
        for (1..range.start.row) |_| _ = it.next();
        break :blk it.next().?;
    };

    const line_trim_left = std.mem.trimStart(u8, line, &std.ascii.whitespace);
    const start_trim_left = line.len - line_trim_left.len;
    const line_trim = std.mem.trimEnd(u8, line_trim_left, &std.ascii.whitespace);

    const caret_len = if (range.start.row == range.end.row)
        range.end.col - range.start.col
    else
        line_trim.len - start_trim_left;
    const caret_spaces_len = range.start.col - 1 - start_trim_left;

    return .{
        .code = line_trim,
        .spaces = @intCast(caret_spaces_len),
        .carets = @intCast(if (caret_len == 0) 1 else caret_len),
    };
}

test "basics" {
    const case =
        \\# [Title]($section.id('foo'))
    ;
    const expected =
        \\ids[1:1] = 'foo'
        \\directive[1:1] = 'section' #foo
        \\directive[1:3] = 'link' #
        \\
    ;

    c.cmark_gfm_core_extensions_ensure_registered();
    const ast = try Ast.init(std.testing.allocator, case, .default(), .{});
    defer ast.deinit(std.testing.allocator);
    try std.testing.expectFmt(expected, "{f}", .{ast});
}

test "image" {
    const case =
        \\This is an inline image [alt text]($image.asset('foo.jpg'))
        \\
        \\[this is a block image]($image.asset('bar.jpg'))
        \\
    ;

    const expected =
        \\directive[1:25] = 'image' #
        \\directive[3:1] = 'image' #
        \\
    ;

    c.cmark_gfm_core_extensions_ensure_registered();
    const ast = try Ast.init(std.testing.allocator, case, .default(), .{});
    defer ast.deinit(std.testing.allocator);
    try std.testing.expectFmt(expected, "{f}", .{ast});
}
