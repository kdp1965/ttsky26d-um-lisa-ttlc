/*
================================================================================
ttlc_storage.asm:  TTLC (MC14500B) storage test (RESPIN 31, the 64-bit storage) -
                   the loopback through the internal storage: inputs 0..31
                   (48..79) to storage bits 32..63 (160..191), inputs 32..47
                   (80..95) to storage bits 0..15 (96..111), and the storage
                   to outputs 0..47, so the outputs follow the inputs only if
                   the ICU writes and reads both storage ranges.

asmsyntax=mc14500b
================================================================================
*/

loop:
    nopo                // run one shift-register scan (outputs out, inputs in)
    ld      48          // input 0
    sto     160         // -> storage 32
    ld      49          // input 1
    sto     161         // -> storage 33
    ld      50          // input 2
    sto     162         // -> storage 34
    ld      51          // input 3
    sto     163         // -> storage 35
    ld      52          // input 4
    sto     164         // -> storage 36
    ld      53          // input 5
    sto     165         // -> storage 37
    ld      54          // input 6
    sto     166         // -> storage 38
    ld      55          // input 7
    sto     167         // -> storage 39
    ld      56          // input 8
    sto     168         // -> storage 40
    ld      57          // input 9
    sto     169         // -> storage 41
    ld      58          // input 10
    sto     170         // -> storage 42
    ld      59          // input 11
    sto     171         // -> storage 43
    ld      60          // input 12
    sto     172         // -> storage 44
    ld      61          // input 13
    sto     173         // -> storage 45
    ld      62          // input 14
    sto     174         // -> storage 46
    ld      63          // input 15
    sto     175         // -> storage 47
    ld      64          // input 16
    sto     176         // -> storage 48
    ld      65          // input 17
    sto     177         // -> storage 49
    ld      66          // input 18
    sto     178         // -> storage 50
    ld      67          // input 19
    sto     179         // -> storage 51
    ld      68          // input 20
    sto     180         // -> storage 52
    ld      69          // input 21
    sto     181         // -> storage 53
    ld      70          // input 22
    sto     182         // -> storage 54
    ld      71          // input 23
    sto     183         // -> storage 55
    ld      72          // input 24
    sto     184         // -> storage 56
    ld      73          // input 25
    sto     185         // -> storage 57
    ld      74          // input 26
    sto     186         // -> storage 58
    ld      75          // input 27
    sto     187         // -> storage 59
    ld      76          // input 28
    sto     188         // -> storage 60
    ld      77          // input 29
    sto     189         // -> storage 61
    ld      78          // input 30
    sto     190         // -> storage 62
    ld      79          // input 31
    sto     191         // -> storage 63
    ld      80          // input 32
    sto     96          // -> storage 0
    ld      81          // input 33
    sto     97          // -> storage 1
    ld      82          // input 34
    sto     98          // -> storage 2
    ld      83          // input 35
    sto     99          // -> storage 3
    ld      84          // input 36
    sto     100         // -> storage 4
    ld      85          // input 37
    sto     101         // -> storage 5
    ld      86          // input 38
    sto     102         // -> storage 6
    ld      87          // input 39
    sto     103         // -> storage 7
    ld      88          // input 40
    sto     104         // -> storage 8
    ld      89          // input 41
    sto     105         // -> storage 9
    ld      90          // input 42
    sto     106         // -> storage 10
    ld      91          // input 43
    sto     107         // -> storage 11
    ld      92          // input 44
    sto     108         // -> storage 12
    ld      93          // input 45
    sto     109         // -> storage 13
    ld      94          // input 46
    sto     110         // -> storage 14
    ld      95          // input 47
    sto     111         // -> storage 15
    ld      160         // storage 32
    sto     0           // -> output 0
    ld      161         // storage 33
    sto     1           // -> output 1
    ld      162         // storage 34
    sto     2           // -> output 2
    ld      163         // storage 35
    sto     3           // -> output 3
    ld      164         // storage 36
    sto     4           // -> output 4
    ld      165         // storage 37
    sto     5           // -> output 5
    ld      166         // storage 38
    sto     6           // -> output 6
    ld      167         // storage 39
    sto     7           // -> output 7
    ld      168         // storage 40
    sto     8           // -> output 8
    ld      169         // storage 41
    sto     9           // -> output 9
    ld      170         // storage 42
    sto     10          // -> output 10
    ld      171         // storage 43
    sto     11          // -> output 11
    ld      172         // storage 44
    sto     12          // -> output 12
    ld      173         // storage 45
    sto     13          // -> output 13
    ld      174         // storage 46
    sto     14          // -> output 14
    ld      175         // storage 47
    sto     15          // -> output 15
    ld      176         // storage 48
    sto     16          // -> output 16
    ld      177         // storage 49
    sto     17          // -> output 17
    ld      178         // storage 50
    sto     18          // -> output 18
    ld      179         // storage 51
    sto     19          // -> output 19
    ld      180         // storage 52
    sto     20          // -> output 20
    ld      181         // storage 53
    sto     21          // -> output 21
    ld      182         // storage 54
    sto     22          // -> output 22
    ld      183         // storage 55
    sto     23          // -> output 23
    ld      184         // storage 56
    sto     24          // -> output 24
    ld      185         // storage 57
    sto     25          // -> output 25
    ld      186         // storage 58
    sto     26          // -> output 26
    ld      187         // storage 59
    sto     27          // -> output 27
    ld      188         // storage 60
    sto     28          // -> output 28
    ld      189         // storage 61
    sto     29          // -> output 29
    ld      190         // storage 62
    sto     30          // -> output 30
    ld      191         // storage 63
    sto     31          // -> output 31
    ld      96          // storage 0
    sto     32          // -> output 32
    ld      97          // storage 1
    sto     33          // -> output 33
    ld      98          // storage 2
    sto     34          // -> output 34
    ld      99          // storage 3
    sto     35          // -> output 35
    ld      100         // storage 4
    sto     36          // -> output 36
    ld      101         // storage 5
    sto     37          // -> output 37
    ld      102         // storage 6
    sto     38          // -> output 38
    ld      103         // storage 7
    sto     39          // -> output 39
    ld      104         // storage 8
    sto     40          // -> output 40
    ld      105         // storage 9
    sto     41          // -> output 41
    ld      106         // storage 10
    sto     42          // -> output 42
    ld      107         // storage 11
    sto     43          // -> output 43
    ld      108         // storage 12
    sto     44          // -> output 44
    ld      109         // storage 13
    sto     45          // -> output 45
    ld      110         // storage 14
    sto     46          // -> output 46
    ld      111         // storage 15
    sto     47          // -> output 47
    nopf                // back to address 0

// vim: sw=4 ts=4 et
