-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

local worker = require("core.worker")
local interlink = require("lib.interlink")
local Receiver = require("apps.interlink.receiver")
local Transmitter = require("apps.interlink.transmitter")
local basic_apps = require("apps.basic.basic_apps")
local Source = require("apps.basic.basic_apps").Sink
local Sink = require("apps.basic.basic_apps").Sink

interlink.create("group/interlink/enc_dec")
interlink.create("group/interlink/enc_enc")

worker.start("esp", [[require("program.vita.test_esp_encap").start(
   "group/interlink/enc_dec",
   "group/interlink/enc_enc"
)]])

local c = config.new()

local packet_size = main.parameters[1]

config.app(c, "source", basic_apps.Source, packet_size)
config.app(c, "tx", Transmitter, {name="group/interlink/enc_dec"})
config.link(c, "source.output->tx.input")

config.app(c, "rx", Receiver, {name="group/interlink/enc_enc"})
config.app(c, "sink", Sink)
config.link(c, "rx.output->sink.input")

engine.configure(c)
engine.main({duration=10, report={showlinks=true}})

for w, s in pairs(worker.status()) do
   print(("worker %s: pid=%s alive=%s status=%s"):format(
         w, s.pid, s.alive, s.status))
end
local stats = link.stats(engine.app_table["sink"].input.input)
print(stats.txpackets / 1e6 / 10 .. " Mpps")
