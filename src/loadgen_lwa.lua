-- Use of this source code is governed by the Apache 2.0 license; see COPYING.
module(..., package.seeall)

local ffi = require("ffi")
local lib = require("core.lib")
local basic = require("apps.basic.basic_apps")
local connectx = require("apps.mellanox.connectx")
local ethernet = require("lib.protocol.ethernet")
local ipv4 = require("lib.protocol.ipv4")
local ipv6 = require("lib.protocol.ipv6")
local udp = require("lib.protocol.udp")

local mac_src = ethernet:pton("00:00:cc:aa:ff:ee")
local mac_ext = ethernet:pton("02:00:00:00:00:01")
local mac_int = ethernet:pton("02:00:00:00:00:02")

local br_addr = ipv6:pton("2003:1b0b:fff9:ffff::4001")

local function int_src (n)
    local a = ipv6:pton("2003:1c09:ffe0:100::1")
    ffi.cast("uint16_t *", a+14)[0] = n
    return a
end

local function int_dst (n)
    local a = ipv4:pton("198.18.0.1")
    ffi.cast("uint16_t *", a+2)[0] = n
    return a
end

local function ext_dst ()
    local a = ipv4:pton("10.99.0.1")
    ffi.cast("uint16_t *", a+2)[0] = between(1, 65535)
    return a
end

function gen_internal_pkt (size)
    assert(size >= ethernet:sizeof() + ipv6:sizeof() + ipv4:sizeof() + udp:sizeof())
    local p = packet.allocate()
    local function append (hdr)
        hdr:copy(p.data+p.length)
        p.length = p.length+hdr:sizeof()
    end
    local eth = ethernet:new{
        src = mac_src,
        dst = mac_int,
        type = 0x86dd
    }
    append(eth)
    local n = between(1, 65535)
    local v6 = ipv6:new{
        src = int_src(n),
        dst = br_addr,
        next_header = 4
    }
    v6:payload_length(size-p.length-v6:sizeof())
    append(v6)
    local v4 = ipv4:new{
        src = int_dst(n),
        dst = ext_dst(),
        ttl = 64,
        protocol = 17
    }
    v4:total_length(size-p.length)
    v4:checksum()
    append(v4)
    local udp = udp:new{
        src_port = between(4000, 16000),
        dst_port = between(4000, 16000)
    }
    udp:length(size-p.length)
    append(udp)
    ffi.copy(p.data+p.length, lib.random_bytes(size-p.length), size-p.length)
    p.length = size
    return p
end

function gen_external_pkt (size)
    assert(size >= ethernet:sizeof() + ipv4:sizeof() + udp:sizeof())
    local p = packet.allocate()
    local function append (hdr)
        hdr:copy(p.data+p.length)
        p.length = p.length+hdr:sizeof()
    end
    local eth = ethernet:new{
        src = mac_src,
        dst = mac_ext,
        type = 0x0800
    }
    append(eth)
    local v4 = ipv4:new{
        src = ext_dst(),
        dst = int_dst(between(1, 65535)),
        ttl = 64,
        protocol = 17
    }
    v4:total_length(size-p.length)
    v4:checksum()
    append(v4)
    local udp = udp:new{
        src_port = between(4000, 16000),
        dst_port = between(4000, 16000)
    }
    udp:length(size-p.length)
    append(udp)
    ffi.copy(p.data+p.length, lib.random_bytes(size-p.length), size-p.length)
    p.length = size
    return p
end

-- Return a random number between min and max (inclusive.)
function between (min, max)
    if min == max then
       return min
    else
       return min + math.random(max-min+1) - 1
    end
 end

Gen = {
    config = {
       size = {default=300},
       npackets = {default=1000}
    }
 }
 
function Gen:new (conf)
    local packets = {}
    while #packets < conf.npackets do
        packets[#packets+1] = gen_internal_pkt(conf.size)
        packets[#packets+1] = gen_external_pkt(conf.size)
    end
    return setmetatable({cur=0, packets=packets}, {__index=Gen})
 end
 
function Gen:pull ()
    local output = assert(self.output.output)
    while not link.full(output) do
        link.transmit(output, packet.clone(self.packets[self.cur+1]))
        self.cur = (self.cur+1) % #self.packets
    end
end

function loadgen (pci, queue, size)
    local c = config.new()
    config.app(c, "source", Gen, {size=size})
    config.app(c, "sink", basic.Sink)
    config.app(c, "nic", connectx.IO, {pciaddress=pci, queue=queue})
    config.link(c, "source.output -> nic.input")
    config.link(c, "nic.output -> sink.input")

    engine.configure(c)
    engine.main{no_report=true}
end
