"""Execute linked ARM code, failing closed on faults or unmodelled hardware.

Unicorn's per-instruction execution hook counts executed architectural
instructions (including IT itself, excluding failed IT predicates). Its count
is not a hardware cycle count. No guest function is replaced with host code.
"""
from collections import Counter, deque
from dataclasses import dataclass
import pathlib
import struct

from elftools.elf.elffile import ELFFile
from unicorn import (Uc, UcError, UC_ARCH_ARM, UC_MODE_THUMB, UC_MODE_MCLASS,
                     UC_HOOK_CODE, UC_HOOK_MEM_INVALID, UC_PROT_READ, UC_PROT_EXEC)
from unicorn.arm_const import (
    UC_CPU_ARM_CORTEX_M33, UC_ARM_REG_SP, UC_ARM_REG_LR, UC_ARM_REG_PC,
    UC_ARM_REG_PRIMASK, UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
)


class ExecutionError(RuntimeError):
    pass


@dataclass
class Image:
    path: pathlib.Path
    symbols: dict
    segments: list

    @classmethod
    def load(cls, path):
        path = pathlib.Path(path)
        with path.open("rb") as file:
            elf = ELFFile(file)
            if elf.elfclass != 32 or not elf.little_endian or elf["e_machine"] != "EM_ARM":
                raise ValueError("Expected a little-endian ARM ELF32 image")
            symbols = {item.name: int(item["st_value"])
                       for item in elf.get_section_by_name(".symtab").iter_symbols()}
            segments = [(int(segment["p_vaddr"]), segment.data(), int(segment["p_memsz"]))
                        for segment in elf.iter_segments() if segment["p_type"] == "PT_LOAD"]
        return cls(path, symbols, segments)


class Machine:
    FLASH = (0x10000000, 0x400000)
    SRAM = (0x20000000, 0x82000)
    RETURN = 0x103fff00
    MAX_INSTRUCTIONS = 2_000_000
    STORAGE_CAPACITY = 128

    def __init__(self, image):
        self.image = image
        self.cpu = Uc(UC_ARCH_ARM, UC_MODE_THUMB | UC_MODE_MCLASS)
        self.cpu.ctl_set_cpu_model(UC_CPU_ARM_CORTEX_M33)
        for base, size in (self.FLASH, self.SRAM):
            self.cpu.mem_map(base, size)
        for address, data, memory_size in image.segments:
            if not any(base <= address and address + memory_size <= base + size
                       for base, size in (self.FLASH, self.SRAM)):
                raise ValueError(f"ELF segment outside the declared RP2350 memory map: {address:#x}")
            if data:
                self.cpu.mem_write(address, data)
        self.cpu.mem_protect(*self.FLASH, UC_PROT_READ | UC_PROT_EXEC)
        self.stack_top = image.symbols.get("__StackTop", self.SRAM[0] + self.SRAM[1])
        self.storage = self.stack_top - 256
        self.stack = self.stack_top - 512
        self.cpu.mmio_map(0xd0000000, 0x1000, self._read_sio, None, self._write_sio, None)
        self.cpu.reg_write(UC_ARM_REG_PRIMASK, 1)
        self.cpu.hook_add(UC_HOOK_CODE, self._instruction)
        self.cpu.hook_add(UC_HOOK_MEM_INVALID, self._invalid_memory)
        self.sio_reads = Counter()
        self.bootstrap = {}
        self.forbidden = {value & ~1: name for name, value in image.symbols.items()
                          if value and name in {"raise", "abort", "_exit", "exit", "panic", "_kill",
                                                "__assert_func", "hard_assertion_failure"}}
        self.count = 0
        self.tail = deque(maxlen=12)
        self.error = None
        self.track_path = False
        self.construct_return = None
        self.data_count = None
        self.sdk_count = None
        self.descriptor = None

    def _fail(self, message):
        self.error = message
        self.cpu.emu_stop()

    def _read_sio(self, cpu, offset, size, _):
        if offset >= 0 and offset + size <= 4:
            self.sio_reads[(offset, size)] += 1
            return 0  # SIO_CPUID: the one executing core is core 0.
        self._fail(f"Unmodelled SIO read at offset {offset:#x}, size {size}")
        return 0

    def _write_sio(self, cpu, offset, size, value, _):
        self._fail(f"Unmodelled SIO write at offset {offset:#x}, size {size}, value {value:#x}")

    def _invalid_memory(self, cpu, access, address, size, value, _):
        self._fail(f"Invalid memory access {access} at {address:#x}, size {size}")
        return False

    def _instruction(self, cpu, address, size, _):
        # A hook fires before execution; a fault invalidates the entire sample.
        if address in self.forbidden:
            self._fail(f"Guest error function reached: {self.forbidden[address]}")
            return
        if self.track_path:
            symbols = self.image.symbols
            if address == symbols["benchmark_construct"] & ~1:
                if self.construct_return is not None:
                    self._fail("Nested or repeated construction in one sample")
                    return
                self.construct_return = cpu.reg_read(UC_ARM_REG_LR) & ~1
            if address == self.construct_return and self.data_count is None:
                self.data_count = self.count
            if address == symbols["benchmark_ready"] & ~1:
                if self.data_count is None or self.sdk_count is not None:
                    self._fail("SDK-ready checkpoint out of order")
                    return
                self.sdk_count = self.count
                pointer = cpu.reg_read(UC_ARM_REG_R0)
                words, count, origin, version, gpio = struct.unpack("<IBbBB", bytes(cpu.mem_read(pointer, 8)))
                if not 1 <= count <= 32:
                    self._fail(f"Invalid SDK descriptor instruction count: {count}")
                    return
                self.descriptor = {"words": list(struct.unpack("<" + "H" * count, bytes(cpu.mem_read(words, count * 2)))),
                                   "count": count, "origin": origin, "version": version, "gpio": gpio}
        self.count += 1
        self.tail.append(address)

    def call(self, name, *arguments, track_path=False, max_instructions=None):
        if len(arguments) > 4:
            raise ValueError("This harness only calls functions with up to four register arguments")
        self.count = 0
        self.tail.clear()
        self.error = None
        self.track_path = track_path
        self.construct_return = self.data_count = self.sdk_count = self.descriptor = None
        self.cpu.reg_write(UC_ARM_REG_SP, self.stack)
        self.cpu.reg_write(UC_ARM_REG_LR, self.RETURN | 1)
        # Begin every independent call with interrupts masked; lock code may
        # save/restore PRIMASK but no interrupt source is scheduled by the model.
        self.cpu.reg_write(UC_ARM_REG_PRIMASK, 1)
        for register, value in zip((UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3), arguments):
            self.cpu.reg_write(register, value & 0xffffffff)
        try:
            self.cpu.emu_start(self.image.symbols[name] | 1, self.RETURN,
                               count=max_instructions or self.MAX_INSTRUCTIONS)
        except UcError as error:
            self.error = self.error or str(error)
        pc = self.cpu.reg_read(UC_ARM_REG_PC)
        if self.error or pc != self.RETURN:
            raise ExecutionError(f"{name}: {self.error or 'instruction budget exhausted'}; PC={pc:#x}; "
                                 f"recent PCs={[hex(item) for item in self.tail]}")
        if self.cpu.reg_read(UC_ARM_REG_SP) != self.stack:
            raise ExecutionError(f"{name}: stack pointer did not balance")
        if track_path and (self.sdk_count is None or self.data_count is None):
            raise ExecutionError(f"{name}: returned without reaching both readiness checkpoints")
        return {"instructions": self.count, "r0": self.cpu.reg_read(UC_ARM_REG_R0),
                "r1": self.cpu.reg_read(UC_ARM_REG_R1), "r2": self.cpu.reg_read(UC_ARM_REG_R2),
                "to_data": self.data_count, "to_sdk": self.sdk_count, "descriptor": self.descriptor}

    def initialize(self):
        # This is neither reset-to-ready nor board boot timing. Initialize only
        # the SDK's real RAM-based spinlock/mutex state before the measured path.
        for name in ("runtime_init_spin_locks_reset", "runtime_init_mutex"):
            if name not in self.image.symbols:
                raise ExecutionError(f"Missing required SDK bootstrap symbol: {name}")
            self.bootstrap[name] = self.call(name)["instructions"]
        size = self.call("benchmark_storage_size")["r0"]
        if not 0 < size <= self.STORAGE_CAPACITY:
            raise ExecutionError(f"Unexpected program storage size: {size}")
        self.cpu.mem_write(self.storage, bytes([0xa5]) * self.STORAGE_CAPACITY)
        return size


def calibrate(path):
    image = Image.load(path)
    results = {}
    expected = {"plain": (3, {"r0": 8}), "loop": (18, {"r0": 5}),
                "calls": (5, {"r0": 1}), "cond_true": (5, {"r1": 9}),
                "cond_false": (5, {"r1": 12}), "memory": (5, {"r1": 42, "r2": 0x1234})}
    for name, (count, registers) in expected.items():
        result = Machine(image).call("calibration_" + name)
        if result["instructions"] != count or any(result[key] != value for key, value in registers.items()):
            raise ExecutionError(f"Instruction-counter calibration failed: {name}: {result}")
        results[name] = {"expected": count, "observed": result["instructions"], **registers}
    for name in ("fault", "unknown_mmio", "guest_error"):
        try:
            Machine(image).call("calibration_" + name)
        except ExecutionError:
            results[name] = {"rejected": True}
        else:
            raise ExecutionError(f"Fault calibration was incorrectly accepted: {name}")
    return results
