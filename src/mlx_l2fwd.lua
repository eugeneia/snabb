module(...,package.seeall)

local ethernet = require("lib.protocol.ethernet")
local connectx = require("apps.mellanox.connectx")
local pcap = require("apps.pcap.pcap")
local worker = require("core.worker")
local lib = require("core.lib")

local Macswap = {zone="Macswap"}

function Macswap:new(conf)
    local self = setmetatable({}, {__index=Macswap})
    self.eth = ethernet:new{}
    self.src = ethernet:pton(conf.mac)
    -- self.throttle = lib.throttle(1)
    return self
end

function Macswap:push()
    local input, output = self.input.input, self.output.output
    local pcap = self.output.pcap
    -- local fwd = self.throttle()
    while not link.empty(input) do
        local p = link.receive(input)
        -- if pcap then
        --     link.transmit(pcap, packet.clone(p))
        -- end

        -- if not fwd then
        --     packet.free(p)
        -- else
            local eth = self.eth:new_from_mem(p.data, p.length)
            if eth then
                eth:dst(eth:src())
                eth:src(self.src)
                link.transmit(output, p)
            else
                packet.free(p)
            end
        -- end
    end
end

function l2fwd (pciaddress, macaddress, nworkers, nqueues, worker)
    local function queue(w,q) return ("w%dq%d"):format(w, q) end
    local c = config:new()
    if worker == 1 then
        local queues = {}
        for w=1,nworkers do
            for q=1,nqueues do
                queues[#queues+1] = {id=queue(w, q)}
            end
        end
        config.app(c, "Control", connectx.ConnectX,
            { pciaddress = pciaddress,
              sendq_size = 2048,
              recvq_size = 2048,
              queues = queues })
    end
    for q=1,nqueues do
        local id = queue(worker, q)
        config.app(c, id, connectx.IO, { pciaddress = pciaddress, queue = id})
        config.app(c, id.."_l2fwd", Macswap, {mac=macaddress})
        config.link(c, id..".output -> "..id.."_l2fwd.input")
        config.link(c, id.."_l2fwd.output -> "..id..".input")
        -- config.app(c, "pcap", pcap.PcapWriter, "out.pcap")
        -- config.link(c, id.."_l2fwd.pcap -> pcap.input")
    end
    engine.configure(c)
    while true do
        engine.report_links()
        engine.main({duration=5})
    end
end

function l2fwd_multi(pciaddress, macaddress, nworkers, nqueues)
    for w=1,nworkers do
        worker.start("w"..w, ([[require("mlx_l2fwd").l2fwd(%q, %q, %d, %d, %d)]])
            :format(pciaddress, macaddress, nworkers, nqueues, w))
    end
    while true do engine.main({duration=5}) end
end
