-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

local lib = require("core.lib")
local counter = require("core.counter")
local worker = require("core.worker")
local connectx = require("apps.mellanox.connectx")

local pci = "0000:85:00.1"
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
    worker.start(queue.id, ([[require("loadgen_lwa").loadgen(%q, %q, %d)]])
        :format(pci, queue.id, size))
end

local counters = {}
local function load_counters ()
    for w, s in pairs(worker.status()) do
        assert(s.alive)
        counters[w] = counters[w] or {
            txpackets = ("/%d/links/source.output -> nic.input/rxpackets.counter"):format(s.pid),
            txbytes = ("/%d/links/source.output -> nic.input/rxbytes.counter"):format(s.pid),
            rxpackets = ("/%d/links/nic.output -> sink.input/txpackets.counter"):format(s.pid),
            rxbytes = ("/%d/links/nic.output -> sink.input/txbytes.counter"):format(s.pid)
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

local txpackets, txbytes = 0ULL, 0ULL
local rxpackets, rxbytes = 0ULL, 0ULL
while true do
    engine.main{duration=1, no_report=true}

    local txpsum, txbsum = 0ULL, 0ULL
    local rxpsum, rxbsum = 0ULL, 0ULL
    if load_counters() then
        for w in pairs(worker.status()) do
            txpsum = txpsum + counter.read(counters[w].txpackets)
            txbsum = txbsum + counter.read(counters[w].txbytes)
            rxpsum = rxpsum + counter.read(counters[w].rxpackets)
            rxbsum = rxbsum + counter.read(counters[w].rxbytes)
        end
    end

    print("TXPACKETS", lib.comma_value(txpsum-txpackets))
    print("TXBYTES", lib.comma_value(txbsum-txbytes))
    txpackets, txbytes = txpsum, txbsum

    print("RXPACKETS", lib.comma_value(rxpsum-rxpackets))
    print("RXBYTES", lib.comma_value(rxbsum-rxbytes))
    rxpackets, rxbytes = rxpsum, rxbsum
end