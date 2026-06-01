local utils = {}

local ok_quarto, quarto = pcall(require, "quarto")
if not ok_quarto then
  -- require() shadows the global; fall back to it when available
  quarto = _G["quarto"] or {}
  ok_quarto = type(quarto) == "table"
end

local FA_CSS_LINK = '<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.7.2/css/all.min.css" crossorigin="anonymous" referrerpolicy="no-referrer" />'
local _fa_css_injected = false
local _listoftodos_injected = false
local _latex_tdo_cleared = false
local _latex_wide_margins_injected = false
local _latex_bezier_injected = false

-- Replaces todonotes' default right-angle connector with a smooth Bézier curve
-- and thinner stroke. Uses \@todonotes@currentlinecolor so it inherits the
-- per-note linecolor option (= author's base colour).
local BEZIER_CONNECTION_LATEX = [[
\makeatletter
\renewcommand{\@todonotes@drawLineToRightMargin}{%
  \if@todonotes@line%
  \begin{tikzpicture}[remember picture,overlay]%
    \node[circle,draw=\@todonotes@currentlinecolor,fill=white,%
          minimum size=4pt,inner sep=0pt,line width=1pt,outer sep=2pt]%
      (todoanch) at ([yshift=-0.25cm,xshift=-0.1cm]inText) {};%
    \draw[draw=\@todonotes@currentlinecolor,line width=0.5pt,dashed]%
      (todoanch) to[out=0,in=180] (inNote.west);%
  \end{tikzpicture}%
  \fi}%
\renewcommand{\@todonotes@drawLineToLeftMargin}{%
  \if@todonotes@line%
  \begin{tikzpicture}[remember picture,overlay]%
    \node[circle,draw=\@todonotes@currentlinecolor,fill=white,%
          minimum size=4pt,inner sep=0pt,line width=1pt,outer sep=2pt]%
      (todoanch) at ([yshift=-0.25cm,xshift=-0.1cm]inText) {};%
    \draw[draw=\@todonotes@currentlinecolor,line width=0.5pt,dashed]%
      (todoanch) to[out=180,in=0] (inNote.east);%
  \end{tikzpicture}%
  \fi}%
\makeatother
]]

local VALID_TYPES = {
  comment = true,
  todo = true,
  note = true,
  question = true,
}

local DEFAULT_HTML_COLORS = {
  comment = "#6C757D",
  todo = "#D55E00",
  note = "#0072B2",
  question = "#8E44AD",
}

local DEFAULT_LATEX_COLORS = {
  comment = "gray!20",
  todo = "red!20",
  note = "blue!20",
  question = "cyan!20",
}

-- Bootstrap 5 base (-500) colors, used for auto-assigned author colors.
-- These are used as-is for HTML accents; in LaTeX they are registered via
-- \definecolor and then diluted with !40!white for the note background.
local PALETTE_HEX = {
  "0d6efd",  -- blue
  "6610f2",  -- indigo
  "6f42c1",  -- purple
  "d63384",  -- pink
  "dc3545",  -- red
  "fd7e14",  -- orange
  "ffc107",  -- yellow
  "198754",  -- green
  "20c997",  -- teal
  "0dcaf0",  -- cyan
}

-- Track which author color names have been declared in the LaTeX preamble
local _latex_colors_declared = {}

local function hash_string(s)
  local sum = 0
  for i = 1, #s do
    sum = sum + string.byte(s, i)
  end
  return sum
end

local function auto_color_hex(author)
  local seed = author.name and author.name ~= "" and author.name or author.id or "x"
  local idx = (hash_string(seed) % #PALETTE_HEX) + 1
  return PALETTE_HEX[idx]
end

local CALLOUT_VARIANTS = {
  comment = "callout-note",
  todo = "callout-warning",
  note = "callout-tip",
  question = "callout-important",
}

local COMMENT_ICONS = {
  comment  = '<i class="fa-regular fa-comment"></i>',
  todo     = '<i class="fa-regular fa-pen-to-square"></i>',
  note     = '<i class="fa-regular fa-bell"></i>',
  question = '<i class="fa-regular fa-circle-question"></i>',
}

local LATEX_FA_ICONS = {
  comment  = "\\faComment[regular]{}",
  todo     = "\\faEdit[regular]{}",
  note     = "\\faBell[regular]{}",
  question = "\\faQuestionCircle[regular]{}",
}

local function sanitize_class(value)
  local cleaned = tostring(value or "")
  cleaned = cleaned:gsub("%s+", "-")
  cleaned = cleaned:gsub("[^%w%-_]", "")
  if cleaned == "" then
    return nil
  end
  return cleaned
end

local function parse_bool(value)
  if value == nil then
    return false
  end
  if type(value) == "boolean" then
    return value
  end
  local lowered = tostring(value):lower()
  return lowered == "true" or lowered == "1" or lowered == "yes" or lowered == "y"
end

local function trim(value)
  local stripped = value:gsub("^%s+", "")
  stripped = stripped:gsub("%s+$", "")
  return stripped
end

local function extract_text(args, kwargs)
  if args ~= nil and #args > 0 then
    local first = args[1]
    if type(first) == "string" then
      return first
    elseif type(first) == "table" then
      return pandoc.utils.stringify(first)
    end
  end
  if kwargs ~= nil and kwargs.text ~= nil then
    local value = kwargs.text
    if type(value) == "string" then
      return value
    elseif type(value) == "table" then
      return pandoc.utils.stringify(value)
    end
  end
  return ""
end

local function meta_to_string(value)
  if not value then
    return ""
  end
  if type(value) == "string" then
    return value
  end
  -- Use pandoc.utils.stringify for all Pandoc meta values
  return pandoc.utils.stringify(value)
end

local function meta_to_bool(value)
  if value == nil then
    return nil
  end
  if type(value) == "boolean" then
    return value
  end
  if type(value) == "table" and value.t == "MetaBool" then
    -- MetaBool objects are truthy tables, need to check stringified value
    local text = pandoc.utils.stringify(value):lower()
    return text == "true"
  end
  local text = meta_to_string(value):lower()
  if text == "true" or text == "1" or text == "yes" then
    return true
  end
  if text == "false" or text == "0" or text == "no" then
    return false
  end
  return nil
end

local function get_config(meta)
  local config = {
    enabled = true,
    show_author = true,
    show_list = false,
    wide_margins = false,
    extra_margin = "6.5cm",
    inner_pad = "0.3cm",
    frame_color = "gray!10",
    frame_line = "gray!60",
    authors = {},
  }

  local config_meta = meta and meta.extensions and meta.extensions["quarto-comments"]
  if not config_meta then
    return config
  end

  -- Access MetaMap fields directly, not via pairs()
  if config_meta.enabled ~= nil then
    local enabled = meta_to_bool(config_meta.enabled)
    if enabled ~= nil then
      config.enabled = enabled
    end
  end

  if config_meta.show_author ~= nil then
    local show_author = meta_to_bool(config_meta.show_author)
    if show_author ~= nil then
      config.show_author = show_author
    end
  end

  if config_meta.show_list ~= nil then
    local show_list = meta_to_bool(config_meta.show_list)
    if show_list ~= nil then
      config.show_list = show_list
    end
  end

  if config_meta.wide_margins ~= nil then
    local wm = meta_to_bool(config_meta.wide_margins)
    if wm ~= nil then config.wide_margins = wm end
  end
  if config_meta.extra_margin then
    config.extra_margin = meta_to_string(config_meta.extra_margin)
  end
  if config_meta.inner_pad then
    config.inner_pad = meta_to_string(config_meta.inner_pad)
  end
  if config_meta.frame_color then
    config.frame_color = meta_to_string(config_meta.frame_color)
  end
  if config_meta.frame_line then
    config.frame_line = meta_to_string(config_meta.frame_line)
  end

  if config_meta.authors then
    local authors_meta = config_meta.authors
    -- MetaMap can be accessed as a table with pandoc >= 2.17
    for author_key, author_meta in pairs(authors_meta) do
      if type(author_meta) == "table" then
        local author = {}
        if author_meta.name then
          author.name = meta_to_string(author_meta.name)
        end
        if author_meta.color_html then
          author.color_html = meta_to_string(author_meta.color_html)
        end
        if author_meta.color_latex then
          author.color_latex = meta_to_string(author_meta.color_latex)
        end
        config.authors[author_key] = author
      end
    end
  end

  return config
end

local function is_html_format()
  if ok_quarto and quarto.doc and quarto.doc.is_format then
    if quarto.doc.is_format("html") or quarto.doc.is_format("revealjs") then
      return true
    end
  end
  local format = FORMAT or ""
  return format:match("html") ~= nil
end

local function is_latex_format()
  if ok_quarto and quarto.doc and quarto.doc.is_format then
    if quarto.doc.is_format("latex") or quarto.doc.is_format("pdf") then
      return true
    end
  end
  local format = FORMAT or ""
  return format:match("latex") ~= nil or format:match("pdf") ~= nil
end

local function resolve_html_color(comment_type, author)
  if author and author.color_html and author.color_html ~= "" then
    return author.color_html
  end
  if author then
    return "#" .. auto_color_hex(author)
  end
  return DEFAULT_HTML_COLORS[comment_type] or DEFAULT_HTML_COLORS.comment
end

-- Returns an xcolor-compatible color name for use in LaTeX.
-- For named/tint specs (e.g. "blue!20") the value is returned as-is.
-- For auto-assigned authors a unique color is declared via \definecolor and
-- its name is returned; hex values from the YAML config are treated the same way.
local function resolve_latex_color(comment_type, author)
  local hex = nil
  if author then
    if author.color_latex and author.color_latex ~= "" then
      if not author.color_latex:match("^#") then
        -- Named xcolor spec — use directly
        return author.color_latex
      else
        hex = author.color_latex:sub(2)  -- strip leading #
      end
    else
      hex = auto_color_hex(author)
    end
  end

  if hex then
    local color_name = "cmt-" .. (author.id or "x")
    if not _latex_colors_declared[color_name] then
      _latex_colors_declared[color_name] = true
      pcall(function()
        quarto.doc.include_text("in-header",
          "\\definecolor{" .. color_name .. "}{HTML}{" .. hex .. "}\n")
      end)
    end
    return color_name
  end

  return DEFAULT_LATEX_COLORS[comment_type] or DEFAULT_LATEX_COLORS.comment
end

local function escape_latex(text)
  local escaped = text
  escaped = escaped:gsub("\\", "\\textbackslash{}")
  escaped = escaped:gsub("{", "\\{")
  escaped = escaped:gsub("}", "\\}")
  escaped = escaped:gsub("%$", "\\$")
  escaped = escaped:gsub("&", "\\&")
  escaped = escaped:gsub("#", "\\#")
  escaped = escaped:gsub("%%", "\\%%")
  escaped = escaped:gsub("_", "\\_")
  escaped = escaped:gsub("~", "\\textasciitilde{}")
  escaped = escaped:gsub("%^", "\\textasciicircum{}")
  return escaped
end

local function escape_latex_with_math(text)
  -- Preserves the $...$ math regions and does not escape them
  local result = {}
  local i = 1
  while i <= #text do
    local j = text:find("%$", i)
    if not j then
      table.insert(result, escape_latex(text:sub(i)))
      break
    end
    if j > i then
      table.insert(result, escape_latex(text:sub(i, j - 1)))
    end
    local k = text:find("%$", j + 1)
    if k then
      table.insert(result, text:sub(j, k))   -- region math verbatim
      i = k + 1
    else
      table.insert(result, "\\$")             -- $ orphelin
      i = j + 1
    end
  end
  return table.concat(result)
end

local function type_label(comment_type)
  if comment_type == "todo" then
    return "To-do"
  elseif comment_type == "note" then
    return "Note"
  elseif comment_type == "question" then
    return "Question"
  end
  return "Comment"
end

-- Parse a text string as Markdown and return its inlines, so that
-- $...$ math regions become proper pandoc.Math nodes rendered by MathJax/KaTeX.
local function parse_inlines(text)
  local doc = pandoc.read(text, "markdown")
  if doc.blocks and #doc.blocks > 0 then
    local first = doc.blocks[1]
    if first.t == "Para" or first.t == "Plain" then
      return first.content
    end
  end
  return pandoc.List({ pandoc.Str(text) })
end

local function build_html_inline(comment_type, comment_text, author, html_color, config)
  local classes = { "quarto-comment", "quarto-comment-inline", "comment-" .. comment_type }
  local attributes = {
    ["data-comment-type"] = comment_type,
    ["data-comment-inline"] = "true",
  }

  -- Add inline styles with color
  if html_color then
    local style_parts = {
      "--comment-color: " .. html_color,
      "color: " .. html_color,
      "border: 1px solid " .. html_color,
      "background: color-mix(in srgb, " .. html_color .. " 15%, #ffffff 85%)",
      "padding: 0.1rem 0.45rem",
      "border-radius: 0.4rem",
      "font-size: 0.9em",
      "display: inline-block",
      "vertical-align: baseline",
      "margin: 0 0.25em",
    }
    attributes.style = table.concat(style_parts, "; ") .. ";"
  end

  if author then
    local sanitized = sanitize_class(author.id)
    if sanitized then
      table.insert(classes, "comment-author-" .. sanitized)
    end
    attributes["data-comment-author"] = author.id
    attributes["data-comment-author-name"] = author.name
  end

  local content = pandoc.List()

  local icon_html = COMMENT_ICONS[comment_type] or COMMENT_ICONS.comment
  content:insert(pandoc.RawInline("html", icon_html .. " "))

  local show_author = config.show_author and author and author.name and author.name ~= ""
  if show_author then
    content:insert(pandoc.Strong { pandoc.Str(author.name .. ": ") })
  end
  content:extend(parse_inlines(comment_text))

  return pandoc.Span(content, pandoc.Attr("", classes, attributes))
end

local function build_html_block(comment_type, comment_text, author, html_color, config)
  -- Build the callout classes
  local callout_classes = {
    "quarto-comment-block",
    "callout",
    "callout-style-default",
    CALLOUT_VARIANTS[comment_type] or CALLOUT_VARIANTS.comment,
    "callout-titled",
  }

  local callout_attributes = {
    ["data-comment-type"] = comment_type,
  }

  -- Add inline styles with color
  if html_color then
    local style_parts = {
      "--comment-color: " .. html_color,
      "border-left: 0.25rem solid " .. html_color .. " !important",
      "background: color-mix(in srgb, " .. html_color .. " 12%, transparent 88%) !important"
    }
    callout_attributes.style = table.concat(style_parts, "; ") .. ";"
  end

  if author then
    local sanitized = sanitize_class(author.id)
    if sanitized then
      table.insert(callout_classes, "comment-author-" .. sanitized)
    end
    callout_attributes["data-comment-author"] = author.id
    callout_attributes["data-comment-author-name"] = author.name
  end

  local icon_html = COMMENT_ICONS[comment_type] or COMMENT_ICONS.comment
  local show_author = config.show_author and author and author.name and author.name ~= ""
  local label_text = show_author and author.name or type_label(comment_type)

  local title_inlines = pandoc.List()
  title_inlines:insert(pandoc.RawInline("html", icon_html))
  title_inlines:insert(pandoc.Str(" " .. label_text))

  local title_style = ""
  if html_color then
    title_style = "color: " .. html_color .. " !important; font-weight: 600;"
  end

  local title_container = pandoc.Div(
    { pandoc.Plain(title_inlines) },
    pandoc.Attr("", { "callout-title-container", "flex-fill" }, { style = title_style })
  )

  local header_style = ""
  if html_color then
    header_style = "background: color-mix(in srgb, " .. html_color .. " 15%, transparent) !important;"
  end
  local header = pandoc.Div(
    { title_container },
    pandoc.Attr("", { "callout-header", "d-flex", "align-content-center" }, { style = header_style })
  )

  local body = pandoc.Div(
    { pandoc.Para(parse_inlines(comment_text)) },
    pandoc.Attr("", { "callout-body-container", "callout-body" })
  )

  local callout = pandoc.Div(
    { header, body },
    pandoc.Attr("", callout_classes, callout_attributes)
  )

  -- Wrap in margin container
  local margin_wrapper = pandoc.Div(
    { callout },
    pandoc.Attr("", { "no-row-height", "column-margin", "column-container" })
  )

  return margin_wrapper
end

local function build_latex(comment_type, comment_text, author, inline, config)
  local latex_color = resolve_latex_color(comment_type, author)
  local options = {}
  if inline then
    table.insert(options, "inline")
  end
  if latex_color and latex_color ~= "" then
    -- For plain color names (auto-assigned via \definecolor), dilute the
    -- background so the note stays light; user-defined tints (e.g. "blue!20")
    -- are used as-is since they already carry the desired opacity.
    local base_color = latex_color:match("^([^!]+)") or latex_color
    local bg_color = latex_color:find("!", 1, true)
      and latex_color
      or  (latex_color .. "!20!white")
    table.insert(options, "color=" .. bg_color)
    table.insert(options, "bordercolor=" .. base_color)
    table.insert(options, "linecolor=" .. base_color)
  end
  local option_string = ""
  table.insert(options, "size=\\footnotesize")
  if #options > 0 then
    option_string = "[" .. table.concat(options, ",") .. "]"
  end

  local pieces = {}

  -- Icon: dilute the base color to 60% so the outline icon looks lighter
  -- and less visually heavy than a fully saturated glyph in print output.
  local icon_color = (latex_color:match("^([^!]+)") or latex_color) .. "!70"
  local fa_cmd = LATEX_FA_ICONS[comment_type] or LATEX_FA_ICONS.comment
  local emoji_cmd = "\\textcolor{" .. icon_color .. "}{" .. fa_cmd .. "}"
  table.insert(pieces, emoji_cmd .. " ")

  local show_author = config.show_author and author and author.name and author.name ~= ""
  if show_author then
    table.insert(pieces, "\\textbf{" .. escape_latex(author.name) .. ":} ")
  end
  table.insert(pieces, escape_latex_with_math(comment_text))
  local content = table.concat(pieces)

  local todo = string.format("\\todo%s{%s}", option_string, content)
  if inline then
    return pandoc.RawInline("tex", todo)
  else
    return pandoc.RawBlock("tex", todo)
  end
end

-- Build the LaTeX preamble snippet that widens the page for draft margin notes.
-- Guards against multiple injections with a LaTeX-level flag so it is safe to
-- call once per shortcode type (up to 4 times per document).
local function build_wide_margins_header(extra_margin, inner_pad, frame_color, frame_line)
  -- \makeatletter is placed OUTSIDE the \ifx guard so that \if@twoside (which
  -- requires @ to be a letter) is accessible in the guard body.
  -- \makeatother is placed AFTER \fi so it always runs regardless of branch.
  --
  -- IMPORTANT: \newif\ifFOO must NOT appear inside an \ifx...\fi guard because
  -- \ifFOO (starting with \if) is counted as an \if token by TeX's conditional
  -- scanner even in a skipped (false) branch, throwing off the \if/\fi balance.
  -- Solution: use \if@twoside directly, with \makeatletter/\makeatother in the
  -- shipout hook argument for runtime access.
  --
  -- The page widening itself is deferred to \AtBeginDocument. If the host loads
  -- geometry, it freezes \textwidth and the margins from \paperwidth at
  -- \AtEndPreamble. Enlarging \paperwidth in the preamble would make geometry
  -- recompute the text block from the already-widened paper, shifting the text
  -- block instead of leaving it in place. Deferring to \AtBeginDocument
  -- guarantees geometry reads the ORIGINAL \paperwidth, so the text block stays
  -- put with OR without geometry. We then bump BOTH registers:
  --   physical page primitive — \pdfpagewidth (pdfTeX/XeTeX) or \pagewidth (LuaTeX),
  --                             each guarded by \ifdefined so the unused one is skipped
  --   \paperwidth   — the reference of pgf/TikZ's `current page` node (and, on
  --                   LuaTeX, what the kernel syncs the physical page from)
  -- Without the \paperwidth bump, the TikZ background would draw at the old
  -- width and the grey zone would land over the text.
  local geom = table.concat({
    "\\makeatletter",                                -- outside guard, always runs
    "\\ifx\\qtc@widemargins@done\\undefined",
    "\\gdef\\qtc@widemargins@done{}%",
    "\\newlength{\\qtcExtraMargin}%",
    "\\setlength{\\qtcExtraMargin}{" .. extra_margin .. "}%",
    "\\newlength{\\qtcInnerPad}%",
    "\\setlength{\\qtcInnerPad}{" .. inner_pad .. "}%",
    "\\colorlet{qtcFrameColor}{" .. frame_color .. "}%",
    "\\colorlet{qtcLineColor}{" .. frame_line .. "}%",
    -- Defer the widening so geometry (if present) freezes the text block from
    -- the ORIGINAL paper width. On twoside, grow the outer margin only so the
    -- inner binding margin is kept; even pages put the annotation zone on the
    -- left (handled by the TikZ background below).
    "\\AtBeginDocument{%",
    "  \\makeatletter",
    -- Widen the physical page via the engine-specific primitive (guarded so the
    -- one absent on the current engine is silently skipped).
    "  \\ifdefined\\pdfpagewidth\\addtolength{\\pdfpagewidth}{\\qtcExtraMargin}\\fi%",
    "  \\ifdefined\\pagewidth\\addtolength{\\pagewidth}{\\qtcExtraMargin}\\fi%",
    "  \\if@twoside",
    "    \\addtolength{\\evensidemargin}{\\qtcExtraMargin}%",
    "  \\fi",
    "  \\addtolength{\\paperwidth}{\\qtcExtraMargin}%",
    -- Place notes inside the grey zone with inner_pad breathing room on each side.
    -- marginparsep = original right margin + inner_pad (left padding inside grey zone)
    -- marginparwidth = qtcExtraMargin - 2*inner_pad (right padding included)
    "  \\setlength{\\marginparsep}{\\dimexpr\\paperwidth-\\qtcExtraMargin-\\textwidth-\\oddsidemargin-1in+\\qtcInnerPad\\relax}%",
    "  \\setlength{\\marginparwidth}{\\dimexpr\\qtcExtraMargin-2\\qtcInnerPad\\relax}%",
    "  \\makeatother",
    "}%",
  }, "\n")

  -- TikZ background: grey zone + dashed separator + "Comments" label.
  -- \makeatletter/\makeatother inside the hook argument gives \if@twoside
  -- access at shipout time. The \if@twoside..\fi pairs are balanced so the
  -- false-branch scan of the outer \ifx guard remains correct.
  local frame = [[
\RequirePackage{eso-pic}%
\usetikzlibrary{calc}%
\AddToShipoutPictureBG{%
  \makeatletter
  \begin{tikzpicture}[remember picture,overlay]
    \if@twoside
      \ifodd\value{page}
        \fill[qtcFrameColor]
          ([xshift=-\qtcExtraMargin]current page.north east)
          rectangle (current page.south east);
        \draw[dashed,qtcLineColor,line width=0.5pt]
          ([xshift=-\qtcExtraMargin]current page.north east) --
          ([xshift=-\qtcExtraMargin]current page.south east);
        \node[anchor=north,font=\scriptsize\sffamily,text=qtcLineColor,yshift=-6pt]
          at ($(current page.north east)+(-0.5*\qtcExtraMargin,0)$)
          {Comments};
      \else
        \fill[qtcFrameColor]
          (current page.north west)
          rectangle ([xshift=\qtcExtraMargin]current page.south west);
        \draw[dashed,qtcLineColor,line width=0.5pt]
          ([xshift=\qtcExtraMargin]current page.north west) --
          ([xshift=\qtcExtraMargin]current page.south west);
        \node[anchor=north,font=\scriptsize\sffamily,text=qtcLineColor,yshift=-6pt]
          at ($(current page.north west)+(0.5*\qtcExtraMargin,0)$)
          {Comments};
      \fi
    \else
      \fill[qtcFrameColor]
        ([xshift=-\qtcExtraMargin]current page.north east)
        rectangle (current page.south east);
      \draw[dashed,qtcLineColor,line width=0.5pt]
        ([xshift=-\qtcExtraMargin]current page.north east) --
        ([xshift=-\qtcExtraMargin]current page.south east);
      \node[anchor=north,font=\scriptsize\sffamily,text=qtcLineColor,yshift=-6pt]
        at ($(current page.north east)+(-0.5*\qtcExtraMargin,0)$)
        {Comments};
    \fi
  \end{tikzpicture}%
  \makeatother
}%
\fi% closes \ifx\qtc@widemargins@done\undefined
\makeatother% outer \makeatother — always runs
]]

  return geom .. "\n" .. frame
end

function utils.render(args, kwargs, meta, forced_type)
  kwargs = kwargs or {}
  local comment_text = extract_text(args, kwargs)
  comment_text = trim(comment_text or "")

  if comment_text == "" then
    return pandoc.Null()
  end

  local comment_type = forced_type or kwargs.type or "comment"
  comment_type = tostring(comment_type):lower()
  if not VALID_TYPES[comment_type] then
    comment_type = "comment"
  end

  local author_id = kwargs.author and meta_to_string(kwargs.author):gsub("[^%w%-_]", "") or nil
  if author_id == "" then author_id = nil end
  local inline = parse_bool(kwargs.inline)

  -- Get configuration from meta
  local config = get_config(meta)

  -- If comments are disabled, return nothing
  if not config.enabled then
    return pandoc.Null()
  end

  -- Resolve author
  local author = nil
  if author_id then
    author = config.authors[author_id]
    if author then
      author = {
        id = author_id,
        name = author.name or author_id,
        color_html = author.color_html,
        color_latex = author.color_latex,
      }
    else
      author = {
        id = author_id,
        name = author_id,
      }
    end
  end

  -- Render based on format
  if is_html_format() then
    local html_color = resolve_html_color(comment_type, author)
    if inline then
      local result = build_html_inline(comment_type, comment_text, author, html_color, config)
      if not _fa_css_injected then
        _fa_css_injected = true
        result.content:insert(1, pandoc.RawInline("html", FA_CSS_LINK))
      end
      return result
    else
      local result = build_html_block(comment_type, comment_text, author, html_color, config)
      if not _fa_css_injected then
        _fa_css_injected = true
        result.content:insert(1, pandoc.RawBlock("html", FA_CSS_LINK))
      end
      return result
    end
  end

  if is_latex_format() then
    pcall(function()
      quarto.doc.use_latex_package("xcolor")
      quarto.doc.use_latex_package("todonotes")
      quarto.doc.use_latex_package("fontawesome5")
      if not _latex_tdo_cleared then
        _latex_tdo_cleared = true
        -- Cross-platform stale .tdo removal (shell commands are not portable)
        if pandoc.system then
          local ok, files = pcall(pandoc.system.list_directory, ".")
          if ok and files then
            for _, f in ipairs(files) do
              if f:match("%.tdo$") then os.remove(f) end
            end
          end
        end
      end
      if config.show_list and not _listoftodos_injected then
        _listoftodos_injected = true
        local fc = config.frame_color
        local fl = config.frame_line
        quarto.doc.use_latex_package("tcolorbox")
        quarto.doc.include_text("in-header", "\\tcbuselibrary{skins,breakable}\n")
        -- Wrap \listoftodos in a styled tcolorbox: grey background, dashed
        -- border with rounded corners. Guard against multiple injections.
        -- Output the section title outside the box, then wrap only the list
        -- content (\@starttoc{tdo}) in the tcolorbox so the title is not
        -- enclosed in the grey frame.
        quarto.doc.include_text("before-body",
          "\\makeatletter\\ifx\\@qtc@listoftodos@done\\undefined" ..
          "\\gdef\\@qtc@listoftodos@done{}" ..
          "\\@ifundefined{chapter}" ..
          "{\\section*{\\@todonotes@todolistname}}" ..
          "{\\chapter*{\\@todonotes@todolistname}}" ..
          "\\begin{tcolorbox}[enhanced," ..
          "colback={" .. fc .. "}," ..
          "colframe=white," ..
          "arc=5pt," ..
          "borderline={0.5pt}{0pt}{{" .. fl .. "},dashed}," ..
          "left=8pt,right=8pt,top=6pt,bottom=6pt," ..
          "breakable]" ..
          "\\@starttoc{tdo}" ..
          "\\end{tcolorbox}" ..
          "\\fi\\makeatother\n")
      end
      if not _latex_bezier_injected then
        _latex_bezier_injected = true
        quarto.doc.include_text("in-header", BEZIER_CONNECTION_LATEX)
      end
      if config.wide_margins and not _latex_wide_margins_injected then
        _latex_wide_margins_injected = true
        quarto.doc.include_text("in-header",
          build_wide_margins_header(
            config.extra_margin,
            config.inner_pad,
            config.frame_color,
            config.frame_line))
      end
    end)
    return build_latex(comment_type, comment_text, author, inline, config)
  end

  -- Fallback for other formats
  local label = type_label(comment_type)
  if author_id and author_id ~= "" then
    label = label .. " (" .. author_id .. ")"
  end
  local inline_content = pandoc.List()
  inline_content:extend({
    pandoc.Str(label .. ": "),
    pandoc.Str(comment_text),
  })

  if inline then
    return pandoc.Span(inline_content)
  else
    return pandoc.Div({ pandoc.Para(inline_content) })
  end
end

return utils.render
