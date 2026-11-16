/*
================================================================================
ttlc_plc.asm:  TTLC (MC14500B) ladder program for the PLC block (RESPIN 40):
               every scan the chains' inputs drive a TON timer, a TOF timer
               and an up counter in the I/O space (139-146 the timers' IN /
               Q, 147-154 the counters' CU / Q, counter n's reset storage bit
               120 + n at 248 + n), the blocks' Q bits go to the outputs, and
               two inputs pass through the new storage bits 64 and 127.

                 input 0 (48) -> T0 IN (139);  T0 Q (139) -> output 0
                 input 1 (49) -> T1 IN (140);  T1 Q (140) -> output 1  (TOF)
                 input 2 (50) -> C0 CU (147);  C0 Q (147) -> output 2
                 input 3 (51) -> storage 120 (248) = C0's reset
                 input 4 (52) -> storage 64 (192) -> output 3
                 input 5 (53) -> storage 127 (255) -> output 4
                 HSC0 GE (155) -> output 5, HSC1 GE (156) -> output 6

asmsyntax=mc14500b
================================================================================
*/
loop:
    nopo                // run one shift-register scan (outputs out, inputs in)
    ld      48          // input 0
    sto     139         // -> T0 IN
    ld      139         // T0 Q
    sto     0           // -> output 0
    ld      49          // input 1
    sto     140         // -> T1 IN
    ld      140         // T1 Q
    sto     1           // -> output 1
    ld      50          // input 2
    sto     147         // -> C0 CU
    ld      147         // C0 Q
    sto     2           // -> output 2
    ld      51          // input 3
    sto     248         // -> storage 120: C0's reset
    ld      52          // input 4
    sto     192         // -> storage 64
    ld      192
    sto     3           // -> output 3
    ld      53          // input 5
    sto     255         // -> storage 127
    ld      255
    sto     4           // -> output 4
    ld      155         // HSC0 count >= compare
    sto     5           // -> output 5
    ld      156         // HSC1 count >= compare
    sto     6           // -> output 6
    nopf                // back to address 0

// vim: sw=4 ts=4 et
