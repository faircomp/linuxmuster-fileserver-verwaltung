.PHONY: all deb clean

all: deb

# Uniform build entry point of the faircomp packages (linuxmusterDEV,
# docs/paket-konventionen.md section 4). dpkg-buildpackage writes the .deb,
# .changes and .buildinfo one level above the source tree; -tc cleans the
# tree afterwards. debian/rules keeps debhelper from calling back into this
# Makefile.
deb:
	dpkg-buildpackage -us -uc -tc -I".git" -I".github"

clean:
	debian/rules clean
