-- Single entry point for all four comment shortcodes. Quarto registers every key
-- of the table returned by a shortcode file, so one file is enough.
--
-- These handlers no longer render anything themselves: they only emit a TRANSIENT
-- marker — Span("", {"qtc-marker"}, data-qtc-*) — carrying the raw invocation data
-- (text, type, author, inline flag, and Quarto's block/inline/text context). The
-- unified post-quarto filter (comments.lua) consumes every marker and does ALL the
-- rendering + preamble/asset injection, so HTML and PDF share one code path.
--
-- The marker NEVER reaches the output: the filter replaces it. Keeping the data on
-- a Span (not e.g. a RawInline) means it survives shortcode expansion as a normal
-- AST node the filter can read in any context. (`qtc-marker` uses the internal
-- `qtc` prefix; it is not a user-facing/output class.)

local function as_string(value)
  if value == nil then return "" end
  if type(value) == "string" then return value end
  return pandoc.utils.stringify(value)
end

-- Positional arg #1 is the comment text; `text=` kwarg is an accepted alias.
local function arg_text(args, kwargs)
  if args ~= nil and #args > 0 then
    return as_string(args[1])
  end
  if kwargs ~= nil and kwargs.text ~= nil then
    return as_string(kwargs.text)
  end
  return ""
end

-- Build the transient marker Span. `forced_type` is set by the todo/note/question
-- handlers (the bare `comment` handler passes nil and lets `type=` or the default
-- decide downstream).
local function marker(args, kwargs, context, forced_type)
  kwargs = kwargs or {}
  local attrs = {
    ["data-qtc-text"]    = arg_text(args, kwargs),
    ["data-qtc-type"]    = forced_type or as_string(kwargs.type),
    ["data-qtc-author"]  = as_string(kwargs.author),
    ["data-qtc-inline"]  = as_string(kwargs.inline),
    ["data-qtc-context"] = as_string(context),
  }
  return pandoc.Span({}, pandoc.Attr("", { "qtc-marker" }, attrs))
end

-- Quarto passes the invocation context as the 5th argument
-- ("block" | "inline" | "text"); it is recorded so the filter can reproduce the
-- block-vs-mid-sentence rendering distinction.
return {
  ['comment']  = function(args, kwargs, meta, raw_args, context) return marker(args, kwargs, context, nil)        end,
  ['todo']     = function(args, kwargs, meta, raw_args, context) return marker(args, kwargs, context, "todo")     end,
  ['note']     = function(args, kwargs, meta, raw_args, context) return marker(args, kwargs, context, "note")     end,
  ['question'] = function(args, kwargs, meta, raw_args, context) return marker(args, kwargs, context, "question") end,
}
