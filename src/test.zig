const std = @import("std");
const assert = std.debug.assert;

const div = @import("divide");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    // const seed = @as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));
    const seed = 0;
    std.debug.print("seed: {}\n", .{seed});

    inline for (.{ u16, i16, u32, i32, u64, i64 }) |I| {
        var fixture = Test(I).init(alloc, seed);
        try fixture.run();
    }
}

const Algo = enum { branch, branchless };

fn Test(comptime Int: type) type {
    const info = @typeInfo(Int).Int;

    const UInt = @Type(.{ .Int = .{ .signedness = .unsigned, .bits = info.bits } });

    return struct {
        alloc: std.mem.Allocator,
        rng: std.rand.DefaultPrng,

        // -- Public functions --

        pub fn init(alloc: std.mem.Allocator, seed: u64) @This() {
            return .{
                .alloc = alloc,
                .rng = std.rand.DefaultPrng.init(seed),
            };
        }

        pub fn run(self: *@This()) !void {
            std.debug.print("testing " ++ @typeName(Int) ++ "\n", .{});

            var tested_denoms = std.AutoHashMap(Int, void).init(self.alloc);
            defer tested_denoms.deinit();

            // primes
            const primes = [_]Int{
                2,  3,  5,  7,  11, 13,  17,  19,  23,  29,  31,  37,  41,  43,  47,  53,  59,  61,  67,  71,
                73, 79, 83, 89, 97, 101, 103, 107, 109, 113, 127, 131, 137, 139, 149, 151, 157, 163, 167, 173,
            };
            for (primes) |p| try testBothSigns(p, &tested_denoms);

            // minimum
            if (info.signedness == .signed) try testAllAlgos(std.math.minInt(Int), &tested_denoms);

            // maximum
            try testAllAlgos(std.math.maxInt(Int), &tested_denoms);

            // power of 2 and adjacent
            {
                const SInt = @Type(.{ .Int = .{ .signedness = .signed, .bits = info.bits } });

                var d1: UInt = std.math.maxInt(UInt);
                var d2: UInt = 1;
                for (0..info.bits) |_| {
                    inline for (.{ -1, 0, 1 }) |j| {
                        try testAllAlgos(@bitCast(d1 +% @as(UInt, @bitCast(@as(SInt, j)))), &tested_denoms);
                        try testAllAlgos(@bitCast(d2 +% @as(UInt, @bitCast(@as(SInt, j)))), &tested_denoms);
                    }
                    d1 <<= 1;
                    d2 <<= 1;
                }
            }

            // random denominators
            for (0..(16 * 1024)) |_| {
                try testAllAlgos(self.getRandom(), &tested_denoms);
            }
        }

        // -- Private testing functions

        const Divider = div.Divider(Int);

        fn testBothSigns(denom: Int, tested_denoms: *std.AutoHashMap(Int, void)) !void {
            // Otherwise, there's a bug in the testing code.
            assert(denom >= 0);

            try testAllAlgos(denom, tested_denoms);
            if (info.signedness == .signed) try testAllAlgos(-denom, tested_denoms);
        }

        fn testAllAlgos(denom: Int, tested_denoms: *std.AutoHashMap(Int, void)) !void {
            if (!tested_denoms.contains(denom)) {
                if (denom != 0) {
                    try testMany(.branch, denom);
                    if (denom != 1) {
                        try testMany(.branchless, denom);
                    }
                }

                tested_denoms.put(denom, {}) catch {
                    std.debug.print("out of memory\n", .{});
                    std.process.exit(1);
                };
            }
        }

        fn testMany(algo: Algo, denom: Int) !void {
            assert(denom != 0);
            if (algo == .branchless) assert(denom != 1);

            // TODO: branchless
            if (algo == .branchless) return;

            const divider = Divider.init(denom);
            if (divider.recover() != denom) {
                std.debug.print("when recovering: expected {}, got {}\n", .{ denom, divider.recover() });
                return Error.test_failure;
            }

            try testEdgeCases(denom, divider);
            try testSmall(denom, divider);
            try testPow2(denom, divider);
        }

        fn testEdgeCases(denom: Int, divider: Divider) !void {
            const min = std.math.minInt(Int);
            const max = std.math.maxInt(Int);
            const all_edge_cases = [_]comptime_int{
                0,               1,               2,           3,           4,           5,           6,           7,
                8,               9,               10,          11,          12,          13,          14,          15,
                16,              17,              18,          19,          20,          21,          22,          23,
                24,              25,              26,          27,          28,          29,          30,          31,
                32,              33,              34,          35,          36,          37,          38,          39,
                40,              41,              42,          43,          44,          45,          46,          47,
                48,              49,              123,         1232,        36847,       506838,      3000003,     70000007,

                max,             max - 1,         max - 2,     max - 3,     max - 4,     max - 5,     max - 3213,  max - 2453242,
                max - 432234231, min,             min + 1,     min + 2,     min + 3,     min + 4,     min + 5,     min + 3213,
                min + 2453242,   min + 432234231, max / 2,     max / 2 + 1, max / 2 - 1, max / 3,     max / 3 + 1, max / 3 - 1,
                max / 4,         max / 4 + 1,     max / 4 - 1, min / 2,     min / 2 + 1, min / 2 - 1, min / 3,     min / 3 + 1,
                min / 3 - 1,     min / 4,         min / 4 + 1, min / 4 - 1,
            };

            // Some edge cases above don't fit in u16 or u32, so we only add those that fit in the bit width.
            const edge_cases = comptime brk: {
                var ec: [all_edge_cases.len]Int = undefined;

                var ii = 0;
                for (all_edge_cases) |num| {
                    if (num >= min and num <= max) {
                        ec[ii] = num;
                        ii += 1;
                    }
                }

                break :brk ec[0..ii];
            };

            for (edge_cases) |num| try testOne(num, denom, divider);
        }
        fn testSmall(denom: Int, divider: Divider) !void {
            const limit = if (info.signedness == .signed) (1 << 14) else (1 << 15);

            for (0..limit) |n| {
                const num: Int = @intCast(n);
                try testOne(num, denom, divider);
                if (info.signedness == .signed) try testOne(-num, denom, divider);
            }
        }
        fn testPow2(denom: Int, divider: Divider) !void {
            var n1: UInt = std.math.maxInt(UInt);
            var n2: UInt = 1;
            for (0..info.bits) |_| {
                try testOne(@bitCast(n1), denom, divider);
                try testOne(@bitCast(n2), denom, divider);
                n1 <<= 1;
                n2 <<= 1;
            }
        }

        fn testOne(num: Int, denom: Int, divider: Divider) !void {
            if (info.signedness == .signed and (num == std.math.minInt(Int) and denom == -1)) {
                // The result of this would overflow the signed int.
                return;
            }

            const got = divider.divTrunc(num);
            const expected = @divTrunc(num, denom);

            if (got != expected) {
                std.debug.print("when {}/{}: expected {}, got {}\n", .{ num, denom, expected, got });
                return Error.test_failure;
            }
        }

        // -- Private helper functions --

        fn getRandom(self: *@This()) Int {
            return self.rng.random().int(Int);
        }
        fn getPositiveRandom(self: *@This()) Int {
            return self.rng.random().intRangeAtMost(Int, 1, std.math.maxInt(Int));
        }
    };
}

const Error = error{
    test_failure,
};
