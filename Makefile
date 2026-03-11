PREFIX ?= /usr/local

build:
	swift build -c release

install: build
	install -d $(PREFIX)/bin
	install -d $(PREFIX)/libexec/overheard
	install .build/release/overheard $(PREFIX)/bin/overheard
	install recognize.py $(PREFIX)/libexec/overheard/recognize.py

uninstall:
	rm -f $(PREFIX)/bin/overheard
	rm -f $(PREFIX)/libexec/overheard/recognize.py

clean:
	swift package clean

.PHONY: build install uninstall clean
