# -----------------------------------------------------------------------------
# crpm_test.S - bare-metal Ibex firmware exercising the CRPM end to end.
#
# The flow spans several resets / power-downs; the boot stage is kept in the
# POR-only CRPM SCRATCH0 register:
#   stage 0 (cold boot)   : ID / reset cause / register checks, clock divider
#                           sweep, IDLE (clock-gated) wake by wake-up timer,
#                           then SLEEP (core power-down with retention)
#   stage 1 (SLEEP wake)  : retention + RAM + status checks, then DEEP sleep
#                           (peripheral clock off) - only ext wake pin enabled
#   stage 2 (DEEP wake)   : status checks, watchdog kick test, wrong-key and
#                           correct-key software reset
#   stage 3 (after SW rst): cause = SW, watchdog expiry
#   stage 4 (after WDT)   : cause = WDT, request external reset pin pulse
#   stage 5 (after EXT)   : cause = EXT, IDLE wake by external irq line, PASS
# -----------------------------------------------------------------------------
        .equ CRPM,          0x10000000
        .equ RETR,          0x10010000
        .equ SIM,           0x20000000
        .equ RAMCHK,        0x00008000

        .equ CLK_CTRL,      0x00
        .equ RST_CTRL,      0x04
        .equ RST_CAUSE,     0x08
        .equ PM_CTRL,       0x0C
        .equ PM_STATUS,     0x10
        .equ WAKE_MASK,     0x14
        .equ WDT_CTRL,      0x18
        .equ WDT_LOAD,      0x1C
        .equ WDT_KICK,      0x20
        .equ WDT_COUNT,     0x24
        .equ LP_STATS,      0x28
        .equ ID,            0x2C
        .equ WAKE_PEND,     0x30
        .equ WKT,           0x34
        .equ SCRATCH0,      0x38
        .equ SCRATCH1,      0x3C

        .equ SIM_END,       0x00     # 1 = PASS, other = FAIL code
        .equ SIM_STAGE,     0x04
        .equ SIM_REQ,       0x08     # 1 = ext wake, 2 = ext reset, 3 = ext irq0
        .equ SIM_CHKDIV,    0x0C     # TB checks core clock period
        .equ SIM_LOG,       0x10
        .equ SIM_CHKPDIV,   0x14     # TB checks peripheral clock period

        .equ LP_IDLE,       1
        .equ LP_SLEEP,      2
        .equ LP_DEEP,       3
        .equ WK_TMR,        0x20000
        .equ WK_EXT,        0x10000
        .equ ST_WAKESEEN,   0x0800
        .equ ST_SLEPT,      0x1000
        .equ ST_DEEP,       0x2000
        .equ CRPM_ID,       0x4352504D
        .equ WDT_KEY,       0x5A5A5A5A
        .equ SW_RST_KEY,    0xA5A

        .org 0x80
reset_vector:
        li   s0, CRPM
        li   s1, SIM
        li   s2, RETR
        li   sp, 0x0000FF00
        lw   t0, SCRATCH0(s0)
        beqz t0, stage0
        li   t1, 1
        beq  t0, t1, stage1
        li   t1, 2
        beq  t0, t1, stage2
        li   t1, 3
        beq  t0, t1, stage3
        li   t1, 4
        beq  t0, t1, stage4
        li   t1, 5
        beq  t0, t1, stage5
        li   a0, 0xEE
        j    fail

# =============================================================== stage 0
stage0:
        li   t0, 0
        sw   t0, SIM_STAGE(s1)
        lw   a0, ID(s0)
        li   a1, CRPM_ID
        li   a2, 0x02
        call check
        lw   a0, RST_CAUSE(s0)              # cold boot -> only POR
        li   a1, 0x1
        li   a2, 0x03
        call check
        li   t0, 0xF                        # W1C all causes
        sw   t0, RST_CAUSE(s0)
        lw   a0, RST_CAUSE(s0)
        li   a1, 0
        li   a2, 0x04
        call check
        li   t0, 0x12345678                 # plain RW register
        sw   t0, WDT_LOAD(s0)
        lw   a0, WDT_LOAD(s0)
        li   a1, 0x12345678
        li   a2, 0x05
        call check
        li   t0, 0x5C5C5C5C                 # survives every reset except POR
        sw   t0, SCRATCH1(s0)
        lw   a0, CLK_CTRL(s0)               # reset value
        li   a1, 0x300
        li   a2, 0x06
        call check

        # ---- core clock divider sweep /2 /4 /8 (TB measures the period)
        li   s3, 1
div_loop:
        ori  t0, s3, 0x300
        sw   t0, CLK_CTRL(s0)
        sw   s3, SIM_CHKDIV(s1)
        li   a0, 40
        call delay
        lw   a0, CLK_CTRL(s0)               # [17:16] = ratio actually applied
        srli a0, a0, 16
        andi a0, a0, 3
        mv   a1, s3
        li   a2, 0x07
        call check
        addi s3, s3, 1
        li   t1, 4
        bne  s3, t1, div_loop
        li   t0, 0x300                      # back to /1
        sw   t0, CLK_CTRL(s0)
        li   t0, 0
        sw   t0, SIM_CHKDIV(s1)
        li   a0, 10
        call delay

        # ---- peripheral clock /4
        li   t0, 0x320
        sw   t0, CLK_CTRL(s0)
        li   t0, 2
        sw   t0, SIM_CHKPDIV(s1)
        li   a0, 60
        call delay
        li   t0, 0x300
        sw   t0, CLK_CTRL(s0)
        li   t0, 0
        sw   t0, SIM_CHKPDIV(s1)

        # ---- enable the wake interrupt in the core (mie.MFIE0); mstatus.MIE
        #      stays 0, so WFI resumes without taking a trap
        li   t0, 0x10000
        csrw mie, t0

        # ---- IDLE: core clock gated, woken by the always-on wake-up timer
        li   t0, 1
        sw   t0, SIM_STAGE(s1)
        li   t0, WK_TMR
        sw   t0, WAKE_MASK(s0)
        li   t0, -1
        sw   t0, WAKE_PEND(s0)
        li   t0, LP_IDLE
        sw   t0, PM_CTRL(s0)
        li   t0, 300
        sw   t0, WKT(s0)
        wfi
        lw   a0, WAKE_PEND(s0)
        li   a1, WK_TMR
        li   a2, 0x10
        call check
        li   t0, -1
        sw   t0, WAKE_PEND(s0)
        lw   a0, LP_STATS(s0)               # one IDLE entry, no SLEEP yet
        li   a1, 0x00000001
        li   a2, 0x11
        call check
        lw   a0, PM_CTRL(s0)                # mode is one-shot
        li   a1, 0
        li   a2, 0x12
        call check
        lw   a0, PM_STATUS(s0)
        li   t1, ST_WAKESEEN
        and  a0, a0, t1
        li   a1, ST_WAKESEEN
        li   a2, 0x13
        call check
        lw   a0, PM_STATUS(s0)              # back in RUN, powered, no isolation
        li   t1, 0x30F
        and  a0, a0, t1
        li   a1, 0x100
        li   a2, 0x14
        call check
        li   t0, 0x800
        sw   t0, PM_STATUS(s0)

        # ---- SLEEP: power the core domain down, keep state in retention
        li   t0, 2
        sw   t0, SIM_STAGE(s1)
        li   t0, 0xCAFEF00D
        sw   t0, 0(s2)                      # retention register 0
        li   t0, 0x600DBEEF
        sw   t0, 12(s2)                     # retention register 3
        li   t0, 0xA5A5A5A5
        li   t1, RAMCHK
        sw   t0, 0(t1)                      # always-on SRAM
        li   t0, 1
        sw   t0, SCRATCH0(s0)
        li   t0, -1
        sw   t0, WAKE_PEND(s0)
        li   t0, LP_SLEEP
        sw   t0, PM_CTRL(s0)
        li   t0, 400
        sw   t0, WKT(s0)
        wfi
        li   a0, 0x20                       # must never return here
        j    fail

# =============================================================== stage 1
stage1:
        li   t0, 3
        sw   t0, SIM_STAGE(s1)
        lw   a0, PM_STATUS(s0)
        li   t1, 0x3000
        and  a0, a0, t1
        li   a1, ST_SLEPT
        li   a2, 0x30
        call check
        lw   a0, 0(s2)
        li   a1, 0xCAFEF00D
        li   a2, 0x31
        call check
        lw   a0, 12(s2)
        li   a1, 0x600DBEEF
        li   a2, 0x32
        call check
        li   t1, RAMCHK
        lw   a0, 0(t1)
        li   a1, 0xA5A5A5A5
        li   a2, 0x33
        call check
        lw   a0, WAKE_PEND(s0)
        li   a1, WK_TMR
        li   a2, 0x34
        call check
        lw   a0, RST_CAUSE(s0)              # power-down is not a reset event
        li   a1, 0
        li   a2, 0x35
        call check
        lw   a0, LP_STATS(s0)               # 1 SLEEP, 1 IDLE
        li   a1, 0x00010001
        li   a2, 0x36
        call check
        li   t0, 0x3800
        sw   t0, PM_STATUS(s0)
        li   t0, -1
        sw   t0, WAKE_PEND(s0)
        li   t0, 0x10000
        csrw mie, t0

        # ---- DEEP: core off + peripheral clock off, only the ext pin wakes
        li   t0, WK_EXT
        sw   t0, WAKE_MASK(s0)
        li   t0, 2
        sw   t0, SCRATCH0(s0)
        li   t0, LP_DEEP
        sw   t0, PM_CTRL(s0)
        li   t0, 150                        # masked timer: must NOT wake us
        sw   t0, WKT(s0)
        li   t0, 1
        sw   t0, SIM_REQ(s1)                # TB drives ext_wake later
        wfi
        li   a0, 0x40
        j    fail

# =============================================================== stage 2
stage2:
        li   t0, 4
        sw   t0, SIM_STAGE(s1)
        lw   a0, PM_STATUS(s0)
        li   t1, 0x3000
        and  a0, a0, t1
        li   a1, 0x3000                     # slept + deep
        li   a2, 0x50
        call check
        lw   a0, WAKE_PEND(s0)              # ext pin + (masked) timer latched
        li   a1, 0x30000
        li   a2, 0x51
        call check
        li   t0, 0x3800
        sw   t0, PM_STATUS(s0)
        li   t0, -1
        sw   t0, WAKE_PEND(s0)

        # ---- watchdog kicked in time -> no reset
        li   t0, 400
        sw   t0, WDT_LOAD(s0)
        li   t0, 1
        sw   t0, WDT_CTRL(s0)
        li   s3, 12
kick_loop:
        li   a0, 40
        call delay
        li   t0, WDT_KEY
        sw   t0, WDT_KICK(s0)
        addi s3, s3, -1
        bnez s3, kick_loop
        lw   a0, WDT_COUNT(s0)              # still counting, far from 0
        li   t1, 200
        sltu a0, t1, a0
        li   a1, 1
        li   a2, 0x52
        call check
        li   t0, 0
        sw   t0, WDT_CTRL(s0)

        # ---- software reset: wrong key ignored, right key resets
        li   t0, 3
        sw   t0, SCRATCH0(s0)
        li   t0, 0x123
        sw   t0, RST_CTRL(s0)
        li   a0, 50
        call delay
        lw   a0, SCRATCH0(s0)
        li   a1, 3
        li   a2, 0x53
        call check
        li   t0, SW_RST_KEY
        sw   t0, RST_CTRL(s0)
        li   a0, 200
        call delay
        li   a0, 0x54
        j    fail

# =============================================================== stage 3
stage3:
        li   t0, 5
        sw   t0, SIM_STAGE(s1)
        lw   a0, RST_CAUSE(s0)
        li   a1, 0x4
        li   a2, 0x60
        call check
        li   t0, 0xF
        sw   t0, RST_CAUSE(s0)
        lw   a0, PM_STATUS(s0)              # sys reset clears sticky PM flags
        li   t1, 0x3800
        and  a0, a0, t1
        li   a1, 0
        li   a2, 0x61
        call check
        lw   a0, 0(s2)                      # retention regs reset by sys reset
        li   a1, 0
        li   a2, 0x62
        call check
        lw   a0, WDT_CTRL(s0)               # watchdog disabled after reset
        li   a1, 0
        li   a2, 0x63
        call check
        # ---- watchdog expiry
        li   t0, 4
        sw   t0, SCRATCH0(s0)
        li   t0, 300
        sw   t0, WDT_LOAD(s0)
        li   t0, 1
        sw   t0, WDT_CTRL(s0)
        li   a0, 2000
        call delay
        li   a0, 0x64
        j    fail

# =============================================================== stage 4
stage4:
        li   t0, 6
        sw   t0, SIM_STAGE(s1)
        lw   a0, RST_CAUSE(s0)
        li   a1, 0x8
        li   a2, 0x70
        call check
        li   t0, 0xF
        sw   t0, RST_CAUSE(s0)
        li   t0, 5
        sw   t0, SCRATCH0(s0)
        li   t0, 2
        sw   t0, SIM_REQ(s1)                # TB pulses ext_rst_n
        li   a0, 3000
        call delay
        li   a0, 0x71
        j    fail

# =============================================================== stage 5
stage5:
        li   t0, 7
        sw   t0, SIM_STAGE(s1)
        lw   a0, RST_CAUSE(s0)
        li   a1, 0x2
        li   a2, 0x80
        call check
        li   t0, 0xF
        sw   t0, RST_CAUSE(s0)
        lw   a0, SCRATCH1(s0)               # POR-only register survived all
        li   a1, 0x5C5C5C5C
        li   a2, 0x81
        call check
        # ---- IDLE woken by external interrupt line 0
        li   t0, 0x10000
        csrw mie, t0
        li   t0, 0x1
        sw   t0, WAKE_MASK(s0)
        li   t0, -1
        sw   t0, WAKE_PEND(s0)
        li   t0, LP_IDLE
        sw   t0, PM_CTRL(s0)
        li   t0, 3
        sw   t0, SIM_REQ(s1)                # TB pulses ext_irq[0]
        wfi
        lw   a0, WAKE_PEND(s0)
        li   a1, 0x1
        li   a2, 0x82
        call check
        li   t0, 0
        sw   t0, SCRATCH0(s0)
        li   t0, 1
        sw   t0, SIM_END(s1)                # PASS
pass_hang:
        j    pass_hang

# ============================================================ subroutines
# check: if (a0 != a1) fail with code a2
check:
        beq  a0, a1, check_ok
        sw   a0, SIM_LOG(s1)
        sw   a1, SIM_LOG(s1)
        mv   a0, a2
        j    fail
check_ok:
        ret

# fail: report code a0 (never 1) and spin
fail:
        sw   a0, SIM_END(s1)
fail_hang:
        j    fail_hang

# delay: a0 iterations
delay:
        addi a0, a0, -1
        bnez a0, delay
        ret
