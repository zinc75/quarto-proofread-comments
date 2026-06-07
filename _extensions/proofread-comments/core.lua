local utils = {}

local ok_quarto, quarto = pcall(require, "quarto")
if not ok_quarto then
  -- require() shadows the global; fall back to it when available
  quarto = _G["quarto"] or {}
  ok_quarto = type(quarto) == "table"
end

local FA_CSS_LINK = '<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.7.2/css/all.min.css" crossorigin="anonymous" referrerpolicy="no-referrer" />'

-- Styling for the numbered-mode HTML feature only (the in-text anchor and the
-- hover/:target highlight). Injected as a <style> because an extension's
-- formats.html.css is not applied when used as a filter, and because the rest of
-- the comment styling is emitted inline per element — so we deliberately do NOT
-- inject the whole comments.css (its base/dark-mode rules would double up with,
-- and override, those inline styles). The hover effect is deliberately light: a
-- small grow plus a thin outer ring in the author colour.
local ANCHOR_CSS = [[
<style>
.proofread-comment-anchor {
  text-decoration: none;
  font-size: 0.8em;
  vertical-align: super;
  padding: 0 0.1em;
  cursor: pointer;
  display: inline-block;
  transition: transform 0.12s ease-in-out, filter 0.12s ease-in-out;
}
/* The icon-only line for a block-context comment: take as little vertical room
   as possible so it does not space out the surrounding paragraphs. */
.proofread-comment-anchor-line {
  margin: 0 !important;
  line-height: 1;
}
.proofread-comment-anchor:hover,
.proofread-comment-anchor.proofread-comment-hl {
  transform: scale(1.4);
  filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.35));
}
/* A highlight (span of text with an attached note) IS its own anchor; hovering it
   (or its callout) draws a ring in the author colour. No scale — it wraps real
   text, which must not jump. */
.proofread-comment-highlight {
  cursor: pointer;
  transition: box-shadow 0.12s ease-in-out;
}
/* Hover/link a highlight: intensify the marker itself (a uniform inset tint of the
   author colour fills it) rather than drawing a box around it, which looks wrong on
   highlighted text. box-decoration-break clones it across line fragments. */
.proofread-comment-highlight:hover,
.proofread-comment-highlight.proofread-comment-hl {
  box-shadow: inset 0 0 0 100vmax color-mix(in srgb, var(--comment-color, #6c757d) 22%, transparent);
}
.proofread-comment-block.callout {
  transition: transform 0.12s ease-in-out, box-shadow 0.12s ease-in-out;
}
.proofread-comment-block.callout:target,
.proofread-comment-block.callout.proofread-comment-hl {
  transform: scale(1.08);
  box-shadow: 0 0 0 1px var(--comment-color, #6c757d),
              0 4px 12px rgba(0, 0, 0, 0.18);
}
</style>
]]

-- Hovering an in-text anchor highlights its margin callout (and vice versa). A
-- CSS sibling selector cannot reach across the DOM (anchor inside the paragraph,
-- callout hoisted elsewhere), so a tiny vanilla script wires the two by id.
local HTML_HOVER_SCRIPT = [[
<script>
(function () {
  function wire() {
    document.querySelectorAll(
      'a.proofread-comment-anchor, a.proofread-comment-highlight'
    ).forEach(function (a) {

      const hash = a.hash;
      if (!hash) return;

      const target = document.getElementById(hash.substring(1));
      if (!target) return;

      const on = function () {
        target.classList.add('proofread-comment-hl');
        a.classList.add('proofread-comment-hl');
      };

      const off = function () {
        target.classList.remove('proofread-comment-hl');
        a.classList.remove('proofread-comment-hl');
      };

      a.addEventListener('mouseenter', on);
      a.addEventListener('mouseleave', off);
      target.addEventListener('mouseenter', on);
      target.addEventListener('mouseleave', off);
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', wire);
  } else {
    wire();
  }
})();
</script>
]]
local _listoftodos_injected = false
local _latex_stale_cleared = false
local _latex_wide_margins_injected = false
local _latex_bezier_injected = false
local _latex_numbered_injected = false
local _latex_inline_flow_injected = false
local _latex_highlight_injected = false
local _latex_twocol_mpwidth_injected = false
local _latex_mparhack_injected = false

-- Global, document-order counter shared by all comments (inline and margin, both
-- formats), so numbering never skips. Assigned once per comment in utils.render.
local _qtc_number = 0

-- Replaces todonotes' default right-angle connector with a smooth dashed curve
-- and thinner stroke. Two refinements over a naive inline redefinition:
--
--   * Anchoring: the curve targets the TOP inner corner of the note box (its
--     icon/author line) rather than its vertical centre, dropped 3mm to land on
--     the first line — north west when the box sits to the right of the anchor,
--     north east when it sits to the left.
--
--   * Z-order: LaTeX has no z-index, and todonotes draws its connector inside
--     the margin box, whose specials can be painted over by boxes typeset
--     afterwards (tcolorbox callouts, code blocks, figures). We instead replay
--     the stroke in the shipout FOREGROUND (eso-pic FG), composited above all
--     page content.
--
-- Why this is non-trivial:
--   - todonotes positions notes with \marginpar[left]{right}, and the LaTeX
--     kernel typesets BOTH arguments into save-boxes; only the side that matches
--     the page is actually shipped. So both drawLineTo{Left,Right}Margin run for
--     every note, but only one margin box ever reaches a page.
--   - The side AND the page the kernel picks are decided in the output routine,
--     NOT when the \marginpar is read in the galley. So neither the page (parity)
--     nor the column (\if@firstcolumn) is reliably known at read time: a note
--     whose anchor sits near a page or column break is placed on the next page /
--     in the other column than the galley state suggests.
--   - todonotes reuses the names inText/inNote for every note, and a
--     remember-picture node referenced from another page does NOT clip cleanly.
--
-- Solution — side-keyed nodes, with the true page AND side recorded at shipout:
--   * \qtc@snap is called from both side macros. The RIGHT call saves a node
--     qtc@r@N (at the box's north-west corner), the LEFT call saves qtc@l@N (north
--     east), both keyed by todonotes' counter, plus qtc@t@N at inText. Only the
--     box the kernel actually ships records real positions; the other side's node
--     stays unplaced — so we must draw ONLY the shipped side (drawing the dead
--     side's node lands the curve at the page origin).
--   * Each call also writes the note's ship page AND its side to the .aux. The
--     write whatsit travels inside the margin box, so it fires only for the box
--     that ships and \thepage expands at shipout (exactly how \label captures a
--     page). So the recorded side is the TRUE side the kernel chose — right on a
--     oneside/odd page, left on a verso page, and by COLUMN in twocolumn — with
--     no galley-time guess (read-time \if@firstcolumn / page parity are both
--     unreliable when a note crosses a column or page break).
--   * The FG hook replays the whole (never-cleared) queue on every page; each
--     \qtc@drawconn draws once, only when the note's recorded page == the current
--     page, toward its recorded side's node.
--   This relies only on the two passes `remember picture` already needs.
--
-- Guarded by \ifx\qtc@bezier@done so the definitions run once even though the
-- snippet is included once per shortcode type. All \if...\fi pairs below are
-- balanced so the skipped-branch scan of the guard stays correct.
local BEZIER_CONNECTION_LATEX = [[
\makeatletter
\ifx\qtc@bezier@done\undefined
\gdef\qtc@bezier@done{}%
\RequirePackage{eso-pic}
\gdef\qtc@connlist{}
% Per-note ship page AND side, recovered from the .aux on the next run (written
% by \qtc@snap from inside the shipped margin box). \qtc@noteinfo{id}{page}{side}
% defines \qtc@pg@<id> and \qtc@side@<id>. Used to replay each connector on the
% page that actually carries its note and toward the side the kernel actually
% chose — both decided in the output routine, not when the \marginpar was read.
\gdef\qtc@noteinfo#1#2#3{%
  \expandafter\gdef\csname qtc@pg@#1\endcsname{#2}%
  \expandafter\gdef\csname qtc@side@#1\endcsname{#3}}
% Replay all queued connectors in the shipout foreground; each \qtc@drawconn
% self-gates so only those whose note ships on THIS page actually draw (a
% remember-picture node referenced from another page does NOT clip cleanly).
% The queue is NOT cleared per page: a note can be pushed to a later page than
% the one TeX was assembling when its \marginpar was read, so we cannot assume
% "queued now => ships on the next shipout". Instead each connector carries its
% note's true ship page (\qtc@pg@<id>, from the .aux) and is drawn only on that
% page. \qtc@curpage exposes the current page for that comparison.
\AddToShipoutPictureFG{%
  \makeatletter
  \edef\qtc@curpage{\thepage}%
  \qtc@connlist
  \makeatother
}%
% Replay one connector (#1 = note id). Drawn only when the note's recorded ship
% page equals the current page (so the remembered nodes are all on this page),
% toward the recorded side's node — qtc@r@id (box north-west) when the kernel put
% the note in the right margin, qtc@l@id (north east) for the left. Only the
% shipped side's node has a real position, so we must never draw the other one.
\newcommand{\qtc@drawconn}[1]{%
  % This note's recorded ship page (undefined -> \relax on the first pass, before
  % the .aux exists, so nothing is drawn until page and side are known).
  \edef\qtc@np{\csname qtc@pg@#1\endcsname}%
  \ifx\qtc@np\qtc@curpage
    \begin{tikzpicture}[remember picture,overlay]%
      \edef\qtc@cl{\csname qtc@col@#1\endcsname}%
      \edef\qtc@sd{\csname qtc@side@#1\endcsname}%
      \node[circle,draw=\qtc@cl,fill=white,minimum size=4pt,inner sep=0pt,%
            line width=1pt,outer sep=2pt] (qtc@cc) at (qtc@t@#1) {};%
      \if r\qtc@sd
        \draw[draw=\qtc@cl,line width=0.5pt,dashed]%
          (qtc@cc) to[out=0,in=180] (qtc@r@#1);%
      \else
        \draw[draw=\qtc@cl,line width=0.5pt,dashed]%
          (qtc@cc) to[out=180,in=0] (qtc@l@#1);%
      \fi
    \end{tikzpicture}%
  \fi
}%
% Snapshot the current note's endpoints into side-keyed, uniquely-named nodes,
% record its ship page + side, and queue the draw. #1 = side (l/r), #2 = box
% anchor. Called from BOTH \marginpar arguments, so each side's node is created
% in its own box; only the box the kernel ships records real positions and fires
% the write, so the recorded {page,side} is the true placement. The draw is
% queued once per note (guarded by \qtc@q@<id>); the side is resolved at draw
% time from the recorded value. The aux line guards itself so a stale .aux cannot
% crash a later run with comments disabled (no \qtc@noteinfo defined then).
\newcommand{\qtc@snap}[2]{%
  \edef\qtc@id{\the\value{@todonotes@numberoftodonotes}}%
  \begin{tikzpicture}[remember picture,overlay]%
    \coordinate (qtc@t@\qtc@id) at ([yshift=-0.25cm,xshift=-0.1cm]inText);%
    \coordinate (qtc@#1@\qtc@id) at ([yshift=-3mm]#2);%
  \end{tikzpicture}%
  \protected@write\@auxout{}{\string\@ifundefined{qtc@noteinfo}{}{\string\qtc@noteinfo{\qtc@id}{\thepage}{#1}}}%
  \global\expandafter\edef\csname qtc@col@\qtc@id\endcsname{\@todonotes@currentlinecolor}%
  \@ifundefined{qtc@q@\qtc@id}{%
    \global\expandafter\gdef\csname qtc@q@\qtc@id\endcsname{}%
    \xdef\qtc@tmp{\noexpand\qtc@drawconn{\qtc@id}}%
    \expandafter\g@addto@macro\expandafter\qtc@connlist\expandafter{\qtc@tmp}%
  }{}%
}%
\renewcommand{\@todonotes@drawLineToRightMargin}{\if@todonotes@line\qtc@snap{r}{inNote.north west}\fi}%
\renewcommand{\@todonotes@drawLineToLeftMargin}{\if@todonotes@line\qtc@snap{l}{inNote.north east}\fi}%
\fi
\makeatother
]]

-- Numbered-anchor mode (default). No connecting line: a clickable icon+number
-- marker is drawn at the in-text anchor and linked (hyperref) to the margin box.
--
-- The marker is drawn in the shipout FOREGROUND (eso-pic FG), above the page,
-- so it is visible (an inline overlay would sit behind the text) and takes no
-- flow space — exactly like the old connector circle. The marker's full LaTeX
-- (icon, number, colour, \hyperlink) is prebuilt per note in Lua and handed over
-- in \qtc@marker; the snapshot hook copies it into a per-note slot and queues the
-- draw. Because the marker sits at the text (not the box), there is no side and
-- no box node to track — only the in-text anchor and its page (recorded via the
-- .aux so the marker replays on the page that actually carries the anchor, even
-- if todonotes floats the box elsewhere). All \if...\fi pairs are balanced for
-- the skipped-branch scan of the \ifx guard.
local NUMBERED_MARKER_LATEX = [[
\makeatletter
\ifx\qtc@numbered@done\undefined
\gdef\qtc@numbered@done{}%
\RequirePackage{eso-pic}
\RequirePackage{graphicx}
\providecommand{\hypertarget}[2]{#2}\providecommand{\hyperlink}[2]{#2}%
\providecommand{\Hy@raisedlink}[1]{#1}%
\newcounter{qtccomment}%
\providecommand{\qtchl}{0}% per-note flag: 1 = the comment highlights a span of text
% Raise a jump target to the top of its line so clicking lands on the box's first
% line, not a couple of lines lower.
\gdef\qtcraise#1{\Hy@raisedlink{#1}}%
\gdef\qtc@mklist{}
\gdef\qtc@mkpagedef#1#2{\expandafter\gdef\csname qtc@pg@#1\endcsname{#2}}
\AddToShipoutPictureFG{%
  \makeatletter
  \edef\qtc@curpage{\thepage}%
  \qtc@mklist
  \makeatother
}%
% Draw one marker (#1 = todonotes note id) on its recorded page only: a small
% (<= line) clickable icon+number node just below the in-text anchor qtc@t@<id>,
% plus a short arrow pointing up to the exact insertion point. Number, colour and
% icon were frozen per note in \qtc@snapmk (the live counter/macros would hold the
% LAST note's values by shipout).
\newcommand{\qtc@drawmk}[1]{%
  \edef\qtc@np{\csname qtc@pg@#1\endcsname}%
  \ifx\qtc@np\qtc@curpage
    \edef\qtc@n{\csname qtc@num@#1\endcsname}%
    \edef\qtc@c{\csname qtc@col@#1\endcsname}%
    \edef\qtc@ishl{\csname qtc@hl@#1\endcsname}%
    \begin{tikzpicture}[remember picture,overlay]%
      % \resizebox scales the marker to <= a line. graphicx scales via \hb@xt@,
      % which mparhack redefines for its column bookkeeping; in twocolumn that
      % redefinition makes \resizebox here (run inside the shipout foreground) throw
      % "Illegal unit of measure". Restore the kernel \hb@xt@ for this box only when
      % mparhack is present (\mph@orig@hb@xt@ is its saved original).
      \if1\qtc@ishl
        % HIGHLIGHT: the highlighted span is already the in-text anchor, so the
        % marker just rides on it — a small icon+number set as a superscript right at
        % the end of the span, with NO arrow (an arrow to a single point makes no
        % sense for a range).
        \node[anchor=base west,inner sep=0pt] (qtc@m@#1)
          at ([yshift=0.18\baselineskip,xshift=-0.28em]qtc@t@#1)
          {\begingroup\ifdefined\mph@orig@hb@xt@\let\hb@xt@\mph@orig@hb@xt@\fi\resizebox{!}{0.38\baselineskip}{\hyperlink{qtc-\qtc@n}{\textcolor{\qtc@c}{\csname qtc@ico@#1\endcsname\,\textbf{\qtc@n}}}}\endgroup};%
      \else
        % INSERTION: icon+number just below the in-text anchor, plus a short arrow
        % pointing up to the exact insertion point.
        \node[anchor=north,inner sep=0pt] (qtc@m@#1)
          at ([yshift=-0.30\baselineskip,xshift=-0.12cm]qtc@t@#1)
          {\begingroup\ifdefined\mph@orig@hb@xt@\let\hb@xt@\mph@orig@hb@xt@\fi\resizebox{!}{0.4\baselineskip}{\hyperlink{qtc-\qtc@n}{\textcolor{\qtc@c}{\csname qtc@ico@#1\endcsname\,\textbf{\qtc@n}}}}\endgroup};%
        \draw[\qtc@c,line width=0.3pt,->,>=stealth,shorten >=0.5pt]
          (qtc@m@#1.north) -- (qtc@t@#1);%
      \fi
    \end{tikzpicture}%
  \fi
}%
% Snapshot the in-text anchor and freeze this note's number (document-order
% LaTeX counter), colour and icon into per-note slots; queue the draw. Called
% from both \marginpar arguments, but only the shipped box records a valid anchor
% and fires the write; queued once per note. \qtccol / \qtcico are @-free macros
% set just before \todo (visible here); the number is the qtccomment counter,
% which at this point equals this note's value.
\newcommand{\qtc@snapmk}{%
  \edef\qtc@id{\the\value{@todonotes@numberoftodonotes}}%
  \begin{tikzpicture}[remember picture,overlay]%
    \coordinate (qtc@t@\qtc@id) at (inText);%
  \end{tikzpicture}%
  \protected@write\@auxout{}{\string\@ifundefined{qtc@mkpagedef}{}{\string\qtc@mkpagedef{\qtc@id}{\thepage}}}%
  \global\expandafter\edef\csname qtc@num@\qtc@id\endcsname{\arabic{qtccomment}}%
  \global\expandafter\edef\csname qtc@col@\qtc@id\endcsname{\qtccol}%
  \global\expandafter\edef\csname qtc@hl@\qtc@id\endcsname{\qtchl}%
  \global\expandafter\let\csname qtc@ico@\qtc@id\endcsname\qtcico
  \@ifundefined{qtc@q@\qtc@id}{%
    \global\expandafter\gdef\csname qtc@q@\qtc@id\endcsname{}%
    \xdef\qtc@tmp{\noexpand\qtc@drawmk{\qtc@id}}%
    \expandafter\g@addto@macro\expandafter\qtc@mklist\expandafter{\qtc@tmp}%
  }{}%
}%
\renewcommand{\@todonotes@drawLineToRightMargin}{\qtc@snapmk}%
\renewcommand{\@todonotes@drawLineToLeftMargin}{\qtc@snapmk}%
\fi
\makeatother
]]

-- True-inline comments (inline_style: flow, default). \todo[inline] is a near-
-- block box that breaks the text flow; this renders an inline comment as a
-- coloured, rounded badge that flows and breaks across lines AND columns, like
-- the HTML inline badge. Built on soul + soulpos + tcolorbox: \ulposdef runs an
-- action per line-fragment of the marked text (giving \ulwidth and start/end
-- flags), drawing an on-line tcolorbox of that width per fragment, with rounded
-- corners only at the true ends (sharp where the text wraps) — so the fragments
-- read as one continuous frame. Technique: https://tex.stackexchange.com/a/697157
--
-- soul handles plain text, math and \textbf inside the marked text; its one
-- soul-hostile command is \textcolor, which the caller isolates in an \mbox for
-- the coloured icon+number prefix (see build_latex). soul must load before
-- soulpos. Guarded so it is injected once.
local INLINE_FLOW_LATEX = [[
\makeatletter
\ifx\qtc@inline@done\undefined
\gdef\qtc@inline@done{}%
\usepackage{soul}
\usepackage{soulpos}
\usepackage{tcolorbox}
% soulpos schedules the generation of its .upb position file by writing a token
% (\ulp@afterend) to the .aux with a DEFERRED \write, executed on the final .aux
% re-read. mparhack rewrites the output routine and swallows that deferred write
% on the last page, so .upb is never produced and the flowing badge boxes vanish
% (the .upa data is fine — these are \immediate writes). Re-schedule the token with
% an IMMEDIATE \write, which mparhack cannot drop, but only when mparhack is loaded
% (otherwise soulpos' own mechanism already works, and we avoid generating .upb
% twice). At \AtEndDocument time the package is loaded-or-not for sure.
\AtEndDocument{\@ifpackageloaded{mparhack}{\immediate\write\@auxout{\string\ulp@afterend}}{}}%
\colorlet{qtcul}{gray}
\newtcbox{\qtc@inlinebox}[1][]{%
  on line, arc=1pt, outer arc=2pt,
  colback=qtcul!12!white, colframe=qtcul!75!black,
  boxsep=0pt, left=1pt, right=-0.5pt, top=0.5pt, bottom=0.5pt,
  boxrule=0pt, toprule=0.6pt, bottomrule=0.6pt, #1}%
\newcommand\qtcinline[1][gray]{\colorlet{qtcul}{#1}\qtc@inline@}%
\ulposdef\qtc@inline@[xoffset-start=2pt]{%
  \ifulstarttype{0}%
    {\tcbset{qtcULside/.append style={leftrule=0.6pt}}}%
    {\tcbset{qtcULside/.append style={leftrule=0pt,sharp corners=west}}}%
  \ifulendtype{0}%
    {\tcbset{qtcULside/.append style={rightrule=0.6pt,right=-0.5pt}}}%
    {\tcbset{qtcULside/.append style={rightrule=0pt,sharp corners=east,right=-2pt}}}%
  \qtc@inlinebox[qtcULside]{\vphantom{Ap}\rule{\ulwidth}{0pt}}%
}%
\fi
\makeatother
]]

-- Marker-pen highlight for a highlighted span of text (the non-empty .comment span)
-- in PDF. Built on soulpos (like the inline badge): \ulposdef runs the marker
-- drawing PER LINE-FRAGMENT, so a highlight breaks cleanly across lines, COLUMNS
-- and pages — each fragment gets its own slanted, random-stepped parallelogram of
-- width \ulwidth. (highlightx, the previous backend, drew a single quad between two
-- tikz marks and bled diagonally across a column/page break.) \ifulstarttype /
-- \ifulendtype slant only the TRUE ends; wrapped edges stay flush so the fragments
-- read as one continuous stroke. The maths path (\qtcHF) stays pure-tikz. soulpos is
-- provided by INLINE_FLOW_LATEX (injected alongside via needs_soul). Guarded once.
local HIGHLIGHT_LATEX = [[
\makeatletter
\ifx\qtc@highlight@done\undefined
\gdef\qtc@highlight@done{}%
\usepackage{tikz}
\usetikzlibrary{calc,decorations.pathmorphing,tikzmark}
\colorlet{hlcolback}{yellow}% fallback only; callers always pass an explicit colour
\tikzset{borderformula/.style={decorate,decoration={random steps,amplitude=0.85pt,segment length=1.1em}}}
\newcommand\qtcHL[1][hlcolback]{\colorlet{qtchlc}{#1}\qtcHL@}
\ulposdef\qtcHL@[xoffset-start=0pt]{%
  \pgfmathsetlengthmacro{\HLs}{(1+4*rnd)*1pt}%
  \ifulstarttype{0}{\edef\HLls{-\HLs}}{\def\HLls{0pt}}%
  \ifulendtype{0}{\let\HLre\HLs}{\def\HLre{0pt}}%
  \edef\HLw{\the\dimexpr\ulwidth\relax}%
  \edef\HLtop{\the\dimexpr\ht\strutbox+0.05\ht\strutbox\relax}%
  \edef\HLbot{-\the\dimexpr\dp\strutbox+0.05\dp\strutbox\relax}%
  \tikz[overlay,baseline]{%
    \fill[qtchlc,borderformula,fill opacity=0.25]
      ($(0pt,\HLtop)+(\HLls,0pt)$) --
      ($(\HLw,\HLtop)+(\HLre,0pt)$) --
      (\HLw,\HLbot) --
      (0pt,\HLbot) -- cycle;%
  }%
}%
% Maths highlight (\qtcHF[colour]{maths}) drawn to MATCH the text marker: a slanted,
% random-stepped parallelogram around the formula box, rather than \HighlightFormula's
% hard-coded rectangle. The formula is set inline as a node, the tinted parallelogram
% is filled around it (0.25 opacity), and the maths is redrawn on top so it stays
% crisp. Works for inline maths, \displaystyle and systems (no soul involved).
\NewDocumentCommand\qtcHF{ O{hlcolback} m }{%
  \tikzmarknode[inner sep=1pt,outer sep=0pt]{qtcF}{\ensuremath{#2}}%
  \begin{tikzpicture}[remember picture,overlay]%
    \pgfmathsetlengthmacro{\HLslant}{(1+4*rnd)*1pt}%
    \pgfmathsetlengthmacro{\HLextra}{(0.9*rnd)*1pt}%
    \fill[#1,borderformula,fill opacity=0.25]
      ([xshift=-1pt+\HLslant,yshift=1pt]qtcF.north west) --
      ([xshift=1pt+\HLslant+\HLextra,yshift=1pt]qtcF.north east) --
      ([xshift=1pt,yshift=-1pt]qtcF.south east) --
      ([xshift=-1pt,yshift=-1pt]qtcF.south west) -- cycle;%
    \node[inner sep=1pt,outer sep=0pt] at (qtcF.center) {\ensuremath{#2}};%
  \end{tikzpicture}%
}%
\fi
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
    show_names = true,
    show_list = false,
    connector = "numbered",
    inline_style = "flow",
    wide_margins = true,
    marginpar_fix = true,
    twocolumn_marginparwidth = "auto",
    extra_margin = "6.5cm",
    inner_pad = "0.3cm",
    frame_color = "gray!10",
    frame_line = "gray!60",
    list_title = "Annotations",
    reviewers = {},
  }

  -- Naming map (kept for reference; the LaTeX prefix is deliberately NOT renamed):
  --   * meta config key  -> extensions["quarto-proofread-comments"] (user-facing)
  --   * HTML classes      -> proofread-comment* (build_html_*, ANCHOR_CSS, HOVER script)
  --   * LaTeX prefix `qtc` / `\qtc@…` and auto colours `cmt-…` -> KEPT (internal only,
  --     and embedded in fragile mparhack/soulpos/highlightx machinery).
  --   * Extension dir `_extensions/proofread-comments/`, files core.lua / filter.lua.
  local config_meta = meta and meta.extensions and meta.extensions["quarto-proofread-comments"]
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

  if config_meta.show_names ~= nil then
    local show_names = meta_to_bool(config_meta.show_names)
    if show_names ~= nil then
      config.show_names = show_names
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
  if config_meta.marginpar_fix ~= nil then
    local mf = meta_to_bool(config_meta.marginpar_fix)
    if mf ~= nil then config.marginpar_fix = mf end
  end
  if config_meta.connector then
    local c = meta_to_string(config_meta.connector):lower()
    if c == "bezier" or c == "numbered" then
      config.connector = c
    end
  end
  if config_meta.inline_style then
    local s = meta_to_string(config_meta.inline_style):lower()
    if s == "flow" or s == "box" then
      config.inline_style = s
    end
  end
  if config_meta.twocolumn_marginparwidth then
    config.twocolumn_marginparwidth = meta_to_string(config_meta.twocolumn_marginparwidth)
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
  if config_meta.list_title then
    config.list_title = meta_to_string(config_meta.list_title)
  end

  if config_meta.reviewers then
    local reviewers_meta = config_meta.reviewers
    -- MetaMap can be accessed as a table with pandoc >= 2.17
    for reviewer_key, reviewer_meta in pairs(reviewers_meta) do
      if type(reviewer_meta) == "table" then
        local reviewer = {}
        if reviewer_meta.name then
          reviewer.name = meta_to_string(reviewer_meta.name)
        end
        if reviewer_meta.color_html then
          reviewer.color_html = meta_to_string(reviewer_meta.color_html)
        end
        if reviewer_meta.color_latex then
          reviewer.color_latex = meta_to_string(reviewer_meta.color_latex)
        end
        config.reviewers[reviewer_key] = reviewer
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
  -- No author: a neutral grey regardless of the comment type (anonymous comment).
  return DEFAULT_HTML_COLORS.comment
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
        -- Make the list-of-todos self-contained: each \listoftodos entry written
        -- to the .tdo references this colour by name (e.g. cmt-sm). A .tdo left
        -- over from an earlier render (e.g. a failed compile that never reached
        -- the cleanup, then an author/colour change) would otherwise reference an
        -- undefined cmt-* colour and crash xcolor at \@starttoc{tdo}. Emitting a
        -- matching \providecolor into the .tdo itself keeps every entry resolvable
        -- regardless of the current author set (\providecolor never clobbers the
        -- real \definecolor above).
        quarto.doc.include_text("in-header",
          "\\AtBeginDocument{\\addtocontents{tdo}{\\protect\\providecolor{"
          .. color_name .. "}{HTML}{" .. hex .. "}}}\n")
      end)
    end
    return color_name
  end

  -- No author: a neutral GREY regardless of the comment type (an anonymous comment),
  -- defined from the same hex as the HTML default so both formats match exactly.
  local gray_hex = DEFAULT_HTML_COLORS.comment:gsub("^#", "")
  local color_name = "qtc-anon"
  if not _latex_colors_declared[color_name] then
    _latex_colors_declared[color_name] = true
    pcall(function()
      quarto.doc.include_text("in-header",
        "\\definecolor{" .. color_name .. "}{HTML}{" .. gray_hex .. "}\n")
      quarto.doc.include_text("in-header",
        "\\AtBeginDocument{\\addtocontents{tdo}{\\protect\\providecolor{"
        .. color_name .. "}{HTML}{" .. gray_hex .. "}}}\n")
    end)
  end
  return color_name
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

local function build_html_inline(comment_type, comment_text, author, html_color, config, number)
  local classes = { "proofread-comment", "proofread-comment-inline", "comment-" .. comment_type }
  local attributes = {
    ["data-comment-type"] = comment_type,
    ["data-comment-inline"] = "true",
  }

  -- Add inline styles with color
  if html_color then
    local style_parts = {
      "--comment-color: " .. html_color,
      -- Body text stays the default colour (black) for readability and to match
      -- the margin callouts; only the icon and the author label are coloured.
      "border: 1px solid " .. html_color,
      "background: color-mix(in srgb, " .. html_color .. " 15%, #ffffff 85%)",
      "padding: 0.1rem 0.45rem",
      "border-radius: 0.4rem",
      "font-size: 0.9em",
      -- display:inline (not inline-block) so a long inline comment FLOWS and
      -- breaks across lines; box-decoration-break:clone repeats the border,
      -- background and padding on each line fragment (rounded ends per fragment),
      -- the CSS equivalent of the LaTeX soulpos badge.
      "display: inline",
      "-webkit-box-decoration-break: clone",
      "box-decoration-break: clone",
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

  -- Icon in the author colour (body text stays black).
  local icon_html = COMMENT_ICONS[comment_type] or COMMENT_ICONS.comment
  local colour_style = html_color and (' style="color:' .. html_color .. '"') or ""
  content:insert(pandoc.RawInline("html",
    "<span" .. colour_style .. ">" .. icon_html .. "</span> "))

  -- Author label: bold, in the author colour.
  local show_names = config.show_names and author and author.name and author.name ~= ""
  if show_names then
    local strong = pandoc.Strong { pandoc.Str(author.name .. ": ") }
    if html_color then
      content:insert(pandoc.Span({ strong }, pandoc.Attr("", {}, { style = "color: " .. html_color })))
    else
      content:insert(strong)
    end
  end
  content:extend(parse_inlines(comment_text))

  return pandoc.Span(content, pandoc.Attr("", classes, attributes))
end

-- Builds the inner callout Div (without the column-margin wrapper). Shared by
-- the block path (wrapped in a div.column-margin) and the inline path (wrapped
-- in a span.column-margin so it does not break the host paragraph).
local function build_html_callout(comment_type, comment_text, author, html_color, config, number)
  -- Build the callout classes
  local callout_classes = {
    "proofread-comment-block",
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
  local show_names = config.show_names and author and author.name and author.name ~= ""
  local label_text = show_names and author.name or type_label(comment_type)

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

  -- An id (qtc-<n>) lets an in-text anchor link to this callout (HTML).
  local callout_id = number and ("qtc-" .. number) or ""
  local callout = pandoc.Div(
    { header, body },
    pandoc.Attr(callout_id, callout_classes, callout_attributes)
  )

  return callout
end

-- Small in-text anchor (HTML): the comment's icon in the author colour, linked
-- to its margin callout (#qtc-<n>). Returns nil when there is no number to link.
local function build_anchor(comment_type, html_color, number)
  if not number then return nil end
  local icon_html = COMMENT_ICONS[comment_type] or COMMENT_ICONS.comment
  local attrs = {}
  if html_color and html_color ~= "" then attrs.style = "color: " .. html_color end
  return pandoc.Link(
    { pandoc.RawInline("html", icon_html) },
    "#qtc-" .. number, "",
    pandoc.Attr("", { "proofread-comment-anchor", "comment-" .. comment_type }, attrs)
  )
end

local function build_html_block(comment_type, comment_text, author, html_color, config, number, with_anchor)
  -- Wrap the callout in the margin container (block context).
  local margin = pandoc.Div(
    { build_html_callout(comment_type, comment_text, author, html_color, config, number) },
    pandoc.Attr("", { "no-row-height", "column-margin", "column-container" })
  )
  -- For a stand-alone (block-context) comment, also drop a clickable in-text
  -- icon in the main column so every margin comment is reachable from the text,
  -- like the mid-sentence ones. (The hoist path passes with_anchor=false because
  -- it inserts the anchor itself, in the middle of the host sentence.)
  if with_anchor then
    local anchor = build_anchor(comment_type, html_color, number)
    if anchor then
      -- Wrap the callout in a Div so Quarto lays it out as a page-columns grid
      -- (body + margin). The in-text icon goes in a small classed Div (the grid
      -- body item) rather than a bare <a> (which, as a direct grid child, would
      -- stretch to the whole column width) or a <p> (whose paragraph margins
      -- would punch a vertical hole between the surrounding paragraphs). The CSS
      -- zeroes that line's margins so it barely takes any room.
      local anchor_line = pandoc.Div(
        { pandoc.Plain({ anchor }) },
        pandoc.Attr("", { "proofread-comment-anchor-line" })
      )
      return pandoc.Div({ anchor_line, margin })
    end
  end
  return margin
end

-- Inline-context placeholder: a non-inline comment placed mid-sentence must
-- render as the margin callout, but a block <div> inside a paragraph breaks the
-- text flow (and an inline .column-margin makes Quarto grid the paragraph). The
-- robust answer is to HOIST the callout out of the paragraph as a sibling
-- div.column-margin (the block mechanism, which works) via the companion
-- comment-hoist.lua filter. The shortcode therefore returns a visible inline
-- badge (graceful fallback if the filter is not active) carrying the data the
-- filter needs; the marker class proofread-comment-hoist tells the filter to
-- replace it with the hoisted margin callout.
local function build_html_inline_placeholder(comment_type, comment_text, author, html_color, config, number)
  local span = build_html_inline(comment_type, comment_text, author, html_color, config, number)
  span.classes:insert("proofread-comment-hoist")
  span.attributes["data-comment-text"] = comment_text
  span.attributes["data-comment-color"] = html_color or ""
  span.attributes["data-comment-show-names"] = config.show_names and "true" or "false"
  span.attributes["data-comment-number"] = number and tostring(number) or ""
  return span
end

-- Build the small in-text anchor (HTML): the comment's icon in the author colour,
-- linked to its hoisted callout (#qtc-<n>). Used by comment-hoist.lua to replace
-- a mid-sentence placeholder, so the reader gets a clickable mark in the text and
-- the full comment floats to the margin.
function utils.build_anchor_from_span(span)
  local a = span.attributes
  local number = a["data-comment-number"]
  if not number or number == "" then return nil end
  return build_anchor(a["data-comment-type"] or "comment", a["data-comment-color"], number)
end

-- Rebuild the margin callout Div from a hoist placeholder's data attributes.
-- Used by comment-hoist.lua, hence exposed on the module table.
function utils.build_hoisted_div(span)
  local a = span.attributes
  local comment_type = a["data-comment-type"] or "comment"
  local comment_text = a["data-comment-text"] or ""
  local html_color = a["data-comment-color"]
  if html_color == "" then html_color = nil end
  local author = nil
  if a["data-comment-author"] and a["data-comment-author"] ~= "" then
    author = { id = a["data-comment-author"], name = a["data-comment-author-name"] }
  end
  local config = { show_names = (a["data-comment-show-names"] == "true") }
  local number = a["data-comment-number"]
  if number == "" then number = nil end
  return build_html_block(comment_type, comment_text, author, html_color, config, number)
end

local function build_latex(comment_type, comment_text, author, inline, config, number, is_highlight)
  local latex_color = resolve_latex_color(comment_type, author)
  local base_color = latex_color:match("^([^!]+)") or latex_color
  -- "numbered" is the default; "bezier" reproduces the legacy connecting line and
  -- shows NO numbers at all (margin or inline).
  local numbered = (config.connector ~= "bezier")

  -- Icon: dilute the base color to 70% inside the box so the outline glyph looks
  -- lighter than a fully saturated one in print.
  local fa_cmd = LATEX_FA_ICONS[comment_type] or LATEX_FA_ICONS.comment
  local icon_box = "\\textcolor{" .. base_color .. "!70}{" .. fa_cmd .. "}"
  local show_names = config.show_names and author and author.name and author.name ~= ""
  -- Author label: bold, in the author colour (convention shared by every type).
  -- `author_colored` is for non-soul contexts (margin, inline box, .tdo caption);
  -- `author_flow` wraps it in \mbox so the soul-hostile \textcolor survives the
  -- soulpos flow badge (the short name stays unbroken — fine).
  local name_bold = show_names and ("\\textbf{" .. escape_latex(author.name) .. ":}") or nil
  local author_colored = name_bold
    and ("\\textcolor{" .. base_color .. "}{" .. name_bold .. "} ") or ""
  local author_flow = name_bold
    and ("\\mbox{\\textcolor{" .. base_color .. "}{" .. name_bold .. "}} ") or ""
  local body = escape_latex_with_math(comment_text)
  -- The displayed number is a LaTeX counter (qtccomment), stepped in DOCUMENT
  -- order at typeset time (the Lua counter follows shortcode-expansion order,
  -- which misnumbers mid-sentence/inline comments). Numbered mode only.
  local num = "\\textcolor{" .. base_color .. "}{\\textbf{\\arabic{qtccomment}}}"

  local function colour_opts(t)
    if latex_color and latex_color ~= "" then
      -- For plain color names (auto-assigned via \definecolor), dilute the
      -- background so the note stays light; user-defined tints (e.g. "blue!20")
      -- are used as-is since they already carry the desired opacity.
      local bg = latex_color:find("!", 1, true) and latex_color or (latex_color .. "!20!white")
      table.insert(t, "color=" .. bg)
      table.insert(t, "bordercolor=" .. base_color)
      table.insert(t, "linecolor=" .. base_color)
    end
  end

  -- ---- INLINE COMMENTS ----
  if inline then
    local step = numbered and "\\stepcounter{qtccomment}" or ""
    -- Coloured prefix: icon (+ number when numbered), isolated from soul by \mbox
    -- (\textcolor is soul's one hostile command; the icon/bold are fine).
    local prefix_inner = numbered and (fa_cmd .. "\\,\\textbf{\\arabic{qtccomment}}") or fa_cmd
    if config.inline_style == "box" then
      -- Legacy todonotes inline box.
      local opts = { "inline", "size=\\footnotesize" }
      colour_opts(opts)
      local content = icon_box .. (numbered and ("\\," .. num) or "") .. " " .. author_colored .. body
      return pandoc.RawInline("tex",
        step .. "\\todo[" .. table.concat(opts, ",") .. "]{" .. content .. "}")
    end
    -- flow (default): a soulpos badge that flows and breaks like the HTML inline
    -- badge. The author \textbf and the text + math flow through soul; only the
    -- coloured prefix is \mbox-isolated. The frame colour is the author colour.
    -- \footnotesize matches the margin notes. No forced space around the badge:
    -- it behaves like a word, so spacing comes from the source (soulpos'
    -- xoffset-start keeps the frame off the preceding glyph even with no space).
    local content = "\\mbox{\\textcolor{" .. base_color .. "}{" .. prefix_inner .. "}}"
      .. " " .. author_flow .. body
    -- \qtcinline does not go through \todo, so register the comment in the
    -- list-of-todos ourselves (same caption format as a margin note), so inline
    -- comments appear in the list like the box mode does.
    local list_cap = icon_box .. (numbered and ("\\," .. num) or "") .. " " .. author_colored .. body
    local tdo = "\\addcontentsline{tdo}{todo}{" .. list_cap .. "}"
    return pandoc.RawInline("tex",
      step .. tdo .. "{\\footnotesize\\qtcinline[" .. base_color .. "]{" .. content .. "}}")
  end

  -- ---- MARGIN COMMENTS ----
  local options = {}
  if numbered then table.insert(options, "noline") end
  colour_opts(options)
  table.insert(options, "size=\\footnotesize")

  if not numbered then
    -- Bezier mode: plain todonotes note, no number; the line/circle is drawn by
    -- BEZIER_CONNECTION_LATEX.
    local content = icon_box .. " " .. author_colored .. body
    -- RawInline (not RawBlock): the filter places every comment at an inline
    -- position, and todonotes handles a mid-paragraph \todo natively, so the host
    -- paragraph is no longer split. Works equally for a comment alone on its line.
    return pandoc.RawInline("tex", "\\todo[" .. table.concat(options, ",") .. "]{" .. content .. "}")
  end

  -- Numbered mode. Caption (plain, robust) feeds the .tdo / list-of-todos with
  -- the correct document-order number; the displayed box raises the jump target
  -- onto the first line, then forces a break so a long author never overflows a
  -- narrow margin. \qtccol/\qtcico feed the foreground-marker machinery
  -- (\qtc@snapmk); \def/\stepcounter do not typeset, so \todo still backs up its
  -- vertical space and the note takes no extra line.
  table.insert(options, "caption={" .. icon_box .. "\\," .. num .. " " .. author_colored .. body .. "}")
  local content = "\\qtcraise{\\hypertarget{qtc-\\arabic{qtccomment}}{}}"
    .. icon_box .. "\\," .. num .. "\\\\" .. author_colored .. body
  local setup = "\\def\\qtccol{" .. base_color .. "}\\def\\qtcico{" .. fa_cmd
    .. "}\\def\\qtchl{" .. (is_highlight and "1" or "0") .. "}\\stepcounter{qtccomment}%\n"
  -- RawInline (not RawBlock): inline placement by the filter; \def/\stepcounter
  -- do not typeset, and todonotes handles the mid-paragraph \todo natively, so the
  -- host paragraph is never split (and a comment alone on its line still works).
  return pandoc.RawInline("tex", setup .. "\\todo[" .. table.concat(options, ",") .. "]{" .. content .. "}")
end

-- Build the LaTeX preamble snippet that gives todonotes a usable marginpar
-- width in TWO-COLUMN layouts (non-wide path). In single column the class
-- default is fine and we emit nothing — the whole body is gated on
-- \if@twocolumn, so single-column output is byte-for-byte unchanged.
--
-- In twocolumn the kernel places a note in the LEFT page margin for the first
-- column and the RIGHT page margin for the second, both using the single
-- \marginparwidth register. The class default is far too narrow there, so the
-- note text gets crushed. We set it AtBeginDocument (after geometry, if loaded,
-- has frozen \textwidth and the margins) to a value that fits.
--
-- width = "auto": take the TIGHTER of the two physical side margins, minus
-- \marginparsep and a 2mm safety pad, so the box fits whichever margin it lands
-- in. Otherwise use the literal value the user supplied.
local function build_twocolumn_marginparwidth_header(width_spec)
  local set_width
  if not width_spec or width_spec == "" or width_spec:lower() == "auto" then
    set_width = table.concat({
      "    \\newlength{\\qtc@mpL}\\newlength{\\qtc@mpR}%",
      "    \\setlength{\\qtc@mpL}{\\dimexpr 1in+\\oddsidemargin-\\marginparsep-2mm\\relax}%",
      "    \\setlength{\\qtc@mpR}{\\dimexpr \\paperwidth-1in-\\oddsidemargin-\\textwidth-\\marginparsep-2mm\\relax}%",
      "    \\ifdim\\qtc@mpL<\\qtc@mpR \\setlength{\\marginparwidth}{\\qtc@mpL}%",
      "    \\else \\setlength{\\marginparwidth}{\\qtc@mpR}\\fi",
    }, "\n")
  else
    set_width = "    \\setlength{\\marginparwidth}{" .. width_spec .. "}%"
  end

  return table.concat({
    "\\makeatletter",
    "\\AtBeginDocument{%",
    "  \\if@twocolumn",
    set_width,
    "  \\fi}%",
    "\\makeatother",
  }, "\n")
end

-- Build the LaTeX preamble snippet that widens the page for draft margin notes.
-- Guards against multiple injections with a LaTeX-level flag so it is safe to
-- call once per shortcode type (up to 4 times per document).
local function build_wide_margins_header(extra_margin, inner_pad, frame_color, frame_line, label)
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
  -- Per-page toggling: the widening is applied through \qtcWideOn / \qtcWideOff
  -- rather than as a one-shot, so a host can scope it (e.g. per chapter). Both
  -- the wide and the normal register values are kept; \qtcWideOn applies the wide
  -- set, \qtcWideOff restores the originals, and \ifqtcWide gates the grey zone.
  -- Since \pdfpagewidth/\paperwidth are read at \shipout and \chapter issues a
  -- \clearpage, toggles land on page boundaries. \AtBeginDocument applies the
  -- default (\qtcWideOn) once, so the out-of-the-box behaviour is unchanged.
  --
  -- \newif\ifqtcWide is placed OUTSIDE the \ifx guard: \ifqtcWide begins with
  -- \if and would be miscounted by TeX's conditional scanner in the guard's
  -- skipped (false) branch (same reason \newif must not sit inside the guard).
  -- The \if...\fi pairs inside the macros below are balanced, so the skipped
  -- scan stays correct.
  local geom = table.concat({
    "\\makeatletter",                                -- outside guard, always runs
    "\\newif\\ifqtcWide",                            -- outside guard (scanner safety)
    "\\qtcWidetrue",
    "\\ifx\\qtc@widemargins@done\\undefined",
    "\\gdef\\qtc@widemargins@done{}%",
    "\\newlength{\\qtcExtraMargin}%",
    "\\setlength{\\qtcExtraMargin}{" .. extra_margin .. "}%",
    "\\newlength{\\qtcInnerPad}%",
    "\\setlength{\\qtcInnerPad}{" .. inner_pad .. "}%",
    "\\colorlet{qtcFrameColor}{" .. frame_color .. "}%",
    "\\colorlet{qtcLineColor}{" .. frame_line .. "}%",
    -- Saved originals and precomputed wide values for the toggle (filled in
    -- \AtBeginDocument, where \paperwidth is still the original).
    "\\newlength{\\qtc@origPaperwidth}%",
    "\\newlength{\\qtc@origOddsidemargin}%",
    "\\newlength{\\qtc@origEvensidemargin}%",
    "\\newlength{\\qtc@origMarginparsep}%",
    "\\newlength{\\qtc@origMarginparwidth}%",
    "\\newlength{\\qtc@wideMarginparsep}%",
    "\\newlength{\\qtc@wideMarginparwidth}%",
    -- \qtcWideOn: widen the physical page (engine-specific primitive, \ifdefined
    -- guarded) and \paperwidth (pgf `current page` ref), then place notes in the
    -- grey zone. TWOCOLUMN differs from single column: the kernel puts first-column
    -- notes in the LEFT page margin and second-column notes in the RIGHT, so we
    -- must reserve a zone on BOTH sides. We grow the paper by 2*extra and shift the
    -- text block right by extra (oddsidemargin += extra), which leaves `extra` of
    -- new paper on each side while preserving \textwidth and the columns. The same
    -- \marginparsep / \marginparwidth then land both sides' notes symmetrically in
    -- their zones (verified for a centred text block). Single column keeps the
    -- original behaviour (grow right only; outer edge on twoside) in the \else.
    "\\gdef\\qtcWideOn{%",
    "  \\qtcWidetrue",
    "  \\if@twocolumn",
    "    \\setlength{\\paperwidth}{\\dimexpr\\qtc@origPaperwidth+2\\qtcExtraMargin\\relax}%",
    "    \\ifdefined\\pdfpagewidth\\setlength{\\pdfpagewidth}{\\dimexpr\\qtc@origPaperwidth+2\\qtcExtraMargin\\relax}\\fi%",
    "    \\ifdefined\\pagewidth\\setlength{\\pagewidth}{\\dimexpr\\qtc@origPaperwidth+2\\qtcExtraMargin\\relax}\\fi%",
    "    \\setlength{\\oddsidemargin}{\\dimexpr\\qtc@origOddsidemargin+\\qtcExtraMargin\\relax}%",
    "    \\setlength{\\evensidemargin}{\\dimexpr\\qtc@origEvensidemargin+\\qtcExtraMargin\\relax}%",
    "  \\else",
    "    \\setlength{\\paperwidth}{\\dimexpr\\qtc@origPaperwidth+\\qtcExtraMargin\\relax}%",
    "    \\ifdefined\\pdfpagewidth\\setlength{\\pdfpagewidth}{\\dimexpr\\qtc@origPaperwidth+\\qtcExtraMargin\\relax}\\fi%",
    "    \\ifdefined\\pagewidth\\setlength{\\pagewidth}{\\dimexpr\\qtc@origPaperwidth+\\qtcExtraMargin\\relax}\\fi%",
    "    \\if@twoside\\setlength{\\evensidemargin}{\\dimexpr\\qtc@origEvensidemargin+\\qtcExtraMargin\\relax}\\fi%",
    "  \\fi",
    "  \\setlength{\\marginparsep}{\\qtc@wideMarginparsep}%",
    "  \\setlength{\\marginparwidth}{\\qtc@wideMarginparwidth}%",
    "}%",
    -- \qtcWideOff: restore the original A4/normal registers (no widening, and the
    -- grey zone is suppressed because \ifqtcWide is now false).
    "\\gdef\\qtcWideOff{%",
    "  \\qtcWidefalse",
    "  \\setlength{\\paperwidth}{\\qtc@origPaperwidth}%",
    "  \\ifdefined\\pdfpagewidth\\setlength{\\pdfpagewidth}{\\qtc@origPaperwidth}\\fi%",
    "  \\ifdefined\\pagewidth\\setlength{\\pagewidth}{\\qtc@origPaperwidth}\\fi%",
    "  \\if@twocolumn",
    "    \\setlength{\\oddsidemargin}{\\qtc@origOddsidemargin}%",
    "    \\setlength{\\evensidemargin}{\\qtc@origEvensidemargin}%",
    "  \\else",
    "    \\if@twoside\\setlength{\\evensidemargin}{\\qtc@origEvensidemargin}\\fi%",
    "  \\fi",
    "  \\setlength{\\marginparsep}{\\qtc@origMarginparsep}%",
    "  \\setlength{\\marginparwidth}{\\qtc@origMarginparwidth}%",
    "}%",
    -- Defer to \AtBeginDocument so geometry (if present) freezes \textwidth from
    -- the ORIGINAL \paperwidth. Capture originals + wide marginpar values, then
    -- apply the default (wide on) once. marginparsep collapses to
    -- origPaperwidth - textwidth - oddsidemargin - 1in + innerPad (the extra
    -- margin cancels); marginparwidth = extraMargin - 2*innerPad.
    "\\AtBeginDocument{%",
    "  \\makeatletter",
    "  \\setlength{\\qtc@origPaperwidth}{\\paperwidth}%",
    "  \\setlength{\\qtc@origOddsidemargin}{\\oddsidemargin}%",
    "  \\setlength{\\qtc@origEvensidemargin}{\\evensidemargin}%",
    "  \\setlength{\\qtc@origMarginparsep}{\\marginparsep}%",
    "  \\setlength{\\qtc@origMarginparwidth}{\\marginparwidth}%",
    "  \\setlength{\\qtc@wideMarginparsep}{\\dimexpr\\qtc@origPaperwidth-\\textwidth-\\oddsidemargin-1in+\\qtcInnerPad\\relax}%",
    "  \\setlength{\\qtc@wideMarginparwidth}{\\dimexpr\\qtcExtraMargin-2\\qtcInnerPad\\relax}%",
    "  \\qtcWideOn",
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
  \ifqtcWide
  \begin{tikzpicture}[remember picture,overlay]
    \if@twocolumn
      % Two-column: a zone on BOTH sides (left-column notes go left, right-column
      % notes go right), no page-parity alternation. Right zone:
      \fill[qtcFrameColor]
        ([xshift=-\qtcExtraMargin]current page.north east)
        rectangle (current page.south east);
      \draw[dashed,qtcLineColor,line width=0.5pt]
        ([xshift=-\qtcExtraMargin]current page.north east) --
        ([xshift=-\qtcExtraMargin]current page.south east);
      \node[anchor=north,font=\scriptsize\sffamily,text=qtcLineColor,yshift=-6pt]
        at ($(current page.north east)+(-0.5*\qtcExtraMargin,0)$)
        {Comments};
      % Left zone:
      \fill[qtcFrameColor]
        (current page.north west)
        rectangle ([xshift=\qtcExtraMargin]current page.south west);
      \draw[dashed,qtcLineColor,line width=0.5pt]
        ([xshift=\qtcExtraMargin]current page.north west) --
        ([xshift=\qtcExtraMargin]current page.south west);
      \node[anchor=north,font=\scriptsize\sffamily,text=qtcLineColor,yshift=-6pt]
        at ($(current page.north west)+(0.5*\qtcExtraMargin,0)$)
        {Comments};
    \else
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
    \fi% closes \if@twoside
    \fi% closes \if@twocolumn
  \end{tikzpicture}%
  \fi% closes \ifqtcWide (grey zone gating)
  \makeatother
}%
\fi% closes \ifx\qtc@widemargins@done\undefined
\makeatother% outer \makeatother — always runs
]]

  -- The grey zone's heading reuses the comment-list title (config.list_title,
  -- default "Annotations") so the zone and the list agree. Replace the placeholder
  -- text in the TikZ nodes (via a function so a % in the label is not magic).
  local heading = escape_latex(label or "Annotations")
  frame = frame:gsub("{Comments}", function() return "{" .. heading .. "}" end)
  return geom .. "\n" .. frame
end

-- Inject the LaTeX preamble this document needs (packages + the connector/list/
-- wide-margin machinery), once each via module guards. Shared by render() (inserted
-- comments) and render_highlight(). `needs_soul` forces the soul/soulpos block (the
-- flowing inline badge AND the \hl highlight need soul).
local function inject_latex(config, needs_soul)
  pcall(function()
    quarto.doc.use_latex_package("xcolor")
    quarto.doc.use_latex_package("todonotes")
    quarto.doc.use_latex_package("fontawesome5")
    -- mparhack fixes the classic \marginpar side bug: a note anchored near a page
    -- (or column) break can be placed on the wrong margin (then clipped by our wide
    -- zone), which made a comment at the END of a twoside document vanish, and in
    -- twocolumn dropped notes onto the text. mparhack records each marginpar's true
    -- side in the .aux and replays it next run. Loaded in BOTH one- and two-column:
    -- the twocolumn clash it used to cause ("Illegal unit of measure" under Quarto's
    -- rerun loop) was its \hb@xt@ redefinition breaking the \resizebox in our shipout
    -- marker — now isolated at the source (\mph@orig@hb@xt@ in NUMBERED_MARKER_LATEX).
    -- mparhack rewrites the output routine and can clash with an arbitrary host
    -- template (e.g. it drops a deferred \write soulpos needs — see the \ulp@afterend
    -- rescue in INLINE_FLOW_LATEX), so it is opt-OUT via `marginpar_fix: false`.
    if config.marginpar_fix and not _latex_mparhack_injected then
      _latex_mparhack_injected = true
      quarto.doc.include_text("in-header",
        "\\makeatletter\\@ifpackageloaded{mparhack}{}{"
        .. "\\RequirePackage{mparhack}}\\makeatother")
    end
    if not _latex_stale_cleared then
      _latex_stale_cleared = true
      -- Remove this extension's stale auxiliary files from a previous render
      -- (cross-platform; once per render, before LaTeX runs): *.tdo (list of todos)
      -- and *.upa/*.upb (soulpos positions). They are recreated for THIS document
      -- by the LaTeX passes; this only sweeps leftovers (notably from a previous
      -- FAILED render, which Quarto does not clean) so the directory stops piling up.
      if pandoc.system then
        local ok, files = pcall(pandoc.system.list_directory, ".")
        if ok and files then
          for _, f in ipairs(files) do
            if f:match("%.tdo$") or f:match("%.upa$") or f:match("%.upb$") then
              os.remove(f)
            end
          end
        end
      end
    end
    if config.show_list and not _listoftodos_injected then
      _listoftodos_injected = true
      local fc = config.frame_color
      local fl = config.frame_line
      local lt = escape_latex(config.list_title or "Annotations")
      quarto.doc.use_latex_package("tcolorbox")
      quarto.doc.include_text("in-header", "\\tcbuselibrary{skins,breakable}\n")
      -- Wrap \listoftodos in a styled tcolorbox (grey bg, dashed rounded border).
      -- The section title (config.list_title, default "Annotations") is output
      -- OUTSIDE the box; only the list content (\@starttoc{tdo}) is wrapped. Guarded
      -- against multiple injections.
      quarto.doc.include_text("before-body",
        "\\makeatletter\\ifx\\@qtc@listoftodos@done\\undefined" ..
        "\\gdef\\@qtc@listoftodos@done{}" ..
        "\\@ifundefined{chapter}" ..
        "{\\section*{" .. lt .. "}}" ..
        "{\\chapter*{" .. lt .. "}}" ..
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
    if config.connector == "bezier" then
      if not _latex_bezier_injected then
        _latex_bezier_injected = true
        quarto.doc.include_text("in-header", BEZIER_CONNECTION_LATEX)
      end
    else
      -- Numbered mode: the clickable icon+number marker, drawn in the shipout
      -- foreground and linked to the box via hyperref.
      if not _latex_numbered_injected then
        _latex_numbered_injected = true
        quarto.doc.use_latex_package("hyperref")
        quarto.doc.include_text("in-header", NUMBERED_MARKER_LATEX)
      end
    end
    -- soul/soulpos/tcolorbox + \qtcinline: needed by the flowing inline badge and by
    -- the \hl highlight (both go through soul).
    if needs_soul and not _latex_inline_flow_injected then
      _latex_inline_flow_injected = true
      quarto.doc.include_text("in-header", INLINE_FLOW_LATEX)
    end
    if config.wide_margins and not _latex_wide_margins_injected then
      _latex_wide_margins_injected = true
      quarto.doc.include_text("in-header",
        build_wide_margins_header(
          config.extra_margin,
          config.inner_pad,
          config.frame_color,
          config.frame_line,
          config.list_title))
    end
    -- Non-wide path: give todonotes a usable marginpar width in twocolumn (the wide
    -- path sets \marginparwidth itself, so this is mutually exclusive).
    if not config.wide_margins and not _latex_twocol_mpwidth_injected then
      _latex_twocol_mpwidth_injected = true
      quarto.doc.include_text("in-header",
        build_twocolumn_marginparwidth_header(config.twocolumn_marginparwidth))
    end
  end)
end

function utils.render(args, kwargs, meta, forced_type, context)
  kwargs = kwargs or {}
  local comment_text = extract_text(args, kwargs)
  comment_text = trim(comment_text or "")

  -- Return nil (not pandoc.Null()) for "render nothing": render() is now called
  -- only from the filter, which treats nil as "drop". A pandoc.Null() block does
  -- not reliably classify as empty outside the shortcode runtime, which would make
  -- the filter inject its HTML assets for a document with no visible comments.
  if comment_text == "" then
    return nil
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

  -- If comments are disabled, return nothing (nil = drop; see note above).
  if not config.enabled then
    return nil
  end

  -- Resolve author
  local author = nil
  if author_id then
    author = config.reviewers[author_id]
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

  -- Assign this comment's global, document-order number (inline and margin
  -- alike, so the sequence never skips). Used as the displayed identifier and,
  -- for margin comments, the hyperlink id.
  _qtc_number = _qtc_number + 1
  local number = _qtc_number

  -- Render based on format. NB: HTML assets (Font Awesome, ANCHOR_CSS,
  -- HTML_HOVER_SCRIPT) are NOT injected here — the unified filter (comments.lua)
  -- injects them once, deterministically, after the document walk. render() only
  -- builds nodes; only the LaTeX preamble (per-comment, config-dependent) is still
  -- injected below, which works because render() now runs from the post-quarto
  -- filter.
  if is_html_format() then
    local html_color = resolve_html_color(comment_type, author)
    if inline then
      return build_html_inline(comment_type, comment_text, author, html_color, config, number)
    elseif context == "inline" then
      -- Non-inline comment placed mid-sentence: emit an inline placeholder badge
      -- carrying hoist data. The filter replaces it with a sibling margin callout
      -- (hoist); without the filter it degrades to a visible inline badge.
      return build_html_inline_placeholder(comment_type, comment_text, author, html_color, config, number)
    else
      -- Non-inline comment on its own line (block context): margin callout Div
      -- plus an in-text icon anchor in the main column.
      return build_html_block(comment_type, comment_text, author, html_color, config, number, true)
    end
  end

  if is_latex_format() then
    inject_latex(config, inline and config.inline_style ~= "box")
    return build_latex(comment_type, comment_text, author, inline, config, number)
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

-- Highlight an existing span of text and attach a margin note to it. `content` is
-- the list of inlines to highlight; `attrs` is the comment span's attribute table
-- (note / type / author). Returns { inlines = <left in the text flow>, blocks =
-- <sibling blocks> }. The highlight itself is the clickable anchor (no separate
-- in-text icon), reusing the numbered/hover/link machinery of inserted comments.
function utils.render_highlight(content, attrs, meta)
  attrs = attrs or {}
  local note_text = trim(meta_to_string(attrs.remark) or "")
  local comment_type = (attrs.type and attrs.type ~= "" and tostring(attrs.type):lower()) or "comment"
  if not VALID_TYPES[comment_type] then comment_type = "comment" end
  local author_id = attrs.by and meta_to_string(attrs.by):gsub("[^%w%-_]", "") or nil
  if author_id == "" then author_id = nil end

  local config = get_config(meta)
  if not config.enabled then
    -- Disabled: leave the highlighted text bare, drop the note.
    return { inlines = content, blocks = {} }
  end

  local author = nil
  if author_id then
    local a = config.reviewers[author_id]
    if a then
      author = { id = author_id, name = a.name or author_id,
                 color_html = a.color_html, color_latex = a.color_latex }
    else
      author = { id = author_id, name = author_id }
    end
  end

  _qtc_number = _qtc_number + 1
  local number = _qtc_number

  if is_html_format() then
    local html_color = resolve_html_color(comment_type, author)
    -- The highlight IS the anchor: a link wrapping the content, with a coloured
    -- background that flows/breaks across lines (box-decoration-break:clone),
    -- linked to its margin callout (#qtc-<n>) and hover-paired with it.
    -- A marker-pen highlight: an irregular multi-stop gradient (denser near the two
    -- ends, lighter in the middle) tinted with the author colour, rather than a flat
    -- fill. box-decoration-break:clone repeats it per line fragment so it flows and
    -- breaks like a real highlighter. No text-shadow (kept subtle, text stays clean).
    local function mix(pct) return "color-mix(in srgb, " .. html_color .. " " .. pct .. "%, transparent)" end
    local bg = "linear-gradient(104deg, " ..
      mix(0) .. " 0.9%, " .. mix(50) .. " 2.4%, " .. mix(24) .. " 5.8%, " ..
      mix(10) .. " 93%, " .. mix(38) .. " 96%, " .. mix(0) .. " 98%)"
    -- A highlight that wraps DISPLAY maths (e.g. [$$…$$]{.comment …}, a system) is
    -- tall; an inline background only paints the line box and leaves the maths
    -- sticking out. Make such a highlight inline-block so the background covers the
    -- whole formula. Text / inline-maths highlights stay display:inline with
    -- box-decoration-break:clone so they flow and break across lines.
    local has_display = false
    for _, c in ipairs(content) do
      if c.t == "Math" and c.mathtype == "DisplayMath" then has_display = true break end
    end
    local style_parts = {
      "--comment-color: " .. html_color,
      "background: " .. bg,
      "border-radius: 0.4rem",
      "text-decoration: none",
      "color: inherit",
    }
    if has_display then
      table.insert(style_parts, "display: inline-block")
      table.insert(style_parts, "vertical-align: middle")
      table.insert(style_parts, "padding: 0.15em 0.35em")
    else
      table.insert(style_parts, "padding: 0.05em 0.2em")
      table.insert(style_parts, "-webkit-box-decoration-break: clone")
      table.insert(style_parts, "box-decoration-break: clone")
    end
    local style = table.concat(style_parts, "; ") .. ";"
    local hl = pandoc.Link(content, "#qtc-" .. number, "",
      pandoc.Attr("", { "proofread-comment-highlight", "comment-" .. comment_type },
        { style = style, ["data-comment-type"] = comment_type }))
    -- Margin callout carrying the note; with_anchor=false because the highlight is
    -- already the anchor (no separate in-text icon).
    local margin = build_html_block(comment_type, note_text, author, html_color, config, number, false)
    return { inlines = { hl }, blocks = { margin }, rendered = true }
  end

  if is_latex_format() then
    inject_latex(config, true) -- todonotes/connector/mparhack + soul/soulpos (\qtcHL)
    if not _latex_highlight_injected then
      _latex_highlight_injected = true
      pcall(function() quarto.doc.include_text("in-header", HIGHLIGHT_LATEX) end)
    end
    local latex_color = resolve_latex_color(comment_type, author)
    local base = latex_color:match("^([^!]+)") or latex_color
    -- soulpos marker-pen highlight: bg = the author colour at 0.25 opacity (a
    -- light tint). It flows and breaks across lines, columns and pages. The content goes
    -- through soul (plain text, math and \emph/\textbf are fine; \textcolor is
    -- soul-hostile — a documented limit for highlighted text). The margin note
    -- follows as a \todo, exactly like an inserted margin comment, so it gets the
    -- same marker / number / list entry.
    -- Split the highlighted content into segments: runs of text/inline markup go
    -- through soulpos via \qtcHL (drawn per line fragment, so it breaks across
    -- lines/columns/pages), while each Math node is highlighted with the dedicated \qtcHF
    -- (it boxes the formula via tikz, NOT soul, so \frac, \mathbf, equation systems
    -- and display maths all work). Adjacent segments abut into one visual highlight
    -- — same author colour at the same light opacity. So the user can highlight
    -- prose, an inline formula, or a whole $$…$$ system without thinking about it.
    local inlines = pandoc.List()
    local run = {}
    -- Emit one text run as a \HighlightText, but with leading/trailing spaces moved
    -- OUTSIDE the box, as ordinary source spaces between segments. Two reasons: a
    -- space left INSIDE soul's argument right before a \qtcHF makes soul restart glued
    -- to the formula and mis-detect the end of that line (the highlight then stops
    -- short); and emitting the boundary space in the source preserves the original
    -- word/formula spacing exactly.
    local function is_space(n) return n.t == "Space" or n.t == "SoftBreak" or n.t == "LineBreak" end
    local function flush_text()
      local lead, trail = false, false
      while #run > 0 and is_space(run[1]) do table.remove(run, 1); lead = true end
      while #run > 0 and is_space(run[#run]) do table.remove(run); trail = true end
      if lead then inlines:insert(pandoc.RawInline("tex", " ")) end
      if #run > 0 then
        inlines:insert(pandoc.RawInline("tex", "\\qtcHL[" .. base .. "]{"))
        for _, n in ipairs(run) do inlines:insert(n) end
        inlines:insert(pandoc.RawInline("tex", "}"))
      end
      if trail then inlines:insert(pandoc.RawInline("tex", " ")) end
      run = {}
    end
    for _, c in ipairs(content) do
      if c.t == "Math" then
        flush_text()
        local disp = (c.mathtype == "DisplayMath") and "\\displaystyle " or ""
        inlines:insert(pandoc.RawInline("tex",
          "\\qtcHF[" .. base .. "]{" .. disp .. c.text .. "}"))
      else
        table.insert(run, c)
      end
    end
    flush_text()
    inlines:insert(build_latex(comment_type, note_text, author, false, config, number, true))
    return { inlines = inlines, blocks = {}, rendered = true }
  end

  -- Other formats: keep the text, append the note in brackets.
  local out = pandoc.List()
  out:extend(content)
  if note_text ~= "" then
    out:insert(pandoc.Str(" [" .. type_label(comment_type) .. ": " .. note_text .. "]"))
  end
  return { inlines = out, blocks = {}, rendered = true }
end

-- Exposed for the unified filter (comments.lua), the single injector of the
-- document-level HTML assets (one Font Awesome <link>, one ANCHOR_CSS <style>,
-- one HTML_HOVER_SCRIPT <script>).
utils.FA_CSS_LINK = FA_CSS_LINK
utils.ANCHOR_CSS = ANCHOR_CSS
utils.HTML_HOVER_SCRIPT = HTML_HOVER_SCRIPT

return utils
