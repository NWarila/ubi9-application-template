// Minimal, deliberately useless example application for
// chiseled-application-template. Downstream repositories replace this with
// their own binary or vendor release artifact.
package main

import (
	"fmt"
	"os"
	"runtime"
)

func main() {
	fmt.Fprintf(
		os.Stdout,
		"hello from chiseled-application-template (built for %s/%s)\n",
		runtime.GOOS,
		runtime.GOARCH,
	)
}
