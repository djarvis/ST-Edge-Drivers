-- Copyright 2022 philh30
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local Driver = require("st.driver")
local caps = require("st.capabilities")
local log = require("log")
local build_eiscp = require("build_eiscp")
local disco = require("disco")
local cap_map = require("cap_map")
local client_functions = require("client_functions")
local split_string = require("split_string")
local wrap = require("wrap_eiscp")
local config = require("config")
local inputCapability = config.inputCapability
local commandCapability = config.commandCapability
local get_inputs = require("inputs")
local socket = require("cosock.socket") -- for delay

DEVICE_MAP = {}

--- @param device st.Device
local function source_list(device)
  local map = get_inputs(device)
  local sources = {}
  for name, _ in pairs(map) do
    if name ~= 'cmd' and name ~= 'query' and name ~='UNKNOWN' then
      table.insert(sources,name)
    end
  end
  return sources
end



--- Called whenever a command is sent. If a message is not received from the device within 1 second,
--- query the attribute. If another 4 seconds pass, assume the connection has dropped and reconnect.
---
--- @param driver Driver
--- @param device st.Device
local function wait_for_response(driver,device,component,capability,attribute)
  
  local function do_reconnect()
    log.warn(string.format('%s CONNECTION DROPPED',device.device_network_id))
    device.thread:cancel_timer(DEVICE_MAP[device.device_network_id].response)
    DEVICE_MAP[device.device_network_id].response = nil
    client_functions.refresh_connection(driver,device)
  end
  local function do_query()
    log.warn(string.format('%s NO RESPONSE - QUERYING %s:%s:%s',device.device_network_id,component,capability,attribute))
    local msg = build_eiscp(device,component,capability,attribute,'query')
    if msg and DEVICE_MAP[device.device_network_id].sock then DEVICE_MAP[device.device_network_id].sock:send(msg) end
    device.thread:cancel_timer(DEVICE_MAP[device.device_network_id].response)
    DEVICE_MAP[device.device_network_id].response = device.thread:call_with_delay(4, do_reconnect)
  end
  if not DEVICE_MAP[device.device_network_id].response then
    DEVICE_MAP[device.device_network_id].response = device.thread:call_with_delay(1, do_query)
  end
end

--- Check connection and send.
---
--- @param driver Driver
--- @param device st.Device
local function send_cmd(driver,device,command,attribute,state)
  local msg = build_eiscp(device,command.component,command.capability,attribute,state)
  client_functions.check_connection(driver,device)
  if msg and DEVICE_MAP[device.device_network_id].sock then DEVICE_MAP[device.device_network_id].sock:send(msg) end
  wait_for_response(driver,device,command.component,command.capability,attribute)
end

--- @param driver Driver
--- @param device st.Device
local function set_switch(driver,device,command)
  local state = command.command
  local attribute = 'switch'
  send_cmd(driver,device,command,attribute,state)
end

--- @param driver Driver
--- @param device st.Device
local function set_mute(driver,device,command)
  local state = ((command.command == 'setMute') and command.args.state or command.command) .. 'd'
  local attribute = 'mute'
  send_cmd(driver,device,command,attribute,state)
end

--- @param driver Driver
--- @param device st.Device
local function set_volume(driver,device,command)
  local state = string.format('%x',math.floor(tonumber(command.args.volume) * device.preferences.volumeScale / 100))
  local attribute = 'volume'
  send_cmd(driver,device,command,attribute,state)
end

--- @param driver Driver
--- @param device st.Device
local function set_media_source(driver,device,command)
  local attribute = 'inputSource'
  local state = command.args.inputSource
  send_cmd(driver,device,command,attribute,state)
end

--- @param driver Driver
--- @param device st.Device
local function refresh_handler(driver,device,command)
  log.trace('REFRESH')
  local map = cap_map(device)
  log.info("In refresh_handler(): device.profile.id is " .. device.profile.id)
  for _, comp in pairs(device.profile.components) do
    log.info("In refresh_handler(): looping on comp.id=" .. comp.id);
    for _, cap in pairs(comp.capabilities) do
      log.info("  In refresh_handler(): looping on cap.id=" .. cap.id);
      if (map[comp.id] or {})[cap.id] then
        log.info("  In refresh_handler(): found map");
        for attr, _ in pairs(map[comp.id][cap.id]) do
          log.info("  In refresh_hander(); looping on attr=" .. attr);
          local msg = build_eiscp(device,comp.id,cap.id,attr,'query')
          if msg and DEVICE_MAP[device.device_network_id].sock then 
            log.info("    In refresh_handler(): sending this query command: " .. msg);
            DEVICE_MAP[device.device_network_id].sock:send(msg)
          else
            log.info("    In refresh_ahndler(): NOT sending this query command: " .. msg);
          end
        
        end
      else
        log.info("  In refresh_handler(): didn't find map");
      end
    end
    log.info("In refresh_handler(): done looping on comp.id=" ..comp.id);
    log.info("In refresh_handler(): calling wait_for_response for switch " .. comp.id);
    wait_for_response(driver,device,comp.id,'switch','switch') -- dan put this here
    log.info("In refresh_handler(): called wait_for_response for switch " .. comp.id);

    log.info("In refresh_handler(): calling wait_for_response for audioVolume " .. comp.id);
    wait_for_response(driver,device,comp.id,'audioVolume','audioVolume') -- dan put this here
    log.info("In refresh_handler(): called wait_for_response for audioVolume " .. comp.id);


  end
  -- wait_for_response(driver,device,'main','switch','switch')

  log.info("In refresh_handler(): ALL DONE!");
end


--- @param driver Driver
--- @param device st.Device
local function info_changed(driver,device,event,args)
  log.info("**************** info_changed()");
  -- if args.old_st_store.preferences.zoneCount ~= device.preferences.zoneCount then
    local mode = tonumber(device.preferences.zoneCount)
    log.info("mode is ", mode);
    local profileName = "onkyo";
    local create_device_msg = {
      profile = profileName,
    }
    assert (device:try_update_metadata(create_device_msg), "Failed to change device")
    log.warn(string.format('Changed to %s profile. App restart may be required.',create_device_msg.profile))

    --
    -- Try refreshing
    --
    refresh_handler(driver,device)

  -- end
  local sources = source_list(device)
  local evt = inputCapability.supportedInputSources({value=sources})
  evt.visibility = {displayed = false}
  device:emit_component_event(device.profile.components['main'],evt)
  if device:component_exists('zone2') then
    log.info("emitting zone2 input capability component");
    device:emit_component_event(device.profile.components['zone2'],evt)
  end
  if device:component_exists('zone3') then
    log.info("emitting zone3 input capability component");
    device:emit_component_event(device.profile.components['zone3'],evt)
  end
end



--- @param driver Driver
--- @param device st.Device
local function send_raw_command(driver,device,command)
  log.trace(string.format("%s Sending raw eISCP command %s",device.device_network_id,command.args.command))
  local cmds = split_string(command.args.command,',')
  client_functions.check_connection(driver,device)
  if DEVICE_MAP[device.device_network_id].sock then
    for _, cmd in ipairs(cmds) do
      if (string.match(command, "PAUSE") == "PAUSE") then
        local s = tonumber(string.sub(command, 6))
        log.trace("send_raw_command(): sleeping for " .. s .. " seconds");
        socket.sleep(1);
        log.trace("send_raw_command(): slept for " .. s .. " seconds");
      else
        DEVICE_MAP[device.device_network_id].sock:send(wrap(cmd))
      end
    end
  end
  wait_for_response(driver,device)
end

local function keep_alive(driver,device)
  local function poll()
      log.trace(string.format('%s POLLING TO KEEP CONNECTION ALIVE',device.device_network_id))
      client_functions.check_connection(driver,device)
      refresh_handler(driver,device)
  end
  if not (DEVICE_MAP[device.device_network_id] or {}).alive then
      if not DEVICE_MAP[device.device_network_id] then DEVICE_MAP[device.device_network_id] = {} end
      DEVICE_MAP[device.device_network_id].alive = device.thread:call_on_schedule(30*60, poll) -- Query power every 30 minutes
  end
end

--- @param driver Driver
--- @param device st.Device
local function init(driver,device,command)
  local sources = source_list(device)
  local evt = inputCapability.supportedInputSources({value=sources})
  evt.visibility = {displayed=false}
  device:emit_component_event(device.profile.components['main'],evt)
  if device:component_exists('zone2') then
    device:emit_component_event(device.profile.components['zone2'],evt)
  end
  if device:component_exists('zone3') then
    device:emit_component_event(device.profile.components['zone3'],evt)
  end
  client_functions.check_connection(driver,device)
  keep_alive(driver,device)
end

--- @param driver Driver
--- @param device st.Device
local function removed(driver,device)
  log.trace(string.format("%s REMOVED",device.device_network_id))
  if DEVICE_MAP[device.device_network_id] then
    if DEVICE_MAP[device.device_network_id].alive then
      device.thread:cancel_timer(DEVICE_MAP[device.device_network_id].alive)
      DEVICE_MAP[device.device_network_id].alive = nil
    end
    DEVICE_MAP[device.device_network_id].sock:close()
    DEVICE_MAP[device.device_network_id] = nil
  end
end

local driver = Driver('onkyo', {
    discovery = disco.start,
    capability_handlers = {
      [caps.refresh.ID] = {
        [caps.refresh.commands.refresh.NAME] = refresh_handler,
      },
      [caps.switch.ID] = {
        [caps.switch.commands.on.NAME] = set_switch,
        [caps.switch.commands.off.NAME] = set_switch,
      },
      [caps.audioMute.ID] = {
        [caps.audioMute.commands.mute.NAME] = set_mute,
        [caps.audioMute.commands.unmute.NAME] = set_mute,
      },
      [caps.audioVolume.ID] = {
        [caps.audioVolume.commands.setVolume.NAME] = set_volume,
      },
      [inputCapability.ID] = {
        [inputCapability.commands.setInputSource.NAME] = set_media_source,
      },
      [commandCapability.ID] = {
        [commandCapability.commands.sendCommand.NAME] = send_raw_command,
      },
    },
    lifecycle_handlers = {
      infoChanged = info_changed,
      init = init,
      removed = removed,
    }
  }
)

driver:run()