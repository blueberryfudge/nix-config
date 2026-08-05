package main

import (
	"os"
)

func main() {
	pinSocket()
	ensureDirs()

	args := os.Args[1:]

	// Bare `cartel` (or `cartel --kind ... / --cwd ...`) seats the patrón in the
	// current repo - the one agent you talk to. Everything else is an explicit verb.
	var sub string
	if len(args) == 0 {
		sub = "patron"
	} else if len(args[0]) > 0 && args[0][0] == '-' {
		switch args[0] {
		case "-h", "--help":
			sub = "help"
			args = args[1:]
		default:
			sub = "patron" // options belong to patron; do NOT consume args[0]
		}
	} else {
		sub = args[0]
		args = args[1:]
	}

	switch sub {
	case "recruit", "up":
		cmdRecruit(args)
	case "patron", "captain":
		cmdPatron(args)
	case "lookout", "watch":
		cmdLookout(args)
	case "roster", "ls", "list":
		cmdRoster(args)
	case "status", "st":
		cmdStatus(args)
	case "wire", "log":
		cmdWire(args)
	case "report":
		cmdReport(args)
	case "order", "say":
		cmdOrder(args)
	case "await":
		cmdAwait(args)
	case "key", "signal":
		cmdKey(args)
	case "wait":
		cmdWait(args)
	case "focus":
		cmdFocus(args)
	case "bury", "silence", "down", "rm":
		cmdBury(args)
	case "daemon": // internal: the long-lived watcher (self-spawned)
		cmdDaemon(args)
	case "help", "-h", "--help":
		usage()
	default:
		usage()
		die("unknown command '%s'", sub)
	}
}
