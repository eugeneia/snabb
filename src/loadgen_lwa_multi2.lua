-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

local lib = require("core.lib")
local counter = require("core.counter")
local worker = require("core.worker")
local connectx = require("apps.mellanox.connectx")

local pci = "0000:85:00.0"
local size = 300
local nworkers = 2

local queues = {}
for i=1, nworkers do
    queues[#queues+1] = {id="w"..i}
end

local c = config.new()
config.app(c, "nic", connectx.ConnectX, {pciaddress=pci, queues=queues})
engine.configure(c)

for _, queue in ipairs(queues) do
    worker.start(queue.id, ([[require("loadgen_lwa").loadgen(%q, %q, %d, 'fwd')]])
        :format(pci, queue.id, size))
end

local counters = {}
local function load_counters ()
    for w, s in pairs(worker.status()) do
        assert(s.alive)
        counters[w] = counters[w] or {
            txpackets = ("/%d/links/fwd.output -> nic.input/rxpackets.counter"):format(s.pid),
            txbytes = ("/%d/links/fwd.output -> nic.input/rxbytes.counter"):format(s.pid),
            rxpackets = ("/%d/links/nic.output -> fwd.input/txpackets.counter"):format(s.pid),
            rxbytes = ("/%d/links/nic.output -> fwd.input/txbytes.counter"):format(s.pid)
        }
        for name in pairs(counters[w]) do
            if type(counters[w][name]) == 'string' then
                local ok, ctr = pcall(counter.open, counters[w][name])
                if ok then
                    print("opened", counters[w][name])
                    counters[w][name] = ctr
                else
                    print("failed to open", counters[w][name])
                    return false
                end
            end
        end
    end
    return true
end

local stat0
while true do
    local txpackets, txbytes = 0ULL, 0ULL
    local rxpackets, rxbytes = 0ULL, 0ULL
    if load_counters() then
        print("--")
        print(("@@ %12s; %16s; %16s; %16s; %16s")
            :format("WORKER", "TXPACKETS", "TXBYTES", "RXPACKETS", "RXBYTES"))
        local stat1 = {}
        for w in pairs(worker.status()) do
            stat1[w] = {}
            stat1[w].txpackets = counter.read(counters[w].txpackets)
            stat1[w].txbytes = counter.read(counters[w].txbytes)
            stat1[w].rxpackets = counter.read(counters[w].rxpackets)
            stat1[w].rxbytes = counter.read(counters[w].rxbytes)
            if stat0 then
                local txp = stat1[w].txpackets - stat0[w].txpackets
                txpackets = txpackets + txp
                local txb = stat1[w].txbytes - stat0[w].txbytes
                txbytes = txbytes + txb
                local rxp = stat1[w].rxpackets - stat0[w].rxpackets
                rxpackets = rxpackets + rxp
                local rxb = stat1[w].rxbytes - stat0[w].rxbytes
                rxbytes = rxbytes + rxb
                print(("@@ %12s; %16s; %16s; %16s; %16s")
                    :format(w,
                        lib.comma_value(txp), lib.comma_value(txb),
                        lib.comma_value(rxp), lib.comma_value(rxb)))
            end
        end
        stat0 = stat1
        print(("@@ %12s; %16s; %16s; %16s; %16s")
            :format("TOTAL",
                    lib.comma_value(txpackets), lib.comma_value(txbytes),
                    lib.comma_value(rxpackets), lib.comma_value(rxbytes)))
    end

    engine.main{duration=1, no_report=true}
end