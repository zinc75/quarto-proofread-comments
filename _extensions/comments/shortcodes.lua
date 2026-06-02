-- Single entry point for all four comment shortcodes. Quarto registers every
-- key of the table returned by a shortcode file, so one file is enough; each
-- handler forwards to the shared renderer in comment_core.lua with its type
-- (comment uses nil, which the renderer treats as the default "comment").
local function core()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  local directory = source:match("(.*[/\\])") or ""
  return dofile(directory .. "comment_core.lua")
end

local render = core()

return {
  ['comment']  = function(args, kwargs, meta) return render(args, kwargs, meta, nil) end,
  ['todo']     = function(args, kwargs, meta) return render(args, kwargs, meta, "todo") end,
  ['note']     = function(args, kwargs, meta) return render(args, kwargs, meta, "note") end,
  ['question'] = function(args, kwargs, meta) return render(args, kwargs, meta, "question") end,
}
