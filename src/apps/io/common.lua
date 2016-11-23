-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- config.app(c, "IOControl", IOControl, {type='pci', device="01:00.0",
--                                        queues={a = {...}, ...}})
--
-- config.app(c, "IO", IO, {type='pci', device="01:00.0", queue='a'})

module(..., package.seeall)

-- Maps type names to implementations
local type = {}


IOControl = {
   config = {
      type = {default='emu'},
      device = {required=true},
      queues = {required=true}
   }
}

function IOControl:configure (c, name, conf)
   local impl= assert(type[conf.type], "Unknown IO type: "..conf.type)
   if impl.control then
      impl.control(c, name, conf.device, conf.queues)
   end
end

IO = {
   config = {
      type = {default='emu'},
      device = {required=true},
      queue = {required=true}
   }
}

function IO:configure (c, name, conf)
   local impl = assert(type[conf.type], "Unknown IO type: "..conf.type)
   if impl.queue then
      impl.queue(c, name, conf.device, conf.queue)
   end
end

type.emu = {
   control = function (c, name, device, queues)
      local FloodingBridge = require("apps.bridge.flooding").bridge
      local EmuControl = require("apps.io.emu").EmuControl
      local ports = {}
      for name, queue in pairs(queues) do
         table.insert(ports, name)
      end
      config.app(c, device, EmuControl, {queues=queues, bridge=name})
      config.app(c, name, FloodingBridge, {ports=ports})
   end,
   queue = function (c, name, device, queue)
      local EmuQueue = require("apps.io.emu").EmuQueue
      local ctrlconf = assert(c.apps[device], "No such device: "..device).conf
      config.app(c, name, EmuQueue, {queue=queue, queues=ctrlconf.queues})
      config.link(c, name..".trunk -> "..ctrlconf.bridge.."."..queue)
      config.link(c, ctrlconf.bridge.."."..queue.." -> "..name..".trunk")
   end
}


-- Maps PCI driver to implementations
local driver = {}

type.pci = {
   control = function (c, name, device, queues)
      local pci = require("lib.hardware.pci")
      local impl = assert(driver[pci.device_info(device).driver],
                          "Unsupported PCI device: "..device)
      if impl.control then
         impl.control(c, name, device, queues)
      end
   end,
   queue = function (c, name, device, queue)
      local pci = require("lib.hardware.pci")
      local impl = assert(driver[pci.device_info(device).driver],
                          "Unsupported PCI device: "..device)
      if impl.queue then
         impl.queue(c, name, device, queues)
      end
   end
}

driver['apps.intel.intel_app'] = {
   state = {},
   control = function (c, name, device, queues)
      local nqueues, vmdq = 0, false
      for _ in pairs(queues) do
         nqueues = nqueues + 1
         if nqueues > 1 then vmdq = true; break end
      end
      for name, queue in pairs(queues) do
         if not queue.macaddr and vmdq then
            error(io..": multiple ports defined, "..
                  "but promiscuous mode requested for queue: "..name)
         end
         queue.pciaddr = device
         queue.vmdq = vmdq or (not not queue.macaddr)
      end
      local PseudoControl = {}
      function PseudoControl:new ()
         driver['apps.intel.intel_app'].state[device] = queues
         return setmetatable(o, {__index=PseudoControl})
      end
      function PseudoControl:stop ()
         driver['apps.intel.intel_app'].state[device] = nil
      end
      config.app(c, name, PseudoControl)
   end,
   queue = function (c, name, device, queue)
      local Intel82599 = require("apps.intel.intel_app").Intel82599
      local queues = assert(driver['apps.intel.intel_app'].state[device],
                            "Device not configured: "..device)
      config.app(c, name, Intel82599,
                 assert(queues[queue], "No such queue: "..queue))
   end
}


function selftest ()
   require("apps.io.emu")
   local c = config.new()
   config.app(c, "IOControl", IOControl,
              {device = "SoftBridge",
               queues = {a = {macaddr="60:50:40:40:20:10", hash=1},
                         b = {macaddr="60:50:40:40:20:10", hash=2}}})
   config.app(c, "IO", IO, {device = "SoftBridge", queue = 'a'})
   engine.configure(c)
   engine.report_apps()
   engine.report_links()
end
