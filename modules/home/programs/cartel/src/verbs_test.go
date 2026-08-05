package main

import (
	"strings"
	"testing"
)

func TestReportContract(t *testing.T) {
	c := reportContract("scout")
	if !strings.Contains(c, reportFile("scout")) {
		t.Fatalf("contract must carry the literal report path, got: %q", c)
	}
	if !strings.Contains(c, "3 short lines") {
		t.Fatalf("contract must cap the chat reply, got: %q", c)
	}
	if !strings.HasPrefix(c, "\n\n---\n") {
		t.Fatalf("contract must be separated from the brief, got prefix: %q", c[:10])
	}
}

func TestReportWriteRule(t *testing.T) {
	r := reportWriteRule()
	if !strings.HasSuffix(r, "/**") {
		t.Fatalf("rule must be a glob over the reports dir, got: %q", r)
	}
	if !strings.HasPrefix(r, "~/") && !strings.HasPrefix(r, "//") {
		t.Fatalf("rule must use ~ (home) or // (absolute) form, got: %q", r)
	}
}
