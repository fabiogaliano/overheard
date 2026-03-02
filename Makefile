PREFIX ?= /usr/local

build:
	swift build -c release

install: build
	install -d $(PREFIX)/bin
	install .build/release/overheard $(PREFIX)/bin/overheard

uninstall:
	rm -f $(PREFIX)/bin/overheard

clean:
	swift package clean

.PHONY: build install uninstall clean
