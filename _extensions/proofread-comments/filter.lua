-- The single rendering filter. Input is the pandoc bracketed-span syntax:
--
--   []{.comment by="vg" remark="…"}               -> an INSERTED comment (empty
--                                                     bracket): margin callout, or an
--                                                     inline badge with inline=true.
--   [highlighted text]{.comment by="vg" remark="…"}
--                                                  -> HIGHLIGHT the text + attach the
--                                                     note in the margin.
--
-- Type via type="comment|todo|note|question" (default comment). The filter walks the
-- document and, for each .comment span:
--   * EMPTY  -> utils.render (reused inserted-comment path). Its result is classified
--       and placed: an inline node stays in place; an HTML mid-sentence placeholder is
--       hoisted (in-text anchor + sibling margin callout); an HTML block-context
--       callout Div becomes a sibling block; nil/disabled is dropped.
--   * NON-EMPTY -> utils.render_highlight, which returns { inlines, blocks }: the
--       highlighted text (the clickable anchor) stays in the flow, the margin note is
--       collected as a sibling block.
--
-- Preamble/asset injection: the LaTeX preamble is injected by the core (it runs here,
-- in the post-quarto filter, where quarto.doc.include_text / use_latex_package work);
-- the document-level HTML assets (Font Awesome, anchor CSS, hover script) are injected
-- ONCE here after the walk. Activated via `filters: [proofread-comments]`.

local function core()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  local directory = source:match("(.*[/\\])") or ""
  return dofile(directory .. "core.lua")
end

local utils = core()

-- Did we render at least one (enabled, non-empty) comment? Gates the one-time HTML
-- asset injection so a document with no comments (or enabled:false) is untouched.
local any_comment = false

local function is_html()
  if quarto and quarto.doc and quarto.doc.is_format then
    if quarto.doc.is_format("html") or quarto.doc.is_format("revealjs") then
      return true
    end
  end
  return (FORMAT or ""):match("html") ~= nil
end

-- Inline containers whose .content is itself an inline list (so a marker may sit
-- inside emphasis, a link, etc.).
local INLINE_CONTAINERS = {
  Emph = true, Strong = true, Underline = true, Strikeout = true,
  Superscript = true, Subscript = true, SmallCaps = true,
  Span = true, Link = true, Quoted = true,
}

-- Punctuation that never takes a leading space (true in both French and English),
-- used to drop the separator space left dangling when a marker that followed a
-- space is removed (e.g. "word {{< comment >}}, next").
local TIGHT_PUNCT = { [","] = true, ["."] = true }

-- A user-facing comment span: [highlighted text]{.comment by=… remark=… type=…}
-- or, empty, an inserted comment: []{.comment by=… remark=…}.
local function is_comment_span(node)
  if node.t ~= "Span" then return false end
  for _, c in ipairs(node.classes) do
    if c == "comment" then return true end
  end
  return false
end

-- Is the span the ONLY meaningful inline in its paragraph? Such a span is the
-- span-syntax equivalent of a comment written on its own line — rendered in the
-- block context (callout + in-text anchor) rather than hoisted mid-sentence.
local function sole_comment_span(inlines)
  local found = nil
  for _, n in ipairs(inlines) do
    local t = n.t
    if t == "Space" or t == "SoftBreak" or t == "LineBreak" then
      -- skip whitespace
    elseif is_comment_span(n) and found == nil then
      found = n
    else
      return nil -- some other content is present
    end
  end
  return found
end

-- An empty comment span ([]{.comment …}) carries no highlighted text; it is an
-- inserted comment. A non-empty one highlights its content.
local function span_is_empty(node)
  if #node.content == 0 then return true end
  return pandoc.utils.stringify(node.content):match("^%s*$") ~= nil
end

-- Render an EMPTY comment span as an inserted comment by reconstructing the shared
-- renderer's inputs (the `remark` attribute is the comment text, `by` the reviewer).
-- Context (block vs mid-sentence) comes from the AST.
local function render_comment_span(node, meta, context)
  local a = node.attributes
  local typ = a["type"]
  if typ == "" then typ = nil end
  local kwargs = { type = typ, author = a["by"], inline = a["inline"] }
  return utils.render({ a["remark"] or "" }, kwargs, meta, nil, context)
end

local function starts_with_tight_punct(node)
  return node ~= nil and node.t == "Str" and TIGHT_PUNCT[node.text:sub(1, 1)] == true
end

-- Classify utils.render's return so the caller knows how to place it.
local function classify(result)
  if result == nil then return "drop" end
  local t = result.t
  if t == "Null" then return "drop" end
  if t == "Span" then
    for _, c in ipairs(result.classes or {}) do
      if c == "proofread-comment-hoist" then return "hoist" end
    end
    return "inline"
  end
  if t == "RawInline" then return "inline" end
  return "block" -- Div, RawBlock, Para, ... (HTML block-context callout, fallbacks)
end

-- Rewrite an inline list: render each marker and place the result. Inline results
-- stay in `out`; hoisted/block results are collected into `blocks` (sibling blocks
-- of the host paragraph) and the marker leaves either an in-text anchor (hoist) or
-- nothing (block). Recurses into inline containers. Returns the new inline list and
-- sets state.changed when any marker was found.
-- Place utils.render's classified return into the inline list `out` / sibling
-- `blocks`. Shared by the marker path and the empty-comment-span path.
local function place_rendered(result, out, blocks, drop_stranded_space, next_node)
  local cls = classify(result)
  if cls ~= "drop" then any_comment = true end
  if cls == "inline" then
    table.insert(out, result)
  elseif cls == "hoist" then
    table.insert(blocks, utils.build_hoisted_div(result))
    local anchor = utils.build_anchor_from_span(result)
    if anchor then
      table.insert(out, anchor)
    else
      drop_stranded_space(next_node)
    end
  elseif cls == "block" then
    table.insert(blocks, result)
    drop_stranded_space(next_node)
  else -- drop
    drop_stranded_space(next_node)
  end
end

local function process_inlines(inlines, blocks, meta, state, sole)
  local out = {}
  local function drop_stranded_space(next_node)
    if #out > 0 and out[#out].t == "Space" and starts_with_tight_punct(next_node) then
      table.remove(out)
    end
  end
  for i = 1, #inlines do
    local node = inlines[i]
    if is_comment_span(node) then
      state.changed = true
      if span_is_empty(node) then
        -- Inserted comment. Sole-in-paragraph -> block context, else mid-sentence.
        local context = (node == sole) and "block" or "inline"
        place_rendered(render_comment_span(node, meta, context), out, blocks,
          drop_stranded_space, inlines[i + 1])
      else
        -- Highlight + note: utils.render_highlight returns { inlines, blocks,
        -- rendered }. `rendered` is false when comments are disabled (it returns the
        -- bare text) — only count a real render towards the HTML asset injection.
        local res = utils.render_highlight(node.content, node.attributes, meta)
        if res then
          for _, n in ipairs(res.inlines or {}) do table.insert(out, n) end
          for _, b in ipairs(res.blocks or {}) do table.insert(blocks, b) end
          if res.rendered then any_comment = true end
        else
          for _, n in ipairs(node.content) do table.insert(out, n) end
        end
      end
    else
      if node.content and INLINE_CONTAINERS[node.t] then
        node.content = process_inlines(node.content, blocks, meta, state, sole)
      end
      table.insert(out, node)
    end
  end
  return pandoc.Inlines(out)
end

local function has_visible_inline(inlines)
  for _, n in ipairs(inlines) do
    if n.t ~= "Space" and n.t ~= "SoftBreak" and n.t ~= "LineBreak" then
      return true
    end
  end
  return false
end

-- Process one inline-holding block (Para/Plain). Returns nil when unchanged, else a
-- list: the (possibly emptied) block followed by its collected sibling blocks. A
-- block whose only content was a block-context / hoisted-away marker is dropped, so
-- a stand-alone comment becomes its margin callout with no empty paragraph left.
local function handle(block, meta)
  local blocks = {}
  local state = { changed = false }
  local sole = sole_comment_span(block.content)
  local new = process_inlines(block.content, blocks, meta, state, sole)
  if not state.changed then
    return nil
  end
  block.content = new
  local out = pandoc.List()
  if has_visible_inline(new) then
    out:insert(block)
  end
  for _, b in ipairs(blocks) do
    out:insert(b)
  end
  return out
end

function Pandoc(doc)
  local meta = doc.meta
  doc = doc:walk({
    Para = function(b) return handle(b, meta) end,
    Plain = function(b) return handle(b, meta) end,
  })

  -- One-time, deterministic HTML asset injection (only when comments were rendered
  -- and the target is HTML). One Font Awesome <link> + the anchor CSS at the top,
  -- the hover script at the end — all valid in <body>, so no include_text timing
  -- dependency.
  if any_comment and is_html() then
    table.insert(doc.blocks, 1,
      pandoc.RawBlock("html", utils.FA_CSS_LINK .. "\n" .. utils.ANCHOR_CSS))
    table.insert(doc.blocks,
      pandoc.RawBlock("html", utils.HTML_HOVER_SCRIPT))
  end
  return doc
end
