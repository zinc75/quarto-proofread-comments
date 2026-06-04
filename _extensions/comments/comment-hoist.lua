-- Hoists mid-sentence (inline-context) comments out of their host paragraph.
--
-- A non-inline comment placed inside a sentence cannot be returned as a block by
-- the shortcode without breaking the paragraph, and an inline .column-margin
-- element makes Quarto grid the whole paragraph (text scatters into columns).
-- So the shortcode emits an inline placeholder badge marked
-- quarto-comment-hoist; this filter pulls each placeholder out of the paragraph
-- and inserts the real margin callout (a sibling div.column-margin, the same
-- block construct used for stand-alone comments) right after it. The paragraph
-- text stays continuous; the callout floats in the margin exactly like a
-- block-context comment.
--
-- Registered at post-quarto (see _extension.yml) so it runs AFTER shortcode
-- expansion. Activated via `filters: [comments]`. Without it, placeholders
-- simply render as inline badges (no loss). PDF is unaffected (no placeholders).

local function core()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  local directory = source:match("(.*[/\\])") or ""
  return dofile(directory .. "comment_core.lua")
end

local utils = core()

local FA_CSS_LINK = '<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.7.2/css/all.min.css" crossorigin="anonymous" referrerpolicy="no-referrer" />'
local fa_injected = false

-- Inline containers whose .content is itself an inline list (so a placeholder
-- may sit inside emphasis, a link, etc.).
local INLINE_CONTAINERS = {
  Emph = true, Strong = true, Underline = true, Strikeout = true,
  Superscript = true, Subscript = true, SmallCaps = true,
  Span = true, Link = true, Quoted = true,
}

-- Punctuation that never takes a leading space (true in both French and
-- English), used to drop the separator space left dangling when a placeholder
-- that followed a space is removed (e.g. "word {{< comment >}}, next").
local TIGHT_PUNCT = { [","] = true, ["."] = true }

local function is_marker(node)
  if node.t ~= "Span" then return false end
  for _, c in ipairs(node.classes) do
    if c == "quarto-comment-hoist" then return true end
  end
  return false
end

local function starts_with_tight_punct(node)
  return node ~= nil and node.t == "Str" and TIGHT_PUNCT[node.text:sub(1, 1)] == true
end

-- Rewrite an inline list: drop marker placeholders (collecting their callout
-- Divs into `divs`), recurse into inline containers, and remove a separator
-- space stranded before tight punctuation by a removed placeholder.
local function process_inlines(inlines, divs)
  local out = {}
  for i = 1, #inlines do
    local node = inlines[i]
    if is_marker(node) then
      table.insert(divs, utils.build_hoisted_div(node))
      -- Leave a small clickable icon anchor in the text (linked to the hoisted
      -- callout). If there is no number to link to, fall back to the old
      -- behaviour: drop the marker and the space stranded before tight punct.
      local anchor = utils.build_anchor_from_span(node)
      if anchor then
        table.insert(out, anchor)
      elseif #out > 0 and out[#out].t == "Space" and starts_with_tight_punct(inlines[i + 1]) then
        table.remove(out)
      end
    else
      if node.content and INLINE_CONTAINERS[node.t] then
        node.content = process_inlines(node.content, divs)
      end
      table.insert(out, node)
    end
  end
  return pandoc.Inlines(out)
end

local function handle(block)
  local divs = {}
  block.content = process_inlines(block.content, divs)
  if #divs == 0 then
    return nil -- unchanged
  end
  local out = pandoc.List({ block })
  for _, div in ipairs(divs) do
    if not fa_injected then
      fa_injected = true
      div.content:insert(1, pandoc.RawBlock("html", FA_CSS_LINK))
    end
    out:insert(div)
  end
  return out
end

-- Only blocks that carry inline content can hold a placeholder.
return {
  {
    Para = handle,
    Plain = handle,
  }
}
