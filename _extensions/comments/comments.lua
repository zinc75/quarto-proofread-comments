-- Unified post-quarto filter: the single rendering entry point for every comment.
--
-- The shortcodes (shortcodes.lua) only emit TRANSIENT markers
-- (Span "" {.qtc-marker} data-qtc-*). This filter walks the document, hands each
-- marker to the shared renderer in comment_core.lua (utils.render), and places the
-- result. Routing all rendering here makes HTML and PDF share one code path and
-- lets a comment carry all its data in one AST node (the basis for the upcoming
-- span-input + highlight feature).
--
-- Per comment, utils.render returns:
--   * an inline node (HTML inline badge, or a LaTeX RawInline \todo)  -> kept in place
--   * an HTML mid-sentence PLACEHOLDER span (.quarto-comment-hoist)   -> hoisted: an
--       in-text anchor is left behind and the margin callout is inserted as a
--       sibling block (so the host paragraph stays intact)
--   * an HTML block-context callout Div                               -> emitted as a
--       sibling block (the host paragraph, which held only the marker, is dropped)
--   * pandoc.Null (disabled / empty)                                  -> removed
--
-- Preamble/asset injection: the LaTeX preamble is injected by utils.render itself
-- (it runs here, in the post-quarto filter, where quarto.doc.include_text /
-- use_latex_package work). The document-level HTML assets (Font Awesome, the anchor
-- CSS, the hover script) are injected ONCE here, deterministically, after the walk.
--
-- Registered at post-quarto (see _extension.yml) so it runs AFTER shortcode
-- expansion. Activated via `filters: [comments]`.

local function core()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  local directory = source:match("(.*[/\\])") or ""
  return dofile(directory .. "comment_core.lua")
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

local function is_marker(node)
  if node.t ~= "Span" then return false end
  for _, c in ipairs(node.classes) do
    if c == "qtc-marker" then return true end
  end
  return false
end

local function starts_with_tight_punct(node)
  return node ~= nil and node.t == "Str" and TIGHT_PUNCT[node.text:sub(1, 1)] == true
end

-- Reconstruct utils.render's inputs from a marker and call the shared renderer.
-- The type travels via kwargs.type (render resolves type/default); forced_type is
-- nil because the shortcode already folded its forced type into data-qtc-type.
local function render_marker(node, meta)
  local a = node.attributes
  local typ = a["data-qtc-type"]
  if typ == "" then typ = nil end
  local context = a["data-qtc-context"]
  if context == "" then context = nil end
  local kwargs = {
    type = typ,
    author = a["data-qtc-author"],
    inline = a["data-qtc-inline"],
  }
  return utils.render({ a["data-qtc-text"] or "" }, kwargs, meta, nil, context)
end

-- Classify utils.render's return so the caller knows how to place it.
local function classify(result)
  if result == nil then return "drop" end
  local t = result.t
  if t == "Null" then return "drop" end
  if t == "Span" then
    for _, c in ipairs(result.classes or {}) do
      if c == "quarto-comment-hoist" then return "hoist" end
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
local function process_inlines(inlines, blocks, meta, state)
  local out = {}
  local function drop_stranded_space(next_node)
    if #out > 0 and out[#out].t == "Space" and starts_with_tight_punct(next_node) then
      table.remove(out)
    end
  end
  for i = 1, #inlines do
    local node = inlines[i]
    if is_marker(node) then
      state.changed = true
      local result = render_marker(node, meta)
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
          drop_stranded_space(inlines[i + 1])
        end
      elseif cls == "block" then
        table.insert(blocks, result)
        drop_stranded_space(inlines[i + 1])
      else -- drop
        drop_stranded_space(inlines[i + 1])
      end
    else
      if node.content and INLINE_CONTAINERS[node.t] then
        node.content = process_inlines(node.content, blocks, meta, state)
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
  local new = process_inlines(block.content, blocks, meta, state)
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
