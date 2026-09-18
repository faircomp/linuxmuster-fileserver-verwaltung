.PHONY: all deb clean

all: deb

# Uniform build entry point of the faircomp packages (linuxmusterDEV,
# docs/paket-konventionen.md section 4). dpkg-buildpackage writes the .deb,
# .changes and .buildinfo one level above the source tree; -tc cleans the
# tree afterwards. debian/rules keeps debhelper from calling back into this
# Makefile. The bare -I keeps dpkg-source's default ignore list (.git,
# .gitignore, editor backups, ...); any -I<pattern> alone would replace it.
deb:
	dpkg-buildpackage -us -uc -tc -I -I".github"

clean:
	debian/rules clean
