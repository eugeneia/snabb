module(..., package.seeall)

local VhostUser = require("apps.vhost.vhost_user").VhostUser

function run (args)
   local socket1 = args[1]
   local socket2 = args[2]

   local c = config.new()
   config.app(c, "Virtio1", VhostUser, {socket_path=socket1})
   config.app(c, "Virtio2", VhostUser, {socket_path=socket2})
   config.link(c, "Virtio1.tx->Virtio2.rx")
   config.link(c, "Virtio2.tx->Virtio1.rx")
   engine.configure(c)
   engine.main()
end
