/*
================================================================================
ttlc_loopback.asm:  TTLC (MC14500B) I/O test - every scan copies the 48 inputs
                    to the 48 outputs.  Inputs are 48..95, outputs 0..47.

asmsyntax=mc14500b
================================================================================
*/

loop:
    nopo                // run one shift-register scan (outputs out, inputs in)
    ld      48          // input 0
    sto     0           // -> output 0
    ld      49          // input 1
    sto     1           // -> output 1
    ld      50          // input 2
    sto     2           // -> output 2
    ld      51          // input 3
    sto     3           // -> output 3
    ld      52          // input 4
    sto     4           // -> output 4
    ld      53          // input 5
    sto     5           // -> output 5
    ld      54          // input 6
    sto     6           // -> output 6
    ld      55          // input 7
    sto     7           // -> output 7
    ld      56          // input 8
    sto     8           // -> output 8
    ld      57          // input 9
    sto     9           // -> output 9
    ld      58          // input 10
    sto     10          // -> output 10
    ld      59          // input 11
    sto     11          // -> output 11
    ld      60          // input 12
    sto     12          // -> output 12
    ld      61          // input 13
    sto     13          // -> output 13
    ld      62          // input 14
    sto     14          // -> output 14
    ld      63          // input 15
    sto     15          // -> output 15
    ld      64          // input 16
    sto     16          // -> output 16
    ld      65          // input 17
    sto     17          // -> output 17
    ld      66          // input 18
    sto     18          // -> output 18
    ld      67          // input 19
    sto     19          // -> output 19
    ld      68          // input 20
    sto     20          // -> output 20
    ld      69          // input 21
    sto     21          // -> output 21
    ld      70          // input 22
    sto     22          // -> output 22
    ld      71          // input 23
    sto     23          // -> output 23
    ld      72          // input 24
    sto     24          // -> output 24
    ld      73          // input 25
    sto     25          // -> output 25
    ld      74          // input 26
    sto     26          // -> output 26
    ld      75          // input 27
    sto     27          // -> output 27
    ld      76          // input 28
    sto     28          // -> output 28
    ld      77          // input 29
    sto     29          // -> output 29
    ld      78          // input 30
    sto     30          // -> output 30
    ld      79          // input 31
    sto     31          // -> output 31
    ld      80          // input 32
    sto     32          // -> output 32
    ld      81          // input 33
    sto     33          // -> output 33
    ld      82          // input 34
    sto     34          // -> output 34
    ld      83          // input 35
    sto     35          // -> output 35
    ld      84          // input 36
    sto     36          // -> output 36
    ld      85          // input 37
    sto     37          // -> output 37
    ld      86          // input 38
    sto     38          // -> output 38
    ld      87          // input 39
    sto     39          // -> output 39
    ld      88          // input 40
    sto     40          // -> output 40
    ld      89          // input 41
    sto     41          // -> output 41
    ld      90          // input 42
    sto     42          // -> output 42
    ld      91          // input 43
    sto     43          // -> output 43
    ld      92          // input 44
    sto     44          // -> output 44
    ld      93          // input 45
    sto     45          // -> output 45
    ld      94          // input 46
    sto     46          // -> output 46
    ld      95          // input 47
    sto     47          // -> output 47
    nopf                // back to address 0

// vim: sw=4 ts=4 et
