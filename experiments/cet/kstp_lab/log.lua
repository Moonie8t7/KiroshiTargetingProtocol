-- KSTP Lab :: log.lua
--
-- Ring-buffered logger with a file sink, plus the paste-back report writer.
-- CET runs each mod with its own working directory, so the relative paths below land
-- in bin/x64/plugins/cyber_engine_tweaks/mods/kstp_lab/ (same idiom as HUDitor's
-- io.open("persistency.json") in the reference corpus).

local Log = {
  buffer = {},
  maxLines = 600,
  clock = 0.0,
  logPath = 'kstp_lab_log.txt',
  reportPath = 'kstp_lab_report.txt',
  toFile = true,
  toConsole = true,
  fileError = nil,
}

function Log.tick(dt)
  Log.clock = Log.clock + (dt or 0.0)
end

local function stamp()
  local ok, s = pcall(os.date, '%H:%M:%S')
  if ok and type(s) == 'string' then return s end
  return string.format('t+%07.2f', Log.clock)
end

local function appendFile(path, text)
  local ok, f = pcall(io.open, path, 'a')
  if not ok or not f then
    Log.fileError = 'io.open failed for ' .. path
    return false
  end
  f:write(text)
  f:close()
  return true
end

function Log.line(text)
  local entry = '[' .. stamp() .. '] ' .. text
  Log.buffer[#Log.buffer + 1] = entry
  while #Log.buffer > Log.maxLines do
    table.remove(Log.buffer, 1)
  end
  if Log.toConsole then
    print('[KSTP-LAB] ' .. text)
  end
  if Log.toFile then
    appendFile(Log.logPath, entry .. '\n')
  end
end

-- Log.write("plain text") or Log.write("fmt %s", arg). The arg-count guard keeps a
-- literal '%' in a plain message from blowing up string.format.
function Log.write(fmt, ...)
  if select('#', ...) > 0 then
    local ok, text = pcall(string.format, fmt, ...)
    Log.line(ok and text or tostring(fmt))
  else
    Log.line(tostring(fmt))
  end
end

function Log.clear()
  Log.buffer = {}
end

function Log.lines()
  return Log.buffer
end

-- Overwrites the report each time so the user always has one current file to paste.
function Log.writeReport(bodyLines)
  local ok, f = pcall(io.open, Log.reportPath, 'w')
  if not ok or not f then
    Log.fileError = 'io.open failed for ' .. Log.reportPath
    Log.write('REPORT WRITE FAILED (%s)', Log.reportPath)
    return false, Log.fileError
  end
  for i = 1, #bodyLines do
    f:write(bodyLines[i])
    f:write('\n')
  end
  f:close()
  Log.write('Report written to mods/kstp_lab/%s', Log.reportPath)
  return true
end

return Log
