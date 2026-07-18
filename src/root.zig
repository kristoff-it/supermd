pub extern fn cmark_list_syntax_extensions([*c]c.cmark_mem) [*c]c.cmark_llist;
pub const c = @import("c");

pub const Ast = @import("Ast.zig");
pub const Node = @import("Node.zig");

pub const context = @import("context.zig");
pub const Value = context.Value;
pub const Content = context.Content;
pub const Directive = context.Directive;

pub const max_size = 4 * 1024 * 1024 * 1024;

pub const Range = struct {
    start: Pos,
    end: Pos,

    const Pos = struct {
        row: u32,
        col: u32,
    };

    // If you're calling this, something dumb is going on.
    // Currently this is used because markdown doesn't provide spans.
    pub fn span(r: Range, src: []const u8) Span {
        const std = @import("std");

        var start: usize = r.start.col;
        var it = std.mem.splitScalar(u8, src, '\n');
        for (1..r.start.row) |_| {
            const line = it.next() orelse "";
            start += line.len + 1;
        }

        var end = start + r.end.col;
        for (r.start.row..r.end.row) |_| {
            const line = it.next() orelse "";
            end += line.len + 1;
        }

        const loc: Span = .{
            .start = @intCast(start - 1),
            .end = @intCast(end - 1),
        };
        return loc;
    }
};

pub const Line = struct { line: []const u8, start: u32 };

pub const Span = struct {
    start: u32,
    end: u32,

    pub fn len(span: Span) u32 {
        return span.end - span.start;
    }

    pub fn slice(self: Span, src: []const u8) []const u8 {
        return src[self.start..self.end];
    }

    pub fn range(self: Span, code: []const u8) Range {
        var selection: Range = .{
            .start = .{ .row = 1, .col = 0 },
            .end = undefined,
        };

        for (code[0..self.start]) |ch| {
            if (ch == '\n') {
                selection.start.row += 1;
                selection.start.col = 0;
            } else selection.start.col += 1;
        }

        selection.end = selection.start;
        selection.start.col += 1;
        for (code[self.start..self.end]) |ch| {
            if (ch == '\n') {
                selection.end.row += 1;
                selection.end.col = 0;
            } else selection.end.col += 1;
        }
        selection.end.col += 1;
        return selection;
    }

    /// Finds the line around a Span. Choose simple spans
    ///  if you don't want unwanted newlines in the middle.
    pub fn line(span: Span, src: []const u8) Line {
        var idx = span.start;
        const s = while (idx > 0) : (idx -= 1) {
            if (src[idx] == '\n') break idx + 1;
        } else 0;

        idx = span.end;
        const e = while (idx < src.len) : (idx += 1) {
            if (src[idx] == '\n') break idx;
        } else src.len - 1;

        return .{ .line = src[s..e], .start = s };
    }

    pub fn debug(span: Span, src: []const u8) void {
        @import("std").debug.print("{s}", .{span.slice(src)});
    }
};

test {
    _ = Ast;
}
