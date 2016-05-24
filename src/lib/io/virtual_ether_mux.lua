-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(..., package.seeall)
local pci = require("lib.hardware.pci")
local RawSocket = require("apps.socket.raw").RawSocket
local LearningBridge = require("apps.bridge.learning").bridge
local vlan = require("apps.vlan.vlan")

function configure (c, ports, io)
   local links
   if io and io.pci then
      local device = pci.decive_info(io.pci)
      if device and (device.driver == 'apps.intel.intel_app'
                  or device.driver == 'apps.solarflare.solarflare') then
         links = configureVMDq(c, device, ports)
      else
         error("Unknown device: "..io.pci)
      end
   else
      local Switch = "Switch"
      local switch_ports = {}
      for i, port in ipairs(ports) do
         switch_ports[i] = port_name(port)
      end
      local Trunk
      if io and io.iface then
         Trunk = "TrunkIf"
         config.app(c, trunk, RawSocket, io.iface)
         switch_ports[#switch_ports+1] = trunk
      end
      config.app(c, Switch, LearningBridge, {ports = switch_ports})
      for _, n in ipairs(switch_ports) do print(n) end
      if Trunk then
         config.link(c, Trunk..".tx -> "..Switch.."."..Trunk)
         config.link(c, Switch.."."..Trunk.." -> "..Trunk..".rx")
      end
      links = {}
      for i, port in ipairs(ports) do
         local name = port_name(port)
         local Switch_link = Switch.."."..name
         local Port_tx, Port_rx = Switch_link, Switch_link
         if port.vlan then
            local VlanTag, VlanUntag = name.."_VlanTag", name.."_VlanUntag"
            config.app(c, VlanTag, vlan.Tagger, {tag = port.vlan})
            config.link(c, VlanTag..".output -> "..Port_rx)
            Port_rx = VlanTag..".input"
            config.app(c, VlanUntag, vlan.Untagger, {tag = port.vlan})
            config.link(c, Port_tx.." -> "..VlanUntag..".input")
            Port_tx = VlanUntag..".output"
         end
         links[i] = {input = Port_rx, output = Port_tx}
      end
   end
   return links
end

-- Return name of port in <port_config>.
function port_name (port_config)
   return port_config.port_id:gsub("-", "_")
end

function configureVMDq (c, device)
   local links = {}
   for i, port in ipairs(ports) do
      local name = port_name(t)
      local NIC = name.."_NIC"
      local vmdq = true
      if not port.mac_address then
         if #ports ~= 1 then
            error("multiple ports defined but promiscuous mode requested for port: "..name)
         end
         vmdq = false
      end
      config.app(c, NIC, require(device.driver).driver,
                 {pciaddr = device.pciaddress,
                  vmdq = vmdq,
                  macaddr = port.mac_address,
                  vlan = port.vlan})
      links[i] = {input = NIC..".rx", output = NIC..".tx"}
   end
end
