const std = @import("std");
const assert = std.debug.assert;

pub fn Divider(comptime Int: type) type {
    const info = @typeInfo(Int);

    comptime {
        if (info != .Int) @compileError("type must be an integer");
        switch (info.Int.bits) {
            16, 32, 64 => {},
            else => @compileError(std.fmt.comptimePrint("unsupported integer bit width {} (must be 16, 32 or 64)", info.Int.bits)),
        }
    }

    const signedness = info.Int.signedness;
    const bits = info.Int.bits;

    return packed struct {
        magic: Int,
        more: More,

        const UInt = @Type(.{ .Int = .{ .signedness = .unsigned, .bits = bits } });

        // Double bitwidth integer types.
        const DInt = @Type(.{ .Int = .{ .signedness = signedness, .bits = 2 * bits } });
        const DUInt = @Type(.{ .Int = .{ .signedness = .unsigned, .bits = 2 * bits } });

        // * Bits 0-5 is the shift value (for shift path or mult path).
        // * Bit 6 is the add indicator for mult path.
        // * Bit 7 is set if the divisor is negative. We use bit 7 as the negative
        //   divisor indicator so that we can efficiently use sign extension to
        //   create a bitmask with all bits set to 1 (if the divisor is negative)
        //   or 0 (if the divisor is positive).
        // u16: [0-3] shift value
        //      [5] ignored
        //      [6] add indicator
        //      magic number of 0 indicates shift path
        //
        // s16: [0-3] shift value
        //      [5] ignored
        //      [6] add indicator
        //      [7] indicates negative divisor
        //      magic number of 0 indicates shift path
        // u32: [0-4] shift value
        //      [5] ignored
        //      [6] add indicator
        //      magic number of 0 indicates shift path
        //
        // s32: [0-4] shift value
        //      [5] ignored
        //      [6] add indicator
        //      [7] indicates negative divisor
        //      magic number of 0 indicates shift path
        //
        // u64: [0-5] shift value
        //      [6] add indicator
        //      magic number of 0 indicates shift path
        //
        // s64: [0-5] shift value
        //      [6] add indicator
        //      [7] indicates negative divisor
        //      magic number of 0 indicates shift path
        const More = if (bits == 16) packed struct(u8) {
            shift: Shift,
            _: u2 = 0,
            add: u1,
            negative: u1,

            pub const Shift = u4;
        } else if (bits == 32) packed struct(u8) {
            shift: Shift,
            _: u1 = 0,
            add: u1,
            negative: u1,

            pub const Shift = u5;
        } else if (bits == 64) packed struct(u8) {
            shift: Shift,
            add: u1,
            negative: u1,

            pub const Shift = u6;
        };

        // -- Public functions --

        pub fn init(d: Int) @This() {
            assert(d != 0);

            const abs_d = std.math.absCast(d);
            const floor_log_2_d = @as(More.Shift, @intCast((bits - 1) - @clz(abs_d)));

            // Check if d is a power of 2 exactly.
            if ((abs_d & (abs_d - 1)) == 0) {
                return .{
                    .magic = 0,
                    .more = .{
                        .shift = @as(More.Shift, @intCast(floor_log_2_d)),
                        .add = 0,
                        .negative = @intFromBool(d < 0),
                    },
                };
            } else {
                if (signedness == .signed) assert(floor_log_2_d >= 1);
                const proposed_m_shift = if (signedness == .signed) (floor_log_2_d - 1) else (floor_log_2_d);

                var shift: More.Shift = undefined;
                var add: u1 = 0;
                var negative: u1 = @intFromBool(d < 0);

                var rem: UInt = undefined;
                var proposed_m = div_full(@as(UInt, 1) << proposed_m_shift, 0, abs_d, &rem);

                const e = abs_d - rem;
                if (e < (@as(UInt, 1) << floor_log_2_d)) {
                    // This power works.
                    shift = @as(More.Shift, proposed_m_shift);
                } else {
                    // We need to go one higher. This should not make proposed_m
                    // overflow, but it will make it negative when interpreted as an i32.
                    proposed_m +%= proposed_m;

                    const twice_rem = rem +% rem;
                    if (twice_rem >= abs_d or twice_rem < rem) proposed_m += 1;
                    shift = @as(More.Shift, @intCast(floor_log_2_d));
                    add = 1;
                }

                proposed_m += 1;
                var magic = @as(Int, @bitCast(proposed_m));

                // Mark if negative
                if (signedness == .signed and negative != 0) magic = -magic;

                return .{ .magic = magic, .more = .{
                    .shift = shift,
                    .add = add,
                    .negative = negative,
                } };
            }
        }

        pub inline fn recover(self: @This()) Int {
            switch (comptime signedness) {
                .unsigned => {
                    if (self.magic == 0) {
                        assert(self.more.add == 0);
                        assert(self.more.negative == 0);
                        return @as(Int, 1) << self.more.shift;
                    } else if (self.more.add == 0) {
                        const hi_dividend = @as(Int, 1) << self.more.shift;
                        var _rem: Int = undefined;
                        return 1 + div_full(hi_dividend, 0, self.magic, &_rem);
                    } else {
                        const half_n: DInt = @as(DInt, 1) << @intCast(bits + self.more.shift);
                        const d: DInt = (@as(DInt, 1) << bits) | self.magic;

                        const half_q: Int = @intCast(half_n / d);
                        const rem = half_n % d;
                        const full_q = half_q + half_q + @intFromBool((rem << 1) >= d);

                        return full_q + 1;
                    }
                },
                .signed => {
                    if (self.magic == 0) {
                        var d: Int = @bitCast(@as(UInt, 1) << self.more.shift);
                        if (self.more.negative == 1) {
                            d = -%d;
                        }
                        return d;
                    } else {
                        const negative_divisor = (self.more.negative == 1);
                        const magic_was_negated = if (self.more.add == 1) (self.magic > 0) else (self.magic < 0);

                        if (self.magic == 0) {
                            const result: Int = @bitCast(@as(UInt, 1) << self.more.shift);
                            return if (negative_divisor) -result else result;
                        }

                        const d: UInt = @bitCast(if (magic_was_negated) -self.magic else self.magic);
                        const n: DUInt = @as(DUInt, 1) << @intCast(bits + self.more.shift);
                        const q: UInt = @intCast(n / d);
                        const result: Int = @as(Int, @bitCast(q)) + 1;
                        return if (negative_divisor) -result else result;
                    }
                },
            }
        }

        pub inline fn divTrunc(self: @This(), numer: Int) Int {
            switch (comptime signedness) {
                .unsigned => {
                    if (self.magic == 0) {
                        assert(self.more.add == 0);
                        assert(self.more.negative == 0);
                        return numer >> self.more.shift;
                    } else {
                        const q = mul_hi(self.magic, numer);
                        if (self.more.add != 0) {
                            const t = ((numer - q) >> 1) + q;
                            return t >> self.more.shift;
                        } else {
                            // All upper bits are 0.
                            assert(self.more.add == 0);
                            assert(self.more.negative == 0);
                            return q >> self.more.shift;
                        }
                    }
                },
                .signed => {
                    const shift = self.more.shift;

                    if (self.magic == 0) {
                        // We rely on sign extension here.
                        const sign: Int = @as(Int, @as(i8, @bitCast(self.more)) >> 7);
                        const mask: UInt = (@as(UInt, 1) << shift) - 1;
                        var q: Int = numer + ((numer >> (bits - 1)) & @as(Int, @bitCast(mask)));
                        // Need arithmetic shift here.
                        q >>= shift;
                        q = (q ^ sign) -% sign;
                        return q;
                    } else {
                        var u_q: UInt = @bitCast(mul_hi(self.magic, numer));
                        if (self.more.add == 1) {
                            // Arithmetic shift and then sign extend.
                            const sign: UInt = @bitCast(@as(Int, @as(i8, @bitCast(self.more)) >> 7));
                            u_q +%= (@as(UInt, @bitCast(numer)) ^ sign) -% sign;
                        }
                        var q: Int = @bitCast(u_q);
                        q >>= shift;
                        q += @intFromBool(q < 0);
                        return q;
                    }
                },
            }
        }

        // -- Private functions --

        // Divides a double bitwidth integer {x1, x0} by a single bitwidth integer {y}.
        // The result must fit in a single bitwidth integer. Quotient is returned directly
        // and remainder is returned through r.*.
        inline fn div_full(x1: UInt, x0: UInt, v: UInt, r: *UInt) UInt {
            const v_d: DUInt = v;

            const n = (@as(DUInt, x1) << bits) | @as(DUInt, x0);
            const result = n / v_d;
            r.* = @intCast(n - result * v_d);
            return @intCast(result);
        }

        // Multiplies x and y as double bitwidth integers, and returns the a single bitwidth
        // integer corresponding to the higher half of the result.
        inline fn mul_hi(x: Int, y: Int) Int {
            const xl = @as(DInt, x);
            const yl = @as(DInt, y);
            const rl = xl * yl;
            return @as(Int, @intCast(rl >> bits));
        }
    };
}
