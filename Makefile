.PHONY: all deb clean

all: deb

deb:
	dpkg-buildpackage -rfakeroot -tc -sa -us -uc -I".directory" -I".git" -I".github"

clean:
	dh clean
