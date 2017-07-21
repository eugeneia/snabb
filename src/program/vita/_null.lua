-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

local VhostUser = require("apps.vhost.vhost_user").VhostUser

local args = main.parameters
assert(#args == 1, "Usage: %null <socket_path>")
local c = config.new()
config.app(c, "VhostServer", VhostUser, {socket_path=args[1], is_server=true})
config.link(c, "VhostServer.tx -> VhostServer.rx")
engine.configure(c)
while true do engine.main({duration=1, report={showlinks=true,showapps=true}}) end
