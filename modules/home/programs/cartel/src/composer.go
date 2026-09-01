package main

import (
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Composer-state guard (ported from the bash/awk backend, condensed from
// firstmate). Lets the daemon push a result into the patrón's pane ONLY when your
// composer is empty, and defer while you are mid-typing - so a report is never
// typed over an in-progress prompt. herdr exposes no cursor-row primitive, so we
// read the pane's styled tail, DROP de-emphasised "ghost" suggestion text
// (claude/codex render a dim hint in the empty composer that a plain read can't
// tell from real input), find the bottom-most composer row, and classify
// empty|pending|unknown.

var (
	// Bottom-most bare AGENT prompt glyphs: ❯ (claude) and › (codex).
	bareRe = regexp.MustCompile(`^(❯|›)`)
	// Known empty-composer placeholder.
	idleRe = regexp.MustCompile(`^Type a message\.\.\.$`)
	// A CSI escape (strip for structural row detection; ghost text is KEPT so a
	// border/prompt glyph stays visible).
	csiRe = regexp.MustCompile("\x1b\\[[0-9;:?]*[a-zA-Z]")
)

func composerLines() int {
	n, err := strconv.Atoi(envOr("CARTEL_COMPOSER_LINES", "20"))
	if err != nil || n <= 0 {
		return 20
	}
	return n
}

func ghostLumaMax() int {
	n, err := strconv.Atoi(envOr("CARTEL_COMPOSER_GHOST_LUMA_MAX", "128"))
	if err != nil {
		return 128
	}
	return n
}

// stripANSI drops every CSI escape, leaving plain text.
func stripANSI(s string) string { return csiRe.ReplaceAllString(s, "") }

func sgrCode(v string) string {
	if idx := strings.IndexByte(v, ':'); idx >= 0 {
		v = v[:idx]
	}
	if v == "" {
		return "0"
	}
	return v
}

// skipColorPayload advances past an extended-color payload following an
// 38/48/58 selector, so its numeric operands aren't re-read as SGR codes.
func skipColorPayload(a []string, p int) int {
	if strings.IndexByte(a[p], ':') >= 0 {
		return p // ITU colon-form: the whole spec is one token
	}
	if p >= len(a)-1 {
		return p
	}
	mode := a[p+1]
	if strings.IndexByte(mode, ':') >= 0 {
		return p + 1
	}
	switch sgrCode(mode) {
	case "5":
		return p + 2
	case "2":
		return p + 4
	}
	return p + 1
}

func atoiLead(s string) int {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	if i == 0 {
		return 0
	}
	n, _ := strconv.Atoi(s[:i])
	return n
}

func luma(r, g, b int) int { return (299*r + 587*g + 114*b) / 1000 }

// fg38IsDark reports whether a `38;...`/`38:...` truecolor foreground selector at
// index p resolves to a dark color (a grok placeholder heuristic).
func fg38IsDark(a []string, p, lumaMax int) bool {
	spec := a[p]
	if strings.IndexByte(spec, ':') >= 0 {
		f := strings.Split(spec, ":")
		if len(f) < 5 || f[1] != "2" {
			return false
		}
		return luma(atoiLead(f[len(f)-3]), atoiLead(f[len(f)-2]), atoiLead(f[len(f)-1])) < lumaMax
	}
	if p+1 >= len(a) || a[p+1] != "2" || p+4 >= len(a) {
		return false
	}
	return luma(atoiLead(a[p+2]), atoiLead(a[p+3]), atoiLead(a[p+4])) < lumaMax
}

// stripGhost extracts "real typed content" from a styled composer row: it drops
// dim/faint runs (SGR 2 - claude/codex ghost text) and dark/muted TRUECOLOR
// foreground runs (grok placeholder), keeping normal-intensity real input.
// Assumes a dark terminal theme. Operates on bytes (as the LC_ALL=C awk did), so
// multibyte glyphs outside a ghost run are preserved verbatim.
func stripGhost(line string, lumaMax int) string {
	var out []byte
	dim := false
	darkfg := false
	n := len(line)
	for i := 0; i < n; {
		c := line[i]
		if c == 0x1b {
			j := i + 1
			if j < n && line[j] == '[' {
				j++
				start := j
				for j < n {
					cc := line[j]
					if cc >= '@' && cc <= '~' {
						break
					}
					j++
				}
				params := line[start:j]
				var final byte
				if j < n {
					final = line[j]
				}
				if final == 'm' {
					if params == "" {
						params = "0"
					}
					a := strings.Split(params, ";")
					for p := 0; p < len(a); p++ {
						code := sgrCode(a[p])
						switch code {
						case "38":
							darkfg = fg38IsDark(a, p, lumaMax)
							p = skipColorPayload(a, p)
						case "48", "58":
							p = skipColorPayload(a, p)
						case "2":
							dim = true
						case "0":
							dim = false
							darkfg = false
						case "22":
							dim = false
						case "39":
							darkfg = false
						default:
							if ci, err := strconv.Atoi(code); err == nil {
								if (ci >= 30 && ci <= 37) || (ci >= 90 && ci <= 97) {
									darkfg = false
								}
							}
						}
					}
				}
				if j < n {
					i = j + 1
				} else {
					i++
				}
				continue
			}
			i++
			continue
		}
		if !dim && !darkfg {
			out = append(out, c)
		}
		i++
	}
	return string(out)
}

// stripPromptPrefix removes a leading prompt glyph (and an optional single
// following space) from a composer row.
func stripPromptPrefix(s string) string {
	glyphs := []string{"❯", "›", ">", "$", "%", "#"}
	for _, g := range glyphs {
		if strings.HasPrefix(s, g+" ") {
			return s[len(g)+1:]
		}
	}
	for _, g := range glyphs {
		if strings.HasPrefix(s, g) {
			return s[len(g):]
		}
	}
	return s
}

// classifyComposer is the verdict for one already-trimmed, border-stripped row.
func classifyComposer(bordered bool, content string) string {
	switch content {
	case "❯", "›":
		return "empty"
	case ">", "$", "%", "#":
		if bordered {
			return "empty"
		}
		return "unknown"
	}
	if content == "" {
		return "empty"
	}
	if idleRe.MatchString(content) {
		return "empty"
	}
	content = strings.TrimSpace(stripPromptPrefix(content))
	if content == "" {
		return "empty"
	}
	if idleRe.MatchString(content) {
		return "empty"
	}
	return "pending"
}

// borderShape reports whether a trimmed row looks like a bordered composer box
// (starts AND ends with the same vertical-bar glyph, with at least the two bars).
func borderShape(s string) bool {
	for _, b := range []string{"│", "┃", "|"} {
		if len(s) >= 2*len(b) && strings.HasPrefix(s, b) && strings.HasSuffix(s, b) {
			return true
		}
	}
	return false
}

// composerState classifies a pane's composer as empty|pending|unknown. Keeps the
// LAST (bottom-most) matching row so a stale decorative box earlier in scrollback
// can't outrank the live composer. Falls back to 'unknown' (never a safe inject
// target) on any read failure or when no composer row is recognised.
func composerState(pane string) string {
	cl := composerLines()
	fetch := cl
	if fetch < 200 {
		fetch = 200
	}
	raw := paneReadANSI(pane, fetch)
	if raw == "" {
		return "unknown"
	}
	lines := strings.Split(strings.TrimRight(raw, "\n"), "\n")
	if len(lines) > cl {
		lines = lines[len(lines)-cl:]
	}
	return classifyLines(lines, ghostLumaMax())
}

// bottomComposerRow finds the LAST (bottom-most) recognised composer row so a
// stale decorative box (or an ECHOED, already-submitted prompt sitting in
// scrollback ABOVE the live composer) can't outrank it, and returns its real
// (ghost-stripped, border-stripped) content.
func bottomComposerRow(lines []string, lumaMax int) (found, bordered bool, content string) {
	shape := ""
	rawMatch := ""
	for _, line := range lines {
		trimmed := strings.TrimSpace(stripANSI(line))
		if trimmed == "" {
			continue
		}
		switch {
		case borderShape(trimmed):
			shape = "bordered"
			rawMatch = line
		case bareRe.MatchString(trimmed):
			shape = "bare"
			rawMatch = line
		}
	}
	if shape == "" {
		return false, false, ""
	}
	content = strings.TrimSpace(stripGhost(rawMatch, lumaMax))
	if shape == "bordered" {
		bordered = true
		content = strings.NewReplacer("│", "", "┃", "", "|", "").Replace(content)
		content = strings.TrimSpace(content)
	}
	return true, bordered, content
}

// classifyLines is the pure core of composerState (no herdr I/O), split out for
// testing.
func classifyLines(lines []string, lumaMax int) string {
	found, bordered, content := bottomComposerRow(lines, lumaMax)
	if !found {
		return "unknown"
	}
	return classifyComposer(bordered, content)
}

// composerRowText returns the live composer row's real (ghost-stripped,
// prompt-glyph-stripped) content, or "" if no composer row is recognised. Used to
// confirm a just-typed prompt/marker was actually SUBMITTED (our text left the
// composer) rather than blindly re-pressing Enter and double-submitting.
func composerRowText(pane string) string {
	cl := composerLines()
	fetch := cl
	if fetch < 200 {
		fetch = 200
	}
	raw := paneReadANSI(pane, fetch)
	if raw == "" {
		return ""
	}
	lines := strings.Split(strings.TrimRight(raw, "\n"), "\n")
	if len(lines) > cl {
		lines = lines[len(lines)-cl:]
	}
	found, _, content := bottomComposerRow(lines, ghostLumaMax())
	if !found {
		return ""
	}
	return strings.TrimSpace(stripPromptPrefix(content))
}

// composerRowContains reports whether the live composer row still holds sub
// (i.e. our typed text has not yet been submitted). Ghost/suggestion text won't
// match a distinctive probe, so this never loops on a post-submit suggestion.
func composerRowContains(pane, sub string) bool {
	if sub == "" {
		return false
	}
	return strings.Contains(composerRowText(pane), sub)
}

// reportMarker builds the FIXED, terse report line typed into the patrón's pane.
// SECURITY: this is treated as a trusted system directive, so it carries NO
// sicario-controlled free text - only ids that pass validID survive. A tampered
// queue line (a same-UID sicario can reach the daemon) cannot smuggle prose,
// newlines, or instructions through.
func reportMarker(ids []string) string {
	seen := map[string]bool{}
	kept := make([]string, 0, len(ids))
	for _, id := range ids {
		if !validID(id) || seen[id] {
			continue
		}
		seen[id] = true
		kept = append(kept, id)
	}
	sort.Strings(kept)
	if len(kept) == 0 {
		return "[cartel] settled"
	}
	return "[cartel] settled: " + strings.Join(kept, ",")
}
