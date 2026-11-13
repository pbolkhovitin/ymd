-- probe.luau — S2/S3/S5: печатает фактический API-поверхности хоста.
-- Результат смотреть в логе Noctalia: noctalia log / journalctl.

local BAR_CANDIDATES = {
  "setText", "setGlyph", "setIcon", "setTooltip", "setColor", "setTextColor",
  "setIconColor", "setVisible", "setOpacity", "setProgress", "setWidth",
  "setImage", "setBadge", "setMarkup", "setLabel", "setEnabled",
}

local NOCTALIA_CANDIDATES = {
  "http", "httpStream", "download", "getColor", "getSetting", "getConfig",
  "readFile", "writeFile", "pluginDataDir", "pluginDir", "notify", "log",
  "expandPath", "getenv", "json", "state", "runAsync", "runStream",
  "togglePanel", "isDarkMode", "nowMs", "setUpdateInterval",
}

local function dump(name, value)
  if type(value) ~= "table" then
    noctalia.log("[probe] " .. name .. " = " .. type(value))
    return
  end

  local keys = {}
  for key, item in pairs(value) do
    table.insert(keys, tostring(key) .. ":" .. type(item))
  end
  table.sort(keys)
  noctalia.log("[probe] " .. name .. " (" .. tostring(#keys) .. "): " .. table.concat(keys, ", "))
end

local function probe_members(name, table_ref, candidates)
  local found = {}
  for _, member in ipairs(candidates) do
    local ok, value = pcall(function()
      return table_ref[member]
    end)
    if ok then
      table.insert(found, member .. "=" .. type(value))
    else
      table.insert(found, member .. "=err")
    end
  end
  noctalia.log("[probe] " .. name .. "[]: " .. table.concat(found, " "))
end

function update()
  noctalia.setUpdateInterval(60000)

  dump("barWidget", barWidget)
  dump("ui", ui)
  dump("noctalia", noctalia)

  probe_members("barWidget", barWidget, BAR_CANDIDATES)
  probe_members("noctalia", noctalia, NOCTALIA_CANDIDATES)

  local ok_color, color = pcall(noctalia.getColor, "primary")
  noctalia.log("[probe] getColor(primary) = " .. tostring(ok_color and color or "err"))

  local ok_setting, order = pcall(noctalia.getSetting, "bar.order")
  noctalia.log("[probe] getSetting(bar.order) = " .. tostring(ok_setting and (type(order) == "table" and table.concat(order, ",") or order) or "err"))

  local ok_ui, column = pcall(function()
    return ui.column({ gap = 2 }, { ui.label({ text = "probe" }) })
  end)
  noctalia.log("[probe] ui.column in widget = " .. tostring(ok_ui) .. " " .. type(column))

  pcall(barWidget.setText, "probe")
end
