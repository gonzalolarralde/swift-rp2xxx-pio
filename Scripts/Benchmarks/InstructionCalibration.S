.syntax unified
.cpu cortex-m33
.thumb
.text

.global calibration_plain
.thumb_func
calibration_plain:
    movs r0, #7
    adds r0, #1
    bx lr

.global calibration_loop
.thumb_func
calibration_loop:
    movs r0, #0
    movs r1, #5
1:
    adds r0, #1
    subs r1, #1
    bne 1b
    bx lr

.global calibration_calls
.thumb_func
calibration_calls:
    push {lr}
    bl calibration_helper
    pop {pc}
.thumb_func
calibration_helper:
    adds r0, #1
    bx lr

// A failing IT predicate does not execute that instruction. Both paths have
// five executed instructions: MOV, CMP, ITE, the selected MOV, and BX.
.global calibration_cond_true
.thumb_func
calibration_cond_true:
    movs r0, #0
    cmp r0, #0
    ite eq
    moveq r1, #9
    movne r1, #12
    bx lr
.global calibration_cond_false
.thumb_func
calibration_cond_false:
    movs r0, #1
    cmp r0, #0
    ite eq
    moveq r1, #9
    movne r1, #12
    bx lr

// Stores, loads and a 32-bit Thumb instruction each count once, not by bytes.
.global calibration_memory
.thumb_func
calibration_memory:
    movs r0, #42
    push {r0}
    pop {r1}
    movw r2, #0x1234
    bx lr

.global calibration_fault
.thumb_func
calibration_fault:
    udf #0
    bx lr

.global calibration_unknown_mmio
.thumb_func
calibration_unknown_mmio:
    movw r0, #4
    movt r0, #0xd000
    ldr r1, [r0]
    bx lr

// Even a bare-metal error stub that returns must not become a valid sample.
.global calibration_guest_error
.thumb_func
calibration_guest_error:
    push {lr}
    bl raise
    pop {pc}
.global raise
.thumb_func
raise:
    movs r0, #0
    bx lr
