//! This file contains the functionality for lowering x86_64 MIR into
//! machine code

const Isel = @This();

const std = @import("std");
const assert = std.debug.assert;
const bits = @import("bits.zig");
const leb128 = std.leb;
const link = @import("../../link.zig");
const log = std.log.scoped(.codegen);
const math = std.math;
const mem = std.mem;
const testing = std.testing;

const Air = @import("../../Air.zig");
const Allocator = mem.Allocator;
const DebugInfoOutput = @import("../../codegen.zig").DebugInfoOutput;
const DW = std.dwarf;
const Encoder = bits.Encoder;
const ErrorMsg = Module.ErrorMsg;
const MCValue = @import("CodeGen.zig").MCValue;
const Mir = @import("Mir.zig");
const Module = @import("../../Module.zig");
const Instruction = bits.Instruction;
const Register = bits.Register;
const Type = @import("../../type.zig").Type;

mir: Mir,
bin_file: *link.File,
debug_output: DebugInfoOutput,
target: *const std.Target,
err_msg: ?*ErrorMsg = null,
src_loc: Module.SrcLoc,
code: *std.ArrayList(u8),

prev_di_line: u32,
prev_di_column: u32,
/// Relative to the beginning of `code`.
prev_di_pc: usize,

code_offset_mapping: std.AutoHashMapUnmanaged(Mir.Inst.Index, usize) = .{},
relocs: std.ArrayListUnmanaged(Reloc) = .{},

const InnerError = error{
    OutOfMemory,
    Overflow,
    IselFail,
};

const Reloc = struct {
    /// Offset of the instruction.
    source: u64,
    /// Target of the relocation.
    target: Mir.Inst.Index,
    /// Offset of the relocation within the instruction.
    offset: u64,
    /// Length of the instruction.
    length: u5,
};

pub fn lowerMir(isel: *Isel) InnerError!void {
    const mir_tags = isel.mir.instructions.items(.tag);

    for (mir_tags) |tag, index| {
        const inst = @intCast(u32, index);
        try isel.code_offset_mapping.putNoClobber(isel.bin_file.allocator, inst, isel.code.items.len);
        switch (tag) {
            .adc => try isel.mirArith(.adc, inst),
            .add => try isel.mirArith(.add, inst),
            .sub => try isel.mirArith(.sub, inst),
            .xor => try isel.mirArith(.xor, inst),
            .@"and" => try isel.mirArith(.@"and", inst),
            .@"or" => try isel.mirArith(.@"or", inst),
            .sbb => try isel.mirArith(.sbb, inst),
            .cmp => try isel.mirArith(.cmp, inst),
            .mov => try isel.mirArith(.mov, inst),

            .adc_mem_imm => try isel.mirArithMemImm(.adc, inst),
            .add_mem_imm => try isel.mirArithMemImm(.add, inst),
            .sub_mem_imm => try isel.mirArithMemImm(.sub, inst),
            .xor_mem_imm => try isel.mirArithMemImm(.xor, inst),
            .and_mem_imm => try isel.mirArithMemImm(.@"and", inst),
            .or_mem_imm => try isel.mirArithMemImm(.@"or", inst),
            .sbb_mem_imm => try isel.mirArithMemImm(.sbb, inst),
            .cmp_mem_imm => try isel.mirArithMemImm(.cmp, inst),
            .mov_mem_imm => try isel.mirArithMemImm(.mov, inst),

            .adc_scale_src => try isel.mirArithScaleSrc(.adc, inst),
            .add_scale_src => try isel.mirArithScaleSrc(.add, inst),
            .sub_scale_src => try isel.mirArithScaleSrc(.sub, inst),
            .xor_scale_src => try isel.mirArithScaleSrc(.xor, inst),
            .and_scale_src => try isel.mirArithScaleSrc(.@"and", inst),
            .or_scale_src => try isel.mirArithScaleSrc(.@"or", inst),
            .sbb_scale_src => try isel.mirArithScaleSrc(.sbb, inst),
            .cmp_scale_src => try isel.mirArithScaleSrc(.cmp, inst),
            .mov_scale_src => try isel.mirArithScaleSrc(.mov, inst),

            .adc_scale_dst => try isel.mirArithScaleDst(.adc, inst),
            .add_scale_dst => try isel.mirArithScaleDst(.add, inst),
            .sub_scale_dst => try isel.mirArithScaleDst(.sub, inst),
            .xor_scale_dst => try isel.mirArithScaleDst(.xor, inst),
            .and_scale_dst => try isel.mirArithScaleDst(.@"and", inst),
            .or_scale_dst => try isel.mirArithScaleDst(.@"or", inst),
            .sbb_scale_dst => try isel.mirArithScaleDst(.sbb, inst),
            .cmp_scale_dst => try isel.mirArithScaleDst(.cmp, inst),
            .mov_scale_dst => try isel.mirArithScaleDst(.mov, inst),

            .adc_scale_imm => try isel.mirArithScaleImm(.adc, inst),
            .add_scale_imm => try isel.mirArithScaleImm(.add, inst),
            .sub_scale_imm => try isel.mirArithScaleImm(.sub, inst),
            .xor_scale_imm => try isel.mirArithScaleImm(.xor, inst),
            .and_scale_imm => try isel.mirArithScaleImm(.@"and", inst),
            .or_scale_imm => try isel.mirArithScaleImm(.@"or", inst),
            .sbb_scale_imm => try isel.mirArithScaleImm(.sbb, inst),
            .cmp_scale_imm => try isel.mirArithScaleImm(.cmp, inst),
            .mov_scale_imm => try isel.mirArithScaleImm(.mov, inst),

            .movabs => try isel.mirMovabs(inst),

            .lea => try isel.mirLea(inst),

            .imul_complex => try isel.mirIMulComplex(inst),

            .push => try isel.mirPushPop(.push, inst),
            .pop => try isel.mirPushPop(.pop, inst),

            .jmp => try isel.mirJmpCall(.jmp_near, inst),
            .call => try isel.mirJmpCall(.call_near, inst),

            .cond_jmp_greater_less,
            .cond_jmp_above_below,
            .cond_jmp_eq_ne,
            => try isel.mirCondJmp(tag, inst),

            .cond_set_byte_greater_less,
            .cond_set_byte_above_below,
            .cond_set_byte_eq_ne,
            => try isel.mirCondSetByte(tag, inst),

            .ret => try isel.mirRet(inst),

            .syscall => try isel.mirSyscall(),

            .@"test" => try isel.mirTest(inst),

            .brk => try isel.mirBrk(),
            .nop => try isel.mirNop(),

            .call_extern => try isel.mirCallExtern(inst),

            .dbg_line => try isel.mirDbgLine(inst),
            .dbg_prologue_end => try isel.mirDbgPrologueEnd(inst),
            .dbg_epilogue_begin => try isel.mirDbgEpilogueBegin(inst),
            .arg_dbg_info => try isel.mirArgDbgInfo(inst),

            .push_regs_from_callee_preserved_regs => try isel.mirPushPopRegsFromCalleePreservedRegs(.push, inst),
            .pop_regs_from_callee_preserved_regs => try isel.mirPushPopRegsFromCalleePreservedRegs(.pop, inst),

            else => {
                return isel.fail("Implement MIR->Isel lowering for x86_64 for pseudo-inst: {s}", .{tag});
            },
        }
    }

    try isel.fixupRelocs();
}

pub fn deinit(isel: *Isel) void {
    isel.relocs.deinit(isel.bin_file.allocator);
    isel.code_offset_mapping.deinit(isel.bin_file.allocator);
    isel.* = undefined;
}

fn fail(isel: *Isel, comptime format: []const u8, args: anytype) InnerError {
    @setCold(true);
    assert(isel.err_msg == null);
    isel.err_msg = try ErrorMsg.create(isel.bin_file.allocator, isel.src_loc, format, args);
    return error.IselFail;
}

fn failWithLoweringError(isel: *Isel, err: LoweringError) InnerError {
    return switch (err) {
        error.RaxOperandExpected => isel.fail("Register.rax expected as destination operand", .{}),
        error.OperandSizeMismatch => isel.fail("operand size mismatch", .{}),
        else => |e| e,
    };
}

fn fixupRelocs(isel: *Isel) InnerError!void {
    // TODO this function currently assumes all relocs via JMP/CALL instructions are 32bit in size.
    // This should be reversed like it is done in aarch64 MIR emit code: start with the smallest
    // possible resolution, i.e., 8bit, and iteratively converge on the minimum required resolution
    // until the entire decl is correctly emitted with all JMP/CALL instructions within range.
    for (isel.relocs.items) |reloc| {
        const offset = try math.cast(usize, reloc.offset);
        const target = isel.code_offset_mapping.get(reloc.target) orelse
            return isel.fail("JMP/CALL relocation target not found!", .{});
        const disp = @intCast(i32, @intCast(i64, target) - @intCast(i64, reloc.source + reloc.length));
        mem.writeIntLittle(i32, isel.code.items[offset..][0..4], disp);
    }
}

fn mirBrk(isel: *Isel) InnerError!void {
    return lowerToZoEnc(.brk, isel.code) catch |err| isel.failWithLoweringError(err);
}

fn mirNop(isel: *Isel) InnerError!void {
    return lowerToZoEnc(.nop, isel.code) catch |err| isel.failWithLoweringError(err);
}

fn mirSyscall(isel: *Isel) InnerError!void {
    return lowerToZoEnc(.syscall, isel.code) catch |err| isel.failWithLoweringError(err);
}

fn mirPushPop(isel: *Isel, tag: Tag, inst: Mir.Inst.Index) InnerError!void {
    const ops = Mir.Ops.decode(isel.mir.instructions.items(.ops)[inst]);
    switch (ops.flags) {
        0b00 => {
            // PUSH/POP reg
            return lowerToOEnc(tag, ops.reg1, isel.code) catch |err| isel.failWithLoweringError(err);
        },
        0b01 => {
            // PUSH/POP r/m64
            const imm = isel.mir.instructions.items(.data)[inst].imm;
            const ptr_size: Memory.PtrSize = switch (immOpSize(imm)) {
                16 => .word_ptr,
                else => .qword_ptr,
            };
            return lowerToMEnc(tag, RegisterOrMemory.mem(ops.reg1, imm, ptr_size), isel.code) catch |err|
                isel.failWithLoweringError(err);
        },
        0b10 => {
            // PUSH imm32
            assert(tag == .push);
            const imm = isel.mir.instructions.items(.data)[inst].imm;
            return lowerToIEnc(.push, imm, isel.code) catch |err|
                isel.failWithLoweringError(err);
        },
        0b11 => unreachable,
    }
}
fn mirPushPopRegsFromCalleePreservedRegs(isel: *Isel, tag: Tag, inst: Mir.Inst.Index) InnerError!void {
    const callee_preserved_regs = bits.callee_preserved_regs;
    const regs = isel.mir.instructions.items(.data)[inst].regs_to_push_or_pop;
    if (tag == .push) {
        for (callee_preserved_regs) |reg, i| {
            if ((regs >> @intCast(u5, i)) & 1 == 0) continue;
            lowerToOEnc(.push, reg, isel.code) catch |err|
                return isel.failWithLoweringError(err);
        }
    } else {
        // pop in the reverse direction
        var i = callee_preserved_regs.len;
        while (i > 0) : (i -= 1) {
            const reg = callee_preserved_regs[i - 1];
            if ((regs >> @intCast(u5, i - 1)) & 1 == 0) continue;
            lowerToOEnc(.pop, reg, isel.code) catch |err|
                return isel.failWithLoweringError(err);
        }
    }
}

fn mirJmpCall(isel: *Isel, tag: Tag, inst: Mir.Inst.Index) InnerError!void {
    const ops = Mir.Ops.decode(isel.mir.instructions.items(.ops)[inst]);
    const flag = @truncate(u1, ops.flags);
    if (flag == 0) {
        const target = isel.mir.instructions.items(.data)[inst].inst;
        const source = isel.code.items.len;
        lowerToDEnc(tag, 0, isel.code) catch |err|
            return isel.failWithLoweringError(err);
        try isel.relocs.append(isel.bin_file.allocator, .{
            .source = source,
            .target = target,
            .offset = isel.code.items.len - 4,
            .length = 5,
        });
        return;
    }
    if (ops.reg1 == .none) {
        // JMP/CALL [imm]
        const imm = isel.mir.instructions.items(.data)[inst].imm;
        const ptr_size: Memory.PtrSize = switch (immOpSize(imm)) {
            16 => .word_ptr,
            else => .qword_ptr,
        };
        return lowerToMEnc(tag, RegisterOrMemory.mem(null, imm, ptr_size), isel.code) catch |err|
            isel.failWithLoweringError(err);
    }
    // JMP/CALL reg
    return lowerToMEnc(tag, RegisterOrMemory.reg(ops.reg1), isel.code) catch |err| isel.failWithLoweringError(err);
}

fn mirCondJmp(isel: *Isel, mir_tag: Mir.Inst.Tag, inst: Mir.Inst.Index) InnerError!void {
    const ops = Mir.Ops.decode(isel.mir.instructions.items(.ops)[inst]);
    const target = isel.mir.instructions.items(.data)[inst].inst;
    const tag = switch (mir_tag) {
        .cond_jmp_greater_less => switch (ops.flags) {
            0b00 => Tag.jge,
            0b01 => Tag.jg,
            0b10 => Tag.jl,
            0b11 => Tag.jle,
        },
        .cond_jmp_above_below => switch (ops.flags) {
            0b00 => Tag.jae,
            0b01 => Tag.ja,
            0b10 => Tag.jb,
            0b11 => Tag.jbe,
        },
        .cond_jmp_eq_ne => switch (@truncate(u1, ops.flags)) {
            0b0 => Tag.jne,
            0b1 => Tag.je,
        },
        else => unreachable,
    };
    const source = isel.code.items.len;
    lowerToDEnc(tag, 0, isel.code) catch |err|
        return isel.failWithLoweringError(err);
    try isel.relocs.append(isel.bin_file.allocator, .{
        .source = source,
        .target = target,
        .offset = isel.code.items.len - 4,
        .length = 6,
    });
}

fn mirCondSetByte(isel: *Isel, mir_tag: Mir.Inst.Tag, inst: Mir.Inst.Index) InnerError!void {
    const ops = Mir.Ops.decode(isel.mir.instructions.items(.ops)[inst]);
    const tag = switch (mir_tag) {
        .cond_set_byte_greater_less => switch (ops.flags) {
            0b00 => Tag.setge,
            0b01 => Tag.setg,
            0b10 => Tag.setl,
            0b11 => Tag.setle,
        },
        .cond_set_byte_above_below => switch (ops.flags) {
            0b00 => Tag.setae,
            0b01 => Tag.seta,
            0b10 => Tag.setb,
            0b11 => Tag.setbe,
        },
        .cond_set_byte_eq_ne => switch (@truncate(u1, ops.flags)) {
            0b0 => Tag.setne,
            0b1 => Tag.sete,
        },
        else => unreachable,
    };
    return lowerToMEnc(tag, RegisterOrMemory.reg(ops.reg1.to8()), isel.code) catch |err|
        isel.failWithLoweringError(err);
}

fn mirTest(isel: *Isel, inst: Mir.Inst.Index) InnerError!void {
    const tag = isel.mir.instructions.items(.tag)[inst];
    assert(tag == .@"test");
    const ops = Mir.Ops.decode(isel.mir.instructions.items(.ops)[inst]);
    switch (ops.flags) {
        0b00 => {
            if (ops.reg2 == .none) {
                // TEST r/m64, imm32
                // MI
                const imm = isel.mir.instructions.items(.data)[inst].imm;
                if (ops.reg1.to64() == .rax) {
                    // TEST rax, imm32
                    // I
                    return lowerToIEnc(.@"test", imm, isel.code) catch |err|
                        isel.failWithLoweringError(err);
                }
                return lowerToMiEnc(.@"test", RegisterOrMemory.reg(ops.reg1), imm, isel.code) catch |err|
                    isel.failWithLoweringError(err);
            }
            // TEST r/m64, r64
            return isel.fail("TODO TEST r/m64, r64", .{});
        },
        else => return isel.fail("TODO more TEST alternatives", .{}),
    }
}

fn mirRet(isel: *Isel, inst: Mir.Inst.Index) InnerError!void {
    const tag = isel.mir.instructions.items(.tag)[inst];
    assert(tag == .ret);
    const ops = Mir.Ops.decode(isel.mir.instructions.items(.ops)[inst]);
    switch (ops.flags) {
        0b00 => {
            // RETF imm16
            // I
            const imm = isel.mir.instructions.items(.data)[inst].imm;
            return lowerToIEnc(.ret_far, imm, isel.code) catch |err| isel.failWithLoweringError(err);
        },
        0b01 => {
            return lowerToZoEnc(.ret_far, isel.code) catch |err| isel.failWithLoweringError(err);
        },
        0b10 => {
            // RET imm16
            // I
            const imm = isel.mir.instructions.items(.data)[inst].imm;
            return lowerToIEnc(.ret_near, imm, isel.code) catch |err| isel.failWithLoweringError(err);
        },
        0b11 => {
            return lowerToZoEnc(.ret_near, isel.code) catch |err| isel.failWithLoweringError(err);
        },
    }
}

fn mirArith(isel: *Isel, tag: Tag, inst: Mir.Inst.Index) InnerError!void {
    const ops = Mir.Ops.decode(isel.mir.instructions.items(.ops)[inst]);
    switch (ops.flags) {
        0b00 => {
            if (ops.reg2 == .none) {
                // mov reg1, imm32
                // MI
                const imm = isel.mir.instructions.items(.data)[inst].imm;
                return lowerToMiEnc(tag, RegisterOrMemory.reg(ops.reg1), imm, isel.code) catch |err|
                    isel.failWithLoweringError(err);
            }
            // mov reg1, reg2
            // RM
            return lowerToRmEnc(tag, ops.reg1, RegisterOrMemory.reg(ops.reg2), isel.code) catch |err|
                isel.failWithLoweringError(err);
        },
        0b01 => {
            // mov reg1, [reg2 + imm32]
            // RM
            const imm = isel.mir.instructions.items(.data)[inst].imm;
            const src_reg: ?Register = if (ops.reg2 == .none) null else ops.reg2;
            return lowerToRmEnc(
                tag,
                ops.reg1,
                RegisterOrMemory.mem(src_reg, imm, Memory.PtrSize.fromBits(ops.reg1.size())),
                isel.code,
            ) catch |err| isel.failWithLoweringError(err);
        },
        0b10 => {
            if (ops.reg2 == .none) {
                return isel.fail("TODO unused variant: mov reg1, none, 0b10", .{});
            }
            // mov [reg1 + imm32], reg2
            // MR
            const imm = isel.mir.instructions.items(.data)[inst].imm;
            return lowerToMrEnc(
                tag,
                RegisterOrMemory.mem(ops.reg1, imm, Memory.PtrSize.fromBits(ops.reg2.size())),
                ops.reg2,
                isel.code,
            ) catch |err| isel.failWithLoweringError(err);
        },
        0b11 => {
            return isel.fail("TODO unused variant: mov reg1, reg2, 0b11", .{});
        },
    }
}

fn mirArithMemImm(isel: *Isel, tag: Tag, inst: Mir.Inst.Index) InnerError!void {
    const ops = Mir.Ops.decode(isel.mir.instructions.items(.ops)[inst]);
    assert(ops.reg2 == .none);
    const payload = isel.mir.instructions.items(.data)[inst].payload;
    const imm_pair = isel.mir.extraData(Mir.ImmPair, payload).data;
    const ptr_size: Memory.PtrSize = switch (ops.flags) {
        0b00 => .byte_ptr,
        0b01 => .word_ptr,
        0b10 => .dword_ptr,
        0b11 => .qword_ptr,
    };
    return lowerToMiEnc(
        tag,
        RegisterOrMemory.mem(ops.reg1, imm_pair.dest_off, ptr_size),
        imm_pair.operand,
        isel.code,
    ) catch |err| isel.failWithLoweringError(err);
}

inline fn setRexWRegister(reg: Register) bool {
    if (reg.size() == 64) return true;
    return switch (reg) {
        .ah, .bh, .ch, .dh => true,
        else => false,
    };
}

inline fn immOpSize(imm: i64) u8 {
    blk: {
        _ = math.cast(i8, imm) catch break :blk;
        return 8;
    }
    blk: {
        _ = math.cast(i16, imm) catch break :blk;
        return 16;
    }
    blk: {
        _ = math.cast(i32, imm) catch break :blk;
        return 32;
    }
    return 64;
}

// TODO
fn mirArithScaleSrc(isel: *Isel, tag: Tag, inst: Mir.Inst.Index) InnerError!void {
    const ops = Mir.Ops.decode(isel.mir.instructions.items(.ops)[inst]);
    const scale = ops.flags;
    // OP reg1, [reg2 + scale*rcx + imm32]
    const opc = getOpCode(tag, .rm, ops.reg1.size() == 8).?;
    const imm = isel.mir.instructions.items(.data)[inst].imm;
    const encoder = try Encoder.init(isel.code, 8);
    encoder.rex(.{
        .w = ops.reg1.size() == 64,
        .r = ops.reg1.isExtended(),
        .b = ops.reg2.isExtended(),
    });
    opc.encode(encoder);
    if (imm <= math.maxInt(i8)) {
        encoder.modRm_SIBDisp8(ops.reg1.lowId());
        encoder.sib_scaleIndexBaseDisp8(scale, Register.rcx.lowId(), ops.reg2.lowId());
        encoder.disp8(@intCast(i8, imm));
    } else {
        encoder.modRm_SIBDisp32(ops.reg1.lowId());
        encoder.sib_scaleIndexBaseDisp32(scale, Register.rcx.lowId(), ops.reg2.lowId());
        encoder.disp32(imm);
    }
}

// TODO
fn mirArithScaleDst(isel: *Isel, tag: Tag, inst: Mir.Inst.Index) InnerError!void {
    const ops = Mir.Ops.decode(isel.mir.instructions.items(.ops)[inst]);
    const scale = ops.flags;
    const imm = isel.mir.instructions.items(.data)[inst].imm;

    if (ops.reg2 == .none) {
        // OP [reg1 + scale*rax + 0], imm32
        const opc = getOpCode(tag, .mi, ops.reg1.size() == 8).?;
        const modrm_ext = getModRmExt(tag).?;
        const encoder = try Encoder.init(isel.code, 8);
        encoder.rex(.{
            .w = ops.reg1.size() == 64,
            .b = ops.reg1.isExtended(),
        });
        opc.encode(encoder);
        encoder.modRm_SIBDisp0(modrm_ext);
        encoder.sib_scaleIndexBase(scale, Register.rax.lowId(), ops.reg1.lowId());
        if (imm <= math.maxInt(i8)) {
            encoder.imm8(@intCast(i8, imm));
        } else if (imm <= math.maxInt(i16)) {
            encoder.imm16(@intCast(i16, imm));
        } else {
            encoder.imm32(imm);
        }
        return;
    }

    // OP [reg1 + scale*rax + imm32], reg2
    const opc = getOpCode(tag, .mr, ops.reg1.size() == 8).?;
    const encoder = try Encoder.init(isel.code, 8);
    encoder.rex(.{
        .w = ops.reg1.size() == 64,
        .r = ops.reg2.isExtended(),
        .b = ops.reg1.isExtended(),
    });
    opc.encode(encoder);
    if (imm <= math.maxInt(i8)) {
        encoder.modRm_SIBDisp8(ops.reg2.lowId());
        encoder.sib_scaleIndexBaseDisp8(scale, Register.rax.lowId(), ops.reg1.lowId());
        encoder.disp8(@intCast(i8, imm));
    } else {
        encoder.modRm_SIBDisp32(ops.reg2.lowId());
        encoder.sib_scaleIndexBaseDisp32(scale, Register.rax.lowId(), ops.reg1.lowId());
        encoder.disp32(imm);
    }
}

// TODO
fn mirArithScaleImm(isel: *Isel, tag: Tag, inst: Mir.Inst.Index) InnerError!void {
    const ops = Mir.Ops.decode(isel.mir.instructions.items(.ops)[inst]);
    const scale = ops.flags;
    const payload = isel.mir.instructions.items(.data)[inst].payload;
    const imm_pair = isel.mir.extraData(Mir.ImmPair, payload).data;
    const opc = getOpCode(tag, .mi, ops.reg1.size() == 8).?;
    const modrm_ext = getModRmExt(tag).?;
    const encoder = try Encoder.init(isel.code, 2);
    encoder.rex(.{
        .w = ops.reg1.size() == 64,
        .b = ops.reg1.isExtended(),
    });
    opc.encode(encoder);
    if (imm_pair.dest_off <= math.maxInt(i8)) {
        encoder.modRm_SIBDisp8(modrm_ext);
        encoder.sib_scaleIndexBaseDisp8(scale, Register.rax.lowId(), ops.reg1.lowId());
        encoder.disp8(@intCast(i8, imm_pair.dest_off));
    } else {
        encoder.modRm_SIBDisp32(modrm_ext);
        encoder.sib_scaleIndexBaseDisp32(scale, Register.rax.lowId(), ops.reg1.lowId());
        encoder.disp32(imm_pair.dest_off);
    }
    encoder.imm32(imm_pair.operand);
}

fn mirMovabs(isel: *Isel, inst: Mir.Inst.Index) InnerError!void {
    const tag = isel.mir.instructions.items(.tag)[inst];
    assert(tag == .movabs);
    const ops = Mir.Ops.decode(isel.mir.instructions.items(.ops)[inst]);
    const imm: i64 = if (ops.reg1.size() == 64) blk: {
        const payload = isel.mir.instructions.items(.data)[inst].payload;
        const imm = isel.mir.extraData(Mir.Imm64, payload).data;
        break :blk @bitCast(i64, imm.decode());
    } else isel.mir.instructions.items(.data)[inst].imm;
    if (ops.flags == 0b00) {
        // movabs reg, imm64
        // OI
        return lowerToOiEnc(.mov, ops.reg1, imm, isel.code) catch |err| isel.failWithLoweringError(err);
    }
    if (ops.reg1 == .none) {
        // movabs moffs64, rax
        // TD
        return lowerToTdEnc(.mov, imm, ops.reg2, isel.code) catch |err| isel.failWithLoweringError(err);
    }
    // movabs rax, moffs64
    // FD
    return lowerToFdEnc(.mov, ops.reg1, imm, isel.code) catch |err| isel.failWithLoweringError(err);
}

fn mirIMulComplex(isel: *Isel, inst: Mir.Inst.Index) InnerError!void {
    const tag = isel.mir.instructions.items(.tag)[inst];
    assert(tag == .imul_complex);
    const ops = Mir.Ops.decode(isel.mir.instructions.items(.ops)[inst]);
    switch (ops.flags) {
        0b00 => {
            return lowerToRmEnc(.imul, ops.reg1, RegisterOrMemory.reg(ops.reg2), isel.code) catch |err|
                isel.failWithLoweringError(err);
        },
        0b10 => {
            const imm = isel.mir.instructions.items(.data)[inst].imm;
            return lowerToRmiEnc(.imul, ops.reg1, RegisterOrMemory.reg(ops.reg2), imm, isel.code) catch |err|
                isel.failWithLoweringError(err);
        },
        else => return isel.fail("TODO implement imul", .{}),
    }
}

fn mirLea(isel: *Isel, inst: Mir.Inst.Index) InnerError!void {
    const tag = isel.mir.instructions.items(.tag)[inst];
    assert(tag == .lea);
    const ops = Mir.Ops.decode(isel.mir.instructions.items(.ops)[inst]);
    switch (ops.flags) {
        0b00 => {
            // lea reg1, [reg2 + imm32]
            // RM
            const imm = isel.mir.instructions.items(.data)[inst].imm;
            const src_reg: ?Register = if (ops.reg2 == .none) null else ops.reg2;
            return lowerToRmEnc(
                .lea,
                ops.reg1,
                RegisterOrMemory.mem(src_reg, imm, Memory.PtrSize.fromBits(ops.reg1.size())),
                isel.code,
            ) catch |err| isel.failWithLoweringError(err);
        },
        0b01 => {
            // lea reg1, [rip + imm32]
            // RM
            const start_offset = isel.code.items.len;
            lowerToRmEnc(
                .lea,
                ops.reg1,
                RegisterOrMemory.rip(0, Memory.PtrSize.fromBits(ops.reg1.size())),
                isel.code,
            ) catch |err| return isel.failWithLoweringError(err);
            const end_offset = isel.code.items.len;
            // Backpatch the displacement
            const payload = isel.mir.instructions.items(.data)[inst].payload;
            const imm = isel.mir.extraData(Mir.Imm64, payload).data.decode();
            const disp = @intCast(i32, @intCast(i64, imm) - @intCast(i64, end_offset - start_offset));
            mem.writeIntLittle(i32, isel.code.items[end_offset - 4 ..][0..4], disp);
        },
        0b10 => {
            // lea reg1, [rip + reloc]
            // RM
            lowerToRmEnc(
                .lea,
                ops.reg1,
                RegisterOrMemory.rip(0, Memory.PtrSize.fromBits(ops.reg1.size())),
                isel.code,
            ) catch |err| return isel.failWithLoweringError(err);
            const end_offset = isel.code.items.len;
            const got_entry = isel.mir.instructions.items(.data)[inst].got_entry;
            if (isel.bin_file.cast(link.File.MachO)) |macho_file| {
                // TODO I think the reloc might be in the wrong place.
                const decl = macho_file.active_decl.?;
                try decl.link.macho.relocs.append(isel.bin_file.allocator, .{
                    .offset = @intCast(u32, end_offset - 4),
                    .target = .{ .local = got_entry },
                    .addend = 0,
                    .subtractor = null,
                    .pcrel = true,
                    .length = 2,
                    .@"type" = @enumToInt(std.macho.reloc_type_x86_64.X86_64_RELOC_GOT),
                });
            } else {
                return isel.fail(
                    "TODO implement lea reg, [rip + reloc] for linking backends different than MachO",
                    .{},
                );
            }
        },
        0b11 => return isel.fail("TODO unused variant lea reg1, reg2, 0b11", .{}),
    }
}

fn mirCallExtern(isel: *Isel, inst: Mir.Inst.Index) InnerError!void {
    const tag = isel.mir.instructions.items(.tag)[inst];
    assert(tag == .call_extern);
    const n_strx = isel.mir.instructions.items(.data)[inst].extern_fn;
    const offset = blk: {
        // callq
        lowerToDEnc(.call_near, 0, isel.code) catch |err|
            return isel.failWithLoweringError(err);
        break :blk @intCast(u32, isel.code.items.len) - 4;
    };
    if (isel.bin_file.cast(link.File.MachO)) |macho_file| {
        // Add relocation to the decl.
        try macho_file.active_decl.?.link.macho.relocs.append(isel.bin_file.allocator, .{
            .offset = offset,
            .target = .{ .global = n_strx },
            .addend = 0,
            .subtractor = null,
            .pcrel = true,
            .length = 2,
            .@"type" = @enumToInt(std.macho.reloc_type_x86_64.X86_64_RELOC_BRANCH),
        });
    } else {
        return isel.fail("TODO implement call_extern for linking backends different than MachO", .{});
    }
}

fn mirDbgLine(isel: *Isel, inst: Mir.Inst.Index) InnerError!void {
    const tag = isel.mir.instructions.items(.tag)[inst];
    assert(tag == .dbg_line);
    const payload = isel.mir.instructions.items(.data)[inst].payload;
    const dbg_line_column = isel.mir.extraData(Mir.DbgLineColumn, payload).data;
    try isel.dbgAdvancePCAndLine(dbg_line_column.line, dbg_line_column.column);
}

fn dbgAdvancePCAndLine(isel: *Isel, line: u32, column: u32) InnerError!void {
    const delta_line = @intCast(i32, line) - @intCast(i32, isel.prev_di_line);
    const delta_pc: usize = isel.code.items.len - isel.prev_di_pc;
    switch (isel.debug_output) {
        .dwarf => |dbg_out| {
            // TODO Look into using the DWARF special opcodes to compress this data.
            // It lets you emit single-byte opcodes that add different numbers to
            // both the PC and the line number at the same time.
            try dbg_out.dbg_line.ensureUnusedCapacity(11);
            dbg_out.dbg_line.appendAssumeCapacity(DW.LNS.advance_pc);
            leb128.writeULEB128(dbg_out.dbg_line.writer(), delta_pc) catch unreachable;
            if (delta_line != 0) {
                dbg_out.dbg_line.appendAssumeCapacity(DW.LNS.advance_line);
                leb128.writeILEB128(dbg_out.dbg_line.writer(), delta_line) catch unreachable;
            }
            dbg_out.dbg_line.appendAssumeCapacity(DW.LNS.copy);
            isel.prev_di_pc = isel.code.items.len;
            isel.prev_di_line = line;
            isel.prev_di_column = column;
            isel.prev_di_pc = isel.code.items.len;
        },
        .plan9 => |dbg_out| {
            if (delta_pc <= 0) return; // only do this when the pc changes
            // we have already checked the target in the linker to make sure it is compatable
            const quant = @import("../../link/Plan9/aout.zig").getPCQuant(isel.target.cpu.arch) catch unreachable;

            // increasing the line number
            try @import("../../link/Plan9.zig").changeLine(dbg_out.dbg_line, delta_line);
            // increasing the pc
            const d_pc_p9 = @intCast(i64, delta_pc) - quant;
            if (d_pc_p9 > 0) {
                // minus one because if its the last one, we want to leave space to change the line which is one quanta
                try dbg_out.dbg_line.append(@intCast(u8, @divExact(d_pc_p9, quant) + 128) - quant);
                if (dbg_out.pcop_change_index.*) |pci|
                    dbg_out.dbg_line.items[pci] += 1;
                dbg_out.pcop_change_index.* = @intCast(u32, dbg_out.dbg_line.items.len - 1);
            } else if (d_pc_p9 == 0) {
                // we don't need to do anything, because adding the quant does it for us
            } else unreachable;
            if (dbg_out.start_line.* == null)
                dbg_out.start_line.* = isel.prev_di_line;
            dbg_out.end_line.* = line;
            // only do this if the pc changed
            isel.prev_di_line = line;
            isel.prev_di_column = column;
            isel.prev_di_pc = isel.code.items.len;
        },
        .none => {},
    }
}

fn mirDbgPrologueEnd(isel: *Isel, inst: Mir.Inst.Index) InnerError!void {
    const tag = isel.mir.instructions.items(.tag)[inst];
    assert(tag == .dbg_prologue_end);
    switch (isel.debug_output) {
        .dwarf => |dbg_out| {
            try dbg_out.dbg_line.append(DW.LNS.set_prologue_end);
            try isel.dbgAdvancePCAndLine(isel.prev_di_line, isel.prev_di_column);
        },
        .plan9 => {},
        .none => {},
    }
}

fn mirDbgEpilogueBegin(isel: *Isel, inst: Mir.Inst.Index) InnerError!void {
    const tag = isel.mir.instructions.items(.tag)[inst];
    assert(tag == .dbg_epilogue_begin);
    switch (isel.debug_output) {
        .dwarf => |dbg_out| {
            try dbg_out.dbg_line.append(DW.LNS.set_epilogue_begin);
            try isel.dbgAdvancePCAndLine(isel.prev_di_line, isel.prev_di_column);
        },
        .plan9 => {},
        .none => {},
    }
}

fn mirArgDbgInfo(isel: *Isel, inst: Mir.Inst.Index) InnerError!void {
    const tag = isel.mir.instructions.items(.tag)[inst];
    assert(tag == .arg_dbg_info);
    const payload = isel.mir.instructions.items(.data)[inst].payload;
    const arg_dbg_info = isel.mir.extraData(Mir.ArgDbgInfo, payload).data;
    const mcv = isel.mir.function.args[arg_dbg_info.arg_index];
    try isel.genArgDbgInfo(arg_dbg_info.air_inst, mcv);
}

fn genArgDbgInfo(isel: *Isel, inst: Air.Inst.Index, mcv: MCValue) !void {
    const ty_str = isel.mir.function.air.instructions.items(.data)[inst].ty_str;
    const zir = &isel.mir.function.mod_fn.owner_decl.getFileScope().zir;
    const name = zir.nullTerminatedString(ty_str.str);
    const name_with_null = name.ptr[0 .. name.len + 1];
    const ty = isel.mir.function.air.getRefType(ty_str.ty);

    switch (mcv) {
        .register => |reg| {
            switch (isel.debug_output) {
                .dwarf => |dbg_out| {
                    try dbg_out.dbg_info.ensureUnusedCapacity(3);
                    dbg_out.dbg_info.appendAssumeCapacity(link.File.Elf.abbrev_parameter);
                    dbg_out.dbg_info.appendSliceAssumeCapacity(&[2]u8{ // DW.AT.location, DW.FORM.exprloc
                        1, // ULEB128 dwarf expression length
                        reg.dwarfLocOp(),
                    });
                    try dbg_out.dbg_info.ensureUnusedCapacity(5 + name_with_null.len);
                    try isel.addDbgInfoTypeReloc(ty); // DW.AT.type,  DW.FORM.ref4
                    dbg_out.dbg_info.appendSliceAssumeCapacity(name_with_null); // DW.AT.name, DW.FORM.string
                },
                .plan9 => {},
                .none => {},
            }
        },
        .stack_offset => {
            switch (isel.debug_output) {
                .dwarf => {},
                .plan9 => {},
                .none => {},
            }
        },
        else => {},
    }
}

/// Adds a Type to the .debug_info at the current position. The bytes will be populated later,
/// after codegen for this symbol is done.
fn addDbgInfoTypeReloc(isel: *Isel, ty: Type) !void {
    switch (isel.debug_output) {
        .dwarf => |dbg_out| {
            assert(ty.hasCodeGenBits());
            const index = dbg_out.dbg_info.items.len;
            try dbg_out.dbg_info.resize(index + 4); // DW.AT.type,  DW.FORM.ref4

            const gop = try dbg_out.dbg_info_type_relocs.getOrPut(isel.bin_file.allocator, ty);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .off = undefined,
                    .relocs = .{},
                };
            }
            try gop.value_ptr.relocs.append(isel.bin_file.allocator, @intCast(u32, index));
        },
        .plan9 => {},
        .none => {},
    }
}

const Tag = enum {
    adc,
    add,
    sub,
    xor,
    @"and",
    @"or",
    sbb,
    cmp,
    mov,
    lea,
    jmp_near,
    call_near,
    push,
    pop,
    @"test",
    brk,
    nop,
    imul,
    syscall,
    ret_near,
    ret_far,
    jo,
    jno,
    jb,
    jbe,
    jc,
    jnae,
    jnc,
    jae,
    je,
    jz,
    jne,
    jnz,
    jna,
    jnb,
    jnbe,
    ja,
    js,
    jns,
    jpe,
    jp,
    jpo,
    jnp,
    jnge,
    jl,
    jge,
    jnl,
    jle,
    jng,
    jg,
    jnle,
    seto,
    setno,
    setb,
    setc,
    setnae,
    setnb,
    setnc,
    setae,
    sete,
    setz,
    setne,
    setnz,
    setbe,
    setna,
    seta,
    setnbe,
    sets,
    setns,
    setp,
    setpe,
    setnp,
    setop,
    setl,
    setnge,
    setnl,
    setge,
    setle,
    setng,
    setnle,
    setg,

    fn isSetCC(tag: Tag) bool {
        return switch (tag) {
            .seto,
            .setno,
            .setb,
            .setc,
            .setnae,
            .setnb,
            .setnc,
            .setae,
            .sete,
            .setz,
            .setne,
            .setnz,
            .setbe,
            .setna,
            .seta,
            .setnbe,
            .sets,
            .setns,
            .setp,
            .setpe,
            .setnp,
            .setop,
            .setl,
            .setnge,
            .setnl,
            .setge,
            .setle,
            .setng,
            .setnle,
            .setg,
            => true,
            else => false,
        };
    }
};

const Encoding = enum {
    /// OP
    zo,

    /// OP rel32
    d,

    /// OP r/m64
    m,

    /// OP r64
    o,

    /// OP imm32
    i,

    /// OP r/m64, imm32
    mi,

    /// OP r/m64, r64
    mr,

    /// OP r64, r/m64
    rm,

    /// OP r64, imm64
    oi,

    /// OP al/ax/eax/rax, moffs
    fd,

    /// OP moffs, al/ax/eax/rax
    td,

    /// OP r64, r/m64, imm32
    rmi,
};

const OpCode = union(enum) {
    one_byte: u8,
    two_byte: struct { _1: u8, _2: u8 },

    fn oneByte(opc: u8) OpCode {
        return .{ .one_byte = opc };
    }

    fn twoByte(opc1: u8, opc2: u8) OpCode {
        return .{ .two_byte = .{ ._1 = opc1, ._2 = opc2 } };
    }

    fn encode(opc: OpCode, encoder: Encoder) void {
        switch (opc) {
            .one_byte => |v| encoder.opcode_1byte(v),
            .two_byte => |v| encoder.opcode_2byte(v._1, v._2),
        }
    }

    fn encodeWithReg(opc: OpCode, encoder: Encoder, reg: Register) void {
        assert(opc == .one_byte);
        encoder.opcode_withReg(opc.one_byte, reg.lowId());
    }
};

inline fn getOpCode(tag: Tag, enc: Encoding, is_one_byte: bool) ?OpCode {
    switch (enc) {
        .zo => return switch (tag) {
            .ret_near => OpCode.oneByte(0xc3),
            .ret_far => OpCode.oneByte(0xcb),
            .brk => OpCode.oneByte(0xcc),
            .nop => OpCode.oneByte(0x90),
            .syscall => OpCode.twoByte(0x0f, 0x05),
            else => null,
        },
        .d => return switch (tag) {
            .jmp_near => OpCode.oneByte(0xe9),
            .call_near => OpCode.oneByte(0xe8),
            .jo => if (is_one_byte) OpCode.oneByte(0x70) else OpCode.twoByte(0x0f, 0x80),
            .jno => if (is_one_byte) OpCode.oneByte(0x71) else OpCode.twoByte(0x0f, 0x81),
            .jb, .jc, .jnae => if (is_one_byte) OpCode.oneByte(0x72) else OpCode.twoByte(0x0f, 0x82),
            .jnb, .jnc, .jae => if (is_one_byte) OpCode.oneByte(0x73) else OpCode.twoByte(0x0f, 0x83),
            .je, .jz => if (is_one_byte) OpCode.oneByte(0x74) else OpCode.twoByte(0x0f, 0x84),
            .jne, .jnz => if (is_one_byte) OpCode.oneByte(0x75) else OpCode.twoByte(0x0f, 0x85),
            .jna, .jbe => if (is_one_byte) OpCode.oneByte(0x76) else OpCode.twoByte(0x0f, 0x86),
            .jnbe, .ja => if (is_one_byte) OpCode.oneByte(0x77) else OpCode.twoByte(0x0f, 0x87),
            .js => if (is_one_byte) OpCode.oneByte(0x78) else OpCode.twoByte(0x0f, 0x88),
            .jns => if (is_one_byte) OpCode.oneByte(0x79) else OpCode.twoByte(0x0f, 0x89),
            .jpe, .jp => if (is_one_byte) OpCode.oneByte(0x7a) else OpCode.twoByte(0x0f, 0x8a),
            .jpo, .jnp => if (is_one_byte) OpCode.oneByte(0x7b) else OpCode.twoByte(0x0f, 0x8b),
            .jnge, .jl => if (is_one_byte) OpCode.oneByte(0x7c) else OpCode.twoByte(0x0f, 0x8c),
            .jge, .jnl => if (is_one_byte) OpCode.oneByte(0x7d) else OpCode.twoByte(0x0f, 0x8d),
            .jle, .jng => if (is_one_byte) OpCode.oneByte(0x7e) else OpCode.twoByte(0x0f, 0x8e),
            .jg, .jnle => if (is_one_byte) OpCode.oneByte(0x7f) else OpCode.twoByte(0x0f, 0x8f),
            else => null,
        },
        .m => return switch (tag) {
            .jmp_near, .call_near, .push => OpCode.oneByte(0xff),
            .pop => OpCode.oneByte(0x8f),
            .seto => OpCode.twoByte(0x0f, 0x90),
            .setno => OpCode.twoByte(0x0f, 0x91),
            .setb, .setc, .setnae => OpCode.twoByte(0x0f, 0x92),
            .setnb, .setnc, .setae => OpCode.twoByte(0x0f, 0x93),
            .sete, .setz => OpCode.twoByte(0x0f, 0x94),
            .setne, .setnz => OpCode.twoByte(0x0f, 0x95),
            .setbe, .setna => OpCode.twoByte(0x0f, 0x96),
            .seta, .setnbe => OpCode.twoByte(0x0f, 0x97),
            .sets => OpCode.twoByte(0x0f, 0x98),
            .setns => OpCode.twoByte(0x0f, 0x99),
            .setp, .setpe => OpCode.twoByte(0x0f, 0x9a),
            .setnp, .setop => OpCode.twoByte(0x0f, 0x9b),
            .setl, .setnge => OpCode.twoByte(0x0f, 0x9c),
            .setnl, .setge => OpCode.twoByte(0x0f, 0x9d),
            .setle, .setng => OpCode.twoByte(0x0f, 0x9e),
            .setnle, .setg => OpCode.twoByte(0x0f, 0x9f),
            else => null,
        },
        .o => return switch (tag) {
            .push => OpCode.oneByte(0x50),
            .pop => OpCode.oneByte(0x58),
            else => null,
        },
        .i => return switch (tag) {
            .push => OpCode.oneByte(if (is_one_byte) 0x6a else 0x68),
            .@"test" => OpCode.oneByte(if (is_one_byte) 0xa8 else 0xa9),
            .ret_near => OpCode.oneByte(0xc2),
            .ret_far => OpCode.oneByte(0xca),
            else => null,
        },
        .mi => return switch (tag) {
            .adc, .add, .sub, .xor, .@"and", .@"or", .sbb, .cmp => OpCode.oneByte(if (is_one_byte) 0x80 else 0x81),
            .mov => OpCode.oneByte(if (is_one_byte) 0xc6 else 0xc7),
            .@"test" => OpCode.oneByte(if (is_one_byte) 0xf6 else 0xf7),
            else => null,
        },
        .mr => return switch (tag) {
            .adc => OpCode.oneByte(if (is_one_byte) 0x10 else 0x11),
            .add => OpCode.oneByte(if (is_one_byte) 0x00 else 0x01),
            .sub => OpCode.oneByte(if (is_one_byte) 0x28 else 0x29),
            .xor => OpCode.oneByte(if (is_one_byte) 0x30 else 0x31),
            .@"and" => OpCode.oneByte(if (is_one_byte) 0x20 else 0x21),
            .@"or" => OpCode.oneByte(if (is_one_byte) 0x08 else 0x09),
            .sbb => OpCode.oneByte(if (is_one_byte) 0x18 else 0x19),
            .cmp => OpCode.oneByte(if (is_one_byte) 0x38 else 0x39),
            .mov => OpCode.oneByte(if (is_one_byte) 0x88 else 0x89),
            else => null,
        },
        .rm => return switch (tag) {
            .adc => OpCode.oneByte(if (is_one_byte) 0x12 else 0x13),
            .add => OpCode.oneByte(if (is_one_byte) 0x02 else 0x03),
            .sub => OpCode.oneByte(if (is_one_byte) 0x2a else 0x2b),
            .xor => OpCode.oneByte(if (is_one_byte) 0x32 else 0x33),
            .@"and" => OpCode.oneByte(if (is_one_byte) 0x22 else 0x23),
            .@"or" => OpCode.oneByte(if (is_one_byte) 0x0b else 0x0b),
            .sbb => OpCode.oneByte(if (is_one_byte) 0x1a else 0x1b),
            .cmp => OpCode.oneByte(if (is_one_byte) 0x3a else 0x3b),
            .mov => OpCode.oneByte(if (is_one_byte) 0x8a else 0x8b),
            .lea => OpCode.oneByte(if (is_one_byte) 0x8c else 0x8d),
            .imul => OpCode.twoByte(0x0f, 0xaf),
            else => null,
        },
        .oi => return switch (tag) {
            .mov => OpCode.oneByte(if (is_one_byte) 0xb0 else 0xb8),
            else => null,
        },
        .fd => return switch (tag) {
            .mov => OpCode.oneByte(if (is_one_byte) 0xa0 else 0xa1),
            else => null,
        },
        .td => return switch (tag) {
            .mov => OpCode.oneByte(if (is_one_byte) 0xa2 else 0xa3),
            else => null,
        },
        .rmi => return switch (tag) {
            .imul => OpCode.oneByte(if (is_one_byte) 0x6b else 0x69),
            else => null,
        },
    }
}

inline fn getModRmExt(tag: Tag) ?u3 {
    return switch (tag) {
        .adc => 0x2,
        .add => 0x0,
        .sub => 0x5,
        .xor => 0x6,
        .@"and" => 0x4,
        .@"or" => 0x1,
        .sbb => 0x3,
        .cmp => 0x7,
        .mov => 0x0,
        .jmp_near => 0x4,
        .call_near => 0x2,
        .push => 0x6,
        .pop => 0x0,
        .@"test" => 0x0,
        .seto,
        .setno,
        .setb,
        .setc,
        .setnae,
        .setnb,
        .setnc,
        .setae,
        .sete,
        .setz,
        .setne,
        .setnz,
        .setbe,
        .setna,
        .seta,
        .setnbe,
        .sets,
        .setns,
        .setp,
        .setpe,
        .setnp,
        .setop,
        .setl,
        .setnge,
        .setnl,
        .setge,
        .setle,
        .setng,
        .setnle,
        .setg,
        => 0x0,
        else => null,
    };
}

const ScaleIndexBase = struct {
    scale: u2,
    index_reg: ?Register,
    base_reg: ?Register,
};

const Memory = struct {
    reg: ?Register,
    rip: bool = false,
    disp: i32,
    ptr_size: PtrSize,
    sib: ?ScaleIndexBase = null,

    const PtrSize = enum {
        byte_ptr,
        word_ptr,
        dword_ptr,
        qword_ptr,

        fn fromBits(in_bits: u64) PtrSize {
            return switch (in_bits) {
                8 => .byte_ptr,
                16 => .word_ptr,
                32 => .dword_ptr,
                64 => .qword_ptr,
                else => unreachable,
            };
        }

        /// Returns size in bits.
        fn size(ptr_size: PtrSize) u64 {
            return switch (ptr_size) {
                .byte_ptr => 8,
                .word_ptr => 16,
                .dword_ptr => 32,
                .qword_ptr => 64,
            };
        }
    };

    fn encodeWithReg(encoder: Encoder, dst: u3, src: u3, disp: i32) void {
        if (dst == 4) {
            if (disp == 0) {
                encoder.modRm_SIBDisp0(src);
                encoder.sib_base(dst);
            } else if (immOpSize(disp) == 8) {
                encoder.modRm_SIBDisp8(src);
                encoder.sib_baseDisp8(dst);
                encoder.disp8(@intCast(i8, disp));
            } else {
                encoder.modRm_SIBDisp32(src);
                encoder.sib_baseDisp32(dst);
                encoder.disp32(disp);
            }
        } else {
            if (disp == 0) {
                encoder.modRm_indirectDisp0(src, dst);
            } else if (immOpSize(disp) == 8) {
                encoder.modRm_indirectDisp8(src, dst);
                encoder.disp8(@intCast(i8, disp));
            } else {
                encoder.modRm_indirectDisp32(src, dst);
                encoder.disp32(disp);
            }
        }
    }

    fn encodeDsOrRip(encoder: Encoder, op: u3, disp: i32, rip: bool) void {
        if (rip) {
            encoder.modRm_RIPDisp32(op);
        } else {
            encoder.modRm_SIBDisp0(op);
            encoder.sib_disp32();
        }
        encoder.disp32(disp);
    }
};

fn encodeImm(encoder: Encoder, imm: i32, size: u64) void {
    switch (size) {
        8 => encoder.imm8(@intCast(i8, imm)),
        16 => encoder.imm16(@intCast(i16, imm)),
        32, 64 => encoder.imm32(imm),
        else => unreachable,
    }
}

const RegisterOrMemory = union(enum) {
    register: Register,
    memory: Memory,

    fn reg(register: Register) RegisterOrMemory {
        return .{ .register = register };
    }

    fn mem(register: ?Register, disp: i32, ptr_size: Memory.PtrSize) RegisterOrMemory {
        return .{
            .memory = .{
                .reg = register,
                .disp = disp,
                .ptr_size = ptr_size,
            },
        };
    }

    fn rip(disp: i32, ptr_size: Memory.PtrSize) RegisterOrMemory {
        return .{
            .memory = .{
                .reg = null,
                .rip = true,
                .disp = disp,
                .ptr_size = ptr_size,
            },
        };
    }
};

const LoweringError = error{
    OutOfMemory,
    Overflow,
    OperandSizeMismatch,
    RaxOperandExpected,
};

fn lowerToZoEnc(tag: Tag, code: *std.ArrayList(u8)) LoweringError!void {
    const opc = getOpCode(tag, .zo, false).?;
    const encoder = try Encoder.init(code, 1);
    opc.encode(encoder);
}

fn lowerToIEnc(tag: Tag, imm: i32, code: *std.ArrayList(u8)) LoweringError!void {
    if (tag == .ret_far or tag == .ret_near) {
        const encoder = try Encoder.init(code, 3);
        const opc = getOpCode(tag, .i, false).?;
        opc.encode(encoder);
        encoder.imm16(@intCast(i16, imm));
        return;
    }
    const opc = getOpCode(tag, .i, immOpSize(imm) == 8).?;
    const encoder = try Encoder.init(code, 5);
    if (immOpSize(imm) == 16) {
        encoder.prefix16BitMode();
    }
    opc.encode(encoder);
    encodeImm(encoder, imm, immOpSize(imm));
}

fn lowerToOEnc(tag: Tag, reg: Register, code: *std.ArrayList(u8)) LoweringError!void {
    if (reg.size() != 16 and reg.size() != 64) {
        return error.OperandSizeMismatch; // TODO correct for push/pop, but is it universal?
    }
    const opc = getOpCode(tag, .o, false).?;
    const encoder = try Encoder.init(code, 3);
    if (reg.size() == 16) {
        encoder.prefix16BitMode();
    }
    encoder.rex(.{
        .w = false,
        .b = reg.isExtended(),
    });
    opc.encodeWithReg(encoder, reg);
}

fn lowerToDEnc(tag: Tag, imm: i32, code: *std.ArrayList(u8)) LoweringError!void {
    const opc = getOpCode(tag, .d, false).?;
    const encoder = try Encoder.init(code, 6);
    opc.encode(encoder);
    encoder.imm32(imm);
}

fn lowerToMEnc(tag: Tag, reg_or_mem: RegisterOrMemory, code: *std.ArrayList(u8)) LoweringError!void {
    const opc = getOpCode(tag, .m, false).?;
    const modrm_ext = getModRmExt(tag).?;
    switch (reg_or_mem) {
        .register => |reg| {
            const op_size_mismatch = blk: {
                if (tag.isSetCC() and reg.size() == 8)
                    break :blk false;
                break :blk reg.size() != 64 and reg.size() != 16;
            };
            if (op_size_mismatch) {
                return error.OperandSizeMismatch;
            }
            const encoder = try Encoder.init(code, 4);
            if (reg.size() == 16) {
                encoder.prefix16BitMode();
            }
            encoder.rex(.{
                .w = switch (reg) {
                    .ah, .bh, .ch, .dh => true,
                    else => false,
                },
                .b = reg.isExtended(),
            });
            opc.encode(encoder);
            encoder.modRm_direct(modrm_ext, reg.lowId());
        },
        .memory => |mem_op| {
            if (mem_op.ptr_size != .qword_ptr and mem_op.ptr_size != .word_ptr) {
                return error.OperandSizeMismatch;
            }
            const encoder = try Encoder.init(code, 8);
            if (mem_op.ptr_size == .word_ptr) {
                encoder.prefix16BitMode();
            }
            if (mem_op.reg) |reg| {
                if (reg.size() != 64) {
                    return error.OperandSizeMismatch;
                }
                encoder.rex(.{
                    .w = false,
                    .b = reg.isExtended(),
                });
                opc.encode(encoder);
                Memory.encodeWithReg(encoder, reg.lowId(), modrm_ext, mem_op.disp);
            } else {
                opc.encode(encoder);
                Memory.encodeDsOrRip(encoder, modrm_ext, mem_op.disp, mem_op.rip);
            }
        },
    }
}

fn lowerToTdEnc(tag: Tag, moffs: i64, reg: Register, code: *std.ArrayList(u8)) LoweringError!void {
    return lowerToTdFdEnc(tag, reg, moffs, code, true);
}

fn lowerToFdEnc(tag: Tag, reg: Register, moffs: i64, code: *std.ArrayList(u8)) LoweringError!void {
    return lowerToTdFdEnc(tag, reg, moffs, code, false);
}

fn lowerToTdFdEnc(tag: Tag, reg: Register, moffs: i64, code: *std.ArrayList(u8), td: bool) LoweringError!void {
    if (reg.lowId() != Register.rax.lowId()) {
        return error.RaxOperandExpected;
    }
    if (reg.size() != immOpSize(moffs)) {
        return error.OperandSizeMismatch;
    }
    const opc = if (td)
        getOpCode(tag, .td, reg.size() == 8).?
    else
        getOpCode(tag, .fd, reg.size() == 8).?;
    const encoder = try Encoder.init(code, 10);
    if (reg.size() == 16) {
        encoder.prefix16BitMode();
    }
    encoder.rex(.{
        .w = setRexWRegister(reg),
    });
    opc.encode(encoder);
    switch (reg.size()) {
        8 => {
            const moffs8 = try math.cast(i8, moffs);
            encoder.imm8(moffs8);
        },
        16 => {
            const moffs16 = try math.cast(i16, moffs);
            encoder.imm16(moffs16);
        },
        32 => {
            const moffs32 = try math.cast(i32, moffs);
            encoder.imm32(moffs32);
        },
        64 => {
            encoder.imm64(@bitCast(u64, moffs));
        },
        else => unreachable,
    }
}

fn lowerToOiEnc(tag: Tag, reg: Register, imm: i64, code: *std.ArrayList(u8)) LoweringError!void {
    if (reg.size() != immOpSize(imm)) {
        return error.OperandSizeMismatch;
    }
    const opc = getOpCode(tag, .oi, reg.size() == 8).?;
    const encoder = try Encoder.init(code, 10);
    if (reg.size() == 16) {
        encoder.prefix16BitMode();
    }
    encoder.rex(.{
        .w = setRexWRegister(reg),
        .b = reg.isExtended(),
    });
    opc.encodeWithReg(encoder, reg);
    switch (reg.size()) {
        8 => {
            const imm8 = try math.cast(i8, imm);
            encoder.imm8(imm8);
        },
        16 => {
            const imm16 = try math.cast(i16, imm);
            encoder.imm16(imm16);
        },
        32 => {
            const imm32 = try math.cast(i32, imm);
            encoder.imm32(imm32);
        },
        64 => {
            encoder.imm64(@bitCast(u64, imm));
        },
        else => unreachable,
    }
}

fn lowerToMiEnc(tag: Tag, reg_or_mem: RegisterOrMemory, imm: i32, code: *std.ArrayList(u8)) LoweringError!void {
    const modrm_ext = getModRmExt(tag).?;
    switch (reg_or_mem) {
        .register => |dst_reg| {
            const opc = getOpCode(tag, .mi, dst_reg.size() == 8).?;
            const encoder = try Encoder.init(code, 7);
            if (dst_reg.size() == 16) {
                // 0x66 prefix switches to the non-default size; here we assume a switch from
                // the default 32bits to 16bits operand-size.
                // More info: https://www.cs.uni-potsdam.de/desn/lehre/ss15/64-ia-32-architectures-software-developer-instruction-set-reference-manual-325383.pdf#page=32&zoom=auto,-159,773
                encoder.prefix16BitMode();
            }
            encoder.rex(.{
                .w = setRexWRegister(dst_reg),
                .b = dst_reg.isExtended(),
            });
            opc.encode(encoder);
            encoder.modRm_direct(modrm_ext, dst_reg.lowId());
            encodeImm(encoder, imm, dst_reg.size());
        },
        .memory => |dst_mem| {
            const opc = getOpCode(tag, .mi, dst_mem.ptr_size == .byte_ptr).?;
            const encoder = try Encoder.init(code, 12);
            if (dst_mem.ptr_size == .word_ptr) {
                encoder.prefix16BitMode();
            }
            if (dst_mem.reg) |dst_reg| {
                if (dst_reg.size() != 64) {
                    return error.OperandSizeMismatch;
                }
                encoder.rex(.{
                    .w = dst_mem.ptr_size == .qword_ptr,
                    .b = dst_reg.isExtended(),
                });
                opc.encode(encoder);
                Memory.encodeWithReg(encoder, dst_reg.lowId(), modrm_ext, dst_mem.disp);
            } else {
                opc.encode(encoder);
                Memory.encodeDsOrRip(encoder, modrm_ext, dst_mem.disp, dst_mem.rip);
            }
            encodeImm(encoder, imm, dst_mem.ptr_size.size());
        },
    }
}

fn lowerToRmEnc(
    tag: Tag,
    reg: Register,
    reg_or_mem: RegisterOrMemory,
    code: *std.ArrayList(u8),
) LoweringError!void {
    const opc = getOpCode(tag, .rm, reg.size() == 8).?;
    switch (reg_or_mem) {
        .register => |src_reg| {
            if (reg.size() != src_reg.size()) {
                return error.OperandSizeMismatch;
            }
            const encoder = try Encoder.init(code, 3);
            encoder.rex(.{
                .w = setRexWRegister(reg) or setRexWRegister(src_reg),
                .r = reg.isExtended(),
                .b = src_reg.isExtended(),
            });
            opc.encode(encoder);
            encoder.modRm_direct(reg.lowId(), src_reg.lowId());
        },
        .memory => |src_mem| {
            if (reg.size() != src_mem.ptr_size.size()) {
                return error.OperandSizeMismatch;
            }
            const encoder = try Encoder.init(code, 9);
            if (reg.size() == 16) {
                encoder.prefix16BitMode();
            }
            if (src_mem.reg) |src_reg| {
                // TODO handle 32-bit base register - requires prefix 0x67
                // Intel Manual, Vol 1, chapter 3.6 and 3.6.1
                if (src_reg.size() != 64) {
                    return error.OperandSizeMismatch;
                }
                encoder.rex(.{
                    .w = setRexWRegister(reg),
                    .r = reg.isExtended(),
                    .b = src_reg.isExtended(),
                });
                opc.encode(encoder);
                Memory.encodeWithReg(encoder, src_reg.lowId(), reg.lowId(), src_mem.disp);
            } else {
                encoder.rex(.{
                    .w = setRexWRegister(reg),
                    .r = reg.isExtended(),
                });
                opc.encode(encoder);
                Memory.encodeDsOrRip(encoder, reg.lowId(), src_mem.disp, src_mem.rip);
            }
        },
    }
}

fn lowerToMrEnc(
    tag: Tag,
    reg_or_mem: RegisterOrMemory,
    reg: Register,
    code: *std.ArrayList(u8),
) LoweringError!void {
    const opc = getOpCode(tag, .mr, reg.size() == 8).?;
    switch (reg_or_mem) {
        .register => |dst_reg| {
            if (dst_reg.size() != reg.size()) {
                return error.OperandSizeMismatch;
            }
            const encoder = try Encoder.init(code, 3);
            encoder.rex(.{
                .w = setRexWRegister(dst_reg) or setRexWRegister(reg),
                .r = reg.isExtended(),
                .b = dst_reg.isExtended(),
            });
            opc.encode(encoder);
            encoder.modRm_direct(reg.lowId(), dst_reg.lowId());
        },
        .memory => |dst_mem| {
            if (dst_mem.ptr_size.size() != reg.size()) {
                return error.OperandSizeMismatch;
            }
            const encoder = try Encoder.init(code, 9);
            if (reg.size() == 16) {
                encoder.prefix16BitMode();
            }
            if (dst_mem.reg) |dst_reg| {
                if (dst_reg.size() != 64) {
                    return error.OperandSizeMismatch;
                }
                encoder.rex(.{
                    .w = dst_mem.ptr_size == .qword_ptr or setRexWRegister(reg),
                    .r = reg.isExtended(),
                    .b = dst_reg.isExtended(),
                });
                opc.encode(encoder);
                Memory.encodeWithReg(encoder, dst_reg.lowId(), reg.lowId(), dst_mem.disp);
            } else {
                encoder.rex(.{
                    .w = dst_mem.ptr_size == .qword_ptr or setRexWRegister(reg),
                    .r = reg.isExtended(),
                });
                opc.encode(encoder);
                Memory.encodeDsOrRip(encoder, reg.lowId(), dst_mem.disp, dst_mem.rip);
            }
        },
    }
}

fn lowerToRmiEnc(
    tag: Tag,
    reg: Register,
    reg_or_mem: RegisterOrMemory,
    imm: i32,
    code: *std.ArrayList(u8),
) LoweringError!void {
    if (reg.size() == 8) {
        return error.OperandSizeMismatch;
    }
    const opc = getOpCode(tag, .rmi, false).?;
    const encoder = try Encoder.init(code, 13);
    if (reg.size() == 16) {
        encoder.prefix16BitMode();
    }
    switch (reg_or_mem) {
        .register => |src_reg| {
            if (reg.size() != src_reg.size()) {
                return error.OperandSizeMismatch;
            }
            encoder.rex(.{
                .w = setRexWRegister(reg) or setRexWRegister(src_reg),
                .r = reg.isExtended(),
                .b = src_reg.isExtended(),
            });
            opc.encode(encoder);
            encoder.modRm_direct(reg.lowId(), src_reg.lowId());
        },
        .memory => |src_mem| {
            if (src_mem.reg) |src_reg| {
                // TODO handle 32-bit base register - requires prefix 0x67
                // Intel Manual, Vol 1, chapter 3.6 and 3.6.1
                if (src_reg.size() != 64) {
                    return error.OperandSizeMismatch;
                }
                if (src_mem.ptr_size == .byte_ptr) {
                    return error.OperandSizeMismatch;
                }
                encoder.rex(.{
                    .w = setRexWRegister(reg),
                    .r = reg.isExtended(),
                    .b = src_reg.isExtended(),
                });
                opc.encode(encoder);
                Memory.encodeWithReg(encoder, src_reg.lowId(), reg.lowId(), src_mem.disp);
            } else {
                encoder.rex(.{
                    .w = setRexWRegister(reg),
                    .r = reg.isExtended(),
                });
                opc.encode(encoder);
                Memory.encodeDsOrRip(encoder, reg.lowId(), src_mem.disp, src_mem.rip);
            }
        },
    }
    encodeImm(encoder, imm, reg.size());
}

fn expectEqualHexStrings(expected: []const u8, given: []const u8, assembly: []const u8) !void {
    assert(expected.len > 0);
    if (mem.eql(u8, expected, given)) return;
    const expected_fmt = try std.fmt.allocPrint(testing.allocator, "{x}", .{std.fmt.fmtSliceHexLower(expected)});
    defer testing.allocator.free(expected_fmt);
    const given_fmt = try std.fmt.allocPrint(testing.allocator, "{x}", .{std.fmt.fmtSliceHexLower(given)});
    defer testing.allocator.free(given_fmt);
    const idx = mem.indexOfDiff(u8, expected_fmt, given_fmt).?;
    var padding = try testing.allocator.alloc(u8, idx + 5);
    defer testing.allocator.free(padding);
    mem.set(u8, padding, ' ');
    std.debug.print("\nASM: {s}\nEXP: {s}\nGIV: {s}\n{s}^ -- first differing byte\n", .{
        assembly,
        expected_fmt,
        given_fmt,
        padding,
    });
    return error.TestFailed;
}

const TestIsel = struct {
    code_buffer: std.ArrayList(u8),
    next: usize = 0,

    fn init() TestIsel {
        return .{
            .code_buffer = std.ArrayList(u8).init(testing.allocator),
        };
    }

    fn deinit(isel: *TestIsel) void {
        isel.code_buffer.deinit();
        isel.next = undefined;
    }

    fn code(isel: *TestIsel) *std.ArrayList(u8) {
        isel.next = isel.code_buffer.items.len;
        return &isel.code_buffer;
    }

    fn lowered(isel: TestIsel) []const u8 {
        return isel.code_buffer.items[isel.next..];
    }
};

test "lower MI encoding" {
    var isel = TestIsel.init();
    defer isel.deinit();
    try lowerToMiEnc(.mov, RegisterOrMemory.reg(.rax), 0x10, isel.code());
    try expectEqualHexStrings("\x48\xc7\xc0\x10\x00\x00\x00", isel.lowered(), "mov rax, 0x10");
    try lowerToMiEnc(.mov, RegisterOrMemory.mem(.r11, 0, .dword_ptr), 0x10, isel.code());
    try expectEqualHexStrings("\x41\xc7\x03\x10\x00\x00\x00", isel.lowered(), "mov dword ptr [r11 + 0], 0x10");
    try lowerToMiEnc(.add, RegisterOrMemory.mem(.rdx, -8, .dword_ptr), 0x10, isel.code());
    try expectEqualHexStrings("\x81\x42\xF8\x10\x00\x00\x00", isel.lowered(), "add dword ptr [rdx - 8], 0x10");
    try lowerToMiEnc(.sub, RegisterOrMemory.mem(.r11, 0x10000000, .dword_ptr), 0x10, isel.code());
    try expectEqualHexStrings(
        "\x41\x81\xab\x00\x00\x00\x10\x10\x00\x00\x00",
        isel.lowered(),
        "sub dword ptr [r11 + 0x10000000], 0x10",
    );
    try lowerToMiEnc(.@"and", RegisterOrMemory.mem(null, 0x10000000, .dword_ptr), 0x10, isel.code());
    try expectEqualHexStrings(
        "\x81\x24\x25\x00\x00\x00\x10\x10\x00\x00\x00",
        isel.lowered(),
        "and dword ptr [ds:0x10000000], 0x10",
    );
    try lowerToMiEnc(.@"and", RegisterOrMemory.mem(.r12, 0x10000000, .dword_ptr), 0x10, isel.code());
    try expectEqualHexStrings(
        "\x41\x81\xA4\x24\x00\x00\x00\x10\x10\x00\x00\x00",
        isel.lowered(),
        "and dword ptr [r12 + 0x10000000], 0x10",
    );
    try lowerToMiEnc(.mov, RegisterOrMemory.rip(0x10, .qword_ptr), 0x10, isel.code());
    try expectEqualHexStrings(
        "\xC7\x05\x10\x00\x00\x00\x10\x00\x00\x00",
        isel.lowered(),
        "mov qword ptr [rip + 0x10], 0x10",
    );
    try lowerToMiEnc(.mov, RegisterOrMemory.mem(.rbp, -8, .qword_ptr), 0x10, isel.code());
    try expectEqualHexStrings(
        "\x48\xc7\x45\xf8\x10\x00\x00\x00",
        isel.lowered(),
        "mov qword ptr [rbp - 8], 0x10",
    );
    try lowerToMiEnc(.mov, RegisterOrMemory.mem(.rbp, -2, .word_ptr), 0x10, isel.code());
    try expectEqualHexStrings("\x66\xC7\x45\xFE\x10\x00", isel.lowered(), "mov word ptr [rbp - 2], 0x10");
    try lowerToMiEnc(.mov, RegisterOrMemory.mem(.rbp, -1, .byte_ptr), 0x10, isel.code());
    try expectEqualHexStrings("\xC6\x45\xFF\x10", isel.lowered(), "mov byte ptr [rbp - 1], 0x10");
}

test "lower RM encoding" {
    var isel = TestIsel.init();
    defer isel.deinit();
    try lowerToRmEnc(.mov, .rax, RegisterOrMemory.reg(.rbx), isel.code());
    try expectEqualHexStrings("\x48\x8b\xc3", isel.lowered(), "mov rax, rbx");
    try lowerToRmEnc(.mov, .rax, RegisterOrMemory.mem(.r11, 0, .qword_ptr), isel.code());
    try expectEqualHexStrings("\x49\x8b\x03", isel.lowered(), "mov rax, qword ptr [r11 + 0]");
    try lowerToRmEnc(.add, .r11, RegisterOrMemory.mem(null, 0x10000000, .qword_ptr), isel.code());
    try expectEqualHexStrings(
        "\x4C\x03\x1C\x25\x00\x00\x00\x10",
        isel.lowered(),
        "add r11, qword ptr [ds:0x10000000]",
    );
    try lowerToRmEnc(.add, .r12b, RegisterOrMemory.mem(null, 0x10000000, .byte_ptr), isel.code());
    try expectEqualHexStrings(
        "\x44\x02\x24\x25\x00\x00\x00\x10",
        isel.lowered(),
        "add r11b, byte ptr [ds:0x10000000]",
    );
    try lowerToRmEnc(.sub, .r11, RegisterOrMemory.mem(.r13, 0x10000000, .qword_ptr), isel.code());
    try expectEqualHexStrings(
        "\x4D\x2B\x9D\x00\x00\x00\x10",
        isel.lowered(),
        "sub r11, qword ptr [r13 + 0x10000000]",
    );
    try lowerToRmEnc(.sub, .r11, RegisterOrMemory.mem(.r12, 0x10000000, .qword_ptr), isel.code());
    try expectEqualHexStrings(
        "\x4D\x2B\x9C\x24\x00\x00\x00\x10",
        isel.lowered(),
        "sub r11, qword ptr [r12 + 0x10000000]",
    );
    try lowerToRmEnc(.mov, .rax, RegisterOrMemory.mem(.rbp, -4, .qword_ptr), isel.code());
    try expectEqualHexStrings("\x48\x8B\x45\xFC", isel.lowered(), "mov rax, qword ptr [rbp - 4]");
    try lowerToRmEnc(.lea, .rax, RegisterOrMemory.rip(0x10, .qword_ptr), isel.code());
    try expectEqualHexStrings("\x48\x8D\x05\x10\x00\x00\x00", isel.lowered(), "lea rax, [rip + 0x10]");
}

test "lower MR encoding" {
    var isel = TestIsel.init();
    defer isel.deinit();
    try lowerToMrEnc(.mov, RegisterOrMemory.reg(.rax), .rbx, isel.code());
    try expectEqualHexStrings("\x48\x89\xd8", isel.lowered(), "mov rax, rbx");
    try lowerToMrEnc(.mov, RegisterOrMemory.mem(.rbp, -4, .qword_ptr), .r11, isel.code());
    try expectEqualHexStrings("\x4c\x89\x5d\xfc", isel.lowered(), "mov qword ptr [rbp - 4], r11");
    try lowerToMrEnc(.add, RegisterOrMemory.mem(null, 0x10000000, .byte_ptr), .r12b, isel.code());
    try expectEqualHexStrings(
        "\x44\x00\x24\x25\x00\x00\x00\x10",
        isel.lowered(),
        "add byte ptr [ds:0x10000000], r12b",
    );
    try lowerToMrEnc(.add, RegisterOrMemory.mem(null, 0x10000000, .dword_ptr), .r12d, isel.code());
    try expectEqualHexStrings(
        "\x44\x01\x24\x25\x00\x00\x00\x10",
        isel.lowered(),
        "add dword ptr [ds:0x10000000], r12d",
    );
    try lowerToMrEnc(.sub, RegisterOrMemory.mem(.r11, 0x10000000, .qword_ptr), .r12, isel.code());
    try expectEqualHexStrings(
        "\x4D\x29\xA3\x00\x00\x00\x10",
        isel.lowered(),
        "sub qword ptr [r11 + 0x10000000], r12",
    );
    try lowerToMrEnc(.mov, RegisterOrMemory.rip(0x10, .qword_ptr), .r12, isel.code());
    try expectEqualHexStrings("\x4C\x89\x25\x10\x00\x00\x00", isel.lowered(), "mov qword ptr [rip + 0x10], r12");
}

test "lower OI encoding" {
    var isel = TestIsel.init();
    defer isel.deinit();
    try lowerToOiEnc(.mov, .rax, 0x1000000000000000, isel.code());
    try expectEqualHexStrings(
        "\x48\xB8\x00\x00\x00\x00\x00\x00\x00\x10",
        isel.lowered(),
        "movabs rax, 0x1000000000000000",
    );
    try lowerToOiEnc(.mov, .r11, 0x1000000000000000, isel.code());
    try expectEqualHexStrings(
        "\x49\xBB\x00\x00\x00\x00\x00\x00\x00\x10",
        isel.lowered(),
        "movabs r11, 0x1000000000000000",
    );
    try lowerToOiEnc(.mov, .r11d, 0x10000000, isel.code());
    try expectEqualHexStrings("\x41\xBB\x00\x00\x00\x10", isel.lowered(), "mov r11d, 0x10000000");
    try lowerToOiEnc(.mov, .r11w, 0x1000, isel.code());
    try expectEqualHexStrings("\x66\x41\xBB\x00\x10", isel.lowered(), "mov r11w, 0x1000");
    try lowerToOiEnc(.mov, .r11b, 0x10, isel.code());
    try expectEqualHexStrings("\x41\xB3\x10", isel.lowered(), "mov r11b, 0x10");
}

test "lower FD/TD encoding" {
    var isel = TestIsel.init();
    defer isel.deinit();
    try lowerToFdEnc(.mov, .rax, 0x1000000000000000, isel.code());
    try expectEqualHexStrings(
        "\x48\xa1\x00\x00\x00\x00\x00\x00\x00\x10",
        isel.lowered(),
        "mov rax, ds:0x1000000000000000",
    );
    try lowerToFdEnc(.mov, .eax, 0x10000000, isel.code());
    try expectEqualHexStrings("\xa1\x00\x00\x00\x10", isel.lowered(), "mov eax, ds:0x10000000");
    try lowerToFdEnc(.mov, .ax, 0x1000, isel.code());
    try expectEqualHexStrings("\x66\xa1\x00\x10", isel.lowered(), "mov ax, ds:0x1000");
    try lowerToFdEnc(.mov, .al, 0x10, isel.code());
    try expectEqualHexStrings("\xa0\x10", isel.lowered(), "mov al, ds:0x10");
}

test "lower M encoding" {
    var isel = TestIsel.init();
    defer isel.deinit();
    try lowerToMEnc(.jmp_near, RegisterOrMemory.reg(.r12), isel.code());
    try expectEqualHexStrings("\x41\xFF\xE4", isel.lowered(), "jmp r12");
    try lowerToMEnc(.jmp_near, RegisterOrMemory.reg(.r12w), isel.code());
    try expectEqualHexStrings("\x66\x41\xFF\xE4", isel.lowered(), "jmp r12w");
    try lowerToMEnc(.jmp_near, RegisterOrMemory.mem(.r12, 0, .qword_ptr), isel.code());
    try expectEqualHexStrings("\x41\xFF\x24\x24", isel.lowered(), "jmp qword ptr [r12]");
    try lowerToMEnc(.jmp_near, RegisterOrMemory.mem(.r12, 0, .word_ptr), isel.code());
    try expectEqualHexStrings("\x66\x41\xFF\x24\x24", isel.lowered(), "jmp word ptr [r12]");
    try lowerToMEnc(.jmp_near, RegisterOrMemory.mem(.r12, 0x10, .qword_ptr), isel.code());
    try expectEqualHexStrings("\x41\xFF\x64\x24\x10", isel.lowered(), "jmp qword ptr [r12 + 0x10]");
    try lowerToMEnc(.jmp_near, RegisterOrMemory.mem(.r12, 0x1000, .qword_ptr), isel.code());
    try expectEqualHexStrings(
        "\x41\xFF\xA4\x24\x00\x10\x00\x00",
        isel.lowered(),
        "jmp qword ptr [r12 + 0x1000]",
    );
    try lowerToMEnc(.jmp_near, RegisterOrMemory.rip(0x10, .qword_ptr), isel.code());
    try expectEqualHexStrings("\xFF\x25\x10\x00\x00\x00", isel.lowered(), "jmp qword ptr [rip + 0x10]");
    try lowerToMEnc(.jmp_near, RegisterOrMemory.mem(null, 0x10, .qword_ptr), isel.code());
    try expectEqualHexStrings("\xFF\x24\x25\x10\x00\x00\x00", isel.lowered(), "jmp qword ptr [ds:0x10]");
    try lowerToMEnc(.seta, RegisterOrMemory.reg(.r11b), isel.code());
    try expectEqualHexStrings("\x41\x0F\x97\xC3", isel.lowered(), "seta r11b");
}

test "lower O encoding" {
    var isel = TestIsel.init();
    defer isel.deinit();
    try lowerToOEnc(.pop, .r12, isel.code());
    try expectEqualHexStrings("\x41\x5c", isel.lowered(), "pop r12");
    try lowerToOEnc(.push, .r12w, isel.code());
    try expectEqualHexStrings("\x66\x41\x54", isel.lowered(), "push r12w");
}

test "lower RMI encoding" {
    var isel = TestIsel.init();
    defer isel.deinit();
    try lowerToRmiEnc(.imul, .rax, RegisterOrMemory.mem(.rbp, -8, .qword_ptr), 0x10, isel.code());
    try expectEqualHexStrings(
        "\x48\x69\x45\xF8\x10\x00\x00\x00",
        isel.lowered(),
        "imul rax, qword ptr [rbp - 8], 0x10",
    );
    try lowerToRmiEnc(.imul, .eax, RegisterOrMemory.mem(.rbp, -4, .dword_ptr), 0x10, isel.code());
    try expectEqualHexStrings("\x69\x45\xFC\x10\x00\x00\x00", isel.lowered(), "imul eax, dword ptr [rbp - 4], 0x10");
    try lowerToRmiEnc(.imul, .ax, RegisterOrMemory.mem(.rbp, -2, .word_ptr), 0x10, isel.code());
    try expectEqualHexStrings("\x66\x69\x45\xFE\x10\x00", isel.lowered(), "imul ax, word ptr [rbp - 2], 0x10");
    try lowerToRmiEnc(.imul, .r12, RegisterOrMemory.reg(.r12), 0x10, isel.code());
    try expectEqualHexStrings("\x4D\x69\xE4\x10\x00\x00\x00", isel.lowered(), "imul r12, r12, 0x10");
    try lowerToRmiEnc(.imul, .r12w, RegisterOrMemory.reg(.r12w), 0x10, isel.code());
    try expectEqualHexStrings("\x66\x45\x69\xE4\x10\x00", isel.lowered(), "imul r12w, r12w, 0x10");
}
