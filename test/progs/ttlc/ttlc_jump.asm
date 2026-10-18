/*
================================================================================
ttlc_jump.asm:  the TTLC's jmp / rtn / skz / nopf in the slot format - the
                loopback (outputs follow the 48 inputs) done through two
                subroutines, so that a wrong jump or return breaks the copy.
                Every scan: jmp copies inputs 0..23, then 24..47, then skz
                over a jmp that would clear output 47 (input 47 set skips
                the clear: RR = input 47), and nopf restarts.

asmsyntax=mc14500b
================================================================================
*/
loop:
    nopo                // run one shift-register scan (outputs out, inputs in)
    jmp     copy_lo     // inputs 0..23 -> outputs 0..23
    jmp     copy_hi     // inputs 24..46 -> outputs 24..46
    ldc     137         // RR = 1 (the constant-0 bit, inverted) ...
    sto     47          // ... output 47 = 1
    ld      95          // input 47
    skz                 // clear: skip the jmp (its two slots)
    jmp     done        // set: keep output 47
    ld      137         // RR = 0 ...
    sto     47          // ... output 47 = 0
    // done is on group 8 (0x008): a skz that advanced one slot instead of
    // two would execute the jmp's target slot as `sto 0`, with RR = 0, and
    // clear output 0 (input 0 is set in some patterns)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
done:
    nopf                // back to loop

copy_lo:
    ld      48
    sto     0
    ld      49
    sto     1
    ld      50
    sto     2
    ld      51
    sto     3
    ld      52
    sto     4
    ld      53
    sto     5
    ld      54
    sto     6
    ld      55
    sto     7
    ld      56
    sto     8
    ld      57
    sto     9
    ld      58
    sto     10
    ld      59
    sto     11
    ld      60
    sto     12
    ld      61
    sto     13
    ld      62
    sto     14
    ld      63
    sto     15
    ld      64
    sto     16
    ld      65
    sto     17
    ld      66
    sto     18
    ld      67
    sto     19
    ld      68
    sto     20
    ld      69
    sto     21
    ld      70
    sto     22
    ld      71
    sto     23
    rtn

copy_hi:
    ld      72
    sto     24
    ld      73
    sto     25
    ld      74
    sto     26
    ld      75
    sto     27
    ld      76
    sto     28
    ld      77
    sto     29
    ld      78
    sto     30
    ld      79
    sto     31
    ld      80
    sto     32
    ld      81
    sto     33
    ld      82
    sto     34
    ld      83
    sto     35
    ld      84
    sto     36
    ld      85
    sto     37
    ld      86
    sto     38
    ld      87
    sto     39
    ld      88
    sto     40
    ld      89
    sto     41
    ld      90
    sto     42
    ld      91
    sto     43
    ld      92
    sto     44
    ld      93
    sto     45
    ld      94
    sto     46
    rtn
