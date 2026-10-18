"""The Ethernet TTLC I/O bridge: frames in and out through the MII pins as
the PHY would carry them (ARP, ping, UDP commands to port 14500), the
chains scanned by the chip's shift_reg_io."""
import struct
import zlib
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer, First

OUR_MAC = bytes.fromhex('024c49534100')
OUR_IP = bytes([192, 168, 1, 200])
PORT = 14500
HOST_MAC = bytes.fromhex('100501446045')
HOST_IP = bytes([192, 168, 1, 133])
HOST_PORT = 40000
OTHER_MAC = bytes.fromhex('0a0b0c0d0e0f')


def csum(b):
    if len(b) % 2:
        b += b'\0'
    s = sum(struct.unpack('!%dH' % (len(b) // 2), b))
    s = (s >> 16) + (s & 0xffff)
    s += s >> 16
    return (~s) & 0xffff


def eth(dst, src, etype, payload):
    return dst + src + struct.pack('!H', etype) + payload


def arp_request(smac, sip, tip):
    return eth(b'\xff' * 6, smac, 0x0806,
               struct.pack('!HHBBH6s4s6s4s', 1, 0x0800, 6, 4, 1, smac, sip, b'\0' * 6, tip))


def ipv4(src, dst, proto, payload, ident=0x1234):
    hdr = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20 + len(payload), ident, 0x4000, 64, proto, 0, src, dst)
    hdr = hdr[:10] + struct.pack('!H', csum(hdr)) + hdr[12:]
    return hdr + payload


def icmp_echo(ident, seq, data):
    h = struct.pack('!BBHHH', 8, 0, 0, ident, seq) + data
    return h[:2] + struct.pack('!H', csum(h)) + h[4:]


def udp(sport, dport, payload):
    return struct.pack('!HHHH', sport, dport, 8 + len(payload), 0) + payload


def ping_frame(data=bytes(range(56)), src_mac=HOST_MAC, src_ip=HOST_IP, dst_mac=OUR_MAC, dst_ip=OUR_IP):
    return eth(dst_mac, src_mac, 0x0800, ipv4(src_ip, dst_ip, 1, icmp_echo(0x4242, 1, data)))


def udp_frame(payload, sport=HOST_PORT, dport=PORT, src_mac=HOST_MAC, src_ip=HOST_IP, dst_mac=OUR_MAC, dst_ip=OUR_IP):
    return eth(dst_mac, src_mac, 0x0800, ipv4(src_ip, dst_ip, 17, udp(sport, dport, payload)))


def with_fcs(frame, corrupt=False):
    frame = frame + b'\0' * max(0, 60 - len(frame))
    crc = zlib.crc32(frame) & 0xffffffff
    if corrupt:
        crc ^= 0x80
    return frame + struct.pack('<I', crc)


class Phy:
    """drives the MII receive pins and collects what the transmit pins carry"""
    def __init__(self, dut):
        self.dut = dut
        self.frames = []
        dut.mii_rx_dv.value = 0
        dut.mii_rx_er.value = 0
        dut.mii_rxd.value = 0
        cocotb.start_soon(self.monitor())

    async def nibble(self, n, dv=1, er=0):
        await FallingEdge(self.dut.mii_rx_clk)
        self.dut.mii_rxd.value = n
        self.dut.mii_rx_dv.value = dv
        self.dut.mii_rx_er.value = er

    async def send(self, frame, corrupt=False, preamble=7):
        data = with_fcs(frame, corrupt)
        for _ in range(preamble):
            await self.nibble(5)
            await self.nibble(5)
        await self.nibble(5)
        await self.nibble(0xd)
        for b in data:
            await self.nibble(b & 0xf)
            await self.nibble(b >> 4)
        await self.nibble(0, dv=0)
        for _ in range(12):           # the gap
            await self.nibble(0, dv=0)

    async def monitor(self):
        nibbles = None
        while True:
            await FallingEdge(self.dut.mii_tx_clk)
            if self.dut.mii_tx_en.value:
                if nibbles is None:
                    nibbles = []
                nibbles.append(int(self.dut.mii_txd.value))
            elif nibbles is not None:
                assert len(nibbles) % 2 == 0, 'an odd number of nibbles'
                data = bytes(nibbles[i] | (nibbles[i + 1] << 4) for i in range(0, len(nibbles), 2))
                assert data[:8] == b'\x55' * 7 + b'\xd5', 'preamble %s' % data[:8].hex()
                data = data[8:]
                assert len(data) >= 64, 'a %d byte frame' % len(data)
                crc, = struct.unpack('<I', data[-4:])
                assert crc == zlib.crc32(data[:-4]) & 0xffffffff, 'bad FCS'
                self.frames.append(data[:-4])
                nibbles = None

    async def expect(self, cycles=20000):
        """the next frame sent, or None"""
        have = len(self.frames)
        for _ in range(cycles // 100):
            if len(self.frames) > have:
                return self.frames[have]
            await ClockCycles(self.dut.clk, 100)
        return None


def parse_status(frame):
    assert frame[:6] == HOST_MAC and frame[6:12] == OUR_MAC and frame[12:14] == b'\x08\x00', frame.hex()
    ip = frame[14:34]
    assert csum(ip) == 0, 'IP checksum'
    assert ip[9] == 17 and ip[12:16] == OUR_IP and ip[16:20] == HOST_IP
    iplen, = struct.unpack('!H', ip[2:4])
    sport, dport, ulen, ucs = struct.unpack('!HHHH', frame[34:42])
    assert sport == PORT and dport == HOST_PORT and ucs == 0
    assert ulen == 8 + 20 and iplen == 28 + 20, (ulen, iplen)
    p = frame[42:62]
    t, flags, us, out, inp, events = struct.unpack('<BBI6s6sH', p)
    return dict(type=chr(t), flags=flags, us=us,
                out=int.from_bytes(out, 'little'), inp=int.from_bytes(inp, 'little'), events=events)


async def scan(dut, outputs):
    """one TTLC I/O scan with the given 48 outputs; returns the 48 inputs read"""
    dut.scan_out.value = outputs
    await RisingEdge(dut.clk)
    dut.scan_start.value = 1
    await RisingEdge(dut.clk)
    dut.scan_start.value = 0
    await ClockCycles(dut.clk, 4)
    while dut.scan_busy.value:
        await ClockCycles(dut.clk, 10)
    await ClockCycles(dut.clk, 4)
    return int(dut.scan_in.value)


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 25, units='ns').start())
    cocotb.start_soon(Clock(dut.mii_rx_clk, 40, units='ns').start())
    cocotb.start_soon(Clock(dut.mii_tx_clk, 40, units='ns').start(start_high=False))
    dut.rst_n.value = 0
    dut.pmod_sel.value = 0
    dut.scan_start.value = 0
    dut.scan_out.value = 0
    phy = Phy(dut)
    await ClockCycles(dut.clk, 20)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 20)
    return phy


@cocotb.test()
async def test_arp(dut):
    """an ARP request for our address is answered, one for another is not"""
    phy = await start(dut)
    await phy.send(arp_request(HOST_MAC, HOST_IP, OUR_IP))
    f = await phy.expect()
    assert f is not None, 'no ARP reply'
    assert f[:6] == HOST_MAC and f[6:12] == OUR_MAC and f[12:14] == b'\x08\x06'
    htype, ptype, hlen, plen, oper, smac, sip, tmac, tip = struct.unpack('!HHBBH6s4s6s4s', f[14:42])
    assert (htype, ptype, hlen, plen, oper) == (1, 0x0800, 6, 4, 2)
    assert smac == OUR_MAC and sip == OUR_IP and tmac == HOST_MAC and tip == HOST_IP
    assert len(f) == 60, 'padded to %d' % len(f)
    await phy.send(arp_request(HOST_MAC, HOST_IP, bytes([192, 168, 1, 201])))
    assert await phy.expect(4000) is None, 'answered an ARP for another address'


@cocotb.test()
async def test_ping(dut):
    """an echo request is echoed with the checksums right; bad frames are ignored"""
    phy = await start(dut)
    data = bytes((i * 7) & 0xff for i in range(200))
    await phy.send(ping_frame(data))
    f = await phy.expect()
    assert f is not None, 'no echo reply'
    assert f[:6] == HOST_MAC and f[6:12] == OUR_MAC and f[12:14] == b'\x08\x00'
    ip = f[14:34]
    assert csum(ip) == 0, 'IP header checksum'
    assert ip[0] == 0x45 and ip[9] == 1 and ip[12:16] == OUR_IP and ip[16:20] == HOST_IP
    iplen, = struct.unpack('!H', ip[2:4])
    assert iplen == 20 + 8 + len(data) and len(f) == 14 + iplen
    icmp = f[34:34 + iplen - 20]
    assert icmp[0] == 0 and icmp[1] == 0 and csum(icmp) == 0, 'ICMP %s' % icmp[:8].hex()
    assert icmp[4:8] == struct.pack('!HH', 0x4242, 1) and icmp[8:] == data
    # not ours: another MAC, another IP, a bad FCS, an RX_ER
    await phy.send(ping_frame(dst_mac=OTHER_MAC))
    await phy.send(ping_frame(dst_ip=bytes([192, 168, 1, 7])))
    await phy.send(ping_frame(), corrupt=True)
    assert await phy.expect(4000) is None, 'answered a frame that was not ours'
    # a short ping: the reply is padded to 60 bytes on the wire
    await phy.send(ping_frame(b'hi'))
    f = await phy.expect()
    assert f is not None and len(f) == 60 and f[42:44] == b'hi' and f[16:18] == struct.pack('!H', 30)
    # two pings back to back: the second finds the frame held and is dropped, the next one is answered
    await phy.send(ping_frame(b'one'))
    await phy.send(ping_frame(b'two'))
    await ClockCycles(dut.clk, 2000)
    await phy.send(ping_frame(b'three'))
    f = await phy.expect()
    assert f is not None and f[42:47] == b'three'


@cocotb.test()
async def test_udp_loopback(dut):
    """I sets the inputs the 165 chains load, R reads the outputs the 595
    chains hold, through the chip's scan; a wrong port is ignored"""
    phy = await start(dut)
    await phy.send(udp_frame(b'R'))
    f = await phy.expect()
    assert f is not None, 'no reply to R'
    st = parse_status(f)
    assert st['type'] == 'S' and st['flags'] >> 4 == 1 and st['out'] == 0 and st['inp'] == 0, st
    for pat in (0x123456789abc, 0x800000000001, 0xffffffffffff, 0xa5a5a5a5a5a5, 0):
        await phy.send(udp_frame(b'I' + pat.to_bytes(6, 'little')))
        f = await phy.expect()
        assert f is not None, 'no reply to I'
        st = parse_status(f)
        assert st['inp'] == pat, 'inputs %012x after I %012x' % (st['inp'], pat)
        got = await scan(dut, pat ^ 0x0f0f0f0f0f0f)
        assert got == pat, 'the scan read %012x for inputs %012x' % (got, pat)
        await phy.send(udp_frame(b'R'))
        st = parse_status(await phy.expect())
        assert st['out'] == pat ^ 0x0f0f0f0f0f0f, 'outputs %012x' % st['out']
    us0 = st['us']
    await ClockCycles(dut.clk, 4000)
    await phy.send(udp_frame(b'R'))
    st = parse_status(await phy.expect())
    assert 95 <= st['us'] - us0 <= 130, 'timestamp advanced %d us over 100' % (st['us'] - us0)
    await phy.send(udp_frame(b'R', dport=PORT + 1))
    await phy.send(udp_frame(b'I' + b'\xff' * 6, dport=PORT + 1))
    assert await phy.expect(4000) is None, 'answered another port'
    assert int(dut.ttlc_in.value) == 0
    # a bare 'I' with too few bytes changes nothing, but is answered
    await phy.send(udp_frame(b'I\x01\x02'))
    st = parse_status(await phy.expect())
    assert st['inp'] == 0


@cocotb.test()
async def test_events(dut):
    """S subscribes to a datagram whenever the outputs change, U ends it"""
    phy = await start(dut)
    await phy.send(udp_frame(b'S'))
    st = parse_status(await phy.expect())
    assert st['flags'] & 1 and st['events'] == 0
    await scan(dut, 0x000000000001)
    f = await phy.expect()
    assert f is not None, 'no event'
    st = parse_status(f)
    assert st['type'] == 'E' and st['out'] == 1 and st['events'] == 1, st
    await scan(dut, 0x000000000001)                 # no change: no event
    assert await phy.expect(4000) is None, 'an event without a change'
    await scan(dut, 0x123456789abc)
    st = parse_status(await phy.expect())
    assert st['type'] == 'E' and st['out'] == 0x123456789abc and st['events'] == 2
    await phy.send(udp_frame(b'U'))
    st = parse_status(await phy.expect())
    assert not st['flags'] & 1 and st['events'] == 2
    await scan(dut, 0)
    assert await phy.expect(4000) is None, 'an event after U'
    await phy.send(udp_frame(b'R'))
    st = parse_status(await phy.expect())
    assert st['out'] == 0 and st['type'] == 'S'


@cocotb.test()
async def test_burst(dut):
    """requests back to back: each is answered or dropped, never garbled,
    and the bridge answers afterwards"""
    phy = await start(dut)
    n0 = len(phy.frames)
    for i in range(4):
        await phy.send(udp_frame(b'I' + (i + 1).to_bytes(6, 'little')), preamble=7)
    await ClockCycles(dut.clk, 3000)
    got = phy.frames[n0:]
    assert len(got) >= 1, 'no reply in a burst'
    for f in got:
        parse_status(f)
    await phy.send(udp_frame(b'R'))
    st = parse_status(await phy.expect())
    assert st['inp'] == 4, 'inputs %x after the burst' % st['inp']
