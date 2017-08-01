-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

local worker = require("core.worker")
local interlink = require("lib.interlink")
local Receiver = require("apps.interlink.receiver")
local Transmitter = require("apps.interlink.transmitter")
local Synth = require("apps.test.synth").Synth
local Sink = require("apps.basic.basic_apps").Sink

interlink.create("group/interlink/enc_dec")
interlink.create("group/interlink/enc_enc")

interlink.create("group/interlink/dec_enc")
interlink.create("group/interlink/dec_dec")

worker.start("encap", [[require("program.vita.test_esp_encap").start(
   "group/interlink/enc_dec",
   "group/interlink/enc_enc"
)]])

worker.start("decap", [[require("program.vita.test_esp_decap").start(
   "group/interlink/dec_enc",
   "group/interlink/dec_dec"
)]])

local c = config.new()

local packet_sizes
if main.parameters[1] then
   packet_sizes = { tonumber(main.parameters[1]) }
else -- IMIX
   packet_sizes = { 54, 54, 54, 54, 54, 54, 54, 590, 590, 590, 590, 1486 }
end
local packet_size = main.parameters[1]

config.app(c, "source", Synth, {sizes=packet_sizes})
config.app(c, "enc_dec", Transmitter, {name="group/interlink/enc_dec"})
config.link(c, "source.output->enc_dec.input")

config.app(c, "enc_enc", Receiver, {name="group/interlink/enc_enc"})
config.app(c, "dec_enc", Transmitter, {name="group/interlink/dec_enc"})
config.link(c, "enc_enc.output->dec_enc.input")

config.app(c, "dec_dec", Receiver, {name="group/interlink/dec_dec"})
config.app(c, "sink", Sink)
config.link(c, "dec_dec.output->sink.input")

engine.configure(c)
engine.main({duration=10, report={showlinks=true}})

for w, s in pairs(worker.status()) do
   print(("worker %s: pid=%s alive=%s status=%s"):format(
         w, s.pid, s.alive, s.status))
end
local stats = link.stats(engine.app_table["sink"].input.input)
print(stats.txbytes * 8 / 1e9 / 10 .. " Gbps")
