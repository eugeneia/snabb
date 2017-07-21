-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

local VhostUser = require("apps.vhost.vhost_user").VhostUser
local basic_apps = require("apps.basic.basic_apps")

local args = main.parameters
assert(#args == 1, "Usage: _source <socket_path>")
local c = config.new()
config.app(c, "VhostUser", VhostUser, {socket_path=args[1]})
config.app(c, "Source", basic_apps.Source)
config.app(c, "Sink", basic_apps.Sink)
config.link(c, "Source.tx -> VhostUser.rx")
config.link(c, "VhostUser.tx -> Sink.rx")
engine.configure(c)
while true do engine.main({duration=1, report={showlinks=true,showapps=true}}) end
