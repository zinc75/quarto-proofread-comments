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

local render = core().render

-- Quarto passes the shortcode invocation context as the 5th argument
-- ("block" | "inline" | "text"). It is forwarded so the renderer can emit a
-- margin callout that does not break the paragraph when a non-inline comment is
-- placed mid-sentence (HTML).
return {
  ['comment']  = function(args, kwargs, meta, raw_args, context) return render(args, kwargs, meta, nil,        context) end,
  ['todo']     = function(args, kwargs, meta, raw_args, context) return render(args, kwargs, meta, "todo",     context) end,
  ['note']     = function(args, kwargs, meta, raw_args, context) return render(args, kwargs, meta, "note",     context) end,
  ['question'] = function(args, kwargs, meta, raw_args, context) return render(args, kwargs, meta, "question", context) end,
}
