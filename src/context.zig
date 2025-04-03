const std = @import("std");
const scripty = @import("scripty");
const ziggy = @import("ziggy");
const utils = @import("context/utils.zig");
const Node = @import("Node.zig");
const Signature = @import("doctypes.zig").Signature;
const Allocator = std.mem.Allocator;

pub const Content = struct {
    section: Directive = .{ .kind = .{ .section = .{} } },
    block: Directive = .{ .kind = .{ .block = .{} } },
    heading: Directive = .{ .kind = .{ .heading = .{} } },
    text: Directive = .{ .kind = .{ .text = .{} } },
    katex: Directive = .{ .kind = .{ .katex = .{} } },
    link: Directive = .{ .kind = .{ .link = .{} } },
    code: Directive = .{ .kind = .{ .code = .{} } },
    image: Directive = .{ .kind = .{ .image = .{} } },
    video: Directive = .{ .kind = .{ .video = .{} } },

    pub const dot = scripty.defaultDot(Content, Value, true);
    pub const description =
        \\The Scripty global scope in SuperMD gives you access to various
        \\rendering directives. Rendering directives allow you to define
        \\embedded assets, give attributes to text, define content sections
        \\that can be rendered individually, and more.
    ;
    pub const Fields = struct {
        pub const section = Section.description;
        pub const block = Block.description;
        pub const heading = Heading.description;
        pub const text = Text.description;
        pub const katex = Katex.description;
        pub const link = Link.description;
        pub const code = Code.description;
        pub const image = Image.description;
        pub const video = Video.description;
    };
    pub const Builtins = struct {};
};

pub const Value = union(enum) {
    content: *Content,
    directive: *Directive,

    // Primitive values
    string: []const u8,
    err: []const u8,
    bool: bool,
    int: i64,

    pub fn errFmt(gpa: Allocator, comptime fmt: []const u8, args: anytype) !Value {
        const err_msg = try std.fmt.allocPrint(gpa, fmt, args);
        return .{ .err = err_msg };
    }

    pub fn fromStringLiteral(s: []const u8) Value {
        return .{ .string = s };
    }

    pub fn fromNumberLiteral(bytes: []const u8) Value {
        const num = std.fmt.parseInt(i64, bytes, 10) catch {
            return .{ .err = "error parsing numeric literal" };
        };
        return .{ .int = num };
    }

    pub fn fromBooleanLiteral(b: bool) Value {
        return .{ .bool = b };
    }

    pub fn from(gpa: Allocator, v: anytype) !Value {
        _ = gpa;
        return switch (@TypeOf(v)) {
            *Content => .{ .content = v },
            *Directive => .{ .directive = v },
            []const u8 => .{ .string = v },
            bool => .{ .bool = v },
            i64, usize => .{ .int = @intCast(v) },
            *Value => v.*,
            else => @compileError("TODO: implement Value.from for " ++ @typeName(@TypeOf(v))),
        };
    }

    pub fn dot(
        self: *Value,
        gpa: Allocator,
        path: []const u8,
    ) error{OutOfMemory}!Value {
        switch (self.*) {
            .content => |c| return c.dot(gpa, path),
            .directive => return .{ .err = "field access on directive" },
            else => return .{ .err = "field access on primitive value" },
        }
    }

    pub const call = scripty.defaultCall(Value, Content);

    pub fn builtinsFor(
        comptime tag: @typeInfo(Value).@"union".tag_type.?,
    ) type {
        const f = std.meta.fieldInfo(Value, tag);
        switch (@typeInfo(f.type)) {
            .pointer => |ptr| {
                if (@typeInfo(ptr.child) == .@"struct") {
                    return @field(ptr.child, "Builtins");
                }
            },
            .@"struct" => {
                return @field(f.type, "Builtins");
            },
            else => {},
        }

        return struct {};
    }
};

pub const Directive = struct {
    id: ?[]const u8 = null,
    attrs: ?[][]const u8 = null,
    title: ?[]const u8 = null,
    data: Data = .{},

    kind: Kind,

    pub const Data = ziggy.dynamic.Map(ziggy.dynamic.Value);
    pub const Kind = union(enum) {
        section: Section,
        block: Block,
        heading: Heading,
        image: Image,
        video: Video,
        link: Link,
        code: Code,
        text: Text,
        katex: Katex,
        // sound: struct {
        //     id: ?[]const u8 = null,
        //     attrs: ?[]const []const u8 = null,
        // },
    };

    pub fn validate(d: *Directive, gpa: Allocator, ctx: Node) !?Value {
        switch (d.kind) {
            inline else => |v| {
                const T = @TypeOf(v);
                if (@hasDecl(T, "validate")) {
                    return T.validate(gpa, d, ctx);
                }

                inline for (T.mandatory) |m| {
                    const f = @tagName(m);
                    if (@field(v, f) == null) {
                        return try Value.errFmt(gpa,
                            \\mandatory field '{s}' is unset
                        , .{f});
                    }
                }
                inline for (T.directive_mandatory) |dm| {
                    const f = @tagName(dm);
                    if (@field(d, f) == null) {
                        return try Value.errFmt(gpa,
                            \\mandatory field '{s}' is unset
                        , .{f});
                    }
                }
            },
        }
        return null;
    }

    pub const fallbackCall = utils.directiveCall;
    pub const PassByRef = true;
    pub const description =
        \\Each Directive has a different set of properties that can be set.
        \\Properties that can be set on all directives are listed here.
    ;
    pub const Builtins = struct {
        pub const id = struct {
            pub const signature: Signature = .{
                .params = &.{.str},
                .ret = .anydirective,
            };
            pub const description =
                \\Sets the unique identifier field of this directive.
            ;

            pub fn call(
                self: *Directive,
                _: Allocator,
                _: *const Content,
                args: []const Value,
            ) !Value {
                const bad_arg: Value = .{
                    .err = "expected 1 string argument",
                };
                if (args.len != 1) return bad_arg;

                const value = switch (args[0]) {
                    .string => |s| s,
                    else => return bad_arg,
                };

                if (self.id != null) return .{ .err = "field already set" };

                self.id = value;

                return .{ .directive = self };
            }
        };
        pub const attrs = struct {
            pub const signature: Signature = .{
                .params = &.{ .str, .{ .Many = .str } },
                .ret = .anydirective,
            };
            pub const description =
                \\Appends to the attributes field of this Directive.
            ;

            pub fn call(
                self: *Directive,
                gpa: Allocator,
                _: *const Content,
                args: []const Value,
            ) !Value {
                const bad_arg: Value = .{
                    .err = "expected 1 or more string arguments",
                };
                if (args.len == 0) return bad_arg;

                if (self.attrs != null) return .{ .err = "field already set" };

                const new = try gpa.alloc([]const u8, args.len);
                self.attrs = new;
                for (args, new) |arg, *attr| {
                    const value = switch (arg) {
                        .string => |s| s,
                        else => return bad_arg,
                    };
                    attr.* = value;
                }

                return .{ .directive = self };
            }
        };
        pub const title = struct {
            pub const signature: Signature = .{
                .params = &.{.str},
                .ret = .anydirective,
            };
            pub const description =
                \\Title for this directive, mostly used as metadata that does
                \\not get rendered directly in the page.
            ;
            pub fn call(
                self: *Directive,
                _: Allocator,
                _: *const Content,
                args: []const Value,
            ) !Value {
                const bad_arg: Value = .{
                    .err = "expected 1 string argument",
                };
                if (args.len != 1) return bad_arg;

                const value = switch (args[0]) {
                    .string => |s| s,
                    else => return bad_arg,
                };

                if (self.title != null) return .{ .err = "field already set" };

                self.title = value;

                return .{ .directive = self };
            }
        };
        pub const data = struct {
            pub const signature: Signature = .{
                .params = &.{ .str, .str, .{ .Many = .str } },
                .ret = .anydirective,
            };
            pub const description =
                \\Adds data key-value pairs of a Directive.
                \\
                \\In SuperHTML data key-value pairs can be accessed 
                \\programmatically in a template when rendering
                \\a section, while data will turn into `data-foo`
                \\attributes otherwise. 
            ;

            pub fn call(
                self: *Directive,
                gpa: Allocator,
                _: *const Content,
                args: []const Value,
            ) !Value {
                const bad_arg: Value = .{
                    .err = "expected a non-zero even number of string arguments",
                };
                if (args.len < 2 or args.len % 2 == 1) return bad_arg;

                if (self.data.fields.count() != 0) return .{
                    .err = "field already set",
                };

                var new: Data = .{};
                var idx: usize = 0;
                while (idx < args.len) {
                    const key = switch (args[idx]) {
                        .string => |s| s,
                        else => return bad_arg,
                    };
                    idx += 1;

                    const value = switch (args[idx]) {
                        .string => |s| s,
                        else => return bad_arg,
                    };
                    idx += 1;

                    const gop = try new.fields.getOrPut(gpa, key);
                    if (gop.found_existing) {
                        return Value.errFmt(
                            gpa,
                            "duplicate key: '{s}'",
                            .{key},
                        );
                    }

                    gop.value_ptr.* = .{ .bytes = value };
                }

                self.data = new;
                return .{ .directive = self };
            }
        };
    };
};

pub const Section = struct {
    end: ?bool = null,

    pub const description =
        \\A content section, used to define a portion of content
        \\that can be rendered individually by a template. 
    ;

    pub fn validate(gpa: Allocator, d: *Directive, ctx: Node) !?Value {
        const parent = ctx.parent().?;

        // A section must be placed either:
        switch (parent.nodeType()) {
            // - at the top level without any embedded text
            //   (because of how md works, it will be inside of a paragraph)
            .PARAGRAPH => {
                if (ctx.firstChild() != null) return .{
                    .err = "top-level section definitions cannot embed any text",
                };

                const not_first = parent.firstChild().?.n != ctx.n;

                const not_top_level = if (parent.parent()) |gp|
                    gp.nodeType() != .DOCUMENT
                else
                    false;

                if (not_first or not_top_level) return .{
                    .err = "sections must be top level elements or be embedded in headings",
                };
            },
            // - In a heading not embedded in other blocks
            .HEADING => {
                if (parent.parent()) |gp| {
                    if (gp.nodeType() != .DOCUMENT) {
                        return try Value.errFmt(
                            gpa,
                            "heading section under '{s}'. heading sections cannot be emdedded in other markdown block elements. did you mean to use `$block`?",
                            .{@tagName(gp.nodeType())},
                        );
                    }
                }
            },
            else => return .{
                .err = "sections must be top level elements or be embedded in headings",
            },
        }

        // End sections additionally cannot have any other property set
        if (d.kind.section.end != null) {
            if (d.id != null or d.attrs != null) {
                return .{
                    .err = "end section directive cannot have any other property set",
                };
            }
        }
        return null;
    }
    pub const Builtins = struct {
        // pub const end = utils.directiveBuiltin("end", .bool,
        //     \\Calling this function makes this section directive
        //     \\terminate a previous section without opening a new
        //     \\one.
        //     \\
        //     \\An end section directive cannot have any other
        //     \\property set.
        // );
    };
};

pub const Text = struct {
    pub const Builtins = struct {};
    pub const description =
        \\Allows giving an id and attributes to some text.
        \\
        \\Example:
        \\```markdown
        \\Hello [World]($text.id('foo').attrs('bar', 'baz'))!
        \\```
        \\
        \\This will be rendered by SuperHTML as:
        \\```html
        \\Hello <span id="foo" class="bar baz">World</span>!
        \\```
    ;

    pub fn validate(_: Allocator, _: *Directive, ctx: Node) !?Value {
        const err: Value = .{
            .err = "text directive must contain some text between square brackets",
        };

        const text = ctx.firstChild().?.literal() orelse return err;
        if (text.len == 0) return err;

        return null;
    }
};

pub const Katex = struct {
    formula: []const u8 = "",

    pub const Builtins = struct {};
    pub const description =
        \\Outputs the given LaTeX formula as a script tag that can be rendered
        \\at runtime by [Katex](https://katex.org). Note that the formula must
        \\be enclosed in backticks to avoid collisions with SuperMD.
        \\
        \\To render math formulas as separate blocks, use this syntax:
        \\
        \\    ```=katex
        \\    x+\sqrt{1-x^2}
        \\    ```
        \\
        \\Example:
        \\```markdown
        \\Here's some [`x+\sqrt{1-x^2}`]($katex) math. 
        \\```
        \\
        \\This will be rendered by SuperHTML as:
        \\```html
        \\Here's some <script type="math/tex">x+\sqrt{1-x^2}</script> math.
        \\```
        \\
        \\It's then the user's responsibility to wire in the necessary Katex JS/CSS
        \\dependencies to obtain runtime rendering of math formulas. Note that
        \\you will need also [this extension](https://github.com/KaTeX/KaTeX/tree/main/contrib/mathtex-script-type) alongside the core Katex dependencies.
        \\
    ;

    pub fn validate(_: Allocator, d: *Directive, ctx: Node) !?Value {
        const err: Value = .{
            .err = "katex directive must contain a LaTeX math formula enclosed in backtics",
        };

        const content = ctx.firstChild().?;
        if (content.nodeType() != .CODE) return err;
        const text = content.literal() orelse return err;
        if (text.len == 0) return err;

        d.kind.katex.formula = text;
        content.unlink();

        return null;
    }
};

pub const Heading = struct {
    pub const Builtins = struct {};
    pub const description =
        \\Allows giving an id and attributes to a heading element.
        \\
        \\Example:
        \\```markdown
        \\# [Title]($heading.id('foo').attrs('bar', 'baz'))
        \\```
        \\
        \\This will be rendered by SuperHTML as:
        \\```html
        \\<h1 id="foo" class="bar baz">Title</h1>
        \\```
    ;

    pub fn validate(_: Allocator, _: *Directive, ctx: Node) !?Value {
        const parent = ctx.parent().?;

        // A heading directive must be placed directly under a md heading
        switch (parent.nodeType()) {
            .HEADING => {},
            else => return .{
                .err = "heading directives must be placed under markdown heading elements",
            },
        }

        return null;
    }
};

pub const Block = struct {
    pub const Builtins = struct {};
    pub const description =
        \\When placed at the beginning of a Markdown quote block, the quote 
        \\block becomes a styleable container for elements.
        \\
        \\SuperHTML will automatically give the class `block` when rendering 
        \\Block directives.
        \\
        \\Example:
        \\```markdown
        \\>[]($block)
        \\>This is now a block.
        \\>Lorem ipsum.
        \\```
        \\
        \\>[]($block)
        \\>This is now a block.
        \\>Lorem ipsum.
        \\
        \\Differently from Sections, Blocks cannot be rendered independently 
        \\and can be nested.
        \\
        \\Example:
        \\```markdown
        \\>[]($block)
        \\>This is now a block.
        \\>
        \\>>[]($block.attrs('padded'))
        \\>>This is a nested block.
        \\>>
        \\>
        \\>back to the outer block
        \\```
        \\
        \\>[]($block)
        \\>This is now a block.
        \\>
        \\>>[]($block.attrs('padded'))
        \\>>This is a nested block.
        \\>
        \\>back to the outer block
        \\
        \\A block can optionally wrap a Markdown heading element. In this case  
        \\the generated Block will be rendered with two separate sub-containers: 
        \\one for the block title and one for the body.
        \\
        \\Example:
        \\```markdown
        \\># [Warning]($block.attrs('warning'))
        \\>This is now a block note.
        \\>Lorem ipsum.
        \\```
        \\># [Warning]($block.attrs('warning'))
        \\>This is now a block note.
        \\>Lorem ipsum.
        \\
    ;

    pub fn validate(gpa: Allocator, _: *Directive, ctx: Node) !?Value {
        const parent = ctx.parent().?;

        // A block directive must be placed either:
        switch (parent.nodeType()) {
            // - directly under a md quote block without any wrapped text
            //   (given how md works, it will be wrapped in a paragraph in
            //   this case)
            .PARAGRAPH => switch (parent.parent().?.nodeType()) {
                else => {},
                .BLOCK_QUOTE => if (ctx.firstChild() != null) return .{
                    .err = "block definitions directly under a quote block cannot embed any text. wrap it in a heading to define a heading block.",
                } else return null,
            },

            // - inside of a md heading element which in turn is under a block
            //   quote
            .HEADING => {
                if (parent.parent()) |gp| {
                    if (gp.nodeType() == .BLOCK_QUOTE) return null;
                }
            },
            else => {},
        }

        return try Value.errFmt(
            gpa,
            "block directive under '{s}'. block directives must be placed under markdown quote blocks",
            .{@tagName(parent.nodeType())},
        );
    }
};

pub const Image = struct {
    alt: ?[]const u8 = null,
    src: ?Src = null,
    linked: ?bool = null,
    size: ?struct { w: i64, h: i64 } = null,

    pub const mandatory = .{.src};
    pub const directive_mandatory = .{};
    pub const description =
        \\An embedded image.
        \\
        \\Any text placed between `[]` will be used as a caption for the image.
        \\
        \\Example:
        \\```markdown
        \\[This is the caption]($image.asset('foo.jpg'))
        \\```
    ;
    pub const Builtins = struct {
        pub const alt = utils.directiveBuiltin("alt", .string,
            \\An alternative description for this image that accessibility
            \\tooling can access.
        );
        pub const linked = utils.directiveBuiltin("linked", .bool,
            \\Wraps the image in a link to itself.
        );

        pub const url = utils.SrcBuiltins.url;
        pub const asset = utils.SrcBuiltins.asset;
        pub const siteAsset = utils.SrcBuiltins.siteAsset;
        pub const buildAsset = utils.SrcBuiltins.buildAsset;
    };
};

pub const Video = struct {
    src: ?Src = null,
    loop: ?bool = null,
    muted: ?bool = null,
    autoplay: ?bool = null,
    controls: ?bool = null,
    pip: ?bool = null,

    pub const mandatory = .{.src};
    pub const directive_mandatory = .{};
    pub const description =
        \\An embedded video.
        \\
        \\Any text placed between `[]` will be used as a caption for the video.
        \\
        \\Example:
        \\```markdown
        \\[This is the caption]($video.asset('foo.webm'))
        \\```
    ;
    pub const Builtins = struct {
        pub const loop = utils.directiveBuiltin("loop", .bool,
            \\If true, the video will seek back to the start upon reaching the 
            \\end.
        );
        pub const muted = utils.directiveBuiltin("muted", .bool,
            \\If true, the video will be silenced at start. 
        );
        pub const autoplay = utils.directiveBuiltin("autoplay", .bool,
            \\If true, the video will start playing automatically. 
        );
        pub const controls = utils.directiveBuiltin("controls", .bool,
            \\If true, the video will display controls (e.g. play/pause, volume). 
        );
        pub const pip = utils.directiveBuiltin("pip", .bool,
            \\If **false**, clients shouldn't try to display the video in a 
            \\Picture-in-Picture context.
        );

        pub const url = utils.SrcBuiltins.url;
        pub const asset = utils.SrcBuiltins.asset;
        pub const siteAsset = utils.SrcBuiltins.siteAsset;
        pub const buildAsset = utils.SrcBuiltins.buildAsset;
    };
};

pub const Link = struct {
    src: ?Src = null,
    alternative: ?[]const u8 = null,
    ref: ?[]const u8 = null,
    ref_unsafe: bool = false,

    new: ?bool = null,

    pub const description =
        \\A link.
    ;
    pub fn validate(_: Allocator, d: *Directive, _: Node) !?Value {
        const self = &d.kind.link;
        if (self.ref != null or self.alternative != null) {
            if (self.src == null) {
                self.src = .{ .self_page = null };
            } else if (self.src.? != .self_page and self.src.? != .page) {
                return .{
                    .err = "`ref` and `alternative` can only be specified when linking to a content page",
                };
            }
        }

        if (self.src == null) return .{
            .err = "missing call to 'url', 'asset', 'siteAsset', 'buildAsset', 'page', 'sibling' or 'sub'",
        };

        return null;
    }

    pub const Builtins = struct {
        pub const url = utils.SrcBuiltins.url;
        pub const asset = utils.SrcBuiltins.asset;
        pub const siteAsset = utils.SrcBuiltins.siteAsset;
        pub const buildAsset = utils.SrcBuiltins.buildAsset;
        pub const page = utils.SrcBuiltins.page;
        pub const sibling = utils.SrcBuiltins.sibling;
        pub const sub = utils.SrcBuiltins.sub;
        pub const new = utils.directiveBuiltin("new", .bool,
            \\When `true` it asks readers to open the link in a new window or 
            \\tab.
        );
        pub const alternative = struct {
            pub const signature: Signature = .{
                .params = &.{.str},
                .ret = .anydirective,
            };
            pub const description =
                \\When linking to a content page, allows to link to a specific
                \\alternative version of the page, which can be particularly
                \\useful when referencing the RSS feed version of a page.
                \\
                \\The string argument is the name of an alrenative as defined 
                \\in the page's `alternatives` frontmatter property.
            ;

            pub fn call(
                self: *Link,
                d: *Directive,
                _: Allocator,
                _: *const Content,
                args: []const Value,
            ) !Value {
                const bad_arg: Value = .{ .err = "expected 1 string argument" };

                if (args.len != 1) return bad_arg;

                const str = switch (args[0]) {
                    .string => |s| s,
                    else => return bad_arg,
                };

                if (self.alternative != null) {
                    return .{ .err = "field already set" };
                }

                self.alternative = str;
                return .{ .directive = d };
            }
        };
        pub const ref = struct {
            pub const signature: Signature = .{
                .params = &.{.str},
                .ret = .anydirective,
            };
            pub const description =
                \\Deep-links to a specific element (like a section or any
                \\directive that specifies an `id`) of either the current
                \\page or a target page set with `page()`.
                \\
                \\Zine tracks all ids defined in content files so referencing 
                \\an id that doesn't exist will result in a build error.
                \\
                \\Zine does not track ids defined inside of templates so 
                \\use `unsafeRef` to deep-link to those. 
            ;

            pub fn call(
                self: *Link,
                d: *Directive,
                _: Allocator,
                _: *const Content,
                args: []const Value,
            ) !Value {
                const bad_arg: Value = .{ .err = "expected 1 string argument" };

                if (args.len != 1) return bad_arg;

                const str = switch (args[0]) {
                    .string => |s| s,
                    else => return bad_arg,
                };

                if (self.ref != null) {
                    return .{ .err = "field already set" };
                }

                self.ref = str;
                return .{ .directive = d };
            }
        };

        pub const unsafeRef = struct {
            pub const signature: Signature = .{
                .params = &.{.str},
                .ret = .anydirective,
            };
            pub const description =
                \\Like `ref` but Zine will not perform any id checking.
                \\
                \\Can be used to deep-link to ids specified in templates. 
            ;

            pub fn call(
                self: *Link,
                d: *Directive,
                _: Allocator,
                _: *const Content,
                args: []const Value,
            ) !Value {
                const bad_arg: Value = .{ .err = "expected 1 string argument" };

                if (args.len != 1) return bad_arg;

                const str = switch (args[0]) {
                    .string => |s| s,
                    else => return bad_arg,
                };

                if (self.ref != null) {
                    return .{ .err = "field already set" };
                }

                self.ref = str;
                self.ref_unsafe = true;
                return .{ .directive = d };
            }
        };
    };
};

pub const Code = struct {
    src: ?Src = null,
    language: ?[]const u8 = null,

    pub const mandatory = .{.src};
    pub const directive_mandatory = .{};
    pub const description =
        \\An embedded piece of code.
        \\
        \\Any text placed between `[]` will be used as a caption for the snippet.
        \\
        \\Example:
        \\```markdown
        \\[This is the caption]($code.asset('foo.zig'))
        \\```
    ;
    pub const Builtins = struct {
        pub const asset = utils.SrcBuiltins.asset;
        pub const siteAsset = utils.SrcBuiltins.siteAsset;
        pub const buildAsset = utils.SrcBuiltins.buildAsset;
        pub const language = utils.directiveBuiltin("language", .string,
            \\Sets the language of this code snippet, which is also used for
            \\syntax highlighting.
        );
    };
};

pub const Src = union(enum) {
    // External link
    url: []const u8,
    self_page: ?[]const u8, // resolved alt if present
    page: struct {
        kind: enum {
            absolute,
            sub,
            sibling,
        },
        ref: []const u8,
        locale: ?[]const u8 = null,
        resolved: struct {
            page_id: u32,
            variant_id: u32,
            path: u32,
            alt: ?[]const u8 = null,
        } = undefined,
    },
    page_asset: AssetData,
    site_asset: AssetData,
    build_asset: struct {
        ref: []const u8,
    },

    const AssetData = struct {
        ref: []const u8,
        resolved: struct {
            path: u32,
            name: u32,
        } = undefined,
    };
};
