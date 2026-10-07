# ArchiveCat — developer entry points.
#
# `make app` is the one that produces something you can double-click.
# All SwiftPM invocations go through Scripts/swift.sh so that every cache lives
# inside .build/ and the build works in sandboxes and CI.

SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help build test app run clean check-app distclean

help:
	@echo "ArchiveCat"
	@echo ""
	@echo "  make build     Build the library, the app and the tests (debug)"
	@echo "  make test      Run the engine test suite"
	@echo "  make app       Assemble dist/ArchiveCat.app (release)"
	@echo "  make run       Build and launch dist/ArchiveCat.app"
	@echo "  make clean     Remove build products"
	@echo "  make distclean Remove build products and dist/"

build:
	./Scripts/swift.sh build --build-tests

test:
	./Scripts/swift.sh test

app:
	./Scripts/build-app.sh

run: app
	open dist/ArchiveCat.app

clean:
	./Scripts/swift.sh package clean 2>/dev/null || rm -rf .build/scratch

distclean: clean
	rm -rf .build dist
