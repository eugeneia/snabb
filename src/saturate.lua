local basic_apps = require("apps.basic.basic_apps")
local Synth = require("apps.test.synth").Synth
local Intel82599 = require("apps.intel.intel_app").Intel82599

local packet_size = 546
packet_size = math.max(packet_size, 46)
local duration = 20

local c = config.new()
config.app(c, "NIC", Intel82599, {pciaddr=main.parameters[1]})
config.app(c, "Source", Synth, {sizes={packet_size}})
config.app(c, "Sink", basic_apps.Sink)

config.link(c, "NIC.tx -> Sink.input")
config.link(c, "Source.output -> NIC.rx")

engine.configure(c)
engine.main({duration=duration})

-- Account for overhead of CRC and inter-packet gap
function bps (bytes) return (bytes+4+5) * 8 / duration end
local in_bytes = link.stats(engine.app_table["NIC"].input.rx).rxbytes
local out_bytes = link.stats(engine.app_table["NIC"].output.tx).rxbytes
print("rxbps "..bps(in_bytes).." txbps "..bps(out_bytes))
